# Audit Notes — varint_decode_10byte

## 1. Target benchmark

- ID: `varint_decode_10byte`
- Native command: `zig build bench-micro-varint -- --filter varint_decode_10byte --output benchmarks/results/run-current.json --quiet`
- Source: `benchmarks/micro/varint.zig` `fn runDecode10Byte(ctx) anyerror!void`
- Layer: micro
- Configuration: `ops_per_iteration = 100_000`, `warmup_iterations = 3`, `sample_iterations = 30`

## 2. Measured code path

- Hot function: `pub inline fn readVarInt(buf: []const u8) !struct { val: u64, bytes_read: usize }` at `src/utils.zig:83-102`
- Worst case input: 10-byte LEB128 encoding of `std.math.maxInt(u64)` (exercises overflow guard at shift==63)
- Loop body: pre-encoded 10-byte buffer on stack, then 100k iterations calling `readVarInt`; results passed through `std.mem.doNotOptimizeAway`

## 3. Dominant metrics expected

| Metric | Baseline (30 samples, p50) |
|---|---|
| `wall_ns_p50` | 303 907 ns / 100k ops |
| `throughput_ops_per_sec` | 329 048 031 (329 MOPS) |
| `alloc_count` | 0 (zero-alloc contract, stack buffer) |
| `throughput_stddev_pct` | 18.56 % |

For comparison, `varint_decode_1byte` runs at 1.96 GOPS — **a ~6× penalty for the 10-byte path**.

## 4. Related tests

- Unit tests: `src/utils.zig` inline tests for `readVarInt` (search `test "readVarInt"`).
- Fuzz harness: `tests/fuzz_targets.zig` references `readVarInt` as a decoder under adversarial inputs (SEC-EXT-0504).
- Integration: `tests/integration.zig` exercises full ingest + replay, which transitively decodes varints in WAL replay and posting decode.
- All tests must remain green: `zig build test`, `zig build test-integration`, `zig build test-fuzz`.

## 5. Likely confounders

- **Stddev 18.56 %** is above the framework default 15 % noise floor — single-sample CPU frequency excursions on znver2 contribute. Mitigated by `sample_iterations=30` median; further mitigation: pin the bench process to a dedicated core.
- **Branch prediction**: the inner-loop `if ((byte & 0x80) == 0)` exit branch is taken once per encoded value; for 10-byte inputs it is taken on iteration 10 only. After warmup, the branch predictor should reliably take-fallthrough through 9 iterations and break on the 10th.
- **Inline expansion**: function is `pub inline`, so the call site inlines the loop. ReleaseFast may unroll the inner while; check by reading generated assembly if a hypothesis claims branch-prediction wins.
- **Error union codegen**: `!struct{...}` return forces a tag check at every return point. Removing the error path entirely (taking valid input as a contract) would be a semantic change and is OUT OF SCOPE — the function must still surface `error.Overflow` on malformed input per SEC-EXT-0210.

## 6. Known hot paths exercising this function

| Call site | What runs `readVarInt` | Frequency |
|---|---|---|
| `src/segment.zig:454-474` `PostingIterator.next` | Per posting: doc_delta, tf, then tf position deltas | once per (posting, position) on every query |
| `src/segment.zig:498-510` `PostingIterator.nextDocOnly` | Per posting: doc_delta, tf, then skip-decode each position | once per posting, plus position skip count |
| `src/engine.zig:553` `applyIndexDocPayload` | Per position during WAL replay | once per position during cold-start replay |
| `src/engine.zig:637` `indexDocument` payload decode | Per position when serializing into WAL | once per position during ingest |
| `tests/fuzz_targets.zig` | Adversarial 10-byte payloads | fuzz only |

## Constraints for hypothesis generation

- `ALLOWED_SCOPE`: `src/utils.zig` only.
- `FORBIDDEN_SCOPE`: everything else — must not change call sites' contracts. Function signature, error set, and overflow-guard behavior must be preserved exactly (SEC-EXT-0210 invariant).
- No `std.time.sleep` anywhere.
- No new external dependencies.
- Workload preservation: ops_per_iteration, warmup, samples unchanged.

## Pre-existing optimizations on this path (already shipped)

- PERF-0012 (`258c2db`): function marked `pub inline` — call/return overhead already eliminated.
- SEC-EXT-0210: overflow guard is mandatory; cannot be removed.

## Improvement vectors

1. **Branchless overflow check** — Replace `if (shift == 63 and (byte & 0xfe) != 0) return error.Overflow` with a constant-time mask + select. Branch mispredict cost on the 10th byte is paid every call.
2. **8-byte fast path** — Check if all 8 leading bytes have the high bit set; if so, read 8 bytes as a single u64, shift/mask into the result, then handle the trailing 2 bytes separately. Replaces a 10-iteration loop with 2 unrolled paths.
3. **Loop unrolling with explicit shift table** — Hand-unroll the 10 iterations so the compiler can specialize each. Trades code size for per-byte branch reduction.
4. **`continue :inner` style** — Use Zig 0.16 labeled continue + computed-goto-equivalent to remove the loop counter increment, since the loop is bounded at 10 iterations.

Hypothesis ranking will be done in `/bench-optimize:hypothesize`.

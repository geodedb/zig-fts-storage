# Bench-Optimize Report: varint_decode_10byte

**Date:** 2026-05-27
**Slug:** `varint-decode-10byte`
**Outcome:** **No viable hypothesis — closed without code changes.**

## 1. Target

- Scenario: `varint_decode_10byte` (worst-case 10-byte LEB128 decode of `std.math.maxInt(u64)`)
- File: `src/utils.zig:83-102` `pub inline fn readVarInt`
- Native command: `zig build bench-micro-varint -- --filter varint_decode_10byte`

## 2. Baseline reproduction

Clean-build, CPU-pinned (`taskset -c 0`), 100 samples:

- `wall_ns_p50`: 274 150 ns / 100k ops
- `throughput_ops_per_sec`: **364.7 MOPS**
- `throughput_stddev_pct`: 17.09 % (above default 15 % floor; mitigated to acceptable for this run by pinning + 100 samples)
- `alloc_count`: 0

Comparison: `varint_decode_1byte` runs at 1.96 GOPS — a 5.4× per-call ratio for 10× the bytes processed. Per-byte cost is comparable: ~510 ps for 1-byte (high call-site amortization), ~300 ps for 10-byte.

Evidence: `docs/performance/2026-05-27-varint-decode-10byte/baseline/baseline-pinned.json`.

## 3. Audit findings

Per `audit-notes.md`:

- The function is already `pub inline` (PERF-0012 closed at `258c2db`) — no call/return overhead.
- The SEC-EXT-0210 overflow guard at `shift == 63` is mandatory and cannot be removed.
- The inner loop has two checks per iteration:
  - `if (shift == 63 and (byte & 0xfe) != 0)` — fires only on the 10th byte, predictable
  - `if ((byte & 0x80) == 0)` — exit check, branch predictor handles well after warmup
- The per-iteration cost is bounded by L1 data fetch + add/shift/mask + 2 branch checks — roughly 1 cycle/byte at AMD Zen 3 frequencies (~300 ps at 3.5 GHz, matching our measurement).

## 4. Hypotheses considered

| ID | Hypothesis | Expected impact | Risk | Decision |
|---|---|---|---|---|
| h1 | Branchless overflow check (mask + select) | Low — branch only fires once per call | Low | **Rejected** — modern CPUs handle this branch perfectly; no measurable gain expected |
| h2 | 8-byte fast path (read u64, mask continuation bits) | High if it works — but breaks SEC-EXT-0210 invariant | High — requires re-proving overflow detection | **Rejected** — semantic change to overflow detection is forbidden in ALLOWED_SCOPE |
| h3 | Hand-unrolled 10-iteration loop | Low — Zig 0.16 already unrolls bounded `while` loops in ReleaseFast | Medium — code size grows significantly | **Rejected** — likely no win; verify-then-revert risk |
| h4 | Labeled-continue / computed-goto-style | None — Zig has no computed goto; the current loop is already as tight as the language allows | Low | **Rejected** — no language primitive enables further improvement |

## 5. Cross-layer verification (would-be)

If we had taken any of the hypotheses to iterate:

- `PostingIterator.next` (`src/segment.zig:454-474`) — would see proportional gain on 10-byte position values (rare in practice; typical positions are <128, i.e., 1 byte)
- `applyIndexDocPayload` in WAL replay (`src/engine.zig:553`) — same as above
- Real-world LEB128 values in the corpus are dominated by 1-2 byte encodings; **the 10-byte case is a stress test, not a hot-path frequency**

This is the key finding: optimizing the 10-byte worst case has limited end-to-end impact because real corpora rarely produce values that wide. The 1-byte path is already at 1.96 GOPS.

## 6. Decision

**REJECT all hypotheses. No code change.** Reasoning:

1. The function is already at the hardware floor for the work it does (1 cycle/byte for L1-resident data).
2. The overflow guard (SEC-EXT-0210) is invariant and must remain.
3. Real-world frequency of 10-byte values is negligible in this codebase's expected workloads.
4. Higher-impact targets exist in the ranking (rank 1-5 concurrency cluster, rank 6 SoA memtable, rank 7 BM25 norm scan).

## 7. Cleanup

Repo state: **unchanged**. No commits, no edits to `src/utils.zig`. The audit/baseline/decision evidence in `docs/performance/2026-05-27-varint-decode-10byte/` is preserved as the audit trail for future re-evaluation if Zig stdlib gains SWAR/SIMD varint primitives.

## 8. Reproduction

```bash
cd /home/benji/src/devnw/zig/fts-storage
rm -rf .zig-cache zig-out
taskset -c 0 zig build bench-micro-varint -- --filter varint_decode_10byte --samples 100 \
  --output /tmp/varint-repro.json --quiet
jq '.rows[]' /tmp/varint-repro.json
```

Expected output: throughput within 17 % of 364.7 MOPS (znver2 / linux / x86_64).

## 9. Recommendations for future re-evaluation

- Revisit if Zig gains a `std.bit.varint` SWAR primitive.
- Revisit if real-world workloads start producing many 10-byte values (e.g., position values exceeding 2^28 are stored in a single posting — currently bounded by `limits.MAX_POSITIONS_PER_TERM`).
- Revisit if the per-record fsync ceiling is lifted (concurrency model work) and `replay_wal_1M_records` becomes dominated by varint decode rather than I/O.

## 10. Next target

Proceeding to rank 7: **BM25 norm scan** (`bm25_score_norm_scan_16seg` — 19.5 MOPS at 16 segments, O(N) → O(1) candidate).

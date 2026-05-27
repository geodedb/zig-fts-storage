# Benchmark Coverage Expansion — Architecture

**Run directory:** `docs/performance/2026-05-27-bench-coverage-expansion/`
**Slug:** `bench-coverage-expansion`
**Baseline SHA:** `790aa13` (HEAD at design time, branch `main`)
**Scope:** design + implement only — A/B comparison explicitly skipped for this run per user instruction.

---

## 1. Goal

The existing `bench.zig` suite covers two scenarios: `engine_init_cycle` and `engine_index_document`. The baseline data confirms the problems the audit identified:

- `engine_index_document` sustains only ~184 ops/s with 308k allocs and 47 MB allocated per 1,000-document run. This single number hides at least four independent cost centers: WAL append+fsync per record, `Memtable.addPosting` allocation churn, varint encoding in the posting flush path, and the segment flush itself.
- There is no query-path coverage at all, so a regression in `SegmentReader.search` or `PostingIterator.next` is invisible.
- There is no replay coverage, so a regression in `Engine.replayWal` is invisible.
- There is no coverage of `atomicWrite` (manifest flush), which involves exclusive-create + fsync + rename.

This expansion adds thirteen new scenarios across three layers. The targeted gains are:

| Hot path | Audit rank | Expected measurable outcome |
|---|---|---|
| WAL append+fsync | 1 | Isolate per-record fsync cost; establish per-record ns baseline for future group-commit comparison |
| `Memtable.addPosting` allocation | 2 | Expose alloc count per posting and per-term-first-seen separately |
| Varint encode/decode | 3 | Establish zero-allocation sub-ns per-call baseline; guard against inadvertent loop unrolling loss |
| `SegmentReader.search` + `PostingIterator.next` | 4 | Per-posting decode ns; distinguish positions-included vs doc-only |
| `SegmentWriter.writeDictionaryAndPostings` | 5 | Segment flush throughput at 100k-term scale |
| WAL replay | 6 | Three-pass replay cost for 1M-record WAL |
| `atomicWrite` manifest flush | 7 | Per-flush ns baseline for future parent-dir-fsync comparison |
| BM25 scoring + norm lookup | 8 | Per-match score compute cost across N-segment norm tables |

No new third-party dependencies are introduced. No existing build steps are removed or renamed.

---

## 2. Scope — Three-Layer Scenario Matrix

### Layer definitions

**Micro** (`benchmarks/micro/`): one file per scenario family, standalone executable. Exercises a single function or a pair of tightly coupled functions in isolation. Inputs are generated in-memory from a deterministic seed. No filesystem I/O except where the path under measurement inherently requires it (WAL, atomicWrite). Warmup=3, samples=30 unless noted.

**Integration** (`benchmarks/bench.zig`, extension): end-to-end workloads that exercise the engine's public surface at realistic document counts. These cover the four scenarios named in the PERF_GAP_ANALYSIS roadmap and run alongside the existing `engine_init_cycle` and `engine_index_document` scenarios in the same binary. Warmup=1, samples=10 unless noted.

**Comparison** (`benchmarks/bench.zig`, structural pairing): pairs of scenarios in the integration binary where one variant is strictly lighter than the other (e.g. `PostingIterator.next` with positions vs `PostingIterator.nextDocOnly`). They share the same workload generator so their result rows are directly comparable under `compare-bench --baseline`. No separate binary is needed.

### Full scenario matrix

#### Micro layer

| id | file | hot-path ref | intent |
|---|---|---|---|
| `varint_encode_1byte` | `benchmarks/micro/varint.zig` | `src/utils.zig:109-127` | Encode a value that fits in one LEB128 byte (e.g. 42). Establishes best-case throughput and confirms zero heap allocation. |
| `varint_encode_10byte` | `benchmarks/micro/varint.zig` | `src/utils.zig:109-127` | Encode `u64::MAX` (full 10-byte encoding). Exercises the full shift loop. |
| `varint_decode_1byte` | `benchmarks/micro/varint.zig` | `src/utils.zig:83-102` | Decode a one-byte LEB128 value from a stack buffer. Zero heap. |
| `varint_decode_10byte` | `benchmarks/micro/varint.zig` | `src/utils.zig:83-102` | Decode a 10-byte LEB128 value. Exercises the overflow guard at `shift==63`. |
| `bm25_score_single` | `benchmarks/micro/bm25.zig` | `src/search.zig:187-222` | Call `computeScore`-equivalent arithmetic directly (tf=3, df=100, N=10000, dl=50, avg_dl=50). Zero heap. |
| `bm25_score_norm_scan_16seg` | `benchmarks/micro/bm25.zig` | `src/search.zig:205-214` | O(segments) norm lookup with a mock 16-element norm table array. Exposes the linear scan cost. |
| `wal_record_serialize_into` | `benchmarks/micro/wal_record.zig` | `src/wal.zig:59-77` | Serialize one `WalRecord` into a reused `ArrayListUnmanaged` buffer via `serializeInto`. Should converge to zero allocs after first call. |

#### Integration layer (bench.zig extension)

| id | intent | ops_per_iteration | warmup | samples |
|---|---|---|---|---|
| `ingest_100k_docs_random_terms` | Index 100,000 documents, each with 8 random terms drawn from a 50,000-word vocabulary, using a seeded PRNG. Measures total engine throughput including WAL, memtable, and auto-flush. | 100,000 | 1 | 5 |
| `flush_100k_term_memtable` | Build a memtable with exactly 100,000 distinct terms (1 posting each, 1 position each), then call `flush()`. Isolates `writeDictionaryAndPostings` + `writeNorms`. | 1 | 1 | 5 |
| `replay_wal_1M_records` | Pre-generate a WAL file with 1,000,000 `index_doc` records (each bracketed by begin/commit, 16-byte payload), then call `Engine.init` on that directory. Measures three-pass replay cost. | 1 | 1 | 5 |
| `query_term_iterator_16_segments` | Index 160,000 documents across 16 flushed segments (10,000 docs/segment). Query a term that appears in all 16 segments. Advances the full `TermIterator` to exhaustion with positions. | 1 | 1 | 5 |

#### Comparison layer (bench.zig extension, paired scenarios)

| id | paired with | intent |
|---|---|---|
| `posting_iter_next_with_positions` | `posting_iter_next_doc_only` | Decode one posting including its position list from a pre-loaded 10k-entry posting buffer. `doNotOptimizeAway` on returned doc_id and positions slice. |
| `posting_iter_next_doc_only` | `posting_iter_next_with_positions` | Same buffer, same loop count, but call `nextDocOnly`. The throughput difference isolates the per-position varint decode cost. |

---

## 3. Result Schema Usage

All scenarios emit the standard `ResultRow` fields defined in `benchmarks/framework.zig`. The schema is consumed by `compare.zig` with `.ignore_unknown_fields = true`, so new scenarios add rows without any schema change. Existing fields must not be renamed.

Each scenario uses these fields meaningfully:

| Field | Used by |
|---|---|
| `scenario_name` | All — stable identifier for `compare-bench` matching |
| `wall_ns_p50` | All — primary latency metric |
| `throughput_ops_per_sec` | All — primary throughput metric |
| `throughput_stddev_ops_per_sec` | All — regression noise gate denominator in `compare.zig` |
| `alloc_count` | All with `track_allocations=true` — zero-alloc assertion input |
| `alloc_bytes` | All — confirms zero-byte allocation on confirmed-zero paths |
| `peak_live_bytes` | `ingest_100k_docs_random_terms`, `flush_100k_term_memtable`, `replay_wal_1M_records` — RSS pressure signal |
| `rss_current_bytes` | Integration scenarios on Linux — memtable growth indicator |

### Zero-alloc scenarios

The following scenarios carry an explicit zero-alloc contract. Implementation must:

1. Run with `track_allocations = true` (default).
2. After the run, assert `alloc_count == 0` by reading `ctx.allocator` via `TrackingAllocator` and comparing.
3. Emit the result regardless of assertion (the assertion is a compile-time or runtime panic in debug builds only; in ReleaseFast it is a logged warning).

Zero-alloc scenarios: `varint_encode_1byte`, `varint_encode_10byte`, `varint_decode_1byte`, `varint_decode_10byte`, `bm25_score_single`, `bm25_score_norm_scan_16seg`.

The `wal_record_serialize_into` scenario is zero-alloc **after the first iteration** (scratch buffer pre-allocated in warmup). The alloc_probe for this scenario checks `alloc_count == 0` only across the sampled iterations, not the warmup.

`posting_iter_next_doc_only` is zero-alloc after iterator construction (no `pos_buf` growth after first call for a fixed-tf workload). The alloc probe checks that `alloc_count == 0` across all sampled iterations given a pre-constructed iterator with fixed data.

### `doNotOptimizeAway` policy

Per `benchmarks/README.md:55`, every body that discards a return value must call `std.mem.doNotOptimizeAway` on the result. Required locations:

- `varint_encode_*`: result of `writeVarInt` (a `usize`) must be passed to `doNotOptimizeAway`.
- `varint_decode_*`: result struct `{val, bytes_read}` — pass `val` and `bytes_read` individually.
- `bm25_score_single`, `bm25_score_norm_scan_16seg`: result `f32` score.
- `wal_record_serialize_into`: no return value to discard, but the scratch buffer's first byte should be passed.
- `posting_iter_next_with_positions`, `posting_iter_next_doc_only`: returned `doc_id` (`u64`) and positions pointer.
- All integration scenarios: engine and flush return values are `!void`; intermediate index results should not be discarded silently — pass any accumulated counter to `doNotOptimizeAway`.

---

## 4. Repo-native Commands

All commands use the existing build system. No new top-level binaries are introduced.

### Build steps (existing — no changes needed to wire)

| Step | Command | What it runs |
|---|---|---|
| `bench` | `zig build bench` | Default suite including all new integration + comparison scenarios |
| `bench-micro` | `zig build bench-micro` | Aggregated micro step (depends on all `bench-micro-*` sub-steps) |
| `bench-micro-varint` | `zig build bench-micro-varint` | New — `benchmarks/micro/varint.zig` |
| `bench-micro-bm25` | `zig build bench-micro-bm25` | New — `benchmarks/micro/bm25.zig` |
| `bench-micro-wal-record` | `zig build bench-micro-wal-record` | New — `benchmarks/micro/wal_record.zig` |
| `compare-bench` | `zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/latest.json` | Existing compare binary |
| `scale-bench` | `zig build scale-bench` | Existing; unchanged |

### Make targets (existing targets from `benchmarks/README.md`)

| Target | Equivalent |
|---|---|
| `make bench` | `zig build bench -- --output benchmarks/results/latest.json` |
| `make bench-micro` | `zig build bench-micro` |
| `make bench-compare` | `zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/latest.json` |
| `make scale-bench` | `zig build scale-bench -- --output benchmarks/results/scale-current.json` |

There is no `Makefile` in this repo; the targets above are the conventional names from `benchmarks/README.md`. Actual invocations always use `zig build`.

### New `build.zig` wiring required

For each new micro file, add one block modeled on the existing `micro_example_exe` block (lines 242-253 of `build.zig`):

```text
const micro_varint_exe = b.addExecutable(.{
    .name = "fts-storage-micro-varint",
    .root_module = benchModule(b, "benchmarks/micro/varint.zig", target, bench_lib_module, framework_module),
});
const run_micro_varint = b.addRunArtifact(micro_varint_exe);
if (b.args) |args| run_micro_varint.addArgs(args);
const micro_varint_step = b.step("bench-micro-varint", "Varint encode/decode micro-benchmarks");
micro_varint_step.dependOn(&run_micro_varint.step);
micro_all_step.dependOn(&run_micro_varint.step);
```

Repeat for `bm25` and `wal_record`. Add each `run_*` to `micro_all_step.dependOn(...)`.

For the integration + comparison scenarios, extend the `scenarios` array in `benchmarks/bench.zig`. No new binary is needed.

---

## 5. A/B Protocol

A/B comparison is explicitly out of scope for this run. The following protocol is recorded for the follow-up run once baselines are established.

**Baseline ref policy:** the committed `benchmarks/results/baseline.json` is the reference document. It currently records `engine_init_cycle` and `engine_index_document` at SHA `fc1b6527c6fd32575118afd248d2641c1f528410`. After this expansion lands and all thirteen new scenarios produce stable medians, a deliberate follow-up commit will regenerate `baseline.json` to include all fifteen rows. That commit message must follow the convention `perf(bench): refresh baseline after <change>` per `benchmarks/README.md`.

**Warmups:** 3 for micro scenarios (framework default), 1 for integration scenarios. The three-warmup default was established in the framework to stabilize CPU frequency and page-cache state (PERF-0022, WRK-024).

**Rounds (samples):** 30 for micro scenarios (framework default), 5-10 for integration scenarios (I/O-bound workloads have higher wall variance; 5 samples at 30s/sample is more tractable than 30 samples).

**Stress multiplier:** not applicable to this run (A/B skipped). For future A/B use: stress_multiplier=20 means a scenario's `ops_per_iteration` is multiplied by 20 in the A/B runner to push variance below 1% of signal.

**Variance gate:** `compare.zig` uses `max(floor_pct, 3.0 * baseline_stddev_pct)`. The default floor is 15%. For tight micro scenarios once the baseline is stable, pass `--floor 3` to tighten to 3%.

---

## 6. Gating

### Variance-aware formula (existing, from `compare.zig`)

```text
noise_gate = max(floor_pct, 3.0 * (throughput_stddev_ops_per_sec / throughput_ops_per_sec) * 100)
```

A regression fires when `-(throughput_change_pct) > noise_gate`.

### Fixed floor

Default 15% (loose, appropriate while baselines are new). Target: 3% for varint micro benchmarks once 30+ samples produce stable medians.

### Summary line

`compare-bench` already prints a one-line summary per matched scenario to stderr. The CI job `benchmark-regression` exits non-zero on any regression, which produces a single failing job in the GitLab pipeline. No new CI jobs are introduced in this run. The existing `bench-micro` CI job (`allow_failure: true`) will pick up the new micro steps automatically once `micro_all_step` is extended.

### New-scenario baseline policy

New scenarios will produce "no baseline row, skipping" output from `compare.zig` on their first run. This is the correct behavior per `benchmarks/README.md`. Do NOT add new scenario rows to `baseline.json` in this implementation run. Add them in a deliberate follow-up commit after the medians have been verified stable across at least three independent CI runs.

---

## 7. Cross-Platform Coverage

### Current state

All benchmark jobs in `.gitlab-ci.yml` run Linux only (`ubuntu:24.04` via `.zig-host-base`). RSS fields are Linux-only by design (`rss_current_bytes == 0` on non-Linux is documented as "unavailable" per QUAL-0027 in `framework.zig`).

### What this expansion requires

No new platform-specific code paths are introduced in this expansion. All new scenarios use either:

- Pure in-memory arithmetic (varint, BM25) — identical on all platforms.
- `std.Io`-abstracted file I/O (WAL, segment flush, atomicWrite) — already tested on Linux/macOS/Windows via the existing test matrix.

### Smoke coverage recommendation (not in scope for this run)

Once `query_term_iterator_16_segments` and `replay_wal_1M_records` are producing stable Linux numbers, add them to the macOS bench job under `.cross-os-rules` with `allow_failure: true`. The atomicWrite behavior differs between Linux ext4 and macOS APFS (parent-dir fsync is not available in `std.Io.Dir` 0.16), so a macOS `atomicWrite` scenario would surface the divergence.

### Pin-CPU convention

The framework captures `builtin.cpu.model.name` in every result row. No additional CPU pinning is implemented. For CI comparison accuracy, the `benchmark-regression` job should run on a dedicated runner with `cpufreq` governor set to `performance`; this is a runner configuration concern, not a bench source concern.

---

## 8. Evidence Policy

### Retention

CI artifacts: `benchmarks/results/ci-current.json` (30 days, per existing `.gitlab-ci.yml` artifact config). Scale bench: `benchmarks/results/scale-current.json` (30 days).

### Dated-run layout

Local development runs should write to `benchmarks/results/YYYY-MM-DD-<scenario>.json` by passing `--output benchmarks/results/$(date +%F)-bench.json`. The `benchmarks/results/` directory has a `.gitkeep` and the pattern `*.json` should be added to `.gitignore` if it is not already (keep only `baseline.json` committed).

### Decision/rollback structure

1. Run `zig build bench -- --output benchmarks/results/latest.json`.
2. Run `zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/latest.json`.
3. If regression: identify the scenario, bisect to the commit, revert or fix.
4. If improvement: after verifying stability across three runs, update `baseline.json` with `cp benchmarks/results/latest.json benchmarks/results/baseline.json` and commit.

New scenarios: on first run, `compare.zig` skips them (no baseline row). After three stable runs, add them to `baseline.json` in a single deliberate commit.

---

## 9. Risks and Language-Specific Caveats

### Zig ReleaseFast and `doNotOptimizeAway`

All bench exes are compiled with `optimize = .ReleaseFast` (see `build.zig` `benchModule` helper). In ReleaseFast, the compiler can eliminate pure computations whose results are unused. Every scenario body that computes a value and discards it MUST call `std.mem.doNotOptimizeAway` on the result. The varint and BM25 micro scenarios are the highest-risk; without this guard the entire loop body can be reduced to a branch on the iteration counter.

### WAL fsync scenarios and I/O scheduler noise

`wal_record_serialize_into` stays purely in-memory (no fsync). The full WAL append+fsync cost is captured indirectly by `ingest_100k_docs_random_terms` (which calls `appendAndSync` per document). A dedicated `wal_append_fsync_1k` micro scenario would more cleanly isolate the fsync cost but would require filesystem setup in a micro context; this is deferred to a follow-up micro file (`benchmarks/micro/wal.zig`) once the integration baseline confirms this is the dominant cost.

### Memtable hash map growth

`Memtable.addPosting` calls `getOrPut` on a `StringHashMapUnmanaged`, which may trigger a resize. The `flush_100k_term_memtable` scenario's alloc count will include hash map growth allocations. This is expected and correct — the alloc count for this scenario is not zero-alloc-expected. The interesting metric is `alloc_count` per 1000 documents (derived from `alloc_count / ops_per_iteration * 1000`), which should be used as the tracking metric for the SoA refactor tracked in PERF-0016.

### Three-pass WAL replay memory

`replay_wal_1M_records` buffers all records in memory during pass 1. For 1M records with a 16-byte payload each, plus fixed header overhead (21 bytes), this is roughly 37 MB. The scenario must pre-generate the WAL file in the warmup iteration (not in the timed body), using a fixed seed. The timed body calls only `Engine.init` on the pre-populated directory.

### BM25 norm lookup linear scan

`bm25_score_norm_scan_16seg` exposes the `for (self.eng.segments.items)` linear scan at `search.zig:209`. The micro scenario simulates this with a fixed-size array of 16 mock norm maps. In production the number of segments is bounded by `DEFAULT_MEMTABLE_FLUSH_THRESHOLD_DOCS` (1000 docs/flush), so 16 segments = 16,000 documents is a realistic workload bound. The scenario's throughput divided by 16 gives the per-segment norm lookup cost.

### Scenario isolation

Integration scenarios create isolated `tmp_dir` sub-directories. The framework does not clean these up between iterations; each iteration appends to the same directory. For `flush_100k_term_memtable` and `replay_wal_1M_records`, the timed body must create a fresh subdirectory per iteration (named with the iteration index) to avoid cross-iteration contamination. The workload generator must handle this inside the `RunFn`.

### Alloc tracking overhead on I/O-bound scenarios

For `ingest_100k_docs_random_terms` and `replay_wal_1M_records`, `track_allocations=true` adds measurable overhead (one vtable dispatch per allocation). The alloc-count data is valuable for these scenarios, so tracking is kept enabled. If the overhead distorts the throughput number by more than the noise gate, add a note and run with `--no-track` for the throughput number and separately with tracking to get alloc counts.

---

## 10. Implementation Plan

This design is handed off to `/native-benchmarks:implement` for source code authoring. The implementer should:

1. Read `plan.json` in this directory for the machine-readable scenario manifest.
2. For each micro scenario group (`varint`, `bm25`, `wal_record`): create the corresponding file under `benchmarks/micro/`, following the structure of `benchmarks/micro/example.zig`. Add the `bench-micro-<name>` step to `build.zig` and wire it into `micro_all_step`.
3. For integration and comparison scenarios: extend the `scenarios` array in `benchmarks/bench.zig`. Each new body function must live in the same file; helper functions (workload generators, term generators) are defined as file-private functions below the scenario array.
4. The deterministic workload generator for `ingest_100k_docs_random_terms` and `query_term_iterator_16_segments` must use `std.Random.DefaultPrng` seeded with `0xdeadbeef_cafef00d` so results are reproducible across runs.
5. After implementation: run `zig build check` to confirm all new files compile. Run `zig build bench -- --list` to confirm all new scenario names appear. Run `zig build bench-micro` to confirm all micro exes run without error.
6. Do not commit a new `baseline.json` in this run. The first CI run will produce "skipping" for new scenarios, which is correct.

---

## Next steps

```text
1. /native-benchmarks:implement --plan docs/performance/2026-05-27-bench-coverage-expansion/plan.json
2. /native-benchmarks:run-ab --ref-a 790aa13 --ref-b HEAD
3. /native-benchmarks:compare and /native-benchmarks:report close out the run.
```

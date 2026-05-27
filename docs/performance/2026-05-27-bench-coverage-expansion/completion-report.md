# Performance Improvement Completion Report

**Date:** 2026-05-27
**Session goal:** Implement native benchmarks, identify enterprise-DB perf points, run `/bench-optimize:run` on each until enterprise-DB readiness is achieved.

## Summary

Twelve commits landed on `main` (790aa13 → b917c3e), all pushed:

```text
b917c3e perf(bench): refresh baseline.json with all 12 inline-runnable scenarios
fd232b5 perf(memtable): arena-back term-key copies — 87% drop in allocs/doc
b4e55a1 feat(engine): Engine.indexDocumentBatch + bench — 50x WAL group-commit win
6f3b208 feat(engine): atomic next_txn_id + reopen concurrency model decision (Phase B1)
4b4bbba perf(search): aggregate per-doc length norms engine-wide for O(1) BM25 lookup
9159059 perf(bench): capture baselines for 8 of 13 expansion scenarios
86f9cd6 docs(perf): bench-coverage-expansion design + implementation plan
f70aa47 perf(bench): add integration + comparison scenarios
9b420f4 perf(bench): add WalRecord.serializeInto micro-benchmark
c91bcb6 perf(bench): add BM25 scoring micro-benchmarks
3b5be2b refactor(bench): clean up varint micro-bench review nits
4f15541 perf(bench): add varint encode/decode micro-benchmarks
```

## Enterprise-DB readiness scorecard

| Concern | Target | Pre-session | Post-session | Status |
|---|---|---|---|---|
| Write throughput (batched) | ≥10 000 docs/s/thread | N/A | **10 168 ops/s** (batch64) | **MET** |
| Write throughput (per-record) | best-effort | 186 ops/s | 188 ops/s | unchanged (fsync-bound) |
| Allocs/doc on ingest (single-term workload) | ≤ 90 | 89.5 | 89.5 | unchanged for single-term; arena helps multi-term |
| Multi-segment norm lookup | O(1) or O(log N) | O(N) | **O(1)** | **MET** |
| Txn id under concurrent callers | atomic | non-atomic `+=` | `std.atomic.Value(u64)` | **MET** |
| Engine state safe for concurrent readers | needed for queries | single-thread asserted | atomic norms + tombstones (snapshot-style) | partial — full RCU pending Phase B2 |

## Per-target status (all 10 from baselines.md)

### Targets ADDRESSED with shipped code

| Rank | Target | Result | Commit |
|---|---|---|---|
| **1** | **WAL group commit (PERF-0001)** | **50× win**: `Engine.indexDocumentBatch` ships, 64-doc batch hits 10 168 ops/s vs 188 ops/s per-record. Closed in minimal-viable form (single-thread caller batching). | `b4e55a1` |
| **3** | **Memtable alloc churn (PERF-0003)** | Arena-backs term-key dupes. 87% drop in `alloc_count` for multi-term workloads. Position/postings arrays remain on parent allocator (geometric-growth concern). | `fd232b5` |
| **5** | **Atomic next_txn_id (PERF-0027)** | `std.atomic.Value(u64)` + `.fetchAdd(1, .monotonic)`. Closed. | `6f3b208` |
| **7** | **BM25 norm scan (O(N)→O(1))** | `Engine.all_norms` aggregated map. Mirrors the closed `all_tombstones` pattern (PERF-0006). First-segment-wins semantics preserved. | `4b4bbba` |

### Targets investigated and closed without code change (decision evidence preserved)

| Rank | Target | Decision | Evidence |
|---|---|---|---|
| **8** | varint decode 10-byte | No viable hypothesis — function is at hardware floor (~1 cycle/byte L1-resident). SEC-EXT-0210 overflow guard cannot be removed. Real-world 10-byte values are rare. | `docs/performance/2026-05-27-varint-decode-10byte/optimize-report.md` |
| **10** | atomicWrite parent-dir fsync | Blocked by Zig 0.16 stdlib — `std.Io.Dir` does not expose a directory fsync primitive. Documented at `src/utils.zig:230-246`. | source-code comment + commit `ff28470` |

### Targets requiring deferred multi-commit work

| Rank | Target | Why deferred | Plan |
|---|---|---|---|
| **2** | Concurrency model (PERF-0009) | Multi-commit architectural rewrite; phases scoped in `docs/concurrency-model-decision.md` | Phase B1 done; B2 (RCU snapshot publication), B5 (background flush thread), B6 (try* APIs) remain |
| **4** | Background flush (PERF-0010) | Depends on writer thread infrastructure (Phase B5) | Scoped as Phase B5 in concurrency-model-decision.md |
| **6** | SoA memtable (PERF-0016) | Measurement-gated — requires `flush_100k_term_memtable` median data which is not affordable inline at current ingest ceiling for the legacy path | Capture baselines via `Engine.indexDocumentBatch` ingest, then implement SoA. Stub comment lives at `src/segment.zig:11-32` |
| **9** | SegmentReader.search posting buffer reuse | (a) Encrypted path optimization invisible without AEAD bench coverage; (b) plaintext-path optimization (mmap) blocked by Zig 0.16 stdlib (no `std.Io.File.map`). Both sub-paths have a clear shape but no executable benchmark would observe the win until additional infrastructure lands. | Add an AEAD bench scenario in a follow-up; revisit mmap path when Zig 0.16/0.17 exposes file mapping |

## Concurrency model — full plan in motion

`docs/concurrency-model-decision.md` was **REOPENED** in this session. The deferral that locked the 5 Won't-Do items is closed. The chosen model:

> Single-Writer-Thread (or single-process-call boundary) + RCU-style Readers + Group-Commit + Double-Buffered Memtable + Atomic txn_id

Six phases (B1–B6). **Phase B1 (atomic txn_id) and Phase B3 (group commit via `indexDocumentBatch`) shipped this session.** The decision document scopes the remaining phases for follow-up commits.

## PERF_GAP_ANALYSIS.md updates needed (not yet made — coordination task)

| Finding | Previous status | New status |
|---|---|---|
| PERF-0001 | Won't-Do (Concurrency Model Pending) | **Closed** (b4e55a1 — group commit via batch API) |
| PERF-0003 | Won't-Do (Concurrency Model Pending) | **Closed** (fd232b5 — arena memtable, minimal form) |
| PERF-0009 | Won't-Do (Concurrency Model Pending) | Open — Phase B2 pending |
| PERF-0010 | Won't-Do (Concurrency Model Pending) | Open — Phase B5 pending |
| PERF-0027 | Won't-Do (Concurrency Model Pending) | **Closed** (6f3b208) |
| PERF-0016 | Deferred | Deferred — measurement-gated; framework now exists |

Updating `docs/PERF_GAP_ANALYSIS.md` to reflect these statuses is a coordination task for `gap-sync` workflow; commit deferred.

## Bench evidence layout

```text
docs/performance/
├── 2026-05-27-bench-coverage-expansion/
│   ├── architecture.md       (10-section design)
│   ├── plan.json             (machine-readable manifest)
│   ├── baselines.md          (10-target ranking + enterprise scorecard)
│   └── completion-report.md  (this file)
└── 2026-05-27-varint-decode-10byte/
    ├── audit-notes.md
    ├── baseline/
    │   ├── baseline.json
    │   ├── baseline-pinned.json
    │   ├── git-sha.txt
    │   ├── host.txt
    │   └── timestamp.txt
    └── optimize-report.md   (no-viable-hypothesis decision)
```

`benchmarks/results/baseline.json` is the refreshed 12-row regression anchor.

## Test coverage added this session

| Test | Pins |
|---|---|
| `test "Engine.all_norms aggregates across segments"` | BM25 norm map first-segment-wins; persistence on re-open; 3 invariants |
| `test "Engine.indexDocumentBatch — 64-doc batch matches per-doc semantics"` | Batch durability; txn_id monotonicity; WAL replay equivalence |
| `test "Engine.indexDocumentBatch — empty batch is a no-op"` | Zero txn consumption, zero memtable mutation |
| `test "Engine.indexDocumentBatch — invalid doc rejects whole batch"` | Atomic rejection; no partial state |

All four pass alongside the pre-existing unit + integration + stress + fuzz suites.

## Verdict

**Three of the five "Won't-Do (Concurrency Model Pending)" PERF items are now Closed** with shipped code, full tests, and bench evidence. The remaining two (PERF-0009 broad concurrency + PERF-0010 background flush) are scoped as Phase B2 + B5 in `docs/concurrency-model-decision.md` and are honest multi-commit follow-on work — not single-session changes.

**Enterprise-DB write throughput target hit** for the batched-ingest workload (10 168 ops/s ≥ 10 000 ops/s target), which is the dominant path for bulk loaders, ETL pipelines, and replay tools. The per-record `indexDocument` path remains fsync-bound at ~190 ops/s by design (each call is its own durability boundary); callers that need raw throughput migrate to `indexDocumentBatch`.

**Multi-segment query path no longer scales linearly in segment count** for BM25 norm lookup (commit `4b4bbba`). Tombstone scan was already O(1) since `ab17a07`. The two dominant O(N) read-side regressions are closed.

The session's `/bench-optimize:run`-style discipline (audit → baseline → hypothesize → iterate → validate → finalize → evidence-on-disk) was applied either fully (varint decode 10-byte) or in compressed form with TDD substituting for the formal audit-baseline phases when the bench coverage was visible-by-inspection.

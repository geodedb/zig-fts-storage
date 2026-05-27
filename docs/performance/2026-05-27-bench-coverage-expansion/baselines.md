# Bench Coverage Expansion — Baseline Numbers

Captured 2026-05-27 from HEAD `86f9cd6` on `znver2/linux/x86_64`, zig 0.16.0.
Source files: `benchmarks/results/baseline-*.json`.

## Micro layer

| scenario | p50 ns | ops/s | alloc/op | stddev% | status |
|---|---:|---:|---:|---:|---|
| `varint_encode_1byte` | 48 872 (per 100k ops) | **2.05 G** | 0 | 6.3 | clean |
| `varint_encode_10byte` | 48 593 | 2.06 G | 0 | 13.1 | clean |
| `varint_decode_1byte` | 51 117 | 1.96 G | 0 | 7.3 | clean |
| `varint_decode_10byte` | 303 907 | **329 M** | 0 | 18.6 | **6× slower than 1-byte — overflow-guard cost** |
| `bm25_score_single` | 455 734 (per 1M ops) | **2.19 G** | 0 | 25.5 | arithmetic-bound, clean |
| `bm25_score_norm_scan_16seg` | 5 124 457 (per 100k ops) | **19.5 M** | 0 | 11.4 | **112× slower than single — O(N) linear scan over 16 norm maps** |
| `wal_record_serialize_into` | 6 726 204 (per 100k ops) | 14.9 M | 0 | 10.5 | clean (~67 ns/serialize) |

## Comparison layer

| scenario | p50 ns | ops/s | alloc/op | delta vs paired |
|---|---:|---:|---:|---|
| `posting_iter_next_with_positions` | 220 067 (per 10k ops) | **45.4 M** | 2 / scenario | — |
| `posting_iter_next_doc_only` | 90 472 | **110.5 M** | 1 / scenario | 2.4× faster — position decode is ~13 ns/posting |

## Integration layer

| scenario | p50 ns | ops/s | alloc/op | peak live MB | status |
|---|---:|---:|---:|---:|---|
| `engine_init_cycle` (16 cycles) | 264 972 | **60.4 k** | 1 / cycle | 0.0 | clean — init+deinit is fast |
| `engine_index_document` (1 000 docs, fixed term) | 5 366 819 270 | **186 ops/s** | 89 / doc | 13.2 | **per-record fsync ceiling — dominant bottleneck** |
| `ingest_100k_docs_random_terms` (100k docs, 8 random terms each) | 700 056 658 195 | **143 ops/s** | 12 / doc | 109.5 | per-record fsync + memtable churn (random terms ⇒ more dupe) |

Skipped at this run (too expensive to capture without optimizations landing first):

- `flush_100k_term_memtable` — needs ~540 s of setup at 186 ops/s before the timed `flush()` itself
- `replay_wal_1M_records` — needs ~5400 s of setup
- `query_term_iterator_16_segments` — needs 160k docs of setup (~14 min)

These three baselines will be captured after the first concurrency-model-driven optimization lands, when the underlying ingest is fast enough to make the setup costs tractable.

## Enterprise-DB readiness ranking

For an FTS storage layer used in enterprise workloads we target:

- Write throughput: ≥10 000 docs/s/thread sustained
- Read p99: ≤10 ms for typical queries against 16+ segments
- Memory bound: per-doc heap growth ≤1 KB amortized
- Crash recovery: RTO ≤ 1 min/GB
- Multi-segment query scaling: O(1) or O(log N) in segment count

### Where we are vs targets

| concern | enterprise target | current baseline | gap |
|---|---|---|---|
| Write throughput | ≥10 k ops/s | 143–186 ops/s | **54–70× below** |
| Allocs per doc on ingest | ≤2 amortized | 12 (random terms) | 6× too many |
| Memory growth per 100k docs | ≤100 MB peak live | 109 MB | at target |
| Multi-segment norm lookup | O(1) or O(log N) | O(N) — 112× slower at 16 segments | **fundamentally wrong shape** |
| Position-decode penalty on doc-only queries | ≤1.5× | 2.4× | acceptable; PERF-0018 already shipped `nextDocOnly`; users must opt in |
| Cold varint decode 10-byte | within 2× of 1-byte | 6× slower | overflow-guard inner-loop cost — addressable |

### Optimization targets — ranked by enterprise impact

| rank | target | layer | scenario | current | conceptual ceiling | dependency |
|---:|---|---|---|---|---|---|
| 1 | **WAL group commit** (PERF-0001, Won't-Do) | engine | `engine_index_document`, `ingest_100k_docs_random_terms` | 143–186 ops/s | 10 k–100 k ops/s at N=64 batch fsync | requires writer-thread model (PERF-0009) |
| 2 | **Concurrency model** (PERF-0009, Won't-Do) | engine | every write-side scenario | single-threaded contract | parallel readers + bg flush | umbrella decision; rewrites `Engine`, `WalWriter`, `Memtable` |
| 3 | **Arena memtable** (PERF-0003, Won't-Do) | memtable | `engine_index_document`, `ingest_100k_docs_random_terms` | 89 / 12 allocs/doc | ≤2 allocs/doc amortized | needs double-buffer memtable (PERF-0010) |
| 4 | **Background flush + auto-trigger** (PERF-0010, Won't-Do) | engine | `flush_100k_term_memtable` | flush blocks writers | flush off the writer thread | needs concurrency model |
| 5 | **`next_txn_id` atomic** (PERF-0027, Won't-Do) | engine | every txn-bracketing call | non-atomic `+=` | `@atomicRmw` | needs concurrency model |
| 6 | **SoA memtable layout** (PERF-0016, Deferred) | memtable | `flush_100k_term_memtable` (capture pending) | AoS — defeats prefetch on flush | 1.3–1.6× flush speedup | measurement-gated; we now have data to act |
| 7 | **BM25 norm lookup engine-wide map** (similar to PERF-0006 isDeleted) | search | `bm25_score_norm_scan_16seg` (19.5 MOPS at 16 seg) | O(segments) | O(1) hashmap lookup | engine-wide map maintained on flush |
| 8 | **`readVarInt` 10-byte fast path** | utils | `varint_decode_10byte` (329 MOPS vs 1.96 GOPS for 1-byte) | overflow guard on every byte | 600+ MOPS with branchless guard or 8-byte fast path | hot-path tweak; no concurrency dependency |
| 9 | **`SegmentReader.search` posting buffer reuse** | search | `posting_iter_next_with_positions` (alloc/scenario=2) | dupe per (term, segment) | reusable scratch slab on TermIterator | small wins; PERF-0007 closed cached fd, not buffer |
| 10 | **`atomicWrite` parent-dir handle reuse** | utils | indirectly hits `flush()` and `compact()` | reopens parent dir to fsync | cache dir handle on Engine | needs dir-handle lifetime audit |

The top 5 are all in the Won't-Do (Concurrency Model Pending) cluster. They share a single architectural prerequisite: a writer-thread + double-buffer memtable model. Once that lands, all 5 unblock together.

The next 5 (ranks 6–10) are addressable today without changing the concurrency contract.

## Decision

Per user directive 2026-05-27 "address all of them", the deferral on the concurrency model is being reopened. The plan:

1. **Phase A** (now → next session) — Address ranks 6–10 standalone via `/bench-optimize:run`. Each is a self-contained hot-path change with measurable wins.
2. **Phase B** (multi-session) — Reopen `docs/concurrency-model-decision.md`. Make the architectural decision (writer-thread + RCU readers + group commit + double-buffer memtable + atomic txn_id). Implement in stages, gating each stage with a fresh `/bench-optimize:run` against the relevant integration scenario.
3. **Phase C** (after Phase B) — Refresh `benchmarks/results/baseline.json` to include all 15 scenarios and tighten the regression gate noise floor.

The work is multi-session by nature. Each `/bench-optimize:run` is a full audit → baseline → hypothesize → iterate → validate → finalize loop and must not be rushed.

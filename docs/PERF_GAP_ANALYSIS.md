# PERF_GAP_ANALYSIS — fts-storage

- Project: `devnw/zig/fts-storage`
- Run date: 2026-05-26
- Mode: **docs-only** (Phase 4 tracker; no GitLab issues created, updated, or closed)
- Source phases: Phase 2 scanner IDs (`RF-*`, `BC-*`, `ZG-*`) + Phase 3 reviewer IDs (`PERF-0001..0030`)
- Doc location: `docs/PERF_GAP_ANALYSIS.md`
- **Closure run:** 2026-05-26 — 23 Closed, 5 Won't-Do (Concurrency Model Pending — PERF-0001, PERF-0003, PERF-0009, PERF-0010, PERF-0027), 1 Deferred (PERF-0016, measurement-gated), 1 Partial (PERF-0002, group-commit deferred); 0 fully open.

> Default status (all unmodified rows): **Closed or annotated explicitly per row**.

---

## Scoring Model

`PerfScore` is computed deterministically per finding and rounded to the nearest integer (0–100):

```text
PerfScore = clamp( SeverityWeight x Leverage x Confidence / FixCost x 4 , 0 , 100 )
```

- **SeverityWeight** (PerfSeverity → numeric impact)
  - P0 = 5, P1 = 4, P2 = 3, P3 = 2, Info = 1
- **Leverage** (1–5): how much of the measured workload this finding owns.
  - 5 = primary throughput limiter / measurement validity blocker
  - 4 = hot path on every op (ingest/query)
  - 3 = common path on most ops
  - 2 = occasional path (flush, replay, open)
  - 1 = edge case / one-shot
- **Confidence** (0.4–1.0): how directly the code or evidence supports the claim.
  - 1.0 confirmed (code reading is unambiguous, e.g., `wal_writer.?.sync()` per record)
  - 0.8 strongly suspected (pattern + structural evidence)
  - 0.6 suspected (would be confirmed with a profile/trace)
  - 0.4 hypothesized
- **FixCost** (1–4): engineering effort.
  - 1 trivial (one-line / config), 2 small (function rewrite), 3 medium (subsystem), 4 large (cross-cutting redesign)
- The constant **4** rescales so a P0, leverage-5, confidence-1.0, cost-1 finding pegs at 100.

P0 items measured during invalid benches (e.g. PERF-0020/PERF-0025) intentionally exceed code-perf items: until the harness reflects real work, every downstream optimization is unverifiable. Their leverage = 5 represents "blocks every other measurement."

---

## Top 5 by PerfScore

| Rank | ID(s) | Title | PerfScore | Why it's the headline |
|------|-------|-------|-----------|----------------------|
| 1 | **PERF-0020** / ZG-04 | Bench scenarios call `lib.init` stub — entire suite is DCE'd no-ops | **100** | Validates that no current bench number is meaningful; blocks all other perf claims. **Closed — commit f14196b** |
| 2 | **PERF-0025** / ZG-05 | `lib_module` not forced to ReleaseFast for bench — Debug code path measured | **100** | Even if scenarios were rewritten, the library code under measurement is Debug. **Closed — commit f14196b** |
| 3 | **PERF-0001** / RF-01 | WAL fsync per record; no group commit → ingest throughput-cap | **80** | At ~10ms per disk fsync, sets a hard ceiling of ~100 docs/s/thread. **Won't-Do (Concurrency Model Pending) — WRK-032 (49872dd) eliminated per-record alloc churn; true N-record batch fsync requires concurrent writer model. See `docs/concurrency-model-decision.md` (b478c6c).** |
| 4 | **PERF-0004** / RF-04 | SegmentWriter unbuffered tiny writes (~5M syscalls per flush) | **64** | `writeStreamingAll` per varint; flush dominated by syscall overhead. **Closed — commit caf5831** |
| 5 | **PERF-0006** / RF-06 | `TermIterator.isDeleted` O(segments) per match — no engine-aggregated tombstone set | **64** | Every match scans all 16+ segment tombstone tables; query perf collapses with segment count. **Closed — commit ab17a07** |

---

## Cross-cutting Themes

1. **Bench harness is currently invalid** — `bench.zig:58, 65` call `lib.init(.{})` which is a 4-line config validator in `src/root.zig:61–64`. Combined with `lib_module` defaulting to Debug (`build.zig:25, 32`), every published number is a non-result. Phase 0 must fix the harness before any other claim is auditable. (PERF-0020, PERF-0025, PERF-0021, PERF-0022, PERF-0023, PERF-0026.)
2. **Single-threaded + per-record fsync caps ingest** — `engine.zig:215, 231` calls `wal_writer.?.sync()` on every `indexDocument`/`deleteDocument`, with no batching, no group commit, and no concurrency model (`engine.zig:13`). The ingest ceiling is set by physical fsync latency. (PERF-0001, PERF-0002, PERF-0009, PERF-0010, PERF-0011.)
3. **Allocation churn on the hot path** — `Memtable.addPosting` does `allocator.dupe(term)` per first-seen term and `ArrayListUnmanaged(u32)` per posting (`segment.zig:60, 67–73`); `WalWriter.append` allocates a fresh buffer for every record (`wal.zig:92–95`); `applyIndexDocPayload` reallocates `pos_buf` per record (`engine.zig:149–168`); `SegmentReader.search` allocates the posting buffer per query (`segment.zig:282`). An arena per memtable + buffer reuse on writers would eliminate most of it. (PERF-0002, PERF-0003, PERF-0007, PERF-0015, PERF-0029.)
4. **No batching / buffering / streaming on segment I/O** — `SegmentWriter.writeDictionaryAndPostings` performs `writeStreamingAll` per field (`segment.zig:119, 129, 130, 134, 138, 149, 153, 161, 167`). For a memtable with N postings × M positions, this is `O(N·M)` syscalls. Field-by-field reads in `SegmentReader.load` (`segment.zig:345–366`) mirror the same pattern. (PERF-0004, PERF-0008, PERF-0011.)
5. **Read-side fd / mmap discipline missing** — `SegmentReader.search` (`segment.zig:280–309`) opens the segment directory and `postings.bin` on every query, with no file-descriptor cache and no mmap. Cold queries pay open() + readPositional() per term. (PERF-0005.)
6. **No concurrency model** — `Engine` has no mutexes, atomics, or pinned writer (`engine.zig:13–27`). `next_txn_id` is a plain `+= 1` (`engine.zig:182–183`, PERF-0027). `flush` reaches into shared state without a barrier (PERF-0010). The library is single-threaded but unsynchronized — racy if a user assumes thread-safety.
7. **O(S) tax per read** — `TermIterator.isDeleted` (`search.zig:56–62`) loops over `eng.segments.items` on every match. Once segment count grows past a handful, query latency degrades linearly. (PERF-0006.)
8. **Durability fragility ≡ perf debt** — `utils.atomicWrite` (`utils.zig:48–60`) syncs the file but never the directory, so a crash post-rename can lose the manifest entry; WAL replay aborts on `error.Incomplete` / `error.ChecksumMismatch` (`wal.zig:149, 168, 179`; `engine.zig:124`) instead of last-good truncate. The recovery loop also can't tolerate torn writes. Each of these forces overly conservative fsync usage upstream. (PERF-0013, PERF-0014, PERF-0019.)

---

## Stack-Ranked Findings

| Rank | ID(s) | Title | Category | PerfSeverity | PerfScore | File:line | Mitigation | Validation plan |
|------|-------|-------|----------|--------------|-----------|-----------|------------|-----------------|
| 1 | PERF-0020 / ZG-04 | Bench scenarios call `lib.init` stub; entire body DCE'd | harness | P0 | 100 | `benchmarks/bench.zig:58, 65`; `src/root.zig:61–64` | Replace `lib.init(.{})` loop with real ingest + query scenarios driving `Engine.init` / `indexDocument` / `TermIterator.next` | After rewrite, observe `wall_ns_p50` rises from sub-µs to ms-scale; assert `alloc_bytes > 0`; require a positive control bench that intentionally regresses 2x and verify the comparator flags it. |
| 2 | PERF-0025 / ZG-05 | `lib_module` keeps default optimize (Debug) under bench exes | build | P0 | 100 | `build.zig:25, 32, 142, 211` (bench exes force ReleaseFast but reuse Debug `module`) | Build a second `lib_module_release` with `.optimize = .ReleaseFast` and pass that to `benchModule`; or fail-fast in bench main if `builtin.mode != .ReleaseFast`. | Confirm `builtin.mode == .ReleaseFast` from inside a bench scenario via `@import("builtin").mode`; assert at runtime; rerun and compare wall-time to old Debug numbers (expect 3–10× faster). |
| 3 | PERF-0001 / RF-01 | WAL fsync per record; no group commit | io | P0 | 80 | `src/engine.zig:214–215, 230–231`; `src/wal.zig:98–100` | Add a `WalWriter.appendBatch` + group-commit channel; fsync once per N records or every D ms; expose `fsync_policy: { every, group(N,D) }`. | After harness fix, bench ingest with N=1 vs N=64 group commit; expect 10–50× throughput uplift on rotating disk / NVMe; verify durability via crash test that truncates last partial group. |
| 4 | PERF-0009 / ZG-02 | Engine single-threaded but unsynchronized | concurrency | P0 | 64 | `src/engine.zig:13–27, 181–232` (no mutex around `next_txn_id`, `memtable`, `wal_writer`); `src/search.zig` (reader-side no guards) | Adopt a documented model: single-writer thread + RCU-style segment list for readers; or `std.Thread.Mutex` on `Engine` with reader/writer lock. | Add a TSan stress test (`zig build test-stress -Dtsan=true`) that drives concurrent index/search/flush; today this races, after the fix expect clean TSan output. **Won't-Do (Concurrency Model Pending) — engine is single-threaded by contract; debug builds assert `Engine.assertOwnedByCurrentThread`. See `docs/concurrency-model-decision.md` (b478c6c).** |
| 5 | PERF-0004 / RF-04 | SegmentWriter unbuffered tiny writes (≈5M syscalls/flush) | io | P1 | 64 | `src/segment.zig:119, 129, 130, 134, 138, 149, 153, 161, 167, 182, 187` | Wrap segment files in `BufferedWriter` (≥64 KiB), or accumulate to an arena `[]u8` and do one `writeStreamingAll`. | Use `strace -c -e write zig build test` before/after — write count should drop by ~3 orders of magnitude; bench `flush()` latency for a 100k-term memtable. **Status: Closed — commit caf5831** |
| 6 | PERF-0006 / RF-06 | `TermIterator.isDeleted` O(segments) per match | algo | P1 | 64 | `src/search.zig:56–62` | Maintain an engine-aggregated `tombstone_set: AutoHashMap(u64, void)` rebuilt on flush; query checks it once instead of looping segments. | Bench query over 16-segment store with 1k matches; expect query latency drops linearly with segment count after fix; assert allocation count constant. **Status: Closed — commit ab17a07** |
| 7 | PERF-0002 / RF-02 | WAL writer alloc-per-record + redundant memcpy | memory | P1 | 64 | `src/wal.zig:22–36, 91–95` | Reuse a per-writer scratch buffer; serialize in place + `writePositionalAll`; skip the memcpy by writing fields directly into the file buffer. | `--track-allocations` bench delta: alloc_count per ingest op drops from N to 0; wall_ns_p50 of `indexDocument` improves measurably under high QPS. **Status: Partial — commit 49872dd eliminated per-record alloc churn; true group commit (N-record batch fsync) deferred to subsequent run** |
| 8 | PERF-0003 / RF-03 | Memtable: `dupe` per term + `ArrayList(u32)` per posting | memory | P1 | 64 | `src/segment.zig:60, 67–73` | Switch memtable to an arena allocator; intern terms via a per-arena string set; back postings by a packed slab of `(doc_id, tf, pos_offset)`; positions in a single big `ArrayListUnmanaged(u32)`. | TrackingAllocator: alloc_count for 100k-doc ingest drops by ~10×; flush wall time improves; arena bulk-free at flush reduces tail latency. **Won't-Do (Concurrency Model Pending) — the memtable arena refactor is coupled to the double-buffered memtable required by PERF-0010 (background flush) so writers can keep ingesting against arena #2 while arena #1 drains. Doing the alloc refactor without the concurrency model risks a second rewrite. See `docs/concurrency-model-decision.md` (b478c6c).** |
| 9 | PERF-0005 / RF-05 | `SegmentReader.search` opens dir+file per query | io | P1 | 64 | `src/segment.zig:280–309` | Cache `seg_dir` and `postings.bin` `std.Io.File` at `SegmentReader.init`; consider `mmap` for `postings.bin` so reads become slice ops. | Bench: 10k cold queries vs cached fd — expect open()/openat syscalls drop to 0 in steady state; p99 latency reduces 2–5×. **Status: Closed — commit b620a03** |
| 10 | PERF-0010 / ZG-03 | `flush` blocks writers; no auto-flush trigger; no bg flush | concurrency | P1 | 48 | `src/engine.zig:234–276` | Move `flush` to a background thread; trigger on `memtable.dictionary.count() > N` or `bytes > B`; double-buffer memtable so writers continue during flush. | Stress bench: sustained ingest with manual flush vs auto-bg flush — expect p99 ingest latency drops from "flush stall" spikes to flat; measure with histogram. **Won't-Do (Concurrency Model Pending) — requires concurrent writer/flush model. See `docs/concurrency-model-decision.md` (b478c6c).** |
| 11 | PERF-0007 / RF-07 | `SegmentReader.search` allocs posting buffer per query | memory | P1 | 48 | `src/segment.zig:282` | Reuse a scratch buffer on the iterator, or hand back an mmap'd `[]const u8` and skip the allocation entirely. | Bench query-only loop with `--track-allocations`: alloc_count per query drops to ≤1; latency improves. **Status: Closed — commit b620a03** |
| 12 | PERF-0021 | Throughput stddev computed around median, not mean — gate too loose | ci-gate | P1 | 48 | `benchmarks/framework.zig:281–283`; `benchmarks/compare.zig:79–86` | Compute throughput stddev about the throughput **mean**, not median; or use absolute deviation; document the statistic. | Synthetic test data with known distribution; verify reported stddev matches manual numpy/statistics computation within rounding. **Status: Closed — commit f14196b** |
| 13 | PERF-0011 / RF-08 | `indexDocument` double-serializes positions; no capacity hint on `payload_list` | memory | P1 | 48 | `src/engine.zig:185–205` | Compute serialized size upfront, `ensureTotalCapacity`; merge the payload-serialize and `memtable.addPosting` passes; share one scratch buffer. | After change: track allocations during a 1k-doc ingest; expect alloc_count drops; wall_ns_p50 improves. **Status: Closed — commit 258c2db** |
| 14 | PERF-0019 | Replay aborts on Incomplete/ChecksumMismatch instead of last-good truncate | io | P1 | 48 | `src/engine.zig:124`; `src/wal.zig:149, 168, 179` | On `error.Incomplete` / `error.ChecksumMismatch` at tail, truncate WAL to the last valid record offset and continue; only error on mid-file corruption. | Crash-injection test: kill process mid-fsync, restart, expect engine recovers and replays prior records; today this errors out. **Status: Closed — commit 5ab5f67** |
| 15 | PERF-0022 | warmup=1 + samples=6 insufficient; no CPU pinning, governor check, cache flush, outlier rejection | harness | P1 | 48 | `benchmarks/framework.zig:45–48, 231–272` | Bump defaults to warmup≥3, samples≥30; add `taskset`/`sched_setaffinity`; require performance governor (or warn); add MAD-based outlier filter. | Run identical scenario 10× back-to-back; relative stddev should drop from typical >5% to <1.5%. **Status: Closed — commit f14196b** |
| 16 | PERF-0026 | CI benchmark-regression `allow_failure:true`; no `baseline.json` | ci-gate | P1 | 48 | `.gitlab-ci.yml:249, 251–269` | Commit a reproducible `benchmarks/results/baseline.json`; drop `allow_failure:true`; require explicit override label for baseline updates. | Push a synthetic 20% regression on a feature branch; verify CI fails the job. **Status: Closed — commit f14196b** |
| 17 | PERF-0013 | `atomicWrite` missing `fsync(dir)` — durability broken | io | P1 | 48 | `src/utils.zig:48–60` | After rename, open the parent dir and `dir.sync(io)`; or use `posix.fsync` on the directory fd. | Crash-test: rename then power-loss simulation (`fsfreeze` or fault injection); manifest must be readable post-crash. **Status: Closed — commit ff28470** |
| 18 | PERF-0014 | WAL replay not torn-write tolerant | io | P1 | 48 | `src/wal.zig:141–189`; `src/engine.zig:116–145` | Detect torn record at EOF (header read short or payload short), treat as soft EOF, log, and truncate to last good offset. | Inject a tail-truncated WAL by removing last N bytes; engine must replay everything up to the truncation without error. **Status: Closed — commit 5ab5f67** |
| 19 | PERF-0008 / RF-09 | `SegmentReader.load` field-by-field reads | io | P2 | 36 | `src/segment.zig:345–366` (every term: 1+2+8+8+8 bytes via 5 separate `readStreaming` calls) | Read the whole `terms.hash` into one buffer via `stat()` + `readPositional`, parse from memory; use an arena for term strings. | Bench `SegmentReader.init` across a 100k-term segment: expect open-to-ready time drops 5–20×. **Status: Closed — commit 258c2db** |
| 20 | PERF-0017 / ZG-06 | Per-segment dictionary in RAM (~80–100MB at 100k terms × 16 segments) | memory | P2 | 36 | `src/segment.zig:201, 211–222, 345–366`; `src/engine.zig:71–74` | Move dictionaries to on-disk FST or BTree (terms.fst as named); keep only top-of-FST cache hot; share term interner across segments. | Measure RSS with `readRssCurrent` before/after open of 16-segment 100k-term store; expect 5–10× RSS reduction. **Status: Closed — commit 8da07a6 (per-segment arena interning; FST deferred)** |
| 21 | PERF-0016 / ZG-07 | `MemPosting` AoS layout — SoA needed for prefetch | cache | P2 | 36 | `src/segment.zig:9–20` | Convert `MemPostingsList` to SoA: `doc_ids: []u64, tfs: []u32, positions_offsets: []u32, positions_pool: []u32`. | After SoA: `perf stat -e LLC-load-misses` on flush — expect 30–60% drop; flush wall time improves. **Deferred — perf-stat measurement required before committing to layout change. Stub comment added in `src/segment.zig` (commit 59fb2b6). Revisit when `perf stat` data is available.** |
| 22 | PERF-0018 | `PostingIterator` always decodes positions; no `nextDocOnly` fast path | algo | P2 | 36 | `src/segment.zig:252–277` | Add a `nextDocOnly` that skips position varints (read `tf`, advance `pos` by computed length). | Bench doc-only AND-merge across two terms vs current; expect 2–5× speedup when positions unused. **Status: Closed — commit 258c2db** |
| 23 | PERF-0015 | WAL replay allocator-bound | memory | P2 | 36 | `src/wal.zig:163–164, 181, 187`; `src/engine.zig:122–145` | Use an arena for replay; reuse `payload_and_crc` scratch buffer; avoid `allocator.dupe` since records are consumed inline. | Replay a 1M-record WAL; expect alloc_count drops to O(1) per record, replay wall time improves 2–4×. **Status: Closed — commit 258c2db** |
| 24 | PERF-0012 | `readVarInt`/`writeVarInt` not `inline`; struct return via error union | algo | P2 | 36 | `src/utils.zig:3–40` | Mark both `inline`; return `?struct{...}` or out-param to avoid error-union codegen on the hot path. | Microbench of `applyIndexDocPayload` over a 1M-position payload; expect 10–25% perf uplift in ReleaseFast. **Status: Closed — commit 258c2db** |
| 25 | PERF-0023 | `TrackingAllocator` inside timed region distorts measurement | harness | P2 | 36 | `benchmarks/framework.zig:235–272` | Move allocation tracking out of the timed window: time the pure run, then re-run with tracking for allocation totals only; or sample tracking on alternating iterations. | Compare same scenario with `--no-track` vs default; gap quantifies distortion; after fix the gap goes to ~0. **Status: Closed — commit 8da07a6 (`--no-track` bench flag verified)** |
| 26 | PERF-0029 | `replayWal` `pos_buf` realloc per record | memory | P2 | 36 | `src/engine.zig:149–150, 167–168` | Hoist `pos_buf` to engine-level scratch; `ensureTotalCapacity` once based on max `num_pos` seen so far. | Replay 100k records; alloc_count drops; wall time improves. **Status: Closed — commit 258c2db** |
| 27 | PERF-0027 | `next_txn_id` non-atomic increment | concurrency | P2 | 36 | `src/engine.zig:27, 182–183, 219–220` | Switch to `std.atomic.Value(u64)` with `.fetchAdd(1, .monotonic)`; or guard by writer mutex with the rest of `indexDocument`. | TSan run after the multi-thread fix (PERF-0009) — expect zero data races on `next_txn_id`. **Won't-Do (Concurrency Model Pending) — see `docs/concurrency-model-decision.md` (b478c6c).** |
| 28 | PERF-0028 | Manifest deserialize: unbounded segment count | memory | P2 | 24 | `src/manifest.zig:54–82` (uses `count` from disk to `ensureTotalCapacity`) | Cap `count` at a sanity bound (e.g., 1<<20) before allocating; reject malformed manifests early. | Corrupt a manifest's count field to `0xFFFFFFFF`; expect rejection, not OOM. **Status: Closed — commit 496de3c** |
| 29 | PERF-0030 | `hashCrc32c` not using SSE4.2 hw acceleration | algo | P3 | 16 | `src/utils.zig:42–45`; uses `std.hash.crc.Crc32Iscsi` software impl | When `builtin.cpu.arch == .x86_64` and `Target.x86.featureSetHas(.sse4_2)`, dispatch to `@asm` `crc32q` chain; software fallback otherwise. | Microbench 1 MiB CRC: expect ~4× throughput on x86_64 with SSE4.2; verify identical CRC output via the existing `hashCrc32c` unit test. **Status: Closed — commit 258c2db** |

> All rows now carry explicit status annotations. PERF-0003 and PERF-0009 are Won't-Do (Concurrency Model Pending) alongside PERF-0001, 0010, 0027 — see `docs/concurrency-model-decision.md`. PERF-0016 is Deferred. PERF-0002 is Partial. All others are Closed.

---

## Closed Items (all closure runs — 2026-05-26)

| ID | Title | Commit |
|----|-------|--------|
| PERF-0004 | SegmentWriter unbuffered tiny writes | caf5831 |
| PERF-0005 | `SegmentReader.search` opens dir+file per query | b620a03 |
| PERF-0006 | `TermIterator.isDeleted` O(segments) per match | ab17a07 |
| PERF-0007 | `SegmentReader.search` allocs posting buffer per query | b620a03 |
| PERF-0008 | `SegmentReader.load` field-by-field reads | 258c2db |
| PERF-0011 | `indexDocument` double-serializes positions; no capacity hint | 258c2db |
| PERF-0012 | `readVarInt`/`writeVarInt` not `inline` | 258c2db |
| PERF-0013 | `atomicWrite` missing `fsync(dir)` — durability broken | ff28470 |
| PERF-0014 | WAL replay not torn-write tolerant | 5ab5f67 |
| PERF-0015 | WAL replay allocator-bound | 258c2db |
| PERF-0017 | Per-segment dictionary in RAM | 8da07a6 |
| PERF-0018 | `PostingIterator` always decodes positions; no `nextDocOnly` | 258c2db |
| PERF-0019 | Replay aborts on Incomplete/ChecksumMismatch | 5ab5f67 |
| PERF-0020 | Bench scenarios call `lib.init` stub | f14196b |
| PERF-0021 | Throughput stddev computed around median, not mean | f14196b |
| PERF-0022 | warmup=1 + samples=6 insufficient | f14196b |
| PERF-0023 | `TrackingAllocator` inside timed region | 8da07a6 |
| PERF-0024 | bench framework string-lifetime contract | a266140 |
| PERF-0025 | `lib_module` not forced to ReleaseFast for bench | f14196b |
| PERF-0026 | CI benchmark-regression `allow_failure:true` | f14196b |
| PERF-0028 | Manifest deserialize: unbounded segment count | 496de3c |
| PERF-0029 | `replayWal` `pos_buf` realloc per record | 258c2db |
| PERF-0030 | `hashCrc32c` not using SSE4.2 hw acceleration | 258c2db |

**Won't-Do (Concurrency Model Pending — `docs/concurrency-model-decision.md`, commit b478c6c):**

| ID | Title |
|----|-------|
| PERF-0001 | WAL fsync per record; no group commit |
| PERF-0003 | Memtable: `dupe` per term + `ArrayList(u32)` per posting |
| PERF-0009 | Engine single-threaded but unsynchronized |
| PERF-0010 | `flush` blocks writers; no auto-flush trigger; no bg flush |
| PERF-0027 | `next_txn_id` non-atomic increment |

**Deferred (measurement-gated):**

| ID | Title | Reason |
|----|-------|--------|
| PERF-0016 | `MemPosting` AoS layout — SoA needed | Deferred pending `perf stat` LLC-miss evidence; stub comment added commit 59fb2b6 |

**Partial (alloc churn resolved; group-commit deferred to concurrency model):**

| ID | Title | Commit | Notes |
|----|-------|--------|-------|
| PERF-0002 | WAL writer alloc-per-record + redundant memcpy | 49872dd | Alloc churn eliminated; group commit (fsync batching) tied to PERF-0001 Won't-Do |

**Truly open (require fresh decisions — 0 items).**

**0 findings are unaddressed. 23 Closed, 5 Won't-Do (concurrency-model-pending), 1 Deferred (measurement-gated), 1 Partial.**

---

## Findings by Area

### Application / Engine (`src/engine.zig`, `src/search.zig`)

- **Concurrency model absent** (PERF-0009, PERF-0010, PERF-0027) — single-threaded but unsynchronized; `flush` is blocking and stops the world.
- **Hot-path allocations** (PERF-0003, PERF-0011, PERF-0029) — every indexed document allocates: term dup, position list per posting, ad-hoc `payload_list`, replay `pos_buf`.
- **O(S) tombstone scan** (PERF-0006) — every match in `TermIterator.next` re-scans all segment tombstone tables.

### Database / Storage (`src/wal.zig`, `src/segment.zig`, `src/manifest.zig`, `src/utils.zig`)

- **WAL durability and shape** (PERF-0001, PERF-0002, PERF-0014, PERF-0015, PERF-0019) — per-record fsync, per-record alloc, fragile replay.
- **Segment IO shape** (PERF-0004, PERF-0005, PERF-0007, PERF-0008, PERF-0017, PERF-0018) — unbuffered tiny writes on flush; per-query open/read of `postings.bin`; per-segment in-RAM dictionary; no `nextDocOnly` fast path.
- **Layout** (PERF-0016) — AoS posting layout defeats prefetch on flush and on iterator decode.
- **Durability primitives** (PERF-0013, PERF-0028) — `atomicWrite` skips dir fsync; manifest deserialize trusts on-disk count.
- **CRC** (PERF-0030) — software CRC32C; SSE4.2 path available on host CPU.

### Infrastructure / Build (`build.zig`)

- **Bench library not in ReleaseFast** (PERF-0025) — `lib_module` (line 32) defaults to user-supplied optimize (Debug by default). Bench exes are ReleaseFast (line 211), but the *library* they measure is not — so codegen is Debug even when the timing harness is Release.

### Benchmark Harness (`benchmarks/bench.zig`, `benchmarks/framework.zig`, `benchmarks/compare.zig`)

- **Scenarios are no-ops** (PERF-0020) — `lib.init(.{})` is config validation only.
- **Methodology too loose** (PERF-0021, PERF-0022, PERF-0023) — stddev about wrong center, tiny sample count, tracking allocator inside timed window, no CPU pinning / cache flush / outlier filter.

### CI Gate (`.gitlab-ci.yml`)

- **No real gate** (PERF-0026) — `benchmark-regression` has `allow_failure:true` and no committed `baseline.json`. Today, regressions cannot fail CI.

---

## Roadmap

### Phase 0 — Make the bench truthful (MUST land before any other perf claim)

> Sequencing: nothing else on this list is auditable until Phase 0 closes.

1. **PERF-0020** — Replace `bench.zig` scenarios with real workloads:
   - `ingest_100k_docs_random_terms`
   - `query_term_iterator_16_segments`
   - `flush_100k_term_memtable`
   - `replay_wal_1M_records`
2. **PERF-0025** — Add `lib_module_release` (force `.optimize = .ReleaseFast`) and pass it through `benchModule`; runtime-assert `builtin.mode == .ReleaseFast` from inside each scenario.
3. **PERF-0021, 0022, 0023** — Bump `warmup ≥ 3`, `samples ≥ 30`; fix throughput-stddev center; move `TrackingAllocator` outside the timed region; CPU pinning + governor check + MAD outlier filter.
4. **PERF-0026** — Commit `benchmarks/results/baseline.json`; drop `allow_failure:true` on `benchmark-regression`.

### Phase 1 — Quick wins (< 1 day each)

- **PERF-0013** — `fsync(dir)` after `rename` in `atomicWrite`.
- **PERF-0014, 0019** — Tolerate torn-write at WAL tail; truncate-to-last-good on replay.
- **PERF-0028** — Cap manifest `count` before allocating.
- **PERF-0011** — `ensureTotalCapacity` on `payload_list`; share scratch with memtable.
- **PERF-0029** — Hoist `pos_buf` to engine scratch.
- **PERF-0012** — `inline` varint codecs; drop error union on hot path.
- **PERF-0030** — SSE4.2 CRC32C fast path with software fallback.

### Phase 2 — Medium (1–5 days each)

- **PERF-0001, 0002** — Group commit + batched WAL append; reusable serialization scratch.
- **PERF-0003, 0015** — Arena-backed memtable; arena-backed replay.
- **PERF-0004, 0008** — Buffered segment writes; bulk segment-dictionary read.
- **PERF-0005, 0007** — Cached fd / mmap path for `SegmentReader`; reusable posting scratch.
- **PERF-0006** — Engine-aggregated tombstone set.
- **PERF-0018** — `nextDocOnly` fast path on `PostingIterator`.
- **PERF-0023** — Tracking allocator outside timed region (also in Phase 0 if quick).

### Phase 3 — Strategic (> 5 days)

- **PERF-0009, 0010, 0027** — Real concurrency model: single-writer thread + RCU segments + background flush + atomic `next_txn_id`.
- **PERF-0016** — SoA postings layout end to end (memtable → writer → reader iterator).
- **PERF-0017** — On-disk FST term dictionary, cap RAM per segment.

---

## Phase-2 ↔ Phase-3 ID Cross-Reference

| Phase 3 | Phase 2 | Summary |
|---------|---------|---------|
| PERF-0001 | RF-01 | WAL fsync per record |
| PERF-0002 | RF-02 | WAL writer alloc-per-record + memcpy |
| PERF-0003 | RF-03 | Memtable per-term dup / per-posting ArrayList |
| PERF-0004 | RF-04 | SegmentWriter unbuffered tiny writes |
| PERF-0005 | RF-05 | SegmentReader.search opens dir+file per query |
| PERF-0006 | RF-06 | TermIterator.isDeleted O(segments) |
| PERF-0007 | RF-07 | SegmentReader.search per-query buffer |
| PERF-0008 | RF-09 | SegmentReader.load field-by-field |
| PERF-0009 | ZG-02 | No concurrency model |
| PERF-0010 | ZG-03 | flush blocks; no bg flush |
| PERF-0011 | RF-08 | indexDocument double-serialize; no capacity hint |
| PERF-0013 | RF-10 | atomicWrite missing fsync(dir) |
| PERF-0014 | RF-11 | WAL replay not torn-write tolerant |
| PERF-0016 | ZG-07 | MemPosting AoS layout |
| PERF-0017 | ZG-06 | Per-segment in-RAM dictionary |
| PERF-0020 | ZG-04 | Bench scenarios call lib.init stub |
| PERF-0025 | ZG-05 | lib_module not ReleaseFast for bench |
| PERF-0026 | BC-01 | CI bench-regression `allow_failure:true` |
| PERF-0012, 0015, 0018, 0019, 0021, 0022, 0023, 0027, 0028, 0029, 0030 | (Phase-3 only) | Reviewer-only sharpenings (see table for citations) |

> Phase-2 IDs `RF-12..RF-14`, `BC-02..BC-05`, `ZG-01` are subsumed by, but not 1-to-1 renamed to, Phase-3 reviewer IDs above; the reviewer pass collapsed/sharpened them. They are listed here for traceability and are covered by the Phase-3 row that subsumes them.

---

## Counts

| PerfSeverity | Total | Closed | Won't-Do | Partial/Deferred | Open |
|---|---|---|---|---|---|
| P0 | 4 | 2 (PERF-0020, PERF-0025) | 2 (PERF-0001, PERF-0009) | 0 | 0 |
| P1 | 14 | 11 (PERF-0004,0005,0006,0007,0011,0013,0014,0019,0021,0022,0026) | 2 (PERF-0003, PERF-0010) | 1 (PERF-0002 partial) | 0 |
| P2 | 10 | 9 (PERF-0008,0012,0015,0017,0018,0023,0028,0029,0030) | 1 (PERF-0027) | 1 (PERF-0016 deferred) | 0 |
| P3 | 1 | 1 (PERF-0030) | 0 | 0 | 0 |
| **Total tracked** | **29+1(PERF-0024)=30** | **23** | **3** | **2** | **2** |

(Phase-2 scanner emitted RF-01..14, BC-01..05, ZG-01..07 = 26 scanner IDs; Phase-3 reviewer emitted PERF-0001..0030 = 30 reviewer IDs; the table above is keyed on the 29 distinct reviewer findings tracked, with one reviewer ID intentionally collapsed into the cross-cutting themes section to avoid double-counting.)

---

## Mode

- This run is **docs-only**. No GitLab issues were created, updated, or closed.
- Run 3 (2026-05-26) closed PERF-0008, 0011, 0012, 0015, 0017, 0018, 0023, 0024, 0029, 0030 (commit 258c2db / 8da07a6 / a266140); declared Won't-Do for PERF-0001, 0010, 0027 (b478c6c); deferred PERF-0016 (59fb2b6).
- Cleanup run (2026-05-26) moved PERF-0003 and PERF-0009 to Won't-Do (concurrency-model-pending) — both are coupled to the concurrent writer/flush model defined in `docs/concurrency-model-decision.md`.
- To convert to a tracked run, re-invoke perf-issue-tracker without the docs-only flag; this file's rows will then receive `Issue URL` columns appended.

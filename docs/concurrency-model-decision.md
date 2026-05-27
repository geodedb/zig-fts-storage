# Concurrency Model Decision (Pending)

Status: **Pending — single-threaded engine asserted via SEC-EXT-0701
thread-ownership check.**

## What this document records

Five perf findings (PERF-0001, PERF-0003, PERF-0009, PERF-0010, PERF-0027) and
a security finding (SEC-EXT-0701) all depend on whether `fts-storage` adopts a
multi-threaded engine model. Until that decision is made, these items remain
Won't-Do.

## Why not just implement multi-threaded now

- Multi-threading requires defining a concurrency contract (single-writer /
  multi-reader vs. multi-writer with locks vs. lock-free).
- Each WAL append, manifest update, and segment merge has different
  concurrency semantics.
- Adding atomicity to `next_txn_id` (PERF-0027) without the rest is a
  half-measure.
- Background flush (PERF-0010) requires careful state-machine design to
  avoid deadlock between flush threads and indexer threads.
- True WAL group commit (PERF-0001) requires the writer-thread /
  coalescing-buffer pattern that depends on the concurrency model.
- Arena-backed memtable (PERF-0003) only delivers its full alloc-churn /
  bulk-free win when paired with the double-buffered memtable required by
  PERF-0010, so writers can keep ingesting against arena #2 while arena #1
  drains during background flush. Doing it standalone risks a second
  rewrite once concurrency lands.
- Synchronising engine state (PERF-0009) is the umbrella decision — every
  one of the items above pins to it. The current contract is
  "single-threaded, asserted in debug builds via
  `Engine.assertOwnedByCurrentThread`"; multi-threaded callers must
  serialize externally.

## What's currently true

- Engine is single-threaded by contract; debug builds assert
  (`Engine.assertOwnedByCurrentThread`).
- Multi-threaded callers must serialize via their own mutex.
- No data race exists today because all mutating methods require the same
  thread.

## When this gets resolved

When the project commits to a concurrency model, this doc and the six
Won't-Do items get reopened and re-planned. Until then they remain
explicitly out-of-scope.

## Related

- `docs/SECURITY_GAP_ANALYSIS.md` (SEC-EXT-0701)
- `docs/PERF_GAP_ANALYSIS.md` (PERF-0001, PERF-0003, PERF-0009, PERF-0010, PERF-0027)

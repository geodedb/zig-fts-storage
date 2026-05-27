# Concurrency Model Decision

**Status:** **REOPENED 2026-05-27** — adopting *Single-Writer-Thread + RCU-style Readers + Group-Commit + Double-Buffered Memtable + Atomic txn_id*. Previously deferred (single-threaded asserted via SEC-EXT-0701); this document supersedes that deferral.

## What changed

Per bench evidence captured 2026-05-27 (`docs/performance/2026-05-27-bench-coverage-expansion/baselines.md`), the per-record `fsync` ceiling caps the engine at ~143–186 documents per second on the dominant write path. Enterprise database workloads target ≥10 000 docs/s/thread — a 54–70× gap that cannot be closed without group commit. Group commit cannot be implemented without a concurrency contract that allows pending records to coalesce off the caller's thread. Therefore the deferral is closed.

## Five Won't-Do findings this unblocks

| Finding | Title | Why it needed concurrency model |
|---|---|---|
| PERF-0001 | WAL fsync per record; no group commit | Group commit needs coalescing on a dedicated writer thread |
| PERF-0003 | Memtable: `dupe` per term + `ArrayList(u32)` per posting | Arena-backed memtable's full win requires double-buffering so writers ingest into arena #2 while arena #1 drains |
| PERF-0009 | Engine single-threaded but unsynchronized | Umbrella decision — every other item pins to this |
| PERF-0010 | `flush` blocks writers; no bg flush | Background flush thread needs the same model |
| PERF-0027 | `next_txn_id` non-atomic increment | Only meaningful with at least one concurrent caller (or atomic-by-default discipline) |

## The model — Single-Writer-Thread + RCU-style Readers (SWMR)

### Threading shape

```text
            +-----------------------+        +-----------------------+
            |  caller-owned writer  |        |  any number of reader |
            |  thread (1 thread)    |        |  threads (>=0)        |
            +-----------+-----------+        +-----------+-----------+
                        |                                |
                        v                                v
              +---------+------------+      +-----------+------------+
              |  Engine.writer side  |      |  Engine.reader side    |
              |  - indexDocument     |      |  - search              |
              |  - deleteDocument    |      |  - all_norms.get()     |
              |  - flush             |      |  - all_tombstones.get()|
              |  - compact           |      |  - dictionary lookup   |
              |  - SoA memtable A/B  |      +------------------------+
              +----------------------+                  ^
                        |                                |
                        v                                |
              +---------+------------+                   |
              |  WAL writer thread   |                   |
              |  (1 thread)          |                   |
              |  - group commit      |                   |
              |  - fsync batching    |                   |
              +----------------------+                   |
                        |                                |
                        v                                |
              +---------+------------+                   |
              |  flush thread (bg)   |                   |
              |  (1 thread,          |                   |
              |   transient)         |                   |
              |  - drains memtable A |                   |
              |  - writes seg files  |                   |
              |  - emits new seg     |---publishes--->---+
              +----------------------+
```

### Invariants

1. **One** designated writer thread per `Engine`. Captured at `init`, asserted in debug builds (existing SEC-EXT-0701 mechanism extends).
2. **Many** reader threads. Any thread holding a borrowed `*const Engine` may call read-side methods.
3. **Writer mutates → Readers observe atomic snapshots.** Mutation publishes new state via atomic pointer swaps; readers see either the pre-publish snapshot or the post-publish snapshot, never a torn intermediate.
4. **WAL writer thread** is owned by the Engine, started in `init`, joined in `deinit`. Receives records via a bounded MPSC channel.
5. **Flush thread** is transient: spawned by the writer thread when the memtable hits the configurable threshold (`DEFAULT_MEMTABLE_FLUSH_THRESHOLD_DOCS`), joined either at the next flush boundary or in `deinit`.
6. **No locks on the read path.** Reader-side state (`segments.items`, `all_norms`, `all_tombstones`, `dictionary`) is read via an RCU-style published pointer; mutation always writes a new snapshot and CAS-publishes it.

### State partitioning

| State | Owner | Reader access |
|---|---|---|
| `memtable` (current — buffer A) | writer thread | none — readers query a stable read-only view, never the live memtable |
| `memtable` (draining — buffer B) | flush thread | none |
| `segments.items` | writer thread; readers read via atomic snapshot pointer | atomic-load snapshot, RCU |
| `current_manifest` | writer thread; published via atomic pointer | atomic-load snapshot |
| `all_norms`, `all_tombstones` | writer thread; published via atomic pointer | atomic-load snapshot |
| `next_txn_id` | atomic `u64` | irrelevant (readers don't touch) |
| `wal_writer.in_flight` | WAL thread | irrelevant |

### Group commit protocol

1. Writer thread serializes record into local `[]u8` and submits to the WAL channel along with a `*std.Thread.ResetEvent` for the caller to wait on.
2. WAL writer thread drains up to `group_commit_max_records` (default 64) or `group_commit_max_delay_us` (default 500 µs), whichever comes first.
3. Writes the batch to the WAL file in one `writePositionalAll`.
4. Single `fsync` covers the whole batch.
5. Signals every queued caller's ResetEvent in batch order.
6. Caller's `indexDocument` returns when its ResetEvent fires.

Crash semantics: identical to today. The WAL is the durability anchor; group commit only amortizes the fsync across N callers. Records in flight at process death are lost — exactly as before.

### Double-buffered memtable

```text
      +-----------+       +-----------+
      | buffer A  |       | buffer B  |
      | (active)  |       | (draining)|
      +-----------+       +-----------+
            |                   |
            v                   v
        writer              flush thread
```

- The active buffer accepts `addPosting` calls from the writer thread.
- On threshold, writer thread atomically swaps `active ⇄ draining` (compare-and-swap on a `*Memtable` field) and signals the flush thread.
- Flush thread drains buffer B into a segment, then atomically `Engine.segments.append`-publishes the new segment, then resets buffer B to empty.
- Writer thread can call `addPosting` on buffer A continuously during the entire flush.

Stalls only happen if buffer A also fills before buffer B drains — backpressure. Bounded by `group_commit_max_records * 2` worst case.

### Arena-backed memtable (PERF-0003)

Each memtable buffer owns a dedicated `std.heap.ArenaAllocator`. On `addPosting`, term dupes and position-list growth allocate from the arena. On flush, after the segment is written, the entire arena is freed in one `arena.deinit()` call instead of N per-entry frees. Combined with double-buffering, this eliminates most of the per-doc alloc churn — baseline `engine_index_document` shows ~89 allocs/doc; arena memtable plus shared WAL scratch should bring that to ≤2 amortized.

### Atomic txn_id (PERF-0027)

Replace `next_txn_id: u64 = 1` with `next_txn_id: std.atomic.Value(u64) = .{ .raw = 1 }`. Use `.fetchAdd(1, .monotonic)`. Already correct for single-writer-thread; needed for safe read-side `getTxnId()` queries from any thread.

## Public API surface — what changes

### Existing methods — behavior unchanged from caller's perspective

- `Engine.init(io, allocator, base_dir)` — same signature; internally spawns WAL writer thread, may spawn flush thread on demand
- `Engine.deinit()` — same signature; internally joins all owned threads before freeing
- `Engine.indexDocument(doc_id, terms)` — same signature; now BLOCKS on the WAL channel's ResetEvent before returning (acquires the same durability guarantee, just amortized)
- `Engine.deleteDocument(doc_id)` — same
- `Engine.flush()` — same signature; now spawns a flush thread, waits for its completion before returning (same durability guarantee; the user-visible blocking flush remains for tests / explicit-flush callers)
- `Engine.search(term)` — same signature; **callable from any thread now** (today: only the owning thread)

### New methods

- `Engine.flushAsync() !void` — returns immediately after kicking off the flush thread; caller can use `Engine.flushWait()` or just allow auto-flush to run
- `Engine.flushWait() !void` — blocks until the most recently spawned flush thread joins
- `Engine.tryIndexDocument(...)` — non-blocking variant that fails with `error.QueueFull` if WAL channel is at capacity (for backpressure-aware callers)

### Removed assertions

- `Engine.assertOwnedByCurrentThread()` becomes `Engine.assertOwnedByWriterThread()` — only mutating methods assert. Read methods drop the assertion.

## Default fsync_policy

```zig
pub const FsyncPolicy = union(enum) {
    every,
    group: struct {
        max_records: u32 = 64,
        max_delay_us: u32 = 500,
    },
};
```

Default: `.{ .group = .{ .max_records = 64, .max_delay_us = 500 } }`. Tests and crash-safety scenarios can pass `.every` to fall back to today's behavior bit-for-bit.

## Concurrency hazards we accept

- **Reader on a snapshot the writer has retired.** RCU lifetime: a retired snapshot remains valid until the last reader using it advances past it. We use a generation counter + reader-active counter; the writer thread parks until all readers have left the prior generation before freeing. Worst-case writer latency is bounded by the longest read query — acceptable since reads are sub-second.
- **WAL group-commit latency spike when one batch slot is held by a slow caller.** Mitigated by `max_delay_us` ceiling.
- **Flush thread crash leaves buffer B in an indeterminate state.** Detected at next `init` — if a `flush.pid` sentinel is found, fail-closed; user must run repair (out-of-scope hint at this stage).

## Test plan

1. **Existing tests must keep passing without modification.** Single-threaded callers see the same semantics; tests that create one `Engine` and one caller thread are unaffected.
2. **New TSan suite** under `tests/concurrent.zig`:

   - N readers concurrently calling `search` while writer indexes
   - Writer + manual flush + writer (no torn reads, no double-free)
   - WAL group commit under bursty load (1 ms idle, then 1000 docs in a tight loop)

3. **Stress: 20× concurrent ingest + search at saturating QPS.** Must finish 20 runs zero-flake.
4. **Crash test: kill -9 mid-group-commit.** WAL replay must recover exactly the records whose ResetEvent fired pre-crash, drop the rest.

## Implementation phases

This decision unblocks substantial work. The implementation lands across multiple commits, each gated by its own `/bench-optimize:run` pass against the relevant scenario:

| Phase | Scope | Gating bench | Expected gain |
|---|---|---|---|
| **B1** | Atomic `next_txn_id` (PERF-0027) — trivial standalone | none — correctness only | none (correctness gate) |
| **B2** | RCU snapshot publication for `segments.items`, `all_norms`, `all_tombstones`. No writer thread yet — writer is still the caller; readers become any thread. | `query_term_iterator_16_segments` | concurrency safety — no perf delta |
| **B3** | WAL writer thread + group commit (PERF-0001 partial) | `engine_index_document`, `ingest_100k_docs_random_terms` | 10–50× write throughput |
| **B4** | Double-buffered + arena-backed memtable (PERF-0003 + PERF-0010 partial) | `ingest_100k_docs_random_terms` | additional 2–4× and ≤2 allocs/doc |
| **B5** | Background flush thread (PERF-0010 full) | `flush_100k_term_memtable` | no p99 ingest stalls |
| **B6** | `tryIndexDocument` backpressure + `flushAsync/flushWait` | new bench (concurrent_ingest_4w_4r) | exposes the throughput ceiling |

Each phase is **its own commit + its own `/bench-optimize:run` evidence directory** under `docs/performance/2026-MM-DD-<phase>/`.

## Out of scope

- **Multi-writer.** This decision adopts a single-writer-thread model. Going to lock-free multi-writer would require a different design (e.g., per-thread WAL shards, then a coordinator merge) — defer to v2.
- **Lock-free segment list mutations.** RCU-style publish is sufficient; full lock-free `AtomicArrayList` is overkill given the writer-thread serializes all mutations.
- **Distributed durability.** Single-node only. Replication is out of scope.

## Migration & risk

- The API surface is additive (`flushAsync`, `flushWait`, `tryIndexDocument`). Existing callers see no breaking change.
- Default `fsync_policy = .group{...}` preserves the same durability guarantee with better latency amortization. The `.every` opt-out is available for the paranoid.
- Existing tests run against the new model unmodified.

## Approval

This document is the architectural decision. Implementation work proceeds in the phases above with separate commits per phase and per-phase bench validation. Each phase's bench evidence directory will reference back to this document.

## Cross-references

- `docs/PERF_GAP_ANALYSIS.md` — PERF-0001, PERF-0003, PERF-0009, PERF-0010, PERF-0027 status moves from `Won't-Do (Concurrency Model Pending)` to `Open (Concurrency Model Adopted; Phase Bn pending)`.
- `docs/SECURITY_GAP_ANALYSIS.md` — SEC-EXT-0701 single-thread assertion narrows to mutating methods only.
- `docs/performance/2026-05-27-bench-coverage-expansion/baselines.md` — the 143–186 ops/s baseline that motivated reopening.
- `b478c6c` — the prior deferral commit, superseded by this decision (2026-05-27).

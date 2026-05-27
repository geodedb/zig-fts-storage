// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Hard caps on disk-resident length fields. Every deserializer must consult
//! these before allocating storage proportional to an untrusted value.

/// Maximum bytes accepted for a single manifest file.
pub const MAX_MANIFEST_BYTES: usize = 64 * 1024 * 1024;

/// Maximum SegmentEntry rows allowed inside a Manifest.
pub const MAX_SEGMENTS_PER_MANIFEST: u32 = 1 << 20; // 1,048,576

/// Maximum total payload bytes accepted for a single WAL record.
pub const MAX_WAL_PAYLOAD_BYTES: u32 = 10 * 1024 * 1024;

/// Aggregate WAL-replay buffer cap. `Engine.replayWal` reads every record
/// into memory before applying it (so it can group by `txn_id` and drop
/// uncommitted brackets). The per-record cap above bounds any single
/// record, but a long-lived WAL with millions of small records could still
/// exhaust memory. Cap the total accumulated payload at 10 GiB across the
/// in-memory list; exceeding it surfaces `error.WalTooLarge` rather than
/// letting the allocator OOM (SEC-EXT-0203).
pub const MAX_WAL_REPLAY_AGGREGATE_BYTES: u64 = 10 * 1024 * 1024 * 1024;

/// Maximum term length (bytes) accepted from any source.
pub const MAX_TERM_LEN: u32 = 1 << 14; // 16 KiB

/// Maximum positions accepted per posting (per (term, doc_id)).
pub const MAX_POSITIONS_PER_TERM: u32 = 1 << 20; // 1,048,576

/// Maximum dictionary terms loaded from a single segment.
pub const MAX_TERMS_PER_SEGMENT: u32 = 1 << 24; // 16,777,216

/// Maximum tombstone entries loaded from a single segment.
pub const MAX_TOMBSTONES_PER_SEGMENT: u32 = 1 << 24;

/// Maximum norm entries (per-doc length records) loaded from a single segment.
/// Bounded the same as terms-per-segment since norms.bin holds one entry per
/// distinct doc_id in the segment (WRK-035, GAP-0005, GAP-0006).
pub const MAX_NORMS_PER_SEGMENT: u32 = 1 << 24;

/// Fallback document length used in BM25 length normalization when the
/// manifest's `avg_doc_len` is still zero (e.g. very first flush) or when
/// a per-doc norm is unavailable. A round-number stand-in keeps the BM25
/// formula stable; correctness of relative ranking is preserved because the
/// same fallback applies uniformly across the missing-data set (WRK-035).
pub const DEFAULT_DOC_LEN: u32 = 100;

/// Maximum byte length of a single segment postings buffer.
pub const MAX_POSTINGS_BYTES: u64 = 4 * 1024 * 1024 * 1024; // 4 GiB

/// Default memtable flush threshold in distinct documents. Exceeding this
/// triggers an automatic flush in `Engine.indexDocument` / `deleteDocument`
/// so memtable memory is bounded regardless of caller behavior
/// (SEC-EXT-0702). The threshold is currently a compile-time constant; a
/// runtime-configurable variant via Engine.init options is deferred.
pub const DEFAULT_MEMTABLE_FLUSH_THRESHOLD_DOCS: u64 = 65536;

test {
    _ = MAX_MANIFEST_BYTES;
}

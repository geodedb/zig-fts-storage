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

/// Maximum term length (bytes) accepted from any source.
pub const MAX_TERM_LEN: u32 = 1 << 14; // 16 KiB

/// Maximum positions accepted per posting (per (term, doc_id)).
pub const MAX_POSITIONS_PER_TERM: u32 = 1 << 20; // 1,048,576

/// Maximum dictionary terms loaded from a single segment.
pub const MAX_TERMS_PER_SEGMENT: u32 = 1 << 24; // 16,777,216

/// Maximum tombstone entries loaded from a single segment.
pub const MAX_TOMBSTONES_PER_SEGMENT: u32 = 1 << 24;

/// Maximum byte length of a single segment postings buffer.
pub const MAX_POSTINGS_BYTES: u64 = 4 * 1024 * 1024 * 1024; // 4 GiB

test {
    _ = MAX_MANIFEST_BYTES;
}

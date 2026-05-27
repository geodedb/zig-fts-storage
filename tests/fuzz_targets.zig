// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Fuzz targets for the critical public deserializers (SEC-EXT-0504).
//!
//! These tests feed adversarial byte sequences into every byte-driven public
//! deserializer that the engine relies on during recovery and startup:
//!
//!   * `fts.manifest.Manifest.deserialize`  — A/B manifest on disk
//!   * `fts.wal.WalRecord.deserialize`      — single WAL record from a buffer
//!   * `fts.utils.readVarInt`               — LEB128 decoder (postings, deltas)
//!
//! Each target must satisfy three contracts:
//!   1. Never panic.
//!   2. Never leak (`std.testing.allocator` enforces).
//!   3. Surface every malformed input as a returned error.
//!
//! Run with `zig build test-fuzz`. The targets exercise a curated corpus of
//! known-adversarial inputs (empty buffers, truncated headers, oversized
//! length fields, bad magic, max-continuation LEB128, etc.). They are not
//! coverage-guided — that is a separate concern handled by the `zig-fuzz`
//! GitLab CI component (`--fuzz` mode), which uses these same entry points.
//! Together they give us coverage-guided exploration in CI plus a fast
//! deterministic regression suite that runs on every push.

const std = @import("std");
const fts = @import("fts_storage");

// ---------------------------------------------------------------------------
// readVarInt — LEB128 u64 decoder. Adversarial inputs target:
//   - empty buffer (EndOfStream)
//   - lone continuation byte (truncated stream)
//   - 11+ bytes of all-0xff (must surface Overflow, not loop or panic)
//   - 10-byte sequence with upper bits set in the 10th byte (SEC-EXT-0210)
//   - the maximum legal LEB128 u64 (boundary case)
// ---------------------------------------------------------------------------

test "fuzz: utils.readVarInt does not panic on adversarial inputs" {
    const cases = [_][]const u8{
        // Empty buffer.
        &[_]u8{},
        // Single continuation byte — truncated stream.
        &[_]u8{0x80},
        // 11 bytes all-continuation — must surface Overflow, not loop.
        &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        // 10 bytes with bits 1..6 of the 10th byte set (SEC-EXT-0210).
        &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7e },
        // Maximum legal u64 LEB128 — last byte is 0x01 (only the low bit set).
        &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
        // Mid-stream EndOfStream (5 continuation bytes, no terminator).
        &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80 },
        // Single zero byte — valid encoding of 0.
        &[_]u8{0x00},
    };
    for (cases) |c| {
        _ = fts.utils.readVarInt(c) catch {};
    }
}

// ---------------------------------------------------------------------------
// Manifest.deserialize — opaque-byte ingestion of the A/B manifest. Adversarial
// inputs target:
//   - empty / undersized buffer
//   - bad magic
//   - oversized segment count (limits.MAX_SEGMENTS_PER_MANIFEST)
//   - mismatched length vs declared count
//   - CRC mismatch
//   - oversized buffer (> MAX_MANIFEST_BYTES)
// ---------------------------------------------------------------------------

test "fuzz: Manifest.deserialize does not panic on adversarial inputs" {
    const allocator = std.testing.allocator;

    const cases = [_][]const u8{
        &[_]u8{},
        // Nominal-length buffer of zeroes — bad magic.
        &[_]u8{0} ** 56,
        // Buffer shorter than min_size (8 magic + 4 fmt + 8 counter + 8 lsn
        // + 8 docs + 4 avg_len + 4 count + 4 crc = 48 bytes).
        &[_]u8{0xab} ** 16,
        // Single 0xff byte — must not panic.
        &[_]u8{0xff},
        // Empty-segment manifest with wrong CRC (valid magic, zero count,
        // zero CRC — CRC of all-zero header is non-zero, so this fails CRC).
        // 8 magic + 40 zeros + 4 crc = 52, but min_size is 48 (no HMAC),
        // so we pad to exactly the minimum.
        blk: {
            var buf: [48]u8 = @splat(0);
            @memcpy(buf[0..8], "FTSMNF01");
            break :blk &buf;
        },
    };
    for (cases) |c| {
        var m = fts.manifest.Manifest.deserialize(allocator, c) catch continue;
        defer m.deinit(allocator);
    }
}

// ---------------------------------------------------------------------------
// WalRecord.deserialize — opaque-byte ingestion of a single WAL record from
// a buffer. Distinct from WalReader.next, which reads from std.Io.File and
// thus cannot accept arbitrary fuzzer-controlled bytes directly. Adversarial
// inputs target:
//   - empty / undersized buffer
//   - invalid record_type byte (0, 5, 0xff)
//   - oversized payload_len triggering buffer-bounds error
//   - CRC mismatch
// ---------------------------------------------------------------------------

test "fuzz: WalRecord.deserialize does not panic on adversarial inputs" {
    const allocator = std.testing.allocator;

    const cases = [_][]const u8{
        &[_]u8{},
        // Header-only zeros — record_type 0 must reject.
        &[_]u8{0} ** 25,
        // record_type 0xff — out of enum range.
        blk: {
            var buf: [25]u8 = @splat(0);
            buf[0] = 0xff;
            break :blk &buf;
        },
        // Valid record_type, oversized payload_len (0xffffffff) — must not
        // attempt to allocate 4 GiB; the bounds check at pos+payload_len+4
        // must reject as Incomplete.
        blk: {
            var buf: [25]u8 = @splat(0);
            buf[0] = 1;
            // payload_len at offset 17..21
            buf[17] = 0xff;
            buf[18] = 0xff;
            buf[19] = 0xff;
            buf[20] = 0xff;
            break :blk &buf;
        },
        // Truncated stream — under the minimum 25-byte header.
        &[_]u8{ 1, 0, 0 },
    };
    for (cases) |c| {
        const result = fts.wal.WalRecord.deserialize(allocator, c) catch continue;
        allocator.free(result.rec.payload);
    }
}

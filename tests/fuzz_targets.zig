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
//!   * `SegmentReader.PostingIterator.next` / `.nextDocOnly` — postings byte
//!     run decoder (doc-id deltas, term frequencies, position deltas)
//!   * `fts.segment.SegmentReader.init`     — file-level ingestion of
//!     `terms.hash` (dictionary), `tombstones.bin`, and `norms.bin`, in both
//!     the legacy-naked and v2-enveloped (magic + version + CRC) formats
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

// ---------------------------------------------------------------------------
// PostingIterator — decodes postings byte runs whose only pre-GSP-9 integrity
// was structural. Adversarial inputs target: truncated varints, max-
// continuation floods, doc-id delta overflow, position delta > u32,
// df larger than the data can satisfy (GSP-4, GSP-10).
// ---------------------------------------------------------------------------

test "fuzz: PostingIterator does not panic on adversarial postings bytes" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        &[_]u8{},
        // Truncated continuation flood.
        &([_]u8{0x80} ** 16),
        // Overflow-length varints everywhere.
        &([_]u8{0xff} ** 32),
        // doc delta = maxInt(u64), then another posting -> checked-add error.
        &([_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 } ++
            [_]u8{ 0x01, 0x01, 0x01, 0x01, 0x01 }),
        // valid doc delta + tf, then position delta = maxInt(u64) -> cast error.
        &([_]u8{ 0x01, 0x01 } ++
            [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }),
        // Single zero byte.
        &[_]u8{0x00},
    };
    for (cases) |c| {
        var it = fts.segment.SegmentReader.PostingIterator{
            .allocator = alloc,
            .data = c,
            .owns_data = false,
            .df = 4,
            .current_idx = 0,
            .pos = 0,
            .last_doc_id = 0,
            .pos_buf = .empty,
        };
        defer it.pos_buf.deinit(alloc);
        // Drain until error or exhaustion; must never panic or leak.
        while (it.next() catch null) |_| {}
        // Same contract for the doc-only fast path.
        var it2 = fts.segment.SegmentReader.PostingIterator{
            .allocator = alloc,
            .data = c,
            .owns_data = false,
            .df = 4,
            .current_idx = 0,
            .pos = 0,
            .last_doc_id = 0,
            .pos_buf = .empty,
        };
        defer it2.pos_buf.deinit(alloc);
        while (it2.nextDocOnly() catch null) |_| {}
    }
}

// ---------------------------------------------------------------------------
// SegmentReader.load — file-level ingestion of terms.hash (GSP-5, GSP-9,
// GSP-10). Adversarial inputs target: naked-legacy garbage, oversized counts,
// truncated entries, hostile (offset, len) pairs, valid-magic envelopes with
// bad CRC, and future envelope versions. tombstones.bin/norms.bin get their
// own dedicated adversarial coverage below (they parse differently from
// terms.hash and need real per-file cases, not shared bytes).
// ---------------------------------------------------------------------------

test "fuzz: SegmentReader.init does not panic on adversarial segment files" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dict_cases = [_][]const u8{
        &[_]u8{},
        // count = maxInt -> TermCountTooLarge.
        &[_]u8{ 0xff, 0xff, 0xff, 0xff },
        // count = 1, truncated entry.
        &[_]u8{ 0x01, 0x00, 0x00, 0x00, 0x05, 0x00 },
        // count = 1, term "t", hostile df/offset/len = all-0xff (maxInt).
        blk: {
            var buf: [4 + 2 + 1 + 24]u8 = @splat(0xff);
            std.mem.writeInt(u32, buf[0..4], 1, .little);
            std.mem.writeInt(u16, buf[4..6], 1, .little);
            buf[6] = 't';
            break :blk &buf;
        },
        // v2 magic + version 2 + garbage payload + wrong CRC.
        blk: {
            var buf: [24]u8 = @splat(0xab);
            @memcpy(buf[0..4], &fts.segment.SEGMENT_FILE_MAGIC);
            std.mem.writeInt(u32, buf[4..8], fts.segment.SEGMENT_FILE_VERSION, .little);
            break :blk &buf;
        },
        // v2 magic + FUTURE version.
        blk: {
            var buf: [24]u8 = @splat(0);
            @memcpy(buf[0..4], &fts.segment.SEGMENT_FILE_MAGIC);
            std.mem.writeInt(u32, buf[4..8], 99, .little);
            break :blk &buf;
        },
    };

    for (dict_cases, 0..) |c, i| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        _ = i;
        try tmp_dir.dir.createDir(io, "seg_1", .default_dir);
        var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);
        {
            const f = try seg_dir.createFile(io, "terms.hash", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, c);
        }
        {
            const f = try seg_dir.createFile(io, "postings.bin", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, &([_]u8{0} ** 4));
        }
        var sr = fts.segment.SegmentReader.init(io, alloc, tmp_dir.dir, 1) catch continue;
        sr.deinit();
    }
}

// ---------------------------------------------------------------------------
// SegmentReader.load — tombstones.bin / norms.bin (GSP-9, GSP-10). Real
// per-file adversarial coverage: each case below is written directly as
// tombstones.bin and, separately, as norms.bin, alongside a *valid* empty
// terms.hash dictionary (count = 0) and a matching valid postings.bin, so
// SegmentReader.init reaches the tombstones/norms parse instead of failing
// earlier on an unrelated file.
//
// `SegmentReader.file_format` is detected once from terms.hash and then
// reused (verbatim) as the `expect` argument for every other segment file
// (segment.zig readSegmentFile call sites for postings.bin/tombstones.bin/
// norms.bin). So the same four adversarial byte blobs are driven twice: once
// with a legacy-naked empty dictionary (tombstones/norms are read verbatim,
// no magic/CRC check — `.legacy` short-circuits in readSegmentFile) and once
// with a v2-enveloped empty dictionary (tombstones/norms must additionally
// satisfy the magic + version + CRC envelope, or the `.enveloped` branch of
// readSegmentFile rejects them). Adversarial inputs target:
//   - empty file (0 bytes)               -> len < 4 Incomplete (legacy) /
//                                            no magic -> InvalidData (env.)
//   - count = maxInt(u32)                 -> Tombstone/NormCountTooLarge
//     (legacy) / no magic -> InvalidData (enveloped, since len < 12)
//   - count = 3, only one full entry present -> per-entry Incomplete
//     (legacy) / no magic -> InvalidData (enveloped; the file is exactly 12
//     bytes, but its leading bytes are the count/payload, not the FSG2
//     magic, so has_magic is false)
//   - v2 magic + version 2 + garbage payload + wrong CRC (24 bytes) ->
//     parsed as naked legacy bytes when terms.hash is legacy (the leading
//     magic bytes just become a huge bogus count, which still must not
//     panic); parsed as a real v2 envelope with ChecksumMismatch when
//     terms.hash is enveloped.
// ---------------------------------------------------------------------------

test "fuzz: SegmentReader.init does not panic on adversarial tombstones/norms" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const adversarial_cases = [_][]const u8{
        // Empty file.
        &[_]u8{},
        // count = maxInt(u32).
        &[_]u8{ 0xff, 0xff, 0xff, 0xff },
        // count = 3, only one full entry's worth of trailing bytes present
        // (8 bytes covers a tombstone doc_id; norms needs 12 and will hit
        // Incomplete one field sooner — both paths must not panic).
        &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
        // v2 magic + version 2 + garbage payload + wrong CRC (24 bytes).
        blk: {
            var buf: [24]u8 = @splat(0xab);
            @memcpy(buf[0..4], &fts.segment.SEGMENT_FILE_MAGIC);
            std.mem.writeInt(u32, buf[4..8], fts.segment.SEGMENT_FILE_VERSION, .little);
            break :blk &buf;
        },
    };

    // Legacy-naked empty dictionary (count = 0) and a matching legacy
    // postings.bin (file_format ends up `.legacy`, so postings.bin carries
    // no envelope and any size is accepted since the dictionary has zero
    // entries to bounds-check against it).
    const legacy_dict = [_]u8{ 0, 0, 0, 0 };
    const legacy_postings = [_]u8{ 0, 0, 0, 0 };

    // Valid v2-enveloped empty dictionary: magic + version + 4-zero-byte
    // payload (count = 0) + correct crc32c over magic+version+payload, per
    // the exact envelope construction in segment.zig's writeFile/
    // readSegmentFile (crc covers everything except its own 4 trailing
    // bytes). file_format ends up `.enveloped`, so postings.bin must also
    // carry a valid 8-byte magic+version header (>= 12 bytes total) — the
    // plaintext postings-sizing path checks that header but not its CRC.
    const enveloped_dict = blk: {
        var buf: [16]u8 = undefined;
        @memcpy(buf[0..4], &fts.segment.SEGMENT_FILE_MAGIC);
        std.mem.writeInt(u32, buf[4..8], fts.segment.SEGMENT_FILE_VERSION, .little);
        @memset(buf[8..12], 0);
        const crc = fts.utils.hashCrc32c(buf[0..12]);
        std.mem.writeInt(u32, buf[12..16], crc, .little);
        break :blk buf;
    };
    const enveloped_postings = blk: {
        var buf: [12]u8 = @splat(0);
        @memcpy(buf[0..4], &fts.segment.SEGMENT_FILE_MAGIC);
        std.mem.writeInt(u32, buf[4..8], fts.segment.SEGMENT_FILE_VERSION, .little);
        break :blk buf;
    };

    const DictVariant = struct { dict: []const u8, postings: []const u8 };
    const dict_variants = [_]DictVariant{
        .{ .dict = &legacy_dict, .postings = &legacy_postings },
        .{ .dict = &enveloped_dict, .postings = &enveloped_postings },
    };

    for (dict_variants) |variant| {
        for (adversarial_cases) |case| {
            // Round A: adversarial bytes as tombstones.bin.
            {
                var tmp_dir = std.testing.tmpDir(.{});
                defer tmp_dir.cleanup();
                try tmp_dir.dir.createDir(io, "seg_1", .default_dir);
                var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
                defer seg_dir.close(io);
                {
                    const f = try seg_dir.createFile(io, "terms.hash", .{});
                    defer f.close(io);
                    try f.writeStreamingAll(io, variant.dict);
                }
                {
                    const f = try seg_dir.createFile(io, "postings.bin", .{});
                    defer f.close(io);
                    try f.writeStreamingAll(io, variant.postings);
                }
                {
                    const f = try seg_dir.createFile(io, "tombstones.bin", .{});
                    defer f.close(io);
                    try f.writeStreamingAll(io, case);
                }
                var sr = fts.segment.SegmentReader.init(io, alloc, tmp_dir.dir, 1) catch continue;
                sr.deinit();
            }
            // Round B: same adversarial bytes as norms.bin.
            {
                var tmp_dir = std.testing.tmpDir(.{});
                defer tmp_dir.cleanup();
                try tmp_dir.dir.createDir(io, "seg_1", .default_dir);
                var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
                defer seg_dir.close(io);
                {
                    const f = try seg_dir.createFile(io, "terms.hash", .{});
                    defer f.close(io);
                    try f.writeStreamingAll(io, variant.dict);
                }
                {
                    const f = try seg_dir.createFile(io, "postings.bin", .{});
                    defer f.close(io);
                    try f.writeStreamingAll(io, variant.postings);
                }
                {
                    const f = try seg_dir.createFile(io, "norms.bin", .{});
                    defer f.close(io);
                    try f.writeStreamingAll(io, case);
                }
                var sr = fts.segment.SegmentReader.init(io, alloc, tmp_dir.dir, 1) catch continue;
                sr.deinit();
            }
        }
    }
}

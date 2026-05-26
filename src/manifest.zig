// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const limits = @import("limits.zig");

pub const Error = @import("errors.zig").ManifestError;

pub const MANIFEST_MAGIC: [8]u8 = .{ 'F', 'T', 'S', 'M', 'N', 'F', '0', '1' };
pub const MANIFEST_VERSION: u32 = 2;

pub const SegmentEntry = struct {
    id: u64,
    doc_count: u64,
    tombstone_count: u64,
    /// LSN at the time this segment was sealed.
    created_lsn: u64 = 0,
    /// Compaction level (0 = flushed memtable; >0 reserved for WRK-041).
    level: u8 = 0,
    /// Padding for fixed serialized size.
    _reserved: [7]u8 = .{0} ** 7,
};

pub const Manifest = struct {
    format_version: u32 = MANIFEST_VERSION,
    counter: u64 = 0,
    last_checkpoint_lsn: u64 = 0,
    total_docs: u64 = 0,
    avg_doc_len: u32 = 0,
    segments: std.ArrayListUnmanaged(SegmentEntry) = .empty,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.segments.deinit(allocator);
    }

    pub fn serialize(self: *const @This(), allocator: Allocator) ![]u8 {
        // v2 layout (QUAL-0014):
        //   magic(8) + version(4) + counter(8) + lsn(8) + total_docs(8)
        // + avg_doc_len(4) + segment_count(4)
        // + segments(40 * count: id(8)+doc_count(8)+tombstone_count(8)
        //                       +created_lsn(8)+level(1)+_reserved(7))
        // + crc(4)
        const header_size = 8 + 4 + 8 + 8 + 8 + 4 + 4;
        const total_size = header_size + (self.segments.items.len * 40) + 4;
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        var pos: usize = 0;

        @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC);
        pos += 8;
        writeU32(buf, &pos, self.format_version);
        writeU64(buf, &pos, self.counter);
        writeU64(buf, &pos, self.last_checkpoint_lsn);
        writeU64(buf, &pos, self.total_docs);
        writeU32(buf, &pos, self.avg_doc_len);
        writeU32(buf, &pos, @intCast(self.segments.items.len));

        for (self.segments.items) |seg| {
            writeU64(buf, &pos, seg.id);
            writeU64(buf, &pos, seg.doc_count);
            writeU64(buf, &pos, seg.tombstone_count);
            writeU64(buf, &pos, seg.created_lsn);
            buf[pos] = seg.level;
            pos += 1;
            @memcpy(buf[pos..][0..7], &seg._reserved);
            pos += 7;
        }

        const crc = utils.hashCrc32c(buf[0..pos]);
        writeU32(buf, &pos, crc);
        return buf;
    }

    pub fn deserialize(allocator: Allocator, data: []const u8) !Manifest {
        const min_size = 8 + 4 + 8 + 8 + 8 + 4 + 4 + 4;
        if (data.len < min_size) return error.InvalidData;
        if (data.len > limits.MAX_MANIFEST_BYTES) return error.ManifestTooLarge;
        if (!std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC)) return error.InvalidMagic;

        const stored_crc = readU32NoAdvance(data, data.len - 4);
        const computed_crc = utils.hashCrc32c(data[0 .. data.len - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        var pos: usize = 8;
        var m = Manifest{};
        m.format_version = readU32(data, &pos);
        m.counter = readU64(data, &pos);
        m.last_checkpoint_lsn = readU64(data, &pos);
        m.total_docs = readU64(data, &pos);
        m.avg_doc_len = readU32(data, &pos);
        const count = readU32(data, &pos);

        if (count > limits.MAX_SEGMENTS_PER_MANIFEST) return error.SegmentCountTooLarge;
        if (data.len != min_size + @as(usize, count) * 40) return error.InvalidData;

        try m.segments.ensureTotalCapacity(allocator, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const id = readU64(data, &pos);
            const doc_count = readU64(data, &pos);
            const tombstone_count = readU64(data, &pos);
            const created_lsn = readU64(data, &pos);
            const level = data[pos];
            pos += 1;
            var reserved: [7]u8 = undefined;
            @memcpy(&reserved, data[pos..][0..7]);
            pos += 7;
            m.segments.appendAssumeCapacity(.{
                .id = id,
                .doc_count = doc_count,
                .tombstone_count = tombstone_count,
                .created_lsn = created_lsn,
                .level = level,
                ._reserved = reserved,
            });
        }
        return m;
    }

    /// Selects the most recent valid manifest from two candidates.
    pub fn selectManifest(a: ?Manifest, b: ?Manifest) !Manifest {
        if (a == null and b == null) return error.NoManifest;
        if (a == null) return b.?;
        if (b == null) return a.?;
        return if (a.?.counter >= b.?.counter) a.? else b.?;
    }

    pub fn writeToFile(self: *const @This(), io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: Allocator) !void {
        const data = try self.serialize(allocator);
        defer allocator.free(data);
        try utils.atomicWrite(io, dir, path, data);
    }
};

fn writeU32(buf: []u8, pos: *usize, value: u32) void {
    @memcpy(buf[pos.*..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
    pos.* += 4;
}

fn writeU64(buf: []u8, pos: *usize, value: u64) void {
    @memcpy(buf[pos.*..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    pos.* += 8;
}

fn readU32(data: []const u8, offset: *usize) u32 {
    const v = std.mem.littleToNative(u32, @bitCast(data[offset.*..][0..4].*));
    offset.* += 4;
    return v;
}

fn readU64(data: []const u8, offset: *usize) u64 {
    const v = std.mem.littleToNative(u64, @bitCast(data[offset.*..][0..8].*));
    offset.* += 8;
    return v;
}

fn readU32NoAdvance(data: []const u8, offset: usize) u32 {
    return std.mem.littleToNative(u32, @bitCast(data[offset..][0..4].*));
}

// ============================================================================
// Unit Tests
// ============================================================================

test "manifest serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    var m = Manifest{
        .counter = 42,
        .last_checkpoint_lsn = 100,
        .total_docs = 500,
        .avg_doc_len = 10,
    };
    try m.segments.append(allocator, .{
        .id = 1,
        .doc_count = 100,
        .tombstone_count = 5,
        .created_lsn = 999,
        .level = 0,
    });
    try m.segments.append(allocator, .{
        .id = 2,
        .doc_count = 200,
        .tombstone_count = 0,
        .created_lsn = 1500,
        .level = 1,
    });
    defer m.deinit(allocator);

    const data = try m.serialize(allocator);
    defer allocator.free(data);

    var m2 = try Manifest.deserialize(allocator, data);
    defer m2.deinit(allocator);

    try std.testing.expectEqual(m.counter, m2.counter);
    try std.testing.expectEqual(m.last_checkpoint_lsn, m2.last_checkpoint_lsn);
    try std.testing.expectEqual(m.total_docs, m2.total_docs);
    try std.testing.expectEqual(m.avg_doc_len, m2.avg_doc_len);
    try std.testing.expectEqual(m.segments.items.len, m2.segments.items.len);
    try std.testing.expectEqual(m.segments.items[0].id, m2.segments.items[0].id);
    try std.testing.expectEqual(m.segments.items[1].tombstone_count, m2.segments.items[1].tombstone_count);
    // SegmentEntry ordering metadata (WRK-018, QUAL-0014) round-trips.
    try std.testing.expectEqual(@as(u64, 999), m2.segments.items[0].created_lsn);
    try std.testing.expectEqual(@as(u64, 1500), m2.segments.items[1].created_lsn);
    try std.testing.expectEqual(@as(u8, 0), m2.segments.items[0].level);
    try std.testing.expectEqual(@as(u8, 1), m2.segments.items[1].level);
}

test "manifest corrupt data detected (bad CRC)" {
    const allocator = std.testing.allocator;
    var m = Manifest{};
    const data = try m.serialize(allocator);
    defer allocator.free(data);

    // Corrupt a byte
    data[20] ^= 0xFF;

    const result = Manifest.deserialize(allocator, data);
    try std.testing.expectError(error.ChecksumMismatch, result);
}

test "manifest deserialize rejects oversized count" {
    const allocator = std.testing.allocator;
    // Craft a manifest header that claims count = MAX_U32 (would allocate ~96 GiB)
    // Layout: magic(8) + version(4) + counter(8) + lsn(8) + total_docs(8) + avg_doc_len(4) + segment_count(4) + crc(4) = 48 bytes
    var buf: [48]u8 = undefined;
    @memcpy(buf[0..8], &MANIFEST_MAGIC);
    var pos: usize = 8;
    writeU32(&buf, &pos, MANIFEST_VERSION);
    writeU64(&buf, &pos, 0); // counter
    writeU64(&buf, &pos, 0); // lsn
    writeU64(&buf, &pos, 0); // total_docs
    writeU32(&buf, &pos, 0); // avg_doc_len
    writeU32(&buf, &pos, 0xFFFFFFFF); // segment_count -- adversarial
    const crc = utils.hashCrc32c(buf[0..44]);
    writeU32(&buf, &pos, crc);

    try std.testing.expectError(error.SegmentCountTooLarge, Manifest.deserialize(allocator, &buf));
}

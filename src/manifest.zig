// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const MANIFEST_MAGIC: [8]u8 = .{ 'F', 'T', 'S', 'M', 'N', 'F', '0', '1' };
pub const MANIFEST_VERSION: u32 = 1;

pub const SegmentEntry = struct {
    id: u64,
    doc_count: u64,
    tombstone_count: u64,
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
        // magic(8) + version(4) + counter(8) + lsn(8) + total_docs(8) + avg_doc_len(4) + segment_count(4) + segments(24 * count) + crc(4)
        const header_size = 8 + 4 + 8 + 8 + 8 + 4 + 4;
        const total_size = header_size + (self.segments.items.len * 24) + 4;
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
        }

        const crc = utils.hashCrc32c(buf[0..pos]);
        writeU32(buf, &pos, crc);
        return buf;
    }

    pub fn deserialize(allocator: Allocator, data: []const u8) !Manifest {
        const min_size = 8 + 4 + 8 + 8 + 8 + 4 + 4 + 4;
        if (data.len < min_size) return error.InvalidData;
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

        if (data.len != min_size + count * 24) return error.InvalidData;

        try m.segments.ensureTotalCapacity(allocator, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            m.segments.appendAssumeCapacity(.{
                .id = readU64(data, &pos),
                .doc_count = readU64(data, &pos),
                .tombstone_count = readU64(data, &pos),
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
    try m.segments.append(allocator, .{ .id = 1, .doc_count = 100, .tombstone_count = 5 });
    try m.segments.append(allocator, .{ .id = 2, .doc_count = 200, .tombstone_count = 0 });
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

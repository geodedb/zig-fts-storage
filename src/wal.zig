// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const Error = @import("errors.zig").WalError;

pub const WalRecordType = enum(u8) {
    begin = 1,
    commit = 2,
    index_doc = 3,
    delete_doc = 4,
};

pub const WalRecord = struct {
    record_type: WalRecordType,
    txn_id: u64,
    doc_id: u64 = 0,
    payload: []const u8 = &[_]u8{},

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        alloc.free(self.payload);
    }

    pub fn serialize(self: *const @This(), alloc: Allocator) ![]u8 {
        const payload_len: u32 = @intCast(self.payload.len);
        const size = 1 + 8 + 8 + 4 + payload_len + 4; // type(1) + txn(8) + doc(8) + len(4) + payload + crc(4)
        const buf = try alloc.alloc(u8, size);
        buf[0] = @intFromEnum(self.record_type);
        var pos: usize = 1;
        writeU64(buf, &pos, self.txn_id);
        writeU64(buf, &pos, self.doc_id);
        writeU32(buf, &pos, payload_len);
        @memcpy(buf[pos .. pos + payload_len], self.payload);
        pos += payload_len;
        const crc = utils.hashCrc32c(buf[0..pos]);
        writeU32(buf, &pos, crc);
        return buf;
    }

    pub fn deserialize(alloc: Allocator, data: []const u8) !struct { rec: WalRecord, bytes_read: usize } {
        if (data.len < 1 + 8 + 8 + 4 + 4) return error.Incomplete;

        var pos: usize = 0;
        const record_type_val = data[0];
        if (record_type_val < 1 or record_type_val > 4) return error.InvalidData;
        const record_type = @as(WalRecordType, @enumFromInt(record_type_val));
        pos += 1;

        const txn_id = readU64(data, &pos);
        const doc_id = readU64(data, &pos);
        const payload_len = readU32(data, &pos);

        if (data.len < pos + payload_len + 4) return error.Incomplete;

        const payload = data[pos .. pos + payload_len];
        pos += payload_len;

        const stored_crc = readU32(data, &pos);
        const computed_crc = utils.hashCrc32c(data[0 .. pos - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // Copy payload to allocator to own the memory
        const payload_copy = try alloc.dupe(u8, payload);

        return .{
            .rec = .{
                .record_type = record_type,
                .txn_id = txn_id,
                .doc_id = doc_id,
                .payload = payload_copy,
            },
            .bytes_read = pos,
        };
    }
};

pub const WalWriter = struct {
    file: std.Io.File,
    allocator: Allocator,
    io: std.Io,
    offset: u64,

    pub fn init(io: std.Io, file: std.Io.File, allocator: Allocator) !WalWriter {
        const stat = try file.stat(io);
        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
            .offset = stat.size,
        };
    }

    pub fn append(self: *WalWriter, record: WalRecord) !void {
        const data = try record.serialize(self.allocator);
        defer self.allocator.free(data);
        try self.file.writePositionalAll(self.io, data, self.offset);
        self.offset += data.len;
    }

    pub fn sync(self: *WalWriter) !void {
        try self.file.sync(self.io);
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

pub const WalReader = struct {
    file: std.Io.File,
    allocator: Allocator,
    io: std.Io,

    pub fn init(io: std.Io, file: std.Io.File, allocator: Allocator) WalReader {
        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
        };
    }

    /// Reads the next WAL record from the file.
    /// Returns null if EOF is reached.
    /// Returns an error if the record is corrupt or incomplete.
    pub fn next(self: *WalReader) !?WalRecord {
        var header_buf: [1 + 8 + 8 + 4]u8 = undefined;
        var header_iov = [_][]u8{&header_buf};
        const read_header = self.file.readStreaming(self.io, &header_iov) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (read_header == 0) return null;
        if (read_header < header_buf.len) return error.Incomplete;

        var pos: usize = 0;
        const record_type_val = header_buf[0];
        if (record_type_val < 1 or record_type_val > 4) return error.InvalidData;
        const record_type = @as(WalRecordType, @enumFromInt(record_type_val));
        pos += 1;

        const txn_id = readU64(&header_buf, &pos);
        const doc_id = readU64(&header_buf, &pos);
        const payload_len = readU32(&header_buf, &pos);

        if (payload_len > 10 * 1024 * 1024) return error.InvalidData;

        const payload_and_crc = try self.allocator.alloc(u8, payload_len + 4);
        defer self.allocator.free(payload_and_crc);

        var payload_iov = [_][]u8{payload_and_crc};
        const read_payload = try self.file.readStreaming(self.io, &payload_iov);
        if (read_payload < payload_len + 4) return error.Incomplete;

        const payload = payload_and_crc[0..payload_len];
        var crc_pos: usize = payload_len;
        const stored_crc = readU32(payload_and_crc, &crc_pos);

        var hasher = std.hash.crc.Crc32Iscsi.init();
        hasher.update(&header_buf);
        hasher.update(payload);
        const computed_crc = hasher.final();

        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        const payload_copy = try self.allocator.dupe(u8, payload);

        return WalRecord{
            .record_type = record_type,
            .txn_id = txn_id,
            .doc_id = doc_id,
            .payload = payload_copy,
        };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "wal serialize/deserialize round-trip" {
    const alloc = std.testing.allocator;

    const r = WalRecord{
        .record_type = .index_doc,
        .txn_id = 999,
        .doc_id = 12345,
        .payload = "hello world",
    };

    const data = try r.serialize(alloc);
    defer alloc.free(data);

    const decoded = try WalRecord.deserialize(alloc, data);
    var r2 = decoded.rec;
    defer r2.deinit(alloc);

    try std.testing.expectEqual(r.record_type, r2.record_type);
    try std.testing.expectEqual(r.txn_id, r2.txn_id);
    try std.testing.expectEqual(r.doc_id, r2.doc_id);
    try std.testing.expectEqualStrings(r.payload, r2.payload);
    try std.testing.expectEqual(data.len, decoded.bytes_read);
}

test "wal corrupt data detected (bad CRC)" {
    const alloc = std.testing.allocator;
    const r = WalRecord{
        .record_type = .begin,
        .txn_id = 1,
    };
    const data = try r.serialize(alloc);
    defer alloc.free(data);

    // Corrupt a byte
    data[2] ^= 0xFF;

    const result = WalRecord.deserialize(alloc, data);
    try std.testing.expectError(error.ChecksumMismatch, result);
}
test "WalReader reads records sequentially" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const file_path = "test_wal.bin";

    // Write records
    {
        const file = try tmp_dir.dir.createFile(io, file_path, .{});
        defer file.close(io);
        var writer = try WalWriter.init(io, file, alloc);

        const r1 = WalRecord{ .record_type = .begin, .txn_id = 1 };
        try writer.append(r1);

        const r2 = WalRecord{ .record_type = .index_doc, .txn_id = 1, .doc_id = 10, .payload = "test payload" };
        try writer.append(r2);

        try writer.sync();
    }

    // Read records
    {
        const file = try tmp_dir.dir.openFile(io, file_path, .{});
        defer file.close(io);
        var reader = WalReader.init(io, file, alloc);

        const rec1 = try reader.next();
        try std.testing.expect(rec1 != null);
        var r1 = rec1.?;
        defer r1.deinit(alloc);
        try std.testing.expectEqual(WalRecordType.begin, r1.record_type);
        try std.testing.expectEqual(@as(u64, 1), r1.txn_id);

        const rec2 = try reader.next();
        try std.testing.expect(rec2 != null);
        var r2 = rec2.?;
        defer r2.deinit(alloc);
        try std.testing.expectEqual(WalRecordType.index_doc, r2.record_type);
        try std.testing.expectEqual(@as(u64, 1), r2.txn_id);
        try std.testing.expectEqual(@as(u64, 10), r2.doc_id);
        try std.testing.expectEqualStrings("test payload", r2.payload);

        const rec3 = try reader.next();
        try std.testing.expect(rec3 == null);
    }
}

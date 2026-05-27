// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const Error = @import("errors.zig").WalError;

pub const WalRecordType = enum(u8) {
    // Reserved: future transactional bracketing (see WRK-025 / GAP-0012, GAP-0013).
    // Today these are accepted on read for forward compat but never emitted by Engine.
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
        utils.writeU64Le(buf, &pos, self.txn_id);
        utils.writeU64Le(buf, &pos, self.doc_id);
        utils.writeU32Le(buf, &pos, payload_len);
        @memcpy(buf[pos .. pos + payload_len], self.payload);
        pos += payload_len;
        const crc = utils.hashCrc32c(buf[0..pos]);
        utils.writeU32Le(buf, &pos, crc);
        return buf;
    }

    /// Serialize into a caller-provided buffer instead of allocating a fresh
    /// one (WRK-032, PERF-0002). Equivalent bytes to `serialize` but reuses
    /// the buffer's capacity across calls — the WalWriter's per-bracket
    /// scratch is the primary caller.
    pub fn serializeInto(self: *const @This(), alloc: Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
        const payload_len: u32 = @intCast(self.payload.len);
        const size = 1 + 8 + 8 + 4 + payload_len + 4;
        try buf.ensureUnusedCapacity(alloc, size);
        const start = buf.items.len;
        buf.appendAssumeCapacity(@intFromEnum(self.record_type));
        var num_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &num_buf, self.txn_id, .little);
        buf.appendSliceAssumeCapacity(&num_buf);
        std.mem.writeInt(u64, &num_buf, self.doc_id, .little);
        buf.appendSliceAssumeCapacity(&num_buf);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, payload_len, .little);
        buf.appendSliceAssumeCapacity(&len_buf);
        buf.appendSliceAssumeCapacity(self.payload);
        const crc = utils.hashCrc32c(buf.items[start..]);
        std.mem.writeInt(u32, &len_buf, crc, .little);
        buf.appendSliceAssumeCapacity(&len_buf);
    }

    pub fn deserialize(alloc: Allocator, data: []const u8) !struct { rec: WalRecord, bytes_read: usize } {
        if (data.len < 1 + 8 + 8 + 4 + 4) return error.Incomplete;

        var pos: usize = 0;
        const record_type_val = data[0];
        if (record_type_val < 1 or record_type_val > 4) return error.InvalidData;
        const record_type = @as(WalRecordType, @enumFromInt(record_type_val));
        pos += 1;

        const txn_id = utils.readU64Le(data, &pos);
        const doc_id = utils.readU64Le(data, &pos);
        const payload_len = utils.readU32Le(data, &pos);

        if (data.len < pos + payload_len + 4) return error.Incomplete;

        const payload = data[pos .. pos + payload_len];
        pos += payload_len;

        const stored_crc = utils.readU32Le(data, &pos);
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
    /// Per-writer scratch buffer reused across append() calls so each WAL
    /// record does not allocate a fresh heap buffer for serialization
    /// (WRK-032, PERF-0002). Group-commit batching (one fsync over N
    /// records) is a follow-up — this change only removes the per-record
    /// alloc/free churn without touching durability semantics.
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    /// Optional HMAC-SHA256 key. When non-null, every appended record is
    /// followed by a 32-byte HMAC tag computed over the existing
    /// `serializeInto` bytes (which already include CRC32C). Default null
    /// preserves the pre-WRK-037 on-disk format byte-for-byte
    /// (SEC-02, SEC-EXT-0401, GAP-0027).
    hmac_key: ?[]const u8 = null,

    pub fn init(io: std.Io, file: std.Io.File, allocator: Allocator) !WalWriter {
        const stat = try file.stat(io);
        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
            .offset = stat.size,
        };
    }

    pub fn initWithHmac(
        io: std.Io,
        file: std.Io.File,
        allocator: Allocator,
        hmac_key: ?[]const u8,
    ) !WalWriter {
        var w = try WalWriter.init(io, file, allocator);
        w.hmac_key = hmac_key;
        return w;
    }

    pub fn deinit(self: *WalWriter) void {
        self.scratch.deinit(self.allocator);
    }

    pub fn append(self: *WalWriter, record: WalRecord) !void {
        self.scratch.clearRetainingCapacity();
        try record.serializeInto(self.allocator, &self.scratch);

        // HMAC-SHA256 envelope when configured (SEC-02, SEC-EXT-0401,
        // GAP-0027). The tag is computed over the entire serialized record
        // — header + payload + CRC — and appended as 32 trailing bytes.
        // Without a key the bytes on disk are unchanged from the pre-WRK-037
        // format, so existing data files and tests remain valid.
        if (self.hmac_key) |key| {
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
            var tag: [Hmac.mac_length]u8 = undefined;
            Hmac.create(&tag, self.scratch.items, key);
            try self.scratch.appendSlice(self.allocator, &tag);
        }

        try self.file.writePositionalAll(self.io, self.scratch.items, self.offset);
        self.offset += self.scratch.items.len;
    }

    pub fn sync(self: *WalWriter) !void {
        try self.file.sync(self.io);
    }
};

pub const WalReader = struct {
    file: std.Io.File,
    allocator: Allocator,
    io: std.Io,
    /// Optional HMAC-SHA256 key. When non-null, every record is expected to
    /// be followed by a 32-byte HMAC tag — `next()` reads and verifies it,
    /// returning `error.HmacMismatch` on failure. Default null preserves the
    /// pre-WRK-037 wire format (SEC-02, SEC-EXT-0401, GAP-0027).
    hmac_key: ?[]const u8 = null,

    pub fn init(io: std.Io, file: std.Io.File, allocator: Allocator) WalReader {
        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
        };
    }

    pub fn initWithHmac(
        io: std.Io,
        file: std.Io.File,
        allocator: Allocator,
        hmac_key: ?[]const u8,
    ) WalReader {
        var r = WalReader.init(io, file, allocator);
        r.hmac_key = hmac_key;
        return r;
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

        const txn_id = utils.readU64Le(&header_buf, &pos);
        const doc_id = utils.readU64Le(&header_buf, &pos);
        const payload_len = utils.readU32Le(&header_buf, &pos);

        if (payload_len > 10 * 1024 * 1024) return error.InvalidData;

        const payload_and_crc = try self.allocator.alloc(u8, payload_len + 4);
        defer self.allocator.free(payload_and_crc);

        var payload_iov = [_][]u8{payload_and_crc};
        const read_payload = try self.file.readStreaming(self.io, &payload_iov);
        if (read_payload < payload_len + 4) return error.Incomplete;

        const payload = payload_and_crc[0..payload_len];
        var crc_pos: usize = payload_len;
        const stored_crc = utils.readU32Le(payload_and_crc, &crc_pos);

        var hasher = std.hash.crc.Crc32Iscsi.init();
        hasher.update(&header_buf);
        hasher.update(payload);
        const computed_crc = hasher.final();

        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // Optional HMAC-SHA256 envelope (SEC-02, SEC-EXT-0401, GAP-0027).
        // The tag is computed over (header || payload || crc) at write time,
        // so we re-compute over the same bytes here.
        if (self.hmac_key) |key| {
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
            var stored_tag: [Hmac.mac_length]u8 = undefined;
            var tag_iov = [_][]u8{&stored_tag};
            const read_tag = try self.file.readStreaming(self.io, &tag_iov);
            if (read_tag < Hmac.mac_length) return error.Incomplete;

            var computed_tag: [Hmac.mac_length]u8 = undefined;
            var hmac_ctx = Hmac.init(key);
            hmac_ctx.update(&header_buf);
            hmac_ctx.update(payload_and_crc);
            hmac_ctx.final(&computed_tag);

            if (!std.mem.eql(u8, &stored_tag, &computed_tag)) return error.HmacMismatch;
        }

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
        defer writer.deinit();

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

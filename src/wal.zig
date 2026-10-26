// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const limits = @import("limits.zig");
const backend = @import("crypto_backend");

pub const Error = @import("errors.zig").WalError;

pub const WalRecordType = enum(u8) {
    // Reserved: future transactional bracketing (see WRK-025 / GAP-0012, GAP-0013).
    // Today these are accepted on read for forward compat but never emitted by Engine.
    begin = 1,
    commit = 2,
    index_doc = 3,
    delete_doc = 4,

    /// Validate-and-convert a raw byte to a WalRecordType. Centralises the
    /// "1..=4" check so both `WalRecord.deserialize` (in-memory buffer) and
    /// `WalReader.next` (streaming file) share one source of truth
    /// (QUAL-0024).
    pub fn fromByte(b: u8) error{InvalidData}!WalRecordType {
        if (b < 1 or b > 4) return error.InvalidData;
        return @as(WalRecordType, @enumFromInt(b));
    }
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
        const record_type = try WalRecordType.fromByte(data[0]);
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

    /// The file must allow reading and writing: initialization queries its size.
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
            // fips-exempt: compile-time tag length only (HMAC goes through the seam).
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
            var tag: [Hmac.mac_length]u8 = undefined;
            // FIPS-0004: integrity HMAC-SHA256 via the seam. Tag is computed
            // over the full serialized record (header || payload || crc),
            // preserving the pre-WRK-037 wire format byte-for-byte.
            _ = backend.Mac.hmac(.sha256, key, self.scratch.items, &tag) catch return error.InvalidData;
            try self.scratch.appendSlice(self.allocator, &tag);
        }

        try self.file.writePositionalAll(self.io, self.scratch.items, self.offset);
        self.offset += self.scratch.items.len;
    }

    pub fn sync(self: *WalWriter) !void {
        try self.file.sync(self.io);
    }

    /// Append a record and immediately fsync the WAL. The Engine always pairs
    /// `append` with `sync` for durability (`engine.zig` indexDocument /
    /// deleteDocument), so this helper makes the pairing atomic at the API
    /// level — callers cannot accidentally forget the sync (QUAL-0032).
    /// `append` + `sync` remain public so tests can exercise the pre-sync
    /// state and so a future group-commit path can fan out manually.
    pub fn appendAndSync(self: *WalWriter, record: WalRecord) !void {
        try self.append(record);
        try self.sync();
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
    /// Tracks the highest txn_id among CRC-valid records that `next()`
    /// skipped via `error.InvalidData` (unknown record type / HMAC-backend
    /// failure); recovery must heal its txn allocator past these too, since
    /// their bytes are preserved by truncation (GSP-3 follow-up).
    max_skipped_txn: u64 = 0,
    /// Total bytes of fully-validated records consumed so far — including
    /// unknown-type records that were skipped for forward compat (their CRC
    /// verified). After a torn-tail error (Incomplete / ChecksumMismatch /
    /// HmacMismatch) this still points at the end of the last good record,
    /// so it is exactly the safe truncation point for recovery (GSP-1,
    /// graph-storage parity: recovery frontier discipline).
    consumed: u64 = 0,
    /// Explicit read position, separate from the validated recovery frontier.
    /// Windows asynchronous no-follow handles do not have a streaming cursor.
    read_offset: u64 = 0,

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

    fn readNext(self: *WalReader, buffer: []u8) !usize {
        const count = try self.file.readPositional(self.io, &.{buffer}, self.read_offset);
        if (count == 0) return error.EndOfStream;
        self.read_offset += count;
        return count;
    }

    /// Reads the next WAL record from the file.
    /// Returns null if EOF is reached.
    /// Returns an error if the record is corrupt or incomplete.
    ///
    /// GSP-1: the record-type byte is validated LAST — after payload, CRC,
    /// and optional HMAC — so an unknown (future) record type leaves the
    /// stream aligned on the next record and counted in `consumed`. Callers
    /// that skip `error.InvalidData` therefore resume at a record boundary
    /// instead of desyncing mid-record. Every `error.InvalidData` path (an
    /// unknown type, or an HMAC-backend failure on an otherwise CRC-valid
    /// record) shares this guarantee. `error.PayloadTooLarge` does NOT: an
    /// oversized `payload_len` means the record's extent is untrusted before
    /// its payload is ever read, so it is treated as a torn tail — `consumed`
    /// is left at the last good record, not advanced past this one.
    pub fn next(self: *WalReader) !?WalRecord {
        var header_buf: [1 + 8 + 8 + 4]u8 = undefined;
        const read_header = self.readNext(&header_buf) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (read_header == 0) return null;
        if (read_header < header_buf.len) return error.Incomplete;

        var pos: usize = 1; // type byte validated after CRC/HMAC (GSP-1)
        const txn_id = utils.readU64Le(&header_buf, &pos);
        const doc_id = utils.readU64Le(&header_buf, &pos);
        const payload_len = utils.readU32Le(&header_buf, &pos);

        // A payload_len this large means the record's extent cannot be
        // trusted — we have no way to know how many bytes to skip to reach
        // the next record boundary. Unlike an unknown record type (which is
        // CRC/HMAC-validated before we ever see it), this fires before the
        // payload is even read, so it must terminate replay like a torn
        // tail rather than being skipped (GSP-1: only length-trusted extents
        // may be skipped).
        if (payload_len > limits.MAX_WAL_PAYLOAD_BYTES) return error.PayloadTooLarge;

        const payload_and_crc = try self.allocator.alloc(u8, payload_len + 4);
        defer self.allocator.free(payload_and_crc);

        const read_payload = try self.readNext(payload_and_crc);
        if (read_payload < payload_len + 4) return error.Incomplete;

        const payload = payload_and_crc[0..payload_len];
        var crc_pos: usize = payload_len;
        const stored_crc = utils.readU32Le(payload_and_crc, &crc_pos);

        // fips-exempt: non-security — CRC32c data-integrity checksum, not a MAC
        // (the optional HMAC trailer below covers integrity-against-adversary).
        var hasher = std.hash.crc.Crc32Iscsi.init();
        hasher.update(&header_buf);
        hasher.update(payload);
        const computed_crc = hasher.final();

        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        var record_bytes: u64 = header_buf.len + @as(u64, payload_len) + 4;

        // Optional HMAC-SHA256 envelope (SEC-02, SEC-EXT-0401, GAP-0027).
        // The tag is computed over (header || payload || crc) at write time,
        // so we re-compute over the same bytes here.
        if (self.hmac_key) |key| {
            // fips-exempt: compile-time tag length only (HMAC goes through the seam).
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
            var stored_tag: [Hmac.mac_length]u8 = undefined;
            const read_tag = try self.readNext(&stored_tag);
            if (read_tag < Hmac.mac_length) return error.Incomplete;

            // FIPS-0004: integrity HMAC-SHA256 via the seam. The one-shot seam
            // requires a contiguous message, so we re-assemble the exact bytes
            // tagged at write time (header || payload || crc) into a scratch
            // buffer — byte-identical to the previous incremental computation.
            const msg = try self.allocator.alloc(u8, header_buf.len + payload_and_crc.len);
            defer self.allocator.free(msg);
            @memcpy(msg[0..header_buf.len], &header_buf);
            @memcpy(msg[header_buf.len..], payload_and_crc);

            var computed_tag: [Hmac.mac_length]u8 = undefined;
            _ = backend.Mac.hmac(.sha256, key, msg, &computed_tag) catch {
                // The full record (header + payload + crc + tag) was already
                // read from the stream and is CRC-valid — only the HMAC
                // backend call itself failed. The stream is aligned on the
                // next record, so these bytes must still count toward
                // `consumed` (GSP-1): understating it here would make a
                // later truncation-at-`consumed` chop valid, already-durable
                // record bytes.
                self.consumed += record_bytes + Hmac.mac_length;
                if (txn_id > self.max_skipped_txn) self.max_skipped_txn = txn_id;
                return error.InvalidData;
            };

            if (!std.mem.eql(u8, &stored_tag, &computed_tag)) return error.HmacMismatch;
            // Truncation-accounting guard (tests/fault_injection.zig "HMAC-mode
            // truncation accounting..."): this must fold the tag length into
            // `record_bytes` BEFORE it is added to `self.consumed` below. If
            // `consumed` ever understated a record's true on-disk length by
            // the trailing HMAC tag, the NEXT engine open's
            // `if (wal_stat.size > wal_valid_bytes) setLength(...)`
            // truncation (engine.zig) would chop the tag off what was the
            // last valid record, and the reopen AFTER that would see a
            // torn/incomplete record and silently drop it — losing a write
            // that had already been fsync-acknowledged as durable.
            record_bytes += Hmac.mac_length;
        }

        // Validate the type byte LAST: the record is structurally sound and
        // integrity-checked, so an unknown type is a forward-compat skip —
        // stream aligned, bytes counted (GSP-1).
        const record_type = WalRecordType.fromByte(header_buf[0]) catch |err| {
            self.consumed += record_bytes;
            if (txn_id > self.max_skipped_txn) self.max_skipped_txn = txn_id;
            return err;
        };

        const payload_copy = try self.allocator.dupe(u8, payload);
        self.consumed += record_bytes;

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

// SEC-EXT-0504: coverage-guided fuzz entry point for the `zig-fuzz` CI
// component (`zig build test --fuzz`). See the equivalent test in
// src/utils.zig for why this lives alongside the deterministic corpus in
// tests/fuzz_targets.zig rather than replacing it.
test "fuzz: WalRecord.deserialize never panics or leaks on arbitrary bytes" {
    const Ctx = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            if (WalRecord.deserialize(std.testing.allocator, buf[0..len])) |res| {
                var r = res.rec;
                r.deinit(std.testing.allocator);
            } else |_| {}
        }
    };
    try std.testing.fuzz(Ctx{}, Ctx.testOne, .{});
}

test "WalReader reads records sequentially" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const file_path = "test_wal.bin";

    // Write records
    {
        const file = try tmp_dir.dir.createFile(io, file_path, .{ .read = true });
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
        const file = try utils.openFileNoFollow(io, tmp_dir.dir, file_path);
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

test "WalReader skips unknown record type and stays aligned (GSP-1)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Hand-build: [unknown-type record with valid CRC][valid index_doc record].
    // A reader that validates the type byte before consuming the payload
    // desyncs after the first record and misparses the second.
    {
        const file = try tmp_dir.dir.createFile(io, "wal_align.bin", .{});
        defer file.close(io);

        // Unknown record: serialize a valid record, then patch the type byte
        // to 9 and recompute the CRC so only the type is "from the future".
        const future = WalRecord{ .record_type = .index_doc, .txn_id = 7, .doc_id = 70, .payload = "future-payload" };
        const raw = try future.serialize(alloc);
        defer alloc.free(raw);
        raw[0] = 9; // unknown type
        const crc = utils.hashCrc32c(raw[0 .. raw.len - 4]);
        std.mem.writeInt(u32, raw[raw.len - 4 ..][0..4], crc, .little);
        try file.writePositionalAll(io, raw, 0);

        const good = WalRecord{ .record_type = .index_doc, .txn_id = 8, .doc_id = 80, .payload = "good" };
        const raw2 = try good.serialize(alloc);
        defer alloc.free(raw2);
        try file.writePositionalAll(io, raw2, raw.len);
        try file.sync(io);
    }

    const file = try tmp_dir.dir.openFile(io, "wal_align.bin", .{});
    defer file.close(io);
    var reader = WalReader.init(io, file, alloc);

    // Unknown type surfaces as InvalidData — but with the stream aligned
    // past the whole record, and the record counted as consumed.
    try std.testing.expectError(error.InvalidData, reader.next());

    // The NEXT record must parse cleanly. Pre-fix this fails (desynced
    // stream -> Incomplete/ChecksumMismatch/garbage).
    const rec2 = (try reader.next()).?;
    var r2 = rec2;
    defer r2.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 8), r2.txn_id);
    try std.testing.expectEqualStrings("good", r2.payload);
}

test "WalReader.consumed tracks validated bytes and freezes at a torn tail (GSP-1)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var rec1_len: u64 = 0;
    var rec2_len: u64 = 0;
    {
        const file = try tmp_dir.dir.createFile(io, "wal_consumed.bin", .{ .read = true });
        defer file.close(io);
        var writer = try WalWriter.init(io, file, alloc);
        defer writer.deinit();
        try writer.append(.{ .record_type = .begin, .txn_id = 1 });
        rec1_len = writer.offset;
        try writer.append(.{ .record_type = .commit, .txn_id = 1 });
        rec2_len = writer.offset - rec1_len;
        // Torn tail: half a header of garbage.
        try writer.file.writePositionalAll(io, &[_]u8{0xAA} ** 10, writer.offset);
        try writer.sync();
    }

    const file = try tmp_dir.dir.openFile(io, "wal_consumed.bin", .{});
    defer file.close(io);
    var reader = WalReader.init(io, file, alloc);

    var r1 = (try reader.next()).?;
    r1.deinit(alloc);
    try std.testing.expectEqual(rec1_len, reader.consumed);
    var r2 = (try reader.next()).?;
    r2.deinit(alloc);
    try std.testing.expectEqual(rec1_len + rec2_len, reader.consumed);

    // Torn tail: error, and consumed does NOT advance past the last good record.
    try std.testing.expectError(error.Incomplete, reader.next());
    try std.testing.expectEqual(rec1_len + rec2_len, reader.consumed);
}

test "WalReader rejects oversized payload_len as a torn tail, not a skip (GSP-1)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Hand-craft a 21-byte header whose payload_len exceeds the cap. The
    // record's true extent cannot be trusted (we don't know how many bytes
    // to skip to reach the next record), so this must NOT be treated like
    // the unknown-record-type forward-compat skip: it has to terminate
    // replay as a torn tail, with `consumed` left at 0.
    {
        const file = try tmp_dir.dir.createFile(io, "wal_oversized.bin", .{});
        defer file.close(io);

        var header_buf: [1 + 8 + 8 + 4]u8 = undefined;
        header_buf[0] = 3; // index_doc
        std.mem.writeInt(u64, header_buf[1..9], 42, .little); // txn_id
        std.mem.writeInt(u64, header_buf[9..17], 7, .little); // doc_id
        std.mem.writeInt(u32, header_buf[17..21], limits.MAX_WAL_PAYLOAD_BYTES + 1, .little);

        try file.writePositionalAll(io, &header_buf, 0);
        try file.sync(io);
    }

    const file = try tmp_dir.dir.openFile(io, "wal_oversized.bin", .{});
    defer file.close(io);
    var reader = WalReader.init(io, file, alloc);

    try std.testing.expectError(error.PayloadTooLarge, reader.next());
    try std.testing.expectEqual(@as(u64, 0), reader.consumed);
}

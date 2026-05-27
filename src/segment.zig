// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const limits = @import("limits.zig");

pub const Error = @import("errors.zig").SegmentError;

// ============================================================================
// Memtable (In-Memory Staging)
// ============================================================================

pub const MemPosting = struct {
    doc_id: u64,
    tf: u32,
    // For simplicity, we just store positions as a slice.
    // In a real implementation this would be an unmanaged array list.
    positions: std.ArrayListUnmanaged(u32),
};

pub const MemPostingsList = struct {
    postings: std.ArrayListUnmanaged(MemPosting),
    df: u64,
};

pub const Memtable = struct {
    allocator: Allocator,
    dictionary: std.StringHashMapUnmanaged(MemPostingsList),
    tombstones: std.AutoHashMapUnmanaged(u64, void),
    /// Tracks unique doc_ids ever observed by addPosting, so total_docs counts
    /// distinct documents rather than (doc, term) postings (QUAL-0006).
    seen_docs: std.AutoHashMapUnmanaged(u64, void),
    total_docs: u64,

    pub fn init(allocator: Allocator) Memtable {
        return .{
            .allocator = allocator,
            .dictionary = .empty,
            .tombstones = .empty,
            .seen_docs = .empty,
            .total_docs = 0,
        };
    }

    pub fn deinit(self: *Memtable) void {
        var it = self.dictionary.iterator();
        while (it.next()) |entry| {
            // we allocated the key string using the allocator
            self.allocator.free(entry.key_ptr.*);

            for (entry.value_ptr.postings.items) |*posting| {
                posting.positions.deinit(self.allocator);
            }
            entry.value_ptr.postings.deinit(self.allocator);
        }
        self.dictionary.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
        self.seen_docs.deinit(self.allocator);
    }

    pub fn addTombstone(self: *Memtable, doc_id: u64) !void {
        try self.tombstones.put(self.allocator, doc_id, {});
    }

    pub fn addPosting(self: *Memtable, term: []const u8, doc_id: u64, positions: []const u32) !void {
        // Track unique doc ids so total_docs reflects distinct documents
        // (QUAL-0006). Do this before the dictionary mutation so a later
        // failure leaves seen_docs over-counted only for *this* call, not for
        // sibling terms in the same indexDocument batch — the engine treats a
        // failure mid-batch as poisoning the engine anyway.
        const gop_doc = try self.seen_docs.getOrPut(self.allocator, doc_id);
        if (!gop_doc.found_existing) {
            self.total_docs += 1;
        }

        var entry = try self.dictionary.getOrPut(self.allocator, term);
        if (!entry.found_existing) {
            // Dup the string to own it. Guard against partial init: if any
            // subsequent step fails the dup'd key would otherwise leak and the
            // hash map would retain a slot pointing at uninitialized memory.
            const key_copy = try self.allocator.dupe(u8, term);
            errdefer self.allocator.free(key_copy);
            entry.key_ptr.* = key_copy;
            entry.value_ptr.* = .{
                .postings = .empty,
                .df = 0,
            };
            errdefer _ = self.dictionary.remove(key_copy);
        }

        var pos_list: std.ArrayListUnmanaged(u32) = .empty;
        errdefer pos_list.deinit(self.allocator);
        try pos_list.ensureTotalCapacity(self.allocator, positions.len);
        pos_list.appendSliceAssumeCapacity(positions);

        const tf_u32 = std.math.cast(u32, positions.len) orelse return error.PositionCountTooLarge;
        try entry.value_ptr.postings.append(self.allocator, .{
            .doc_id = doc_id,
            .tf = tf_u32,
            .positions = pos_list,
        });
        entry.value_ptr.df += 1;
    }
};

// ============================================================================
// Segment Writer
// ============================================================================

pub const SegmentWriter = struct {
    io: std.Io,
    dir: std.Io.Dir,
    allocator: Allocator,
    segment_id: u64,

    pub fn writeMemtable(self: *SegmentWriter, memtable: *Memtable) !void {
        var seg_dir_name_buf: [64]u8 = undefined;
        const seg_dir_name = try std.fmt.bufPrint(&seg_dir_name_buf, "seg_{d}", .{self.segment_id});

        // Create segment directory with owner-only perms (SEC-09, SEC-EXT-0302).
        self.dir.createDir(self.io, seg_dir_name, utils.dirMode(0o700)) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var seg_dir = try self.dir.openDir(self.io, seg_dir_name, .{});
        defer seg_dir.close(self.io);

        try self.writeDictionaryAndPostings(&seg_dir, memtable);
        try self.writeTombstones(&seg_dir, memtable);
    }

    fn writeDictionaryAndPostings(self: *SegmentWriter, seg_dir: *std.Io.Dir, memtable: *Memtable) !void {
        // We will write `terms.fst` (a flat hash map for now) and `postings.bin`.
        const dict_file = try seg_dir.createFile(self.io, "terms.hash", .{ .permissions = utils.fileMode(0o600) });
        defer dict_file.close(self.io);

        const post_file = try seg_dir.createFile(self.io, "postings.bin", .{ .permissions = utils.fileMode(0o600) });
        defer post_file.close(self.io);

        // We use explicit buffers for std.mem.writeInt instead of writer.writeInt
        var num_buf: [8]u8 = undefined;
        var post_offset: u64 = 0;

        // Write number of terms
        std.mem.writeInt(u32, num_buf[0..4], @intCast(memtable.dictionary.count()), .little);
        try dict_file.writeStreamingAll(self.io, num_buf[0..4]);

        var buf: [32]u8 = undefined;
        var it = memtable.dictionary.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            const list = entry.value_ptr.*;

            // Write term len + term
            std.mem.writeInt(u16, num_buf[0..2], @intCast(term.len), .little);
            try dict_file.writeStreamingAll(self.io, num_buf[0..2]);
            try dict_file.writeStreamingAll(self.io, term);

            // Write df
            std.mem.writeInt(u64, num_buf[0..8], list.df, .little);
            try dict_file.writeStreamingAll(self.io, num_buf[0..8]);

            // Write postings offset
            std.mem.writeInt(u64, num_buf[0..8], post_offset, .little);
            try dict_file.writeStreamingAll(self.io, num_buf[0..8]);

            // Write postings
            var last_doc_id: u64 = 0;
            var bytes_written: u64 = 0;
            for (list.postings.items) |posting| {
                // Delta encoded doc_id
                const delta = posting.doc_id - last_doc_id;
                last_doc_id = posting.doc_id;

                const w1 = try utils.writeVarInt(&buf, delta);
                try post_file.writeStreamingAll(self.io, buf[0..w1]);
                bytes_written += w1;

                const w2 = try utils.writeVarInt(&buf, posting.tf);
                try post_file.writeStreamingAll(self.io, buf[0..w2]);
                bytes_written += w2;

                var last_pos: u32 = 0;
                for (posting.positions.items) |pos| {
                    const pos_delta = pos - last_pos;
                    last_pos = pos;
                    const w3 = try utils.writeVarInt(&buf, pos_delta);
                    try post_file.writeStreamingAll(self.io, buf[0..w3]);
                    bytes_written += w3;
                }
            }
            // Write postings len
            std.mem.writeInt(u64, num_buf[0..8], bytes_written, .little);
            try dict_file.writeStreamingAll(self.io, num_buf[0..8]);

            post_offset += bytes_written;
        }
    }

    fn writeTombstones(self: *SegmentWriter, seg_dir: *std.Io.Dir, memtable: *Memtable) !void {
        if (memtable.tombstones.count() == 0) return;

        const ts_file = try seg_dir.createFile(self.io, "tombstones.bin", .{ .permissions = utils.fileMode(0o600) });
        defer ts_file.close(self.io);

        var num_buf: [8]u8 = undefined;

        std.mem.writeInt(u32, num_buf[0..4], @intCast(memtable.tombstones.count()), .little);
        try ts_file.writeStreamingAll(self.io, num_buf[0..4]);

        var it = memtable.tombstones.keyIterator();
        while (it.next()) |doc_id| {
            std.mem.writeInt(u64, num_buf[0..8], doc_id.*, .little);
            try ts_file.writeStreamingAll(self.io, num_buf[0..8]);
        }
    }
};

// ============================================================================
// Segment Reader
// ============================================================================

pub const SegmentReader = struct {
    io: std.Io,
    dir: std.Io.Dir,
    allocator: Allocator,
    segment_id: u64,
    dictionary: std.StringHashMapUnmanaged(DictEntry),
    tombstones: std.AutoHashMapUnmanaged(u64, void),

    // Dictionary cached in memory for fast lookup
    pub const DictEntry = struct {
        df: u64,
        postings_offset: u64,
        postings_len: u64,
    };

    pub fn init(io: std.Io, allocator: Allocator, dir: std.Io.Dir, segment_id: u64) !SegmentReader {
        var seg = SegmentReader{
            .io = io,
            .dir = dir,
            .allocator = allocator,
            .segment_id = segment_id,
            .dictionary = .empty,
            .tombstones = .empty,
        };
        try seg.load();
        return seg;
    }

    pub fn deinit(self: *SegmentReader) void {
        var it = self.dictionary.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.dictionary.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
    }

    pub const PostingIterator = struct {
        allocator: Allocator,
        data: []u8,
        df: u64,
        current_idx: u64,
        pos: usize,
        last_doc_id: u64,
        pos_buf: std.ArrayListUnmanaged(u32),

        pub const Posting = struct {
            doc_id: u64,
            positions: []const u32,
        };

        pub fn deinit(self: *PostingIterator) void {
            self.allocator.free(self.data);
            self.pos_buf.deinit(self.allocator);
        }

        pub fn next(self: *PostingIterator) !?Posting {
            if (self.current_idx >= self.df) return null;

            const doc_delta = try utils.readVarInt(self.data[self.pos..]);
            self.pos += doc_delta.bytes_read;
            self.last_doc_id += doc_delta.val;

            const tf_res = try utils.readVarInt(self.data[self.pos..]);
            self.pos += tf_res.bytes_read;
            const tf = tf_res.val;

            if (tf > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;
            const tf_usize = std.math.cast(usize, tf) orelse return error.PositionCountTooLarge;

            self.pos_buf.clearRetainingCapacity();
            try self.pos_buf.ensureTotalCapacity(self.allocator, tf_usize);

            var last_pos: u32 = 0;
            var i: u64 = 0;
            while (i < tf) : (i += 1) {
                const pos_delta = try utils.readVarInt(self.data[self.pos..]);
                self.pos += pos_delta.bytes_read;
                last_pos += @intCast(pos_delta.val);
                self.pos_buf.appendAssumeCapacity(last_pos);
            }

            self.current_idx += 1;
            return Posting{ .doc_id = self.last_doc_id, .positions = self.pos_buf.items };
        }
    };

    pub fn search(self: *SegmentReader, term: []const u8) !?PostingIterator {
        if (self.dictionary.get(term)) |entry| {
            if (entry.postings_len > limits.MAX_POSTINGS_BYTES) return error.PostingsTooLarge;
            const postings_len_usize = std.math.cast(usize, entry.postings_len) orelse return error.PostingsTooLarge;
            const data = try self.allocator.alloc(u8, postings_len_usize);
            var seg_dir_name_buf: [64]u8 = undefined;
            const seg_dir_name = try std.fmt.bufPrint(&seg_dir_name_buf, "seg_{d}", .{self.segment_id});
            var seg_dir = try self.dir.openDir(self.io, seg_dir_name, .{});
            defer seg_dir.close(self.io);

            // SEC-EXT-0301: O_NOFOLLOW — segment files are owner-only-perms;
            // refuse to follow symlinks so a malicious actor with write
            // access to the segments tree cannot redirect reads.
            const file = try seg_dir.openFile(self.io, "postings.bin", .{ .follow_symlinks = false });
            defer file.close(self.io);

            var index: usize = 0;
            while (index < data.len) {
                const amt = try file.readPositional(self.io, &.{data[index..]}, entry.postings_offset + index);
                if (amt == 0) return error.Incomplete;
                index += amt;
            }

            return PostingIterator{
                .allocator = self.allocator,
                .data = data,
                .df = entry.df,
                .current_idx = 0,
                .pos = 0,
                .last_doc_id = 0,
                .pos_buf = .empty,
            };
        }
        return null;
    }

    fn readU32FromFile(file: std.Io.File, io: std.Io) !u32 {
        var buf: [4]u8 = undefined;
        var iov = [_][]u8{&buf};
        const read = try file.readStreaming(io, &iov);
        if (read < 4) return error.Incomplete;
        return std.mem.readInt(u32, &buf, .little);
    }

    fn readU16FromFile(file: std.Io.File, io: std.Io) !u16 {
        var buf: [2]u8 = undefined;
        var iov = [_][]u8{&buf};
        const read = try file.readStreaming(io, &iov);
        if (read < 2) return error.Incomplete;
        return std.mem.readInt(u16, &buf, .little);
    }

    fn readU64FromFile(file: std.Io.File, io: std.Io) !u64 {
        var buf: [8]u8 = undefined;
        var iov = [_][]u8{&buf};
        const read = try file.readStreaming(io, &iov);
        if (read < 8) return error.Incomplete;
        return std.mem.readInt(u64, &buf, .little);
    }

    fn load(self: *SegmentReader) !void {
        var seg_dir_name_buf: [64]u8 = undefined;
        const seg_dir_name = try std.fmt.bufPrint(&seg_dir_name_buf, "seg_{d}", .{self.segment_id});
        var seg_dir = try self.dir.openDir(self.io, seg_dir_name, .{});
        defer seg_dir.close(self.io);

        // Load dictionary — refuse to follow symlinks (SEC-EXT-0301).
        if (seg_dir.openFile(self.io, "terms.hash", .{ .follow_symlinks = false })) |file| {
            defer file.close(self.io);

            const count = readU32FromFile(file, self.io) catch 0;
            if (count > limits.MAX_TERMS_PER_SEGMENT) return error.TermCountTooLarge;
            try self.dictionary.ensureTotalCapacity(self.allocator, count);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const term_len = try readU16FromFile(file, self.io);
                const term = try self.allocator.alloc(u8, term_len);
                errdefer self.allocator.free(term);

                var iov = [_][]u8{term};
                const read = try file.readStreaming(self.io, &iov);
                if (read < term_len) return error.Incomplete;

                const df = try readU64FromFile(file, self.io);
                const offset = try readU64FromFile(file, self.io);
                const len = try readU64FromFile(file, self.io);

                self.dictionary.putAssumeCapacityNoClobber(term, .{
                    .df = df,
                    .postings_offset = offset,
                    .postings_len = len,
                });
            }
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        // Load tombstones — refuse to follow symlinks (SEC-EXT-0301).
        if (seg_dir.openFile(self.io, "tombstones.bin", .{ .follow_symlinks = false })) |file| {
            defer file.close(self.io);
            const count = readU32FromFile(file, self.io) catch 0;
            if (count > limits.MAX_TOMBSTONES_PER_SEGMENT) return error.TombstoneCountTooLarge;
            try self.tombstones.ensureTotalCapacity(self.allocator, count);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const doc_id = try readU64FromFile(file, self.io);
                self.tombstones.putAssumeCapacityNoClobber(doc_id, {});
            }
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "memtable and segment write/read roundtrip" {
    const alloc = std.testing.allocator;

    var memtable = Memtable.init(alloc);
    defer memtable.deinit();

    try memtable.addPosting("hello", 1, &[_]u32{ 10, 20 });
    try memtable.addPosting("world", 1, &[_]u32{15});
    try memtable.addPosting("hello", 2, &[_]u32{5});
    try memtable.addTombstone(3);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();

    var writer = SegmentWriter{
        .io = io,
        .dir = tmp_dir.dir,
        .allocator = alloc,
        .segment_id = 42,
    };

    try writer.writeMemtable(&memtable);

    var reader = try SegmentReader.init(io, alloc, tmp_dir.dir, 42);
    defer reader.deinit();

    try std.testing.expectEqual(@as(usize, 2), reader.dictionary.count());

    const hello_entry = reader.dictionary.get("hello").?;
    try std.testing.expectEqual(@as(u64, 2), hello_entry.df);

    const world_entry = reader.dictionary.get("world").?;
    try std.testing.expectEqual(@as(u64, 1), world_entry.df);

    try std.testing.expectEqual(@as(usize, 1), reader.tombstones.count());
    try std.testing.expect(reader.tombstones.contains(3));
}

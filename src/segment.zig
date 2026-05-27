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
        try self.writeNorms(&seg_dir, memtable);
    }

    /// Per-doc length normalization data (norms.bin) for BM25 scoring
    /// (WRK-035, GAP-0005, GAP-0006). Layout:
    ///   [count: u32 LE][doc_id: u64 LE, length: u32 LE]*count
    /// where `length` is the sum of `MemPosting.tf` across every term for the
    /// document — i.e. the document's total token count. Empty memtables
    /// write no file; reader treats absence as "no norms available".
    fn writeNorms(self: *SegmentWriter, seg_dir: *std.Io.Dir, memtable: *Memtable) !void {
        if (memtable.seen_docs.count() == 0) return;

        // Accumulate per-doc total length. Iterate every (term, posting) and
        // sum tf into a doc_id -> length map. Capacity is bounded by
        // seen_docs.count() since postings only ever reference observed docs.
        var doc_lens: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer doc_lens.deinit(self.allocator);
        try doc_lens.ensureTotalCapacity(self.allocator, memtable.seen_docs.count());

        var dict_it = memtable.dictionary.iterator();
        while (dict_it.next()) |entry| {
            for (entry.value_ptr.postings.items) |posting| {
                const gop = try doc_lens.getOrPut(self.allocator, posting.doc_id);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = std.math.add(u32, gop.value_ptr.*, posting.tf) catch
                    return error.PositionCountTooLarge;
            }
        }

        // Build entire payload in memory, single writeStreamingAll
        // (PERF-0004 spirit applied to norms).
        var norms_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer norms_buf.deinit(self.allocator);

        var num_buf: [8]u8 = undefined;
        std.mem.writeInt(u32, num_buf[0..4], @intCast(doc_lens.count()), .little);
        try norms_buf.appendSlice(self.allocator, num_buf[0..4]);

        var it = doc_lens.iterator();
        while (it.next()) |entry| {
            std.mem.writeInt(u64, num_buf[0..8], entry.key_ptr.*, .little);
            try norms_buf.appendSlice(self.allocator, num_buf[0..8]);
            std.mem.writeInt(u32, num_buf[0..4], entry.value_ptr.*, .little);
            try norms_buf.appendSlice(self.allocator, num_buf[0..4]);
        }

        const norms_file = try seg_dir.createFile(self.io, "norms.bin", .{ .permissions = utils.fileMode(0o600) });
        defer norms_file.close(self.io);
        try norms_file.writeStreamingAll(self.io, norms_buf.items);
    }

    fn writeDictionaryAndPostings(self: *SegmentWriter, seg_dir: *std.Io.Dir, memtable: *Memtable) !void {
        // Build the entire dictionary and postings payloads in memory, then
        // issue exactly one writeStreamingAll per file (PERF-0004, WRK-034).
        // For a segment with 100k terms this turns millions of tiny syscalls
        // into two large ones.
        var dict_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer dict_buf.deinit(self.allocator);
        var post_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer post_buf.deinit(self.allocator);

        // We use explicit buffers for std.mem.writeInt instead of writer.writeInt
        var num_buf: [8]u8 = undefined;

        // Write number of terms
        std.mem.writeInt(u32, num_buf[0..4], @intCast(memtable.dictionary.count()), .little);
        try dict_buf.appendSlice(self.allocator, num_buf[0..4]);

        var buf: [32]u8 = undefined;
        var it = memtable.dictionary.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            const list = entry.value_ptr.*;

            // Write term len + term
            std.mem.writeInt(u16, num_buf[0..2], @intCast(term.len), .little);
            try dict_buf.appendSlice(self.allocator, num_buf[0..2]);
            try dict_buf.appendSlice(self.allocator, term);

            // Write df
            std.mem.writeInt(u64, num_buf[0..8], list.df, .little);
            try dict_buf.appendSlice(self.allocator, num_buf[0..8]);

            // Postings offset is the current length of post_buf BEFORE we
            // append this term's posting bytes (WRK-034).
            const entry_postings_offset: u64 = @intCast(post_buf.items.len);
            std.mem.writeInt(u64, num_buf[0..8], entry_postings_offset, .little);
            try dict_buf.appendSlice(self.allocator, num_buf[0..8]);

            // Write postings
            var last_doc_id: u64 = 0;
            for (list.postings.items) |posting| {
                // Delta encoded doc_id
                const delta = posting.doc_id - last_doc_id;
                last_doc_id = posting.doc_id;

                const w1 = try utils.writeVarInt(&buf, delta);
                try post_buf.appendSlice(self.allocator, buf[0..w1]);

                const w2 = try utils.writeVarInt(&buf, posting.tf);
                try post_buf.appendSlice(self.allocator, buf[0..w2]);

                var last_pos: u32 = 0;
                for (posting.positions.items) |pos| {
                    const pos_delta = pos - last_pos;
                    last_pos = pos;
                    const w3 = try utils.writeVarInt(&buf, pos_delta);
                    try post_buf.appendSlice(self.allocator, buf[0..w3]);
                }
            }

            // Write postings len for this term (derived from current post_buf
            // length minus the offset captured above).
            const bytes_written: u64 = @as(u64, @intCast(post_buf.items.len)) - entry_postings_offset;
            std.mem.writeInt(u64, num_buf[0..8], bytes_written, .little);
            try dict_buf.appendSlice(self.allocator, num_buf[0..8]);
        }

        // Single writeStreamingAll per file (PERF-0004).
        const dict_file = try seg_dir.createFile(self.io, "terms.hash", .{ .permissions = utils.fileMode(0o600) });
        defer dict_file.close(self.io);
        const post_file = try seg_dir.createFile(self.io, "postings.bin", .{ .permissions = utils.fileMode(0o600) });
        defer post_file.close(self.io);

        try dict_file.writeStreamingAll(self.io, dict_buf.items);
        try post_file.writeStreamingAll(self.io, post_buf.items);
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
    /// Per-doc length norms loaded from norms.bin. Used by BM25 scoring in
    /// search.zig to compute length normalization (WRK-035, GAP-0005,
    /// GAP-0006). Missing file -> empty map -> callers fall back to
    /// `limits.DEFAULT_DOC_LEN`.
    norms: std.AutoHashMapUnmanaged(u64, u32),
    /// Cached open handles so search() does not pay an openDir + openFile +
    /// close per query (PERF-0005, PERF-0007, WRK-033). Opened in init,
    /// released in deinit.
    seg_dir: std.Io.Dir,
    postings_file: std.Io.File,

    // Dictionary cached in memory for fast lookup
    pub const DictEntry = struct {
        df: u64,
        postings_offset: u64,
        postings_len: u64,
    };

    pub fn init(io: std.Io, allocator: Allocator, dir: std.Io.Dir, segment_id: u64) !SegmentReader {
        // Open the segment's own subdirectory once. We hold this for the
        // reader's lifetime so search() does not have to reopen it per query.
        var seg_dir_name_buf: [64]u8 = undefined;
        const seg_dir_name = try std.fmt.bufPrint(&seg_dir_name_buf, "seg_{d}", .{segment_id});
        var seg_dir = try dir.openDir(io, seg_dir_name, .{});
        errdefer seg_dir.close(io);

        // SEC-EXT-0301: O_NOFOLLOW on postings.bin too. Opened once at init
        // and held for the reader's lifetime (WRK-033).
        const postings_file = try seg_dir.openFile(io, "postings.bin", .{ .follow_symlinks = false });
        errdefer postings_file.close(io);

        var seg = SegmentReader{
            .io = io,
            .dir = dir,
            .allocator = allocator,
            .segment_id = segment_id,
            .dictionary = .empty,
            .tombstones = .empty,
            .norms = .empty,
            .seg_dir = seg_dir,
            .postings_file = postings_file,
        };
        // If load() fails partway (corrupted terms.hash, truncated payload),
        // any dictionary entries / capacity already allocated must be torn
        // down or the caller leaks (WRK-022).
        errdefer {
            var it = seg.dictionary.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            seg.dictionary.deinit(allocator);
            seg.tombstones.deinit(allocator);
            seg.norms.deinit(allocator);
        }
        try seg.load();
        return seg;
    }

    pub fn deinit(self: *SegmentReader) void {
        self.postings_file.close(self.io);
        self.seg_dir.close(self.io);
        var it = self.dictionary.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.dictionary.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
        self.norms.deinit(self.allocator);
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
            errdefer self.allocator.free(data);

            // Use the cached postings.bin handle opened in init (WRK-033) so
            // we do not pay an openDir + openFile + close per query
            // (PERF-0005, PERF-0007).
            var index: usize = 0;
            while (index < data.len) {
                const amt = try self.postings_file.readPositional(self.io, &.{data[index..]}, entry.postings_offset + index);
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
        // Reuse the seg_dir handle opened in init rather than opening a new
        // one (WRK-033). The cached handle is also used by search().

        // Load dictionary — refuse to follow symlinks (SEC-EXT-0301).
        if (self.seg_dir.openFile(self.io, "terms.hash", .{ .follow_symlinks = false })) |file| {
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
        if (self.seg_dir.openFile(self.io, "tombstones.bin", .{ .follow_symlinks = false })) |file| {
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

        // Load per-doc length norms — refuse to follow symlinks
        // (SEC-EXT-0301). Absence is fine: segments written before WRK-035
        // simply have no norms.bin, and BM25 falls back to DEFAULT_DOC_LEN.
        if (self.seg_dir.openFile(self.io, "norms.bin", .{ .follow_symlinks = false })) |file| {
            defer file.close(self.io);
            const count = readU32FromFile(file, self.io) catch 0;
            if (count > limits.MAX_NORMS_PER_SEGMENT) return error.NormCountTooLarge;
            try self.norms.ensureTotalCapacity(self.allocator, count);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const doc_id = try readU64FromFile(file, self.io);
                const length = try readU32FromFile(file, self.io);
                self.norms.putAssumeCapacityNoClobber(doc_id, length);
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

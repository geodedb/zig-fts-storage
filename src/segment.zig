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

// PERF-0016: the current layout is Array-of-Structs (AoS) — every
// `MemPosting` row carries an inline `ArrayListUnmanaged(u32)` header (a
// 24-byte struct that itself holds a heap pointer to the positions array).
// For workloads with many short posting lists the flush loop walks
// `postings.items` and dereferences a separate heap pointer per row,
// breaking the CPU's stride prefetch — most cycles end up waiting on L1/L2.
//
// Production path: refactor to Struct-of-Arrays (SoA) on the per-term
// posting list — `doc_ids: []u64`, `tfs: []u32`, plus a sidecar
// `positions: []u32` with `positions_offsets: []u32` so each posting's
// positions are a single contiguous span. The flush iteration then becomes
// three linear scans over packed arrays, which the prefetcher can saturate.
//
// Deferred until cachegrind / `perf stat` measurements on the spec'd
// 100k-doc corpus confirm the L1/L2 cost is dominant — the AoS layout is
// fine for the v0.1 scale (<10k terms per memtable) and a refactor of
// `MemPostingsList`, `addPosting`, and `writeMemtable` is more risk than
// the win justifies at this scale. The token here is tracked so the
// optimization is not silently lost; reopen with the perf evidence in hand.
pub const MemPosting = struct {
    doc_id: u64,
    tf: u32,
    /// Per-posting position list. ArrayListUnmanaged is chosen so the
    /// per-posting growth cost is amortized — the alternative (a fresh
    /// allocator.dupe on every position update) would dominate ingest
    /// (see PERF-0003 / the SoA refactor note above).
    positions: std.ArrayListUnmanaged(u32),
};

pub const MemPostingsList = struct {
    postings: std.ArrayListUnmanaged(MemPosting),
    df: u64,
};

pub const Memtable = struct {
    allocator: Allocator,
    /// Arena allocator used for term-key copies. PERF-0003 / Phase B4:
    /// every `addPosting` first-seen term path previously called
    /// `allocator.dupe(u8, term)` and the matching `allocator.free` ran on
    /// every deinit/flush — N* allocations and N matching frees per memtable
    /// generation. Arena-backing the term keys lets the entire generation
    /// free in O(1) at flush via `arena.deinit()`. Position lists, postings
    /// vectors, and hash maps stay on the parent allocator because they
    /// grow geometrically inside a memtable's lifetime and the arena would
    /// leak intermediate reallocations until the next flush.
    arena: std.heap.ArenaAllocator,
    dictionary: std.StringHashMapUnmanaged(MemPostingsList),
    tombstones: std.AutoHashMapUnmanaged(u64, void),
    /// Tracks unique doc_ids ever observed by addPosting, so total_docs counts
    /// distinct documents rather than (doc, term) postings (QUAL-0006).
    seen_docs: std.AutoHashMapUnmanaged(u64, void),
    total_docs: u64,

    pub fn init(allocator: Allocator) Memtable {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .dictionary = .empty,
            .tombstones = .empty,
            .seen_docs = .empty,
            .total_docs = 0,
        };
    }

    pub fn deinit(self: *Memtable) void {
        var it = self.dictionary.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.postings.items) |*posting| {
                posting.positions.deinit(self.allocator);
            }
            entry.value_ptr.postings.deinit(self.allocator);
        }
        self.dictionary.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
        self.seen_docs.deinit(self.allocator);
        // All term-key copies live in the arena; one deinit frees them all
        // (PERF-0003 / Phase B4).
        self.arena.deinit();
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
            // PERF-0003 / Phase B4: dup the key into the arena instead of
            // the parent allocator. Failure here would leave the hash map
            // entry pointing at uninitialized memory; the arena-dup is
            // infallible from the caller's perspective except on OOM, where
            // we still remove the half-installed entry to keep map slots
            // consistent. Arena memory is reclaimed wholesale at flush.
            const key_copy = self.arena.allocator().dupe(u8, term) catch |err| {
                _ = self.dictionary.remove(term);
                return err;
            };
            entry.key_ptr.* = key_copy;
            entry.value_ptr.* = .{
                .postings = .empty,
                .df = 0,
            };
            // No errdefer free of key_copy — arena ownership.
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
    /// Optional AES-256-GCM key for at-rest segment encryption (WRK-038,
    /// GAP-0009, SEC-EXT-0402). When non-null, each file's payload is
    /// wrapped in `nonce(12) || ciphertext || tag(16)` before being written
    /// to disk. Null preserves the pre-WRK-038 plaintext format.
    aead_key: ?[]const u8 = null,

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

    /// Write `buf` to `seg_dir/name`, transparently AEAD-encrypting first
    /// when `self.aead_key` is non-null (WRK-038). Pulled into a helper so
    /// every file goes through the same envelope path.
    fn writeFile(self: *SegmentWriter, seg_dir: *std.Io.Dir, name: []const u8, buf: []const u8) !void {
        const file = try seg_dir.createFile(self.io, name, .{ .permissions = utils.fileMode(0o600) });
        defer file.close(self.io);

        if (self.aead_key) |key| {
            const enc = try utils.aeadEncrypt(self.io, key, buf, self.allocator);
            defer self.allocator.free(enc);
            try file.writeStreamingAll(self.io, enc);
        } else {
            try file.writeStreamingAll(self.io, buf);
        }
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

        try self.writeFile(seg_dir, "norms.bin", norms_buf.items);
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

        // Single writeStreamingAll per file (PERF-0004); each goes through
        // writeFile so opt-in AEAD encryption (WRK-038) is applied uniformly.
        try self.writeFile(seg_dir, "terms.hash", dict_buf.items);
        try self.writeFile(seg_dir, "postings.bin", post_buf.items);
    }

    fn writeTombstones(self: *SegmentWriter, seg_dir: *std.Io.Dir, memtable: *Memtable) !void {
        if (memtable.tombstones.count() == 0) return;

        // Buffer the entire tombstones payload before writing so opt-in AEAD
        // encryption (WRK-038) has a single contiguous plaintext to encrypt.
        // This also collapses N tiny syscalls into one writeStreamingAll
        // (matches the PERF-0004 pattern used for terms/postings/norms).
        var ts_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer ts_buf.deinit(self.allocator);

        var num_buf: [8]u8 = undefined;
        std.mem.writeInt(u32, num_buf[0..4], @intCast(memtable.tombstones.count()), .little);
        try ts_buf.appendSlice(self.allocator, num_buf[0..4]);

        var it = memtable.tombstones.keyIterator();
        while (it.next()) |doc_id| {
            std.mem.writeInt(u64, num_buf[0..8], doc_id.*, .little);
            try ts_buf.appendSlice(self.allocator, num_buf[0..8]);
        }

        try self.writeFile(seg_dir, "tombstones.bin", ts_buf.items);
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
    /// PERF-0017: per-segment term-key arena. The dictionary hash map's keys
    /// are slices into this single contiguous allocation rather than N
    /// independently-allocated `allocator.dupe(u8, term)` strings. For a
    /// segment with 100k terms × ~8-byte avg term, this drops the heap
    /// footprint from ~100k × (term_len + allocator-header overhead) to
    /// ~100k × term_len + one header — roughly a 2-3× reduction. Freed once
    /// in deinit instead of per-entry. Empty (`.len == 0`) when the segment
    /// has no terms.
    key_arena: []u8,
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
    /// Optional AES-256-GCM key for at-rest decryption (WRK-038, GAP-0009,
    /// SEC-EXT-0402). Null = plaintext segments (default).
    aead_key: ?[]const u8 = null,
    /// When `aead_key` is set, the *decrypted* postings.bin is materialized
    /// in memory at init time and `search()` reads from this buffer instead
    /// of `postings_file`. AEAD ciphertext is not random-accessible — the
    /// tag covers the whole stream — so we cannot stream-decrypt by offset.
    /// Null means "use postings_file" (the plaintext path).
    postings_data: ?[]u8 = null,

    // Dictionary cached in memory for fast lookup
    pub const DictEntry = struct {
        df: u64,
        postings_offset: u64,
        postings_len: u64,
    };

    pub fn init(io: std.Io, allocator: Allocator, dir: std.Io.Dir, segment_id: u64) !SegmentReader {
        return initWithAead(io, allocator, dir, segment_id, null);
    }

    pub fn initWithAead(
        io: std.Io,
        allocator: Allocator,
        dir: std.Io.Dir,
        segment_id: u64,
        aead_key: ?[]const u8,
    ) !SegmentReader {
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
            .key_arena = &.{},
            .tombstones = .empty,
            .norms = .empty,
            .seg_dir = seg_dir,
            .postings_file = postings_file,
            .aead_key = aead_key,
            .postings_data = null,
        };
        // If load() fails partway (corrupted terms.hash, truncated payload),
        // any dictionary entries / capacity already allocated must be torn
        // down or the caller leaks (WRK-022). PERF-0017: keys live in the
        // single `key_arena` allocation, so the per-entry free loop is gone —
        // just freeing the arena (when non-empty) suffices.
        errdefer {
            seg.dictionary.deinit(allocator);
            if (seg.key_arena.len != 0) allocator.free(seg.key_arena);
            seg.tombstones.deinit(allocator);
            seg.norms.deinit(allocator);
            if (seg.postings_data) |pd| allocator.free(pd);
        }
        try seg.load();
        return seg;
    }

    pub fn deinit(self: *SegmentReader) void {
        self.postings_file.close(self.io);
        self.seg_dir.close(self.io);
        // PERF-0017: dictionary keys are slices into `key_arena`; a single
        // free replaces the prior per-entry free loop.
        self.dictionary.deinit(self.allocator);
        if (self.key_arena.len != 0) self.allocator.free(self.key_arena);
        self.tombstones.deinit(self.allocator);
        self.norms.deinit(self.allocator);
        if (self.postings_data) |pd| self.allocator.free(pd);
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

        /// Advance past one posting and return just the `doc_id` — skip the
        /// positions varint loop entirely so the iterator does not pay the
        /// per-position decode cost when the caller only needs document
        /// membership (e.g. boolean intersection / RLS-gated count queries).
        ///
        /// PERF-0018: a typical posting has 1-8 positions; decoding them is
        /// roughly half the per-posting wall time at large fan-out. Callers
        /// that need positions must still use `next()` — this method does
        /// not populate `pos_buf`, so reading `pos_buf.items` after a call
        /// returns stale data from the previous `next()` (if any).
        pub fn nextDocOnly(self: *PostingIterator) !?u64 {
            if (self.current_idx >= self.df) return null;

            const doc_delta = try utils.readVarInt(self.data[self.pos..]);
            self.pos += doc_delta.bytes_read;
            self.last_doc_id += doc_delta.val;

            const tf_res = try utils.readVarInt(self.data[self.pos..]);
            self.pos += tf_res.bytes_read;
            const tf = tf_res.val;
            if (tf > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;

            // Skip the positions varint stream without materializing them.
            // We still have to advance `self.pos` byte-by-byte through each
            // varint because positions are variable-width — there is no
            // length prefix on the position run, only a count (`tf`).
            var i: u64 = 0;
            while (i < tf) : (i += 1) {
                const pos_delta = try utils.readVarInt(self.data[self.pos..]);
                self.pos += pos_delta.bytes_read;
            }

            self.current_idx += 1;
            return self.last_doc_id;
        }
    };

    pub fn search(self: *SegmentReader, term: []const u8) !?PostingIterator {
        if (self.dictionary.get(term)) |entry| {
            if (entry.postings_len > limits.MAX_POSTINGS_BYTES) return error.PostingsTooLarge;
            // SEC-EXT-0703: per-query bound. The on-disk size cap above
            // protects against an oversized persisted entry, but a 4-GiB
            // allocation per term per segment is still ruinous for an
            // attacker-influenced query (or even an honest one against a
            // hostile corpus). 256 MiB is enough to hold ~50M postings —
            // beyond any realistic per-term-per-segment workload — while
            // keeping the worst-case multi-segment fan-out (N * 256 MiB)
            // bounded. Multi-segment queries pay this per segment; an
            // engine-wide bound would require coordination across iterator
            // construction and is deferred (TermIterator-level cap).
            if (entry.postings_len > limits.MAX_POSTINGS_BYTES_PER_QUERY) return error.PostingsTooLarge;
            const postings_len_usize = std.math.cast(usize, entry.postings_len) orelse return error.PostingsTooLarge;
            const data = try self.allocator.alloc(u8, postings_len_usize);
            errdefer self.allocator.free(data);

            if (self.postings_data) |pd| {
                // Encrypted segment path (WRK-038, GAP-0009, SEC-EXT-0402):
                // the entire decrypted postings.bin is in memory; just slice.
                const offset_usize = std.math.cast(usize, entry.postings_offset) orelse return error.PostingsTooLarge;
                if (offset_usize + postings_len_usize > pd.len) return error.Incomplete;
                @memcpy(data, pd[offset_usize .. offset_usize + postings_len_usize]);
            } else {
                // Plaintext path: use the cached postings.bin handle opened
                // in init (WRK-033) so we do not pay an openDir + openFile +
                // close per query (PERF-0005, PERF-0007).
                var index: usize = 0;
                while (index < data.len) {
                    const amt = try self.postings_file.readPositional(self.io, &.{data[index..]}, entry.postings_offset + index);
                    if (amt == 0) return error.Incomplete;
                    index += amt;
                }
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

    // PERF-0008: the field-by-field `readU{16,32,64}FromFile` helpers used by
    // pre-WRK-034 segment load have been retired. `readSegmentFile` slurps the
    // entire file in one read and the in-memory parser walks the bytes with
    // `utils.readU{16,32,64}Le`. This trades a few KB of transient memory per
    // segment for ~5× fewer syscalls during init (1 read vs. ~12N reads where
    // N is the term count).

    /// Read `name` from `seg_dir` into a fresh allocator-owned buffer,
    /// transparently AEAD-decrypting when `self.aead_key` is set
    /// (WRK-038, GAP-0009, SEC-EXT-0402). Returns null when the file does
    /// not exist. SEC-EXT-0301: refuses to follow symlinks.
    fn readSegmentFile(self: *SegmentReader, name: []const u8) !?[]u8 {
        const file = self.seg_dir.openFile(self.io, name, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const size_usize = std.math.cast(usize, stat.size) orelse return error.PostingsTooLarge;

        const raw = try self.allocator.alloc(u8, size_usize);
        errdefer self.allocator.free(raw);

        if (size_usize > 0) {
            var index: usize = 0;
            while (index < size_usize) {
                const amt = try file.readPositional(self.io, &.{raw[index..]}, index);
                if (amt == 0) return error.Incomplete;
                index += amt;
            }
        }

        if (self.aead_key) |key| {
            defer self.allocator.free(raw);
            return try utils.aeadDecrypt(key, raw, self.allocator);
        }

        return raw;
    }

    fn load(self: *SegmentReader) !void {
        // Reuse the seg_dir handle opened in init rather than opening a new
        // one (WRK-033). The cached handle is also used by search().
        //
        // Each file is read into a contiguous buffer, optionally AEAD-
        // decrypted (WRK-038), and then parsed in-memory. The plaintext
        // path is byte-for-byte equivalent to the pre-WRK-038 streaming
        // parser since `readSegmentFile` returns the same bytes that used
        // to be streamed.

        // Load dictionary. PERF-0017: keys are interned into a single
        // per-segment arena instead of N individual `dupe` allocations.
        // Two-pass over dict_buf — first to compute total term bytes so the
        // arena can be sized exactly, second to copy + register entries.
        if (try self.readSegmentFile("terms.hash")) |dict_buf| {
            defer self.allocator.free(dict_buf);
            var pos: usize = 0;
            if (dict_buf.len < 4) return error.Incomplete;
            const count = utils.readU32Le(dict_buf, &pos);
            if (count > limits.MAX_TERMS_PER_SEGMENT) return error.TermCountTooLarge;
            const header_end = pos;

            // Pass 1: compute total bytes of term names. Walk the same record
            // layout the writer emits: u16 term_len | term | 24 bytes of
            // (df,offset,len). Bounds-check every step exactly like Pass 2.
            var total_term_bytes: usize = 0;
            {
                var p: usize = header_end;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    if (p + 2 > dict_buf.len) return error.Incomplete;
                    const tl = utils.readU16Le(dict_buf, &p);
                    if (p + tl > dict_buf.len) return error.Incomplete;
                    total_term_bytes += tl;
                    p += tl;
                    if (p + 24 > dict_buf.len) return error.Incomplete;
                    p += 24;
                }
            }

            // Allocate the arena exactly once. Empty segments (count==0)
            // intentionally leave `key_arena.len == 0` so deinit skips the
            // free path.
            if (total_term_bytes != 0) {
                self.key_arena = try self.allocator.alloc(u8, total_term_bytes);
            }

            try self.dictionary.ensureTotalCapacity(self.allocator, count);

            // Pass 2: populate. `arena_off` tracks the write head into
            // key_arena; each entry's key is a stable slice into it (the
            // arena is allocated once, never resized, so slices never move).
            var arena_off: usize = 0;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (pos + 2 > dict_buf.len) return error.Incomplete;
                const term_len = utils.readU16Le(dict_buf, &pos);
                if (pos + term_len > dict_buf.len) return error.Incomplete;

                const key_slice = self.key_arena[arena_off .. arena_off + term_len];
                @memcpy(key_slice, dict_buf[pos .. pos + term_len]);
                arena_off += term_len;
                pos += term_len;

                if (pos + 24 > dict_buf.len) return error.Incomplete;
                const df = utils.readU64Le(dict_buf, &pos);
                const offset = utils.readU64Le(dict_buf, &pos);
                const len = utils.readU64Le(dict_buf, &pos);

                self.dictionary.putAssumeCapacityNoClobber(key_slice, .{
                    .df = df,
                    .postings_offset = offset,
                    .postings_len = len,
                });
            }
        }

        // Load tombstones.
        if (try self.readSegmentFile("tombstones.bin")) |ts_buf| {
            defer self.allocator.free(ts_buf);
            var pos: usize = 0;
            if (ts_buf.len < 4) return error.Incomplete;
            const count = utils.readU32Le(ts_buf, &pos);
            if (count > limits.MAX_TOMBSTONES_PER_SEGMENT) return error.TombstoneCountTooLarge;
            try self.tombstones.ensureTotalCapacity(self.allocator, count);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (pos + 8 > ts_buf.len) return error.Incomplete;
                const doc_id = utils.readU64Le(ts_buf, &pos);
                self.tombstones.putAssumeCapacityNoClobber(doc_id, {});
            }
        }

        // Load per-doc length norms. Absence is fine: pre-WRK-035 segments
        // simply have no norms.bin, and BM25 falls back to DEFAULT_DOC_LEN.
        if (try self.readSegmentFile("norms.bin")) |norms_buf| {
            defer self.allocator.free(norms_buf);
            var pos: usize = 0;
            if (norms_buf.len < 4) return error.Incomplete;
            const count = utils.readU32Le(norms_buf, &pos);
            if (count > limits.MAX_NORMS_PER_SEGMENT) return error.NormCountTooLarge;
            try self.norms.ensureTotalCapacity(self.allocator, count);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (pos + 12 > norms_buf.len) return error.Incomplete;
                const doc_id = utils.readU64Le(norms_buf, &pos);
                const length = utils.readU32Le(norms_buf, &pos);
                self.norms.putAssumeCapacityNoClobber(doc_id, length);
            }
        }

        // When AEAD is enabled, the postings_file handle cannot be used for
        // positional reads — the GCM tag covers the entire file so the
        // ciphertext is not random-accessible. Pre-load and decrypt the
        // whole file once at init; search() will read from this buffer.
        if (self.aead_key != null) {
            self.postings_data = (try self.readSegmentFile("postings.bin")) orelse
                try self.allocator.alloc(u8, 0);
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

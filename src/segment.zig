// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const limits = @import("limits.zig");

pub const Error = @import("errors.zig").SegmentError;

/// v2 segment-file envelope (GSP-9): magic(4) | version(4 LE) | payload |
/// crc32c(4, over magic..payload). Uniform across terms.hash, postings.bin,
/// tombstones.bin, norms.bin; applied INSIDE the AEAD envelope when
/// encryption is on. The magic's four bytes deliberately decode — as the
/// u32 LE `count` field every legacy parser reads first — to ~843.5M, far
/// above every MAX_*_PER_SEGMENT cap (2^24), so a pre-v2 binary that opens
/// a v2 file fails loudly at its existing count guard instead of misparsing
/// (graph-storage parity: cross-layout misroutes must trip existing guards).
pub const SEGMENT_FILE_MAGIC: [4]u8 = .{ 'F', 'S', 'G', '2' };
pub const SEGMENT_FILE_VERSION: u32 = 2;

// ============================================================================
// Memtable (In-Memory Staging)
// ============================================================================

// PERF-0016 (closed 2026-05-27): switched from Array-of-Structs to
// Struct-of-Arrays. The prior layout walked `postings.items` and
// dereferenced a fresh heap pointer for the positions ArrayList on every
// row, breaking the CPU's stride prefetch. The new layout packs each term's
// postings into four parallel arrays (doc_ids, tfs, positions_offsets,
// positions_pool); flush iterates four linear scans over contiguous
// memory, which the prefetcher can saturate. See `MemPostingsList.get` for
// the view returned to consumers — the surface API stays the same shape
// (a `MemPosting` value), only the storage is SoA.
/// A read-only view of one posting in a `MemPostingsList`. Returned by
/// `MemPostingsList.get(i)`. Backed by the SoA arrays; the `positions`
/// slice borrows from the list's `positions_pool` and is valid as long
/// as the list is not mutated.
pub const MemPosting = struct {
    doc_id: u64,
    tf: u32,
    positions: []const u32,
};

pub const MemPostingsList = struct {
    /// Parallel arrays — one entry per posting at index i.
    doc_ids: std.ArrayListUnmanaged(u64) = .empty,
    tfs: std.ArrayListUnmanaged(u32) = .empty,
    /// Boundaries into `positions_pool`. Has `count() + 1` entries; the
    /// span `positions_pool.items[positions_offsets[i] .. positions_offsets[i+1]]`
    /// holds posting i's positions. The sentinel last entry tracks the
    /// pool's high-water mark so the next append knows where to start.
    positions_offsets: std.ArrayListUnmanaged(u32) = .empty,
    /// Contiguous pool of every posting's positions. Densely packed —
    /// position spans are concatenated end-to-end.
    positions_pool: std.ArrayListUnmanaged(u32) = .empty,
    df: u64 = 0,

    pub fn count(self: *const MemPostingsList) usize {
        return self.doc_ids.items.len;
    }

    /// Materialize a read-only view of posting `i`. The `positions` slice
    /// borrows from `positions_pool` — valid only until the next mutation.
    pub fn get(self: *const MemPostingsList, i: usize) MemPosting {
        const start: usize = @intCast(self.positions_offsets.items[i]);
        const end: usize = @intCast(self.positions_offsets.items[i + 1]);
        return .{
            .doc_id = self.doc_ids.items[i],
            .tf = self.tfs.items[i],
            .positions = self.positions_pool.items[start..end],
        };
    }

    pub fn deinit(self: *MemPostingsList, allocator: Allocator) void {
        self.doc_ids.deinit(allocator);
        self.tfs.deinit(allocator);
        self.positions_offsets.deinit(allocator);
        self.positions_pool.deinit(allocator);
    }
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
            entry.value_ptr.deinit(self.allocator);
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
            entry.value_ptr.* = .{};
            // No errdefer free of key_copy — arena ownership.
            errdefer _ = self.dictionary.remove(key_copy);
            // Seed positions_offsets with the leading sentinel (=0) so the
            // first append can use the standard "push end-offset after
            // payload" pattern below.
            try entry.value_ptr.positions_offsets.append(self.allocator, 0);
        }

        const tf_u32 = std.math.cast(u32, positions.len) orelse return error.PositionCountTooLarge;
        const pl = entry.value_ptr;

        // PERF-0016 SoA append. Three parallel array growths + one bulk
        // positions copy. Allocations grow geometrically inside each array,
        // so the amortized cost per addPosting is O(1).
        try pl.doc_ids.append(self.allocator, doc_id);
        errdefer _ = pl.doc_ids.pop();
        try pl.tfs.append(self.allocator, tf_u32);
        errdefer _ = pl.tfs.pop();
        try pl.positions_pool.appendSlice(self.allocator, positions);
        errdefer pl.positions_pool.shrinkRetainingCapacity(pl.positions_pool.items.len - positions.len);
        // Push the new high-water sentinel — the end offset of this posting's
        // positions slice. Indexing: get(i) reads offsets[i]..offsets[i+1].
        const new_end: u32 = std.math.cast(u32, pl.positions_pool.items.len) orelse return error.PositionCountTooLarge;
        try pl.positions_offsets.append(self.allocator, new_end);

        pl.df += 1;
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
        // Build the v2 envelope (GSP-9). Transient copy is the same order
        // of memory the AEAD path already pays; acceptable for flush-sized
        // payloads.
        const enveloped = try self.allocator.alloc(u8, 8 + buf.len + 4);
        defer self.allocator.free(enveloped);
        @memcpy(enveloped[0..4], &SEGMENT_FILE_MAGIC);
        std.mem.writeInt(u32, enveloped[4..8], SEGMENT_FILE_VERSION, .little);
        @memcpy(enveloped[8 .. 8 + buf.len], buf);
        // fips-exempt: non-security — CRC32c integrity checksum (the AEAD
        // envelope covers integrity-against-adversary when enabled).
        const crc = utils.hashCrc32c(enveloped[0 .. 8 + buf.len]);
        std.mem.writeInt(u32, enveloped[8 + buf.len ..][0..4], crc, .little);

        const file = try seg_dir.createFile(self.io, name, .{ .permissions = utils.fileMode(0o600) });
        defer file.close(self.io);

        if (self.aead_key) |key| {
            const enc = try utils.aeadEncrypt(self.io, key, enveloped, self.allocator);
            defer self.allocator.free(enc);
            try file.writeStreamingAll(self.io, enc);
        } else {
            try file.writeStreamingAll(self.io, enveloped);
        }

        // GSP-7: fsync segment data BEFORE flushLocked Phase 2 publishes a
        // manifest referencing this file and Phase 3 truncates the WAL.
        // Without this, a durable manifest can point at torn segment pages
        // that no WAL replay can repair (durable-reference/volatile-data
        // inversion). Directory-entry durability (the rename/creation
        // itself) remains a documented std.Io.Dir limitation — see
        // utils.atomicWrite.
        try file.sync(self.io);
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
            // PERF-0016 SoA iteration: walk doc_ids + tfs in lockstep. The
            // prefetcher sees both arrays as linear streams and saturates
            // easily — no per-posting heap pointer dereference for the
            // positions ArrayList header (which the old AoS layout forced).
            const pl = entry.value_ptr;
            const n = pl.count();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const gop = try doc_lens.getOrPut(self.allocator, pl.doc_ids.items[i]);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = std.math.add(u32, gop.value_ptr.*, pl.tfs.items[i]) catch
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

            // Write postings — SoA iteration (PERF-0016). The three parallel
            // arrays are walked in lockstep so the prefetcher can keep all
            // three streams in flight; positions span comes from one
            // contiguous pool, not per-posting heap-pointer dereferences.
            var last_doc_id: u64 = 0;
            const n = list.count();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const doc_id = list.doc_ids.items[i];
                const tf = list.tfs.items[i];
                const pos_start: usize = @intCast(list.positions_offsets.items[i]);
                const pos_end: usize = @intCast(list.positions_offsets.items[i + 1]);
                const positions = list.positions_pool.items[pos_start..pos_end];

                // Delta encoded doc_id.
                const delta = doc_id - last_doc_id;
                last_doc_id = doc_id;

                const w1 = try utils.writeVarInt(&buf, delta);
                try post_buf.appendSlice(self.allocator, buf[0..w1]);

                const w2 = try utils.writeVarInt(&buf, tf);
                try post_buf.appendSlice(self.allocator, buf[0..w2]);

                var last_pos: u32 = 0;
                for (positions) |pos| {
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
    /// GSP-9: per-segment file format, detected once on terms.hash (whose
    /// magic is unambiguous — see SEGMENT_FILE_MAGIC doc). `.legacy` reads
    /// every file verbatim (naked v1 layout); `.enveloped` requires and
    /// strips the v2 envelope on every file.
    file_format: FileFormat = .auto,
    /// Byte offset of the postings payload inside postings.bin: 8 when the
    /// segment is v2-enveloped (magic+version header), 0 for legacy. Used
    /// by the plaintext positional-read path in search().
    postings_base: u64 = 0,

    pub const FileFormat = enum { auto, enveloped, legacy };

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
        const postings_file = try utils.openFileNoFollow(io, seg_dir, "postings.bin");
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
        data: []const u8,
        /// True when the iterator owns `data` and must free it on deinit.
        /// False when `data` is a borrowed slice into the parent reader's
        /// `postings_data` buffer (encrypted-segment fast path — PERF rank
        /// 9, AEAD branch). Borrowing skips one alloc + memcpy of the full
        /// postings span per (term, segment) query when AEAD is enabled.
        owns_data: bool,
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
            if (self.owns_data) {
                self.allocator.free(@constCast(self.data));
            }
            self.pos_buf.deinit(self.allocator);
        }

        pub fn next(self: *PostingIterator) !?Posting {
            if (self.current_idx >= self.df) return null;

            const doc_delta = try utils.readVarInt(self.data[self.pos..]);
            self.pos += doc_delta.bytes_read;
            // GSP-4: disk-derived deltas get checked arithmetic in every
            // build mode — a corrupt delta must surface as an error, never
            // a panic (Debug/ReleaseSafe) or silent wrap (ReleaseFast).
            self.last_doc_id = std.math.add(u64, self.last_doc_id, doc_delta.val) catch
                return error.InvalidData;

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
                // GSP-4, single-branch form: delta must fit in the remaining
                // u32 headroom. One compare replaces the previous
                // cast-then-checked-add pair (two branches) — same guarantee
                // (never panics, never wraps, in every build mode), measured
                // ~half the checked-decode overhead on the posting_iter
                // microbenches. `maxInt(u32) - last_pos` cannot underflow and
                // the subsequent add cannot overflow by construction.
                if (pos_delta.val > std.math.maxInt(u32) - last_pos)
                    return error.PositionOutOfRange;
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
            // GSP-4: same checked add as `next` — corrupt delta streams
            // must error, never panic or wrap.
            self.last_doc_id = std.math.add(u64, self.last_doc_id, doc_delta.val) catch
                return error.InvalidData;

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

            if (self.postings_data) |pd| {
                // Encrypted segment fast path (WRK-038, GAP-0009, SEC-EXT-0402).
                // PERF rank 9: the entire decrypted postings.bin is already
                // resident; return a borrowed slice instead of allocating +
                // memcpy'ing a private copy per (term, segment) call. Saves
                // one alloc + one memcpy of `postings_len_usize` bytes per
                // query when AEAD is enabled.
                const offset_usize = std.math.cast(usize, entry.postings_offset) orelse return error.PostingsTooLarge;
                if (offset_usize + postings_len_usize > pd.len) return error.Incomplete;
                return PostingIterator{
                    .allocator = self.allocator,
                    .data = pd[offset_usize .. offset_usize + postings_len_usize],
                    .owns_data = false,
                    .df = entry.df,
                    .current_idx = 0,
                    .pos = 0,
                    .last_doc_id = 0,
                    .pos_buf = .empty,
                };
            }

            // Plaintext path: use the cached postings.bin handle opened in
            // init (WRK-033) so we do not pay an openDir + openFile + close
            // per query (PERF-0005, PERF-0007). The buffer is owned by the
            // iterator because postings.bin is not memory-resident.
            const owned_data = try self.allocator.alloc(u8, postings_len_usize);
            errdefer self.allocator.free(owned_data);
            var index: usize = 0;
            while (index < owned_data.len) {
                const amt = try self.postings_file.readPositional(
                    self.io,
                    &.{owned_data[index..]},
                    self.postings_base + entry.postings_offset + index,
                );
                if (amt == 0) return error.Incomplete;
                index += amt;
            }

            return PostingIterator{
                .allocator = self.allocator,
                .data = owned_data,
                .owns_data = true,
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
    fn readSegmentFile(self: *SegmentReader, name: []const u8, expect: FileFormat) !?[]u8 {
        const file = utils.openFileNoFollow(self.io, self.seg_dir, name) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const size_usize = std.math.cast(usize, stat.size) orelse return error.PostingsTooLarge;

        const raw = try self.allocator.alloc(u8, size_usize);
        // `raw_owned` tracks whether `raw` still needs freeing via the
        // errdefer below. The AEAD branch frees `raw` unconditionally once
        // it has been consumed by `aeadDecrypt` (success or failure) — if
        // that errdefer stayed armed unconditionally, a later error (e.g.
        // ChecksumMismatch/UnsupportedSegmentVersion, both reachable only
        // after a *successful* decrypt) would free `raw` a second time.
        var raw_owned = true;
        errdefer if (raw_owned) self.allocator.free(raw);

        if (size_usize > 0) {
            var index: usize = 0;
            while (index < size_usize) {
                const amt = try file.readPositional(self.io, &.{raw[index..]}, index);
                if (amt == 0) return error.Incomplete;
                index += amt;
            }
        }

        const plain = if (self.aead_key) |key| blk: {
            raw_owned = false;
            defer self.allocator.free(raw);
            break :blk try utils.aeadDecrypt(key, raw, self.allocator);
        } else raw;
        errdefer if (self.aead_key != null) self.allocator.free(plain);

        // GSP-9 envelope handling. `.legacy` returns the bytes verbatim —
        // legacy postings.bin could coincidentally start with the magic
        // bytes as valid varint data, so legacy segments are never
        // envelope-sniffed beyond the initial terms.hash detection.
        switch (expect) {
            .legacy => return plain,
            .auto, .enveloped => {},
        }
        const has_magic = plain.len >= 12 and std.mem.eql(u8, plain[0..4], &SEGMENT_FILE_MAGIC);
        if (!has_magic) {
            if (expect == .enveloped) return error.InvalidData;
            // .auto on a naked file: legacy segment.
            self.file_format = .legacy;
            return plain;
        }
        if (expect == .auto) self.file_format = .enveloped;

        const version = std.mem.readInt(u32, plain[4..8], .little);
        if (version != SEGMENT_FILE_VERSION) return error.UnsupportedSegmentVersion;
        const stored_crc = std.mem.readInt(u32, plain[plain.len - 4 ..][0..4], .little);
        // fips-exempt: non-security — CRC32c integrity checksum (AEAD covers
        // integrity-against-adversary when enabled).
        const computed = utils.hashCrc32c(plain[0 .. plain.len - 4]);
        if (stored_crc != computed) return error.ChecksumMismatch;

        const payload_len = plain.len - 12;
        std.mem.copyForwards(u8, plain[0..payload_len], plain[8 .. 8 + payload_len]);
        // OWNERSHIP HAZARD: on the plaintext path `plain == raw` and the
        // `raw_owned` errdefer above is still armed — it is the sole owner
        // until this expression completes (the dupe-OOM `try` inside the
        // catch relies on it). A successful realloc may free-and-move that
        // memory, so NOTHING fallible may be inserted between the realloc
        // and the return, or the stale errdefer double-frees.
        const shrunk = self.allocator.realloc(plain, payload_len) catch blk: {
            const copy = try self.allocator.dupe(u8, plain[0..payload_len]);
            self.allocator.free(plain);
            break :blk copy;
        };
        return shrunk;
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

        // GSP-9: detect the segment's file format on terms.hash FIRST — its
        // magic is unambiguous (see SEGMENT_FILE_MAGIC). Every other file in
        // the segment must then match.
        const dict_buf_opt = try self.readSegmentFile("terms.hash", .auto);

        // GSP-5: materialize AEAD postings before dictionary parse so its
        // length bounds the (offset, len) validation below. For the v2
        // plaintext path, verify the postings header eagerly and account
        // for the 8-byte payload base + 4-byte CRC trailer; whole-file CRC
        // verification for plaintext postings is deliberately skipped at
        // open (O(file) read) — integrity there = checked decode (GSP-4)
        // + extent validation (GSP-5) + AEAD when enabled.
        if (self.aead_key != null) {
            self.postings_data = (try self.readSegmentFile("postings.bin", self.file_format)) orelse
                try self.allocator.alloc(u8, 0);
        }
        var postings_size: u64 = 0;
        if (self.postings_data) |pd| {
            postings_size = pd.len;
        } else {
            const st = try self.postings_file.stat(self.io);
            if (self.file_format == .enveloped) {
                if (st.size < 12) return error.Incomplete;
                var hdr: [8]u8 = undefined;
                var got: usize = 0;
                while (got < hdr.len) {
                    const amt = try self.postings_file.readPositional(self.io, &.{hdr[got..]}, got);
                    if (amt == 0) return error.Incomplete;
                    got += amt;
                }
                if (!std.mem.eql(u8, hdr[0..4], &SEGMENT_FILE_MAGIC)) return error.InvalidData;
                const version = std.mem.readInt(u32, hdr[4..8], .little);
                if (version != SEGMENT_FILE_VERSION) return error.UnsupportedSegmentVersion;
                self.postings_base = 8;
                postings_size = st.size - 12;
            } else {
                postings_size = st.size;
            }
        }

        // Load dictionary. PERF-0017: keys are interned into a single
        // per-segment arena instead of N individual `dupe` allocations.
        // Two-pass over dict_buf — first to compute total term bytes so the
        // arena can be sized exactly, second to copy + register entries.
        if (dict_buf_opt) |dict_buf| {
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

                // GSP-5 (graph-storage parity): validate disk-derived extents
                // at load, symmetrically for plaintext and AEAD paths. A
                // wrong-but-in-range offset can still decode garbage until
                // the v2 envelope (GSP-9) adds whole-file CRC — but out-of-
                // range and absurd entries fail loud at open, not at query.
                if (len > limits.MAX_POSTINGS_BYTES) return error.PostingsTooLarge;
                const end = std.math.add(u64, offset, len) catch return error.InvalidData;
                if (end > postings_size) return error.InvalidData;
                // Every posting occupies at least one byte, so df can never
                // exceed the byte length of its postings run.
                if (df > len) return error.InvalidData;

                self.dictionary.putAssumeCapacityNoClobber(key_slice, .{
                    .df = df,
                    .postings_offset = offset,
                    .postings_len = len,
                });
            }
        }

        // Load tombstones.
        if (try self.readSegmentFile("tombstones.bin", self.file_format)) |ts_buf| {
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
        if (try self.readSegmentFile("norms.bin", self.file_format)) |norms_buf| {
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

test "PostingIterator rejects doc-id delta overflow instead of panicking (GSP-4)" {
    const alloc = std.testing.allocator;
    // Posting 1: doc delta = maxInt(u64), tf = 1, one position delta 1.
    // Posting 2: doc delta = 1 -> u64 overflow on accumulate.
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);
    var vbuf: [10]u8 = undefined;
    var w = try utils.writeVarInt(&vbuf, std.math.maxInt(u64));
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // tf
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // pos delta
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // posting 2 doc delta -> overflow
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // tf
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // pos delta
    try data.appendSlice(alloc, vbuf[0..w]);

    var it = SegmentReader.PostingIterator{
        .allocator = alloc,
        .data = data.items,
        .owns_data = false,
        .df = 2,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.pos_buf.deinit(alloc);
    _ = try it.next(); // posting 1: doc_id = maxInt, fine
    try std.testing.expectError(error.InvalidData, it.next());
}

test "PostingIterator rejects oversized position delta instead of panicking (GSP-4)" {
    const alloc = std.testing.allocator;
    // One posting: doc delta 1, tf 1, position delta maxInt(u64) — the
    // unchecked @intCast to u32 used to panic (Debug/ReleaseSafe) or wrap
    // silently (ReleaseFast).
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);
    var vbuf: [10]u8 = undefined;
    var w = try utils.writeVarInt(&vbuf, 1);
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1);
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, std.math.maxInt(u64));
    try data.appendSlice(alloc, vbuf[0..w]);

    var it = SegmentReader.PostingIterator{
        .allocator = alloc,
        .data = data.items,
        .owns_data = false,
        .df = 1,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.pos_buf.deinit(alloc);
    try std.testing.expectError(error.PositionOutOfRange, it.next());
}

test "nextDocOnly rejects doc-id delta overflow (GSP-4)" {
    const alloc = std.testing.allocator;
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);
    var vbuf: [10]u8 = undefined;
    var w = try utils.writeVarInt(&vbuf, std.math.maxInt(u64));
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 0); // tf = 0, no positions
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // posting 2 delta -> overflow
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 0);
    try data.appendSlice(alloc, vbuf[0..w]);

    var it = SegmentReader.PostingIterator{
        .allocator = alloc,
        .data = data.items,
        .owns_data = false,
        .df = 2,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.pos_buf.deinit(alloc);
    _ = try it.nextDocOnly();
    try std.testing.expectError(error.InvalidData, it.nextDocOnly());
}

test "SegmentReader.load rejects dictionary entries pointing outside postings.bin (GSP-5)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try tmp_dir.dir.createDir(io, "seg_1", .default_dir);
    var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
    defer seg_dir.close(io);

    // terms.hash claiming (offset=0, len=1 GiB) against an 8-byte postings.bin.
    var dict: std.ArrayListUnmanaged(u8) = .empty;
    defer dict.deinit(alloc);
    var num: [8]u8 = undefined;
    std.mem.writeInt(u32, num[0..4], 1, .little); // count = 1
    try dict.appendSlice(alloc, num[0..4]);
    std.mem.writeInt(u16, num[0..2], 1, .little); // term_len = 1
    try dict.appendSlice(alloc, num[0..2]);
    try dict.append(alloc, 't');
    std.mem.writeInt(u64, num[0..8], 1, .little); // df
    try dict.appendSlice(alloc, num[0..8]);
    std.mem.writeInt(u64, num[0..8], 0, .little); // postings_offset
    try dict.appendSlice(alloc, num[0..8]);
    std.mem.writeInt(u64, num[0..8], 1 << 30, .little); // postings_len — hostile
    try dict.appendSlice(alloc, num[0..8]);

    {
        const f = try seg_dir.createFile(io, "terms.hash", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, dict.items);
    }
    {
        const f = try seg_dir.createFile(io, "postings.bin", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, &[_]u8{0} ** 8);
    }

    // Pre-fix: init succeeds and the bad entry waits to poison a query.
    // Post-fix: load rejects at open.
    try std.testing.expectError(
        error.InvalidData,
        SegmentReader.init(io, alloc, tmp_dir.dir, 1),
    );
}

test "segment v2 envelope round-trips and legacy naked files still load (GSP-9)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Write a segment through the writer (v2 enveloped post-fix).
    var mt = Memtable.init(alloc);
    defer mt.deinit();
    try mt.addPosting("hello", 1, &[_]u32{ 1, 3 });
    try mt.addPosting("hello", 2, &[_]u32{2});
    try mt.addTombstone(9);
    var writer = SegmentWriter{ .io = io, .dir = tmp_dir.dir, .allocator = alloc, .segment_id = 1 };
    try writer.writeMemtable(&mt);

    // terms.hash must start with the magic.
    {
        var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);
        const f = try seg_dir.openFile(io, "terms.hash", .{});
        defer f.close(io);
        var hdr: [4]u8 = undefined;
        _ = try f.readPositional(io, &.{&hdr}, 0);
        try std.testing.expectEqualSlices(u8, &SEGMENT_FILE_MAGIC, &hdr);
    }

    // v2 reader round-trip.
    {
        var sr = try SegmentReader.init(io, alloc, tmp_dir.dir, 1);
        defer sr.deinit();
        var it = (try sr.search("hello")).?;
        defer it.deinit();
        const p1 = (try it.next()).?;
        try std.testing.expectEqual(@as(u64, 1), p1.doc_id);
        try std.testing.expect(sr.tombstones.contains(9));
    }

    // Strip the envelope from every file -> legacy naked layout; the reader
    // must still load it (permanent read-both).
    {
        var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);
        for ([_][]const u8{ "terms.hash", "postings.bin", "tombstones.bin", "norms.bin" }) |name| {
            const f = seg_dir.openFile(io, name, .{}) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            const stat = try f.stat(io);
            const buf = try alloc.alloc(u8, @intCast(stat.size));
            defer alloc.free(buf);
            var idx: usize = 0;
            while (idx < buf.len) {
                const amt = try f.readPositional(io, &.{buf[idx..]}, idx);
                if (amt == 0) break;
                idx += amt;
            }
            f.close(io);
            try seg_dir.deleteFile(io, name);
            const nf = try seg_dir.createFile(io, name, .{});
            defer nf.close(io);
            try nf.writeStreamingAll(io, buf[8 .. buf.len - 4]);
            try nf.sync(io);
        }
        var sr = try SegmentReader.init(io, alloc, tmp_dir.dir, 1);
        defer sr.deinit();
        var it = (try sr.search("hello")).?;
        defer it.deinit();
        const p1 = (try it.next()).?;
        try std.testing.expectEqual(@as(u64, 1), p1.doc_id);
    }
}

test "segment v2 envelope detects payload corruption and rejects future versions (GSP-9)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var mt = Memtable.init(alloc);
    defer mt.deinit();
    try mt.addPosting("term", 1, &[_]u32{1});
    var writer = SegmentWriter{ .io = io, .dir = tmp_dir.dir, .allocator = alloc, .segment_id = 1 };
    try writer.writeMemtable(&mt);

    var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
    defer seg_dir.close(io);

    // Flip one payload byte in terms.hash: pre-envelope this was silently
    // absorbed or surfaced as a confusing structural error; now it is a
    // deterministic ChecksumMismatch at open.
    {
        const f = try seg_dir.openFile(io, "terms.hash", .{ .mode = .read_write });
        defer f.close(io);
        var b: [1]u8 = undefined;
        _ = try f.readPositional(io, &.{&b}, 9);
        b[0] ^= 0xFF;
        try f.writePositionalAll(io, &b, 9);
        try f.sync(io);
    }
    try std.testing.expectError(
        error.ChecksumMismatch,
        SegmentReader.init(io, alloc, tmp_dir.dir, 1),
    );

    // Repair the byte, then stamp version=3 with a recomputed CRC: must be
    // UnsupportedSegmentVersion (the downgrade gate), not a misparse.
    {
        const f = try seg_dir.openFile(io, "terms.hash", .{ .mode = .read_write });
        defer f.close(io);
        var b: [1]u8 = undefined;
        _ = try f.readPositional(io, &.{&b}, 9);
        b[0] ^= 0xFF;
        try f.writePositionalAll(io, &b, 9);
        const stat = try f.stat(io);
        const buf = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(buf);
        var idx: usize = 0;
        while (idx < buf.len) {
            const amt = try f.readPositional(io, &.{buf[idx..]}, idx);
            if (amt == 0) break;
            idx += amt;
        }
        std.mem.writeInt(u32, buf[4..8], 3, .little);
        const crc = utils.hashCrc32c(buf[0 .. buf.len - 4]);
        std.mem.writeInt(u32, buf[buf.len - 4 ..][0..4], crc, .little);
        try f.writePositionalAll(io, buf, 0);
        try f.sync(io);
    }
    try std.testing.expectError(
        error.UnsupportedSegmentVersion,
        SegmentReader.init(io, alloc, tmp_dir.dir, 1),
    );
}

test "AEAD path: post-decrypt version mismatch does not double-free the ciphertext scratch buffer (GSP-9)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const key = "32-bytes-of-aes-gcm-key-PLEASE!!";
    try std.testing.expectEqual(@as(usize, 32), key.len);

    var mt = Memtable.init(alloc);
    defer mt.deinit();
    try mt.addPosting("term", 1, &[_]u32{1});
    var writer = SegmentWriter{ .io = io, .dir = tmp_dir.dir, .allocator = alloc, .segment_id = 1, .aead_key = key };
    try writer.writeMemtable(&mt);

    // Craft a custom v2-enveloped payload with version=3, authentically
    // AEAD-encrypted under the real key, and overwrite terms.hash with it.
    {
        var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);

        var payload_buf: [64]u8 = undefined;
        @memcpy(payload_buf[0..4], &SEGMENT_FILE_MAGIC);
        std.mem.writeInt(u32, payload_buf[4..8], 3, .little); // future version
        const fake_payload = "hello-world-payload";
        @memcpy(payload_buf[8 .. 8 + fake_payload.len], fake_payload);
        const crc = utils.hashCrc32c(payload_buf[0 .. 8 + fake_payload.len]);
        std.mem.writeInt(u32, payload_buf[8 + fake_payload.len ..][0..4], crc, .little);
        const enveloped = payload_buf[0 .. 8 + fake_payload.len + 4];

        const enc = try utils.aeadEncrypt(io, key, enveloped, alloc);
        defer alloc.free(enc);

        try seg_dir.deleteFile(io, "terms.hash");
        const f = try seg_dir.createFile(io, "terms.hash", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, enc);
        try f.sync(io);
    }

    try std.testing.expectError(
        error.UnsupportedSegmentVersion,
        SegmentReader.initWithAead(io, alloc, tmp_dir.dir, 1, key),
    );
}

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("engine.zig");
const segment = @import("segment.zig");
const limits = @import("limits.zig");

/// BM25 scoring constants. Standard defaults from the BM25 paper; we keep
/// them compile-time fixed since exposing knobs prematurely is more rope to
/// hang downstream consumers with (WRK-035, GAP-0005).
pub const BM25_K1: f32 = 1.2;
pub const BM25_B: f32 = 0.75;

pub const TermIterator = struct {
    eng: *engine.Engine,
    term: []const u8,
    allocator: Allocator,

    // Iterator state
    mem_postings: ?*const segment.MemPostingsList,
    mem_idx: usize,

    seg_iters: std.ArrayListUnmanaged(segment.SegmentReader.PostingIterator),
    /// Parallel to `seg_iters`: the segment that produced each iterator, kept
    /// so `next()` can look up the per-doc length norm from that segment's
    /// `norms` map (WRK-035, GAP-0005, GAP-0006).
    seg_refs: std.ArrayListUnmanaged(*segment.SegmentReader),
    seg_idx: usize,

    /// Per-term document frequency: number of distinct docs containing the
    /// term across the memtable + all segments. Captured at iterator init so
    /// every yielded `Match.score` uses the same df (WRK-035).
    df: u64,

    pub const Match = struct {
        doc_id: u64,
        positions: []const u32,
        /// BM25 relevance score for this (term, doc) match. Higher is more
        /// relevant. Computed from term frequency, document length, the
        /// engine's running `avg_doc_len`, and the iterator's captured `df`
        /// (WRK-035, GAP-0005). `0.0` is a valid score; callers should not
        /// special-case it.
        score: f32,
    };

    pub fn init(allocator: Allocator, eng: *engine.Engine, term: []const u8) !TermIterator {
        // Validate inputs at the API boundary (SEC-EXT-0101, 0102).
        if (term.len == 0) return error.EmptyTerm;
        if (term.len > limits.MAX_TERM_LEN) return error.TermTooLong;

        var seg_iters: std.ArrayListUnmanaged(segment.SegmentReader.PostingIterator) = .empty;
        errdefer {
            for (seg_iters.items) |*iter| iter.deinit();
            seg_iters.deinit(allocator);
        }
        var seg_refs: std.ArrayListUnmanaged(*segment.SegmentReader) = .empty;
        errdefer seg_refs.deinit(allocator);

        // Sum df across segments and the memtable. df is the number of
        // distinct docs that contain the term; the segment writer already
        // stores it per-term, and the memtable tracks it on MemPostingsList.
        // The numbers are additive here only because each doc lives in
        // exactly one place (a doc never appears in two segments at the same
        // time pre-compaction in this minimum-viable engine) — this is good
        // enough for relative ranking.
        var df_total: u64 = 0;
        for (eng.segments.items) |*seg| {
            if (try seg.search(term)) |posting_iter| {
                try seg_iters.append(allocator, posting_iter);
                try seg_refs.append(allocator, seg);
                if (seg.dictionary.get(term)) |entry| {
                    df_total += entry.df;
                }
            }
        }

        const mem_postings = if (eng.memtable.dictionary.getPtr(term)) |pl| pl else null;
        if (mem_postings) |pl| df_total += pl.df;

        return TermIterator{
            .eng = eng,
            .term = term,
            .allocator = allocator,
            .mem_postings = mem_postings,
            .mem_idx = 0,
            .seg_iters = seg_iters,
            .seg_refs = seg_refs,
            .seg_idx = 0,
            .df = df_total,
        };
    }

    pub fn deinit(self: *TermIterator) void {
        for (self.seg_iters.items) |*iter| {
            iter.deinit();
        }
        self.seg_iters.deinit(self.allocator);
        self.seg_refs.deinit(self.allocator);
    }

    fn isDeleted(self: *TermIterator, doc_id: u64) bool {
        // O(1) via the engine-aggregated tombstone set rather than scanning
        // every segment per yielded doc (PERF-0006, WRK-031). The aggregated
        // set is kept consistent in Engine.init, deleteDocument, and flush.
        return self.eng.all_tombstones.contains(doc_id);
    }

    /// Compute the BM25 score for a single (term, doc, tf) tuple, given the
    /// engine's running corpus statistics and this iterator's captured df.
    ///
    /// Formula (Robertson/Spärck Jones, standard form):
    ///   idf      = log((N - df + 0.5) / (df + 0.5) + 1.0)
    ///   tf_norm  = tf * (k1 + 1) / (tf + k1 * (1 - b + b * dl / avg_dl))
    ///   score    = idf * tf_norm
    ///
    /// Falls back to `limits.DEFAULT_DOC_LEN` for `avg_dl` and `dl` when the
    /// manifest's `avg_doc_len` is still zero (e.g. before the first flush)
    /// or when the doc has no entry in any segment's norms map (e.g. doc
    /// lives in the memtable). The fallback preserves relative ordering
    /// because it applies uniformly to the missing-data set (WRK-035).
    fn computeScore(self: *TermIterator, doc_id: u64, tf: u32) f32 {
        const total_docs = self.eng.current_manifest.total_docs;
        // Guard against an empty corpus: with N = 0 the formula's numerator
        // goes negative and log() produces NaN. Score 0 is a sane default —
        // it means "no evidence to rank on yet".
        if (total_docs == 0) return 0.0;
        const N: f32 = @floatFromInt(total_docs);
        const df_f: f32 = @floatFromInt(self.df);

        const idf_arg: f32 = (N - df_f + 0.5) / (df_f + 0.5) + 1.0;
        const idf: f32 = std.math.log(f32, std.math.e, idf_arg);

        const avg_dl_raw = self.eng.current_manifest.avg_doc_len;
        const avg_dl: f32 = if (avg_dl_raw == 0)
            @floatFromInt(limits.DEFAULT_DOC_LEN)
        else
            @floatFromInt(avg_dl_raw);

        // Look up per-doc length in any segment that has a norm for this
        // doc; fall back to DEFAULT_DOC_LEN if absent (memtable doc, or
        // pre-WRK-035 segment without norms.bin).
        var dl_u32: u32 = limits.DEFAULT_DOC_LEN;
        for (self.eng.segments.items) |*seg| {
            if (seg.norms.get(doc_id)) |n| {
                dl_u32 = n;
                break;
            }
        }
        const dl: f32 = @floatFromInt(dl_u32);

        const tf_f: f32 = @floatFromInt(tf);
        const tf_norm = tf_f * (BM25_K1 + 1.0) /
            (tf_f + BM25_K1 * (1.0 - BM25_B + BM25_B * dl / avg_dl));

        return idf * tf_norm;
    }

    pub fn next(self: *TermIterator) !?Match {
        while (true) {
            var match: ?Match = null;

            // First exhaust memtable
            if (self.mem_postings) |pl| {
                if (self.mem_idx < pl.postings.items.len) {
                    const posting = pl.postings.items[self.mem_idx];
                    self.mem_idx += 1;
                    const score = self.computeScore(posting.doc_id, posting.tf);
                    match = Match{
                        .doc_id = posting.doc_id,
                        .positions = posting.positions.items,
                        .score = score,
                    };
                }
            }

            // Then segments
            if (match == null) {
                while (self.seg_idx < self.seg_iters.items.len) {
                    if (try self.seg_iters.items[self.seg_idx].next()) |posting| {
                        const tf: u32 = std.math.cast(u32, posting.positions.len) orelse
                            std.math.maxInt(u32);
                        const score = self.computeScore(posting.doc_id, tf);
                        match = Match{
                            .doc_id = posting.doc_id,
                            .positions = posting.positions,
                            .score = score,
                        };
                        break;
                    } else {
                        self.seg_idx += 1;
                    }
                }
            }

            if (match) |m| {
                if (self.isDeleted(m.doc_id)) {
                    continue;
                }
                return m;
            } else {
                return null;
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "TermIterator searches across memtable and segments" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try engine.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    // Document 1
    const t1 = engine.TermPosting{ .term = "hello", .positions = &[_]u32{ 1, 5 } };
    const t2 = engine.TermPosting{ .term = "world", .positions = &[_]u32{2} };
    try eng.indexDocument(1, &[_]engine.TermPosting{ t1, t2 });

    // Document 2
    const t3 = engine.TermPosting{ .term = "hello", .positions = &[_]u32{10} };
    try eng.indexDocument(2, &[_]engine.TermPosting{t3});

    // Flush to create segment 1
    try eng.flush();

    // Document 3 (in memtable)
    const t4 = engine.TermPosting{ .term = "hello", .positions = &[_]u32{20} };
    try eng.indexDocument(3, &[_]engine.TermPosting{t4});

    // Delete document 1 (tombstone in memtable)
    try eng.deleteDocument(1);

    // Search for "hello"
    var iter = try TermIterator.init(alloc, eng, "hello");
    defer iter.deinit();

    // Should yield doc 3 (memtable)
    const m1 = (try iter.next()).?;
    try std.testing.expectEqual(@as(u64, 3), m1.doc_id);
    try std.testing.expectEqual(@as(usize, 1), m1.positions.len);
    try std.testing.expectEqual(@as(u32, 20), m1.positions[0]);

    // Should yield doc 2 (segment)
    const m2 = (try iter.next()).?;
    try std.testing.expectEqual(@as(u64, 2), m2.doc_id);
    try std.testing.expectEqual(@as(usize, 1), m2.positions.len);
    try std.testing.expectEqual(@as(u32, 10), m2.positions[0]);

    // Doc 1 is deleted, so it should be filtered out
    try std.testing.expectEqual(@as(?TermIterator.Match, null), try iter.next());
}

test "TermIterator yields BM25 score (rare > common)" {
    // WRK-035, GAP-0005, GAP-0006: rarer terms must score higher than
    // common terms via the IDF factor of BM25. Build a 3-doc corpus where
    // "common" appears in every doc and "rare" appears in only one, flush
    // so `avg_doc_len` and per-doc norms are persisted, then compare the
    // first yielded score for each term.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try engine.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const common_t = engine.TermPosting{ .term = "common", .positions = &[_]u32{1} };
    const rare_t = engine.TermPosting{ .term = "rare", .positions = &[_]u32{2} };
    try eng.indexDocument(1, &[_]engine.TermPosting{ common_t, rare_t });
    try eng.indexDocument(2, &[_]engine.TermPosting{common_t});
    try eng.indexDocument(3, &[_]engine.TermPosting{common_t});

    // Flush so manifest.total_docs / avg_doc_len and the segment norms.bin
    // are all populated. Without flushing, total_docs is still 0 and the
    // scoring function falls through to score=0.
    try eng.flush();

    var rare_it = try TermIterator.init(alloc, eng, "rare");
    defer rare_it.deinit();
    const m_rare = (try rare_it.next()).?;

    var common_it = try TermIterator.init(alloc, eng, "common");
    defer common_it.deinit();
    const m_common = (try common_it.next()).?;

    try std.testing.expect(m_rare.score > m_common.score);
}

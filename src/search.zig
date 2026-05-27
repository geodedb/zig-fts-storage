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

/// Caller-supplied predicate that decides whether a candidate `doc_id`
/// should be yielded by a search iterator. Return `true` to authorize the
/// match; `false` to silently skip it. `ctx` is whatever opaque pointer the
/// caller passed to the iterator's `initWith*` constructor — typically a
/// session / tenant / user context.
///
/// WRK-039 (GAP-0011, SEC-EXT-0106): authorization is a post-filter applied
/// after positional + tombstone gating, not a pre-filter on the dictionary.
/// The trade-off is throughput vs simplicity — we walk the same posting
/// list either way, but the engine does not need to know how the
/// application's RLS/ABAC rules are expressed.
pub const AuthFilter = *const fn (doc_id: u64, ctx: ?*anyopaque) bool;

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

    /// Optional RLS/ABAC post-filter. When non-null, every candidate doc_id
    /// is passed through `auth_filter(doc_id, auth_ctx)` and skipped on
    /// `false`. Default null preserves the pre-WRK-039 behavior
    /// (GAP-0011, SEC-EXT-0106).
    auth_filter: ?AuthFilter = null,
    auth_ctx: ?*anyopaque = null,

    /// A single (doc_id, positions, score) match yielded by `TermIterator`.
    ///
    /// HIGHLIGHTING (GAP-0002): `positions` is the authoritative highlight
    /// contract. Each entry is the token-position (NOT the byte offset) of
    /// one occurrence of `term` inside `doc_id`. To render byte-offset
    /// highlights for display:
    ///
    /// 1. The caller already tokenized the document at index time and
    ///    supplied positions to `indexDocument`. The same tokenizer must
    ///    be available at query time.
    /// 2. Re-tokenize the original document, recording byte ranges for
    ///    each emitted token in addition to the position counter.
    /// 3. For each `pos` in `positions`, look up the byte range for the
    ///    token whose position equals `pos`.
    /// 4. Compose the snippet by slicing the original text around the
    ///    matched byte ranges, with the caller's preferred context window
    ///    (e.g. ±40 chars) and ellipsis policy.
    ///
    /// The library deliberately does NOT store byte offsets alongside
    /// positions: token-position is the unit BM25 scores against and the
    /// unit phrase queries align on, so storing both would double the
    /// segment size for a renderer concern that already has all the
    /// information it needs in the original document plus the tokenizer.
    /// Callers who don't tokenize symmetrically (e.g. they index on
    /// stemmed tokens but want to highlight surface forms) must keep
    /// their own token-position to byte-offset map outside the engine.
    pub const Match = struct {
        doc_id: u64,
        /// Token-position (not byte offset) of each occurrence of the term
        /// in the document. Sorted ascending. See the doc comment above
        /// for the highlight contract.
        positions: []const u32,
        /// BM25 relevance score for this (term, doc) match. Higher is more
        /// relevant. Computed from term frequency, document length, the
        /// engine's running `avg_doc_len`, and the iterator's captured `df`
        /// (WRK-035, GAP-0005). `0.0` is a valid score; callers should not
        /// special-case it.
        score: f32,
    };

    pub fn init(allocator: Allocator, eng: *engine.Engine, term: []const u8) !TermIterator {
        return initWithAuth(allocator, eng, term, null, null);
    }

    /// Construct a TermIterator with an optional RLS/ABAC post-filter
    /// (WRK-039, GAP-0011, SEC-EXT-0106). Identical to `init` when
    /// `auth_filter` is null.
    pub fn initWithAuth(
        allocator: Allocator,
        eng: *engine.Engine,
        term: []const u8,
        auth_filter: ?AuthFilter,
        auth_ctx: ?*anyopaque,
    ) !TermIterator {
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
            .auth_filter = auth_filter,
            .auth_ctx = auth_ctx,
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

        // Look up per-doc length via the engine-wide aggregated norms map
        // (O(1)); fall back to DEFAULT_DOC_LEN if absent (memtable doc, or
        // pre-WRK-035 segment without norms.bin). The aggregated map is
        // built at init / refreshed on flush / compact in engine.zig and
        // preserves the historical first-segment-wins semantics via
        // `getOrPutValue` (PERF — bm25 norm scan).
        const dl_u32: u32 = self.eng.all_norms.get(doc_id) orelse limits.DEFAULT_DOC_LEN;
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
                // WRK-039 (GAP-0011, SEC-EXT-0106): RLS/ABAC post-filter.
                // Applied after the tombstone check so an unauthorized but
                // already-deleted doc is treated as deleted, not as a
                // permission denial — keeps timing-side-channel surface
                // identical to the no-filter path.
                if (self.auth_filter) |filter| {
                    if (!filter(m.doc_id, self.auth_ctx)) continue;
                }
                return m;
            } else {
                return null;
            }
        }
    }
};

/// PhraseIterator yields documents in which a sequence of terms appears in
/// consecutive positions (slop = 0) or within a configurable position window
/// (slop > 0). Wraps one TermIterator per phrase term and gates on positional
/// alignment.
///
/// Complexity: O(N * M * P) where N is the matches for the leading term, M is
/// the phrase length, and P is the per-doc position-list length. This is a
/// minimum-viable implementation — production phrase search uses positional
/// skip-lists and a true k-way merge. WRK-036 (GAP-0001).
pub const PhraseIterator = struct {
    eng: *engine.Engine,
    term_iters: []TermIterator,
    slop: u32,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        eng: *engine.Engine,
        terms: []const []const u8,
        slop: u32,
    ) !PhraseIterator {
        return initWithAuth(allocator, eng, terms, slop, null, null);
    }

    /// Construct a PhraseIterator with an optional RLS/ABAC post-filter
    /// (WRK-039, GAP-0011, SEC-EXT-0106). The filter is applied to the
    /// leading term iterator only, which is the cursor whose matches drive
    /// candidate doc selection — trailing terms are re-iterated per
    /// candidate and inherit the filter via the same engine's pipeline.
    pub fn initWithAuth(
        allocator: Allocator,
        eng: *engine.Engine,
        terms: []const []const u8,
        slop: u32,
        auth_filter: ?AuthFilter,
        auth_ctx: ?*anyopaque,
    ) !PhraseIterator {
        if (terms.len == 0) return error.EmptyTerm;

        const iters = try allocator.alloc(TermIterator, terms.len);
        // Track how many iterators were successfully initialized so the
        // errdefer can tear down exactly those if a later TermIterator.init
        // fails part-way through.
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) iters[i].deinit();
            allocator.free(iters);
        }

        for (terms, 0..) |t, i| {
            // Only the leading iterator drives candidate yield order; the
            // trailing iterators are positional probes used by
            // checkPhraseAt to verify alignment. Applying the auth filter
            // only at the lead keeps a single check per candidate doc and
            // matches the post-filter semantics of TermIterator.
            if (i == 0) {
                iters[i] = try TermIterator.initWithAuth(allocator, eng, t, auth_filter, auth_ctx);
            } else {
                iters[i] = try TermIterator.init(allocator, eng, t);
            }
            initialized = i + 1;
        }

        return .{
            .eng = eng,
            .term_iters = iters,
            .slop = slop,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PhraseIterator) void {
        for (self.term_iters) |*it| it.deinit();
        self.allocator.free(self.term_iters);
    }

    pub fn next(self: *PhraseIterator) !?TermIterator.Match {
        // For each candidate doc yielded by the leading term, try to align
        // the remaining terms at consecutive positions. The trailing terms
        // are re-iterated via fresh TermIterator handles per candidate doc
        // — inefficient but correct, and acceptable for a minimum-viable
        // surface (WRK-036).
        while (try self.term_iters[0].next()) |m0| {
            for (m0.positions) |p0| {
                if (try self.checkPhraseAt(m0.doc_id, p0)) {
                    return TermIterator.Match{
                        .doc_id = m0.doc_id,
                        .positions = m0.positions,
                        .score = m0.score,
                    };
                }
            }
        }
        return null;
    }

    /// Returns true iff term i can be found at position `start + i` (exact)
    /// or within `[start + i, start + i + slop]` (slop > 0) in `doc_id`.
    fn checkPhraseAt(self: *PhraseIterator, doc_id: u64, start: u32) !bool {
        var i: usize = 1;
        while (i < self.term_iters.len) : (i += 1) {
            const want_base: u32 = start +% @as(u32, @intCast(i));
            const term = self.term_iters[i].term;

            // Fresh iterator so we don't disturb the i-th iterator's main-
            // line cursor (which the outer next() may consume later, though
            // in this minimum-viable design only iter[0]'s cursor is
            // load-bearing).
            var it = try TermIterator.init(self.allocator, self.eng, term);
            defer it.deinit();

            var found = false;
            while (try it.next()) |m| {
                if (m.doc_id != doc_id) continue;
                for (m.positions) |p| {
                    if (self.slop == 0) {
                        if (p == want_base) {
                            found = true;
                            break;
                        }
                    } else {
                        if (p >= want_base and p <= want_base + self.slop) {
                            found = true;
                            break;
                        }
                    }
                }
                // Don't keep scanning later docs once we've inspected the
                // target doc's positions — there is only one posting per
                // (term, doc_id) so a position-list scan is enough.
                break;
            }
            if (!found) return false;
        }
        return true;
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

test "AuthFilter excludes unauthorized doc_ids" {
    // WRK-039, GAP-0011, SEC-EXT-0106: caller-supplied predicate filters
    // candidate doc_ids before they are yielded by TermIterator.next().
    // Default null preserves prior behavior; non-null gates each match.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try engine.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const t = engine.TermPosting{ .term = "hello", .positions = &[_]u32{1} };
    try eng.indexDocument(1, &[_]engine.TermPosting{t});
    try eng.indexDocument(2, &[_]engine.TermPosting{t});
    try eng.indexDocument(3, &[_]engine.TermPosting{t});

    // Only authorize doc_id == 2.
    const Filter = struct {
        fn only2(doc_id: u64, ctx: ?*anyopaque) bool {
            _ = ctx;
            return doc_id == 2;
        }
    };

    var iter = try TermIterator.initWithAuth(alloc, eng, "hello", Filter.only2, null);
    defer iter.deinit();

    const m = (try iter.next()).?;
    try std.testing.expectEqual(@as(u64, 2), m.doc_id);
    try std.testing.expectEqual(@as(?TermIterator.Match, null), try iter.next());
}

test "PhraseIterator yields docs with consecutive terms" {
    // WRK-036, GAP-0001: phrase queries require positional matching. doc 1
    // contains "the quick brown fox" — "quick brown" is a phrase. doc 2
    // contains "quick", "fox", "brown" at consecutive token offsets but
    // "quick brown" is NOT adjacent there, so it must not match.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try engine.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    try eng.indexDocument(1, &[_]engine.TermPosting{
        .{ .term = "the", .positions = &[_]u32{0} },
        .{ .term = "quick", .positions = &[_]u32{1} },
        .{ .term = "brown", .positions = &[_]u32{2} },
        .{ .term = "fox", .positions = &[_]u32{3} },
    });
    try eng.indexDocument(2, &[_]engine.TermPosting{
        .{ .term = "quick", .positions = &[_]u32{0} },
        .{ .term = "fox", .positions = &[_]u32{1} },
        .{ .term = "brown", .positions = &[_]u32{2} },
    });

    var phrase = try PhraseIterator.init(alloc, eng, &[_][]const u8{ "quick", "brown" }, 0);
    defer phrase.deinit();

    const m = (try phrase.next()).?;
    try std.testing.expectEqual(@as(u64, 1), m.doc_id);
    try std.testing.expectEqual(@as(?TermIterator.Match, null), try phrase.next());
}

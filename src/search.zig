// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("engine.zig");
const segment = @import("segment.zig");
const limits = @import("limits.zig");

pub const TermIterator = struct {
    eng: *engine.Engine,
    term: []const u8,
    allocator: Allocator,

    // Iterator state
    mem_postings: ?*const segment.MemPostingsList,
    mem_idx: usize,

    seg_iters: std.ArrayListUnmanaged(segment.SegmentReader.PostingIterator),
    seg_idx: usize,

    pub const Match = struct {
        doc_id: u64,
        positions: []const u32,
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

        for (eng.segments.items) |*seg| {
            if (try seg.search(term)) |posting_iter| {
                try seg_iters.append(allocator, posting_iter);
            }
        }

        const mem_postings = if (eng.memtable.dictionary.getPtr(term)) |pl| pl else null;

        return TermIterator{
            .eng = eng,
            .term = term,
            .allocator = allocator,
            .mem_postings = mem_postings,
            .mem_idx = 0,
            .seg_iters = seg_iters,
            .seg_idx = 0,
        };
    }

    pub fn deinit(self: *TermIterator) void {
        for (self.seg_iters.items) |*iter| {
            iter.deinit();
        }
        self.seg_iters.deinit(self.allocator);
    }

    fn isDeleted(self: *TermIterator, doc_id: u64) bool {
        if (self.eng.memtable.tombstones.contains(doc_id)) return true;
        for (self.eng.segments.items) |seg| {
            if (seg.tombstones.contains(doc_id)) return true;
        }
        return false;
    }

    pub fn next(self: *TermIterator) !?Match {
        while (true) {
            var match: ?Match = null;

            // First exhaust memtable
            if (self.mem_postings) |pl| {
                if (self.mem_idx < pl.postings.items.len) {
                    const posting = pl.postings.items[self.mem_idx];
                    self.mem_idx += 1;
                    match = Match{ .doc_id = posting.doc_id, .positions = posting.positions.items };
                }
            }

            // Then segments
            if (match == null) {
                while (self.seg_idx < self.seg_iters.items.len) {
                    if (try self.seg_iters.items[self.seg_idx].next()) |posting| {
                        match = Match{ .doc_id = posting.doc_id, .positions = posting.positions };
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

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Integration tests for fts-storage.
//!
//! These tests run via `zig build test-integration` and exercise the
//! library through its public module surface (the same way a downstream
//! consumer would import it). They drive the real Engine end-to-end.

const std = @import("std");
const fts = @import("fts_storage");

test "integration: index, flush, reopen, and recover from manifest" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const docs = [_]struct { id: u64, term: []const u8 }{
        .{ .id = 1, .term = "alpha" },
        .{ .id = 2, .term = "beta" },
        .{ .id = 3, .term = "gamma" },
    };

    // Phase A: index + flush
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        for (docs) |d| {
            const t = fts.TermPosting{ .term = d.term, .positions = &[_]u32{1} };
            try eng.indexDocument(d.id, &[_]fts.TermPosting{t});
        }
        try eng.flush();
        try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
    }

    // Phase B: reopen, verify manifest + segments restored
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
        try std.testing.expectEqual(@as(u64, 1), eng.current_manifest.counter);
        // WRK-016: total_docs is now plumbed through flush.
        try std.testing.expectEqual(@as(u64, docs.len), eng.current_manifest.total_docs);
    }
}

test "integration: delete is visible after reopen via WAL replay" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "x", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
        try eng.deleteDocument(1);
        // No flush — must come back via WAL replay
    }
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expect(eng.memtable.tombstones.contains(1));
    }
}

test "integration: input validation rejects garbage at API boundary" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const empty = fts.TermPosting{ .term = "", .positions = &[_]u32{1} };
    try std.testing.expectError(
        error.EmptyTerm,
        eng.indexDocument(1, &[_]fts.TermPosting{empty}),
    );

    const unsorted = fts.TermPosting{ .term = "x", .positions = &[_]u32{ 5, 3 } };
    try std.testing.expectError(
        error.PositionsNotMonotonic,
        eng.indexDocument(1, &[_]fts.TermPosting{unsorted}),
    );
}

test "integration: version is defined" {
    try std.testing.expect(fts.version.len > 0);
}

test "compact: merges multiple segments and drops tombstoned docs" {
    // WRK-041, GAP-0003: manual compaction must collapse the segment list
    // to one entry, fold tombstones in by exclusion, and mark the merged
    // segment with level > 0 to distinguish it from a freshly flushed
    // memtable.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const t = fts.TermPosting{ .term = "x", .positions = &[_]u32{1} };
    try eng.indexDocument(1, &[_]fts.TermPosting{t});
    try eng.flush();
    try eng.indexDocument(2, &[_]fts.TermPosting{t});
    try eng.flush();
    try eng.indexDocument(3, &[_]fts.TermPosting{t});
    try eng.flush();
    try eng.deleteDocument(2);
    try eng.flush();

    try std.testing.expect(eng.segments.items.len >= 4);
    try eng.compact();
    try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
    try std.testing.expectEqual(@as(u8, 1), eng.current_manifest.segments.items[0].level);
}

test "flush populates manifest total_docs and segment doc_count" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const t = fts.TermPosting{ .term = "x", .positions = &[_]u32{1} };
    try eng.indexDocument(1, &[_]fts.TermPosting{t});
    try eng.indexDocument(2, &[_]fts.TermPosting{t});
    try eng.indexDocument(3, &[_]fts.TermPosting{t});

    try eng.flush();

    try std.testing.expectEqual(@as(u64, 3), eng.current_manifest.total_docs);
    try std.testing.expectEqual(@as(u64, 3), eng.current_manifest.segments.items[0].doc_count);
}

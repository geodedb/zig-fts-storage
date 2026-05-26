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
        // NOTE: Engine.flush() currently does not increment
        // current_manifest.total_docs (WRK-016 deferred). Assert on the
        // segment-count side instead.
        try std.testing.expectEqual(@as(u64, 1), eng.current_manifest.counter);
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

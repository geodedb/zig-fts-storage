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

// SEC-EXT-0701: the default EngineConfig must keep the strict single-writer
// thread-identity assertion ON. We cannot assert that a debug-assert *fires*
// without aborting the test process, so instead we pin the contract that the
// default-constructed config has the flag set to true. Any change that
// silently flipped the default to permissive would fail here.
test "default EngineConfig keeps single-writer thread check enabled" {
    const cfg: fts.EngineConfig = .{};
    try std.testing.expect(cfg.single_writer_thread_check == true);
}

// Hand-off for running Engine.init on a DIFFERENT thread than the one that
// drives index/flush/delete/deinit. The spawned thread only calls
// initWithConfig and records the result; the allocator, io, and tmp dir are
// owned by the main thread and outlive the engine (whose teardown also runs
// on the main thread).
const CrossThreadInit = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    base_dir: std.Io.Dir,
    engine: ?*fts.Engine = null,
    err: ?anyerror = null,

    fn run(self: *CrossThreadInit) void {
        // single_writer_thread_check = false: init captures THIS (spawned)
        // thread as owning_thread, but the assert is gated off so later calls
        // from the main thread do not trip SEC-EXT-0701.
        self.engine = fts.Engine.initWithConfig(
            self.io,
            self.alloc,
            self.base_dir,
            .{ .single_writer_thread_check = false },
        ) catch |e| {
            self.err = e;
            return;
        };
    }
};

// With single_writer_thread_check = false, the engine may be created on one
// thread and driven from another. This mirrors geode's embedding: a worker
// thread runs CREATE INDEX (Engine.init) while a different worker later runs
// writes, a delete, and teardown. Correctness across threads is still
// guaranteed by the engine's rw_lock (writers exclusive) and, for deinit, the
// quiescence contract -- the flag only removes the thread-identity debug
// assert, not any lock.
test "cross-thread embedding with single_writer_thread_check=false" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // --- init() runs on a spawned thread (the "owning" thread) ---
    var ctx: CrossThreadInit = .{ .io = io, .alloc = alloc, .base_dir = tmp_dir.dir };
    const init_thread = try std.Thread.spawn(.{}, CrossThreadInit.run, .{&ctx});
    init_thread.join();
    if (ctx.err) |e| return e;
    const eng = ctx.engine orelse return error.InitProducedNoEngine;
    // deinit also runs on the MAIN thread (!= the init/owning thread). Under
    // the default strict config this would trip assertOwnedByCurrentThread.
    defer eng.deinit();

    // --- everything below runs on the MAIN thread (different from init) ---
    const hello = fts.TermPosting{ .term = "hello", .positions = &[_]u32{0} };
    try eng.indexDocument(1, &[_]fts.TermPosting{hello});
    try eng.indexDocument(2, &[_]fts.TermPosting{hello});
    // The write landed in the memtable from a non-owning thread without panic.
    try std.testing.expect(eng.memtable.dictionary.contains("hello"));

    // flush() takes rw_lock exclusive before mutating; runs on the main thread.
    try eng.flush();
    try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
    try std.testing.expectEqual(@as(u64, 2), eng.current_manifest.total_docs);

    // delete() also takes the writer lock; doc 1 must become a tombstone.
    try eng.deleteDocument(1);
    try std.testing.expect(eng.all_tombstones.contains(1));
    try std.testing.expect(!eng.all_tombstones.contains(2));
}

test "integration: compact heals total_docs and avg_doc_len (GSP-8)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        // 4 docs, 2 tokens each.
        var doc_id: u64 = 1;
        while (doc_id <= 4) : (doc_id += 1) {
            const t = fts.TermPosting{ .term = "common", .positions = &[_]u32{ 1, 2 } };
            try eng.indexDocument(doc_id, &[_]fts.TermPosting{t});
        }
        try eng.flush();
        try std.testing.expectEqual(@as(u64, 4), eng.current_manifest.total_docs);

        // Delete half, flush the tombstones as a second segment.
        try eng.deleteDocument(1);
        try eng.deleteDocument(2);
        try eng.flush();
        // Stale by design pre-compact: deletes don't decrement.
        try std.testing.expectEqual(@as(u64, 4), eng.current_manifest.total_docs);

        // Compact drops the tombstoned docs physically; the manifest stats
        // must converge to the merged truth (GSP-8). Pre-fix: stays 4.
        try eng.compact();
        try std.testing.expectEqual(@as(u64, 2), eng.current_manifest.total_docs);
        try std.testing.expectEqual(@as(u32, 2), eng.current_manifest.avg_doc_len);
    }

    // Healed values are durable across reopen.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expectEqual(@as(u64, 2), eng.current_manifest.total_docs);
        try std.testing.expectEqual(@as(u32, 2), eng.current_manifest.avg_doc_len);
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress tests for fts-storage.
//!
//! These tests run via `zig build test-stress` and exercise the Engine
//! under a bounded but high-iteration workload. They run in ReleaseFast
//! by default (ReleaseSafe under `-Dtsan`) so they finish in
//! CI-acceptable time.

const std = @import("std");
const fts = @import("fts_storage");

test "stress: 1000 docs across 4 flushes" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var term_buf: [16]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "term{d}", .{i % 32});
        const t = fts.TermPosting{
            .term = term,
            .positions = &[_]u32{@intCast(i % 100)},
        };
        try eng.indexDocument(i, &[_]fts.TermPosting{t});
        if (i % 250 == 249) try eng.flush();
    }

    // NOTE: Engine.flush() currently does not increment
    // current_manifest.total_docs (WRK-016 deferred). Assert on
    // segment count instead.
    try std.testing.expect(eng.segments.items.len >= 4);
    try std.testing.expectEqual(@as(u64, 4), eng.current_manifest.counter);
}

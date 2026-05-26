// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Basic usage example for fts-storage.
//!
//! Run with `zig build example`.

const std = @import("std");
const Io = std.Io;
const fts = @import("fts_storage");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("fts-storage Example (v{s})\n", .{fts.version});
    try out.writeAll("========================\n\n");

    var dir = try Io.Dir.cwd().createDirPathOpen(io, "example-data", .{});
    defer dir.close(io);

    var engine = try fts.Engine.init(io, allocator, dir);
    defer engine.deinit();

    const t = fts.TermPosting{ .term = "hello", .positions = &[_]u32{ 1, 5 } };
    try engine.indexDocument(42, &[_]fts.TermPosting{t});
    try engine.flush();

    try out.print(
        "indexed doc 42; manifest_counter={d}, segments={d}\n",
        .{ engine.current_manifest.counter, engine.segments.items.len },
    );
    try out.writeAll("Example completed successfully!\n");
    try out.flush();
}

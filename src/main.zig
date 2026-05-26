// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! CLI entry point for fts-storage.
//!
//! This binary is built when `-Dno-cli=true` is *not* passed to
//! `zig build`. It links against the library module exposed by
//! `src/root.zig` and exposes a small, real command surface backed
//! by `fts.Engine` (no template stubs).
//!
//! Subcommands:
//!   - `version`           print the library version
//!   - `stats <data-dir>`  open an Engine against <data-dir> and print
//!                         manifest counter, last checkpoint LSN, total
//!                         docs, and segment count
//!   - `help`              print usage

const std = @import("std");
const Io = std.Io;
const fts = @import("fts_storage");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const err = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        try out.writeAll(usage_text);
        try out.flush();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        try out.print("fts-storage {s}\n", .{fts.version});
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        try out.writeAll(usage_text);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "stats")) {
        if (args.len < 3) {
            try err.writeAll("usage: fts-storage stats <data-dir>\n");
            try err.flush();
            return error.MissingArgument;
        }
        try statsCmd(io, allocator, args[2], out);
        try out.flush();
        return;
    }

    try err.print("unknown subcommand: {s}\n", .{cmd});
    try err.flush();
    try out.writeAll(usage_text);
    try out.flush();
    return error.UnknownSubcommand;
}

const usage_text =
    \\fts-storage — append-only inverted-index storage engine
    \\
    \\Usage:
    \\  fts-storage version
    \\  fts-storage stats <data-dir>
    \\  fts-storage help
    \\
;

fn statsCmd(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    out: *Io.Writer,
) !void {
    var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    var engine = try fts.Engine.init(io, allocator, dir);
    defer engine.deinit();

    try out.print("manifest_counter:    {d}\n", .{engine.current_manifest.counter});
    try out.print("last_checkpoint_lsn: {d}\n", .{engine.current_manifest.last_checkpoint_lsn});
    try out.print("total_docs:          {d}\n", .{engine.current_manifest.total_docs});
    try out.print("segments:            {d}\n", .{engine.segments.items.len});
}

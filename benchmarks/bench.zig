// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Default benchmark suite for fts-storage.
//!
//! Exercises the real engine surface (`Engine.init` and
//! `indexDocument`) so the framework's stats reflect actual library
//! behavior rather than a template stub.
//!
//! CLI:
//!   zig build bench                        # run default suite
//!   zig build bench -- --output bench.json # write JSON
//!   zig build bench -- --filter index      # subset
//!   zig build bench -- --list              # list scenarios

const std = @import("std");
const Io = std.Io;
const fts = @import("fts_storage");
const framework = @import("framework");

const IoBox = struct { io: std.Io };

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var io_box = IoBox{ .io = init.io };

    const scenarios = [_]framework.Scenario{
        .{
            .name = "engine_init_cycle",
            .ops_per_iteration = 16,
            .user_data = @ptrCast(&io_box),
            .run = benchEngineInit,
        },
        .{
            .name = "engine_index_document",
            .ops_per_iteration = 1_000,
            .user_data = @ptrCast(&io_box),
            .run = benchIndexDocument,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// Scenario bodies — exercise the real Engine public surface.
// ----------------------------------------------------------------------------

fn ioFromCtx(ctx: *framework.Context) std.Io {
    const box: *IoBox = @ptrCast(@alignCast(ctx.user_data.?));
    return box.io;
}

fn benchEngineInit(ctx: *framework.Context) anyerror!void {
    const io = ioFromCtx(ctx);
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp", .{});
        defer tmp_dir.close(io);
        var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
        engine.deinit();
    }
}

fn benchIndexDocument(ctx: *framework.Context) anyerror!void {
    const io = ioFromCtx(ctx);
    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp-idx", .{});
    defer tmp_dir.close(io);
    var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
    defer engine.deinit();

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const term = fts.TermPosting{ .term = "bench", .positions = &[_]u32{ 1, 2, 3 } };
        try engine.indexDocument(i, &[_]fts.TermPosting{term});
    }
}

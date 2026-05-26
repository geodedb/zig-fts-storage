// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Scale benchmark suite for fts-storage.
//!
//! These scenarios run for longer than the default `bench` suite —
//! useful for ad-hoc grid sweeps or scheduled CI runs. Wired via
//! `zig build scale-bench` and gated to schedule/manual in the default
//! `.gitlab-ci.yml`.

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
            .name = "engine_index_x100k",
            .ops_per_iteration = 100_000,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .user_data = @ptrCast(&io_box),
            .run = runIndexLarge,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "scale-bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn ioFromCtx(ctx: *framework.Context) std.Io {
    const box: *IoBox = @ptrCast(@alignCast(ctx.user_data.?));
    return box.io;
}

fn runIndexLarge(ctx: *framework.Context) anyerror!void {
    const io = ioFromCtx(ctx);
    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".scale-tmp", .{});
    defer tmp_dir.close(io);
    var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
    defer engine.deinit();

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const term = fts.TermPosting{ .term = "scale", .positions = &[_]u32{ 1, 2 } };
        try engine.indexDocument(i, &[_]fts.TermPosting{term});
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Example micro-benchmark for fts-storage.
//!
//! Micro-benchmarks isolate a single function so regressions in one
//! corner of the library don't get hidden inside a broader workload.
//! Wired via `zig build bench-micro-example` (see build.zig). Copy
//! this file as a starting point for additional micro-benchmarks.

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
            .name = "engine_init_x32",
            .ops_per_iteration = 32,
            .warmup_iterations = 2,
            .sample_iterations = 6,
            .user_data = @ptrCast(&io_box),
            .run = run,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-example"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn ioFromCtx(ctx: *framework.Context) std.Io {
    const box: *IoBox = @ptrCast(@alignCast(ctx.user_data.?));
    return box.io;
}

fn run(ctx: *framework.Context) anyerror!void {
    const io = ioFromCtx(ctx);
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".micro-tmp", .{});
        defer tmp_dir.close(io);
        var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
        engine.deinit();
    }
}

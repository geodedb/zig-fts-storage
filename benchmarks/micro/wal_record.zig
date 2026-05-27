// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! WAL record serialization micro-benchmark.
//!
//! Measures WalRecord.serializeInto with scratch-buffer reuse: the
//! per-iteration cost should converge to zero allocations after the
//! scratch buffer pre-grows to the record size (warmup absorbs the
//! initial growth).
//!
//! CLI:
//!   zig build bench-micro-wal-record
//!   zig build bench-micro-wal-record -- --output wr.json
//!
//! Hot path ref:
//!   * src/wal.zig:59-77       WalRecord.serializeInto

const std = @import("std");
const Io = std.Io;
const fts = @import("fts_storage");
const framework = @import("framework");

const PAYLOAD = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

const WalCtx = struct {
    scratch: std.ArrayListUnmanaged(u8),
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Pre-grow the scratch buffer outside the timed region so the first
    // sampled iteration does not allocate.
    var ctx_data = WalCtx{ .scratch = .empty };
    try ctx_data.scratch.ensureTotalCapacity(allocator, 64);

    const scenarios = [_]framework.Scenario{
        .{
            .name = "wal_record_serialize_into",
            .ops_per_iteration = 100_000,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .user_data = @ptrCast(&ctx_data),
            .run = runSerializeInto,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-wal-record"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn runSerializeInto(ctx: *framework.Context) anyerror!void {
    const data: *WalCtx = @ptrCast(@alignCast(ctx.user_data.?));
    const record = fts.wal.WalRecord{
        .record_type = .index_doc,
        .txn_id = 1,
        .doc_id = 42,
        .payload = &PAYLOAD,
    };
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        data.scratch.clearRetainingCapacity();
        try record.serializeInto(ctx.allocator, &data.scratch);
        std.mem.doNotOptimizeAway(data.scratch.items[0]);
    }
}

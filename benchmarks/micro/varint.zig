// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Varint LEB128 micro-benchmarks.
//!
//! Isolates `utils.readVarInt` and `utils.writeVarInt` — the innermost
//! decode/encode loop on every indexing, replay, and segment-scan path.
//! Four scenarios cover the 1-byte best case and the 10-byte
//! overflow-guard worst case for both directions.
//!
//! CLI:
//!   zig build bench-micro-varint                     # run suite
//!   zig build bench-micro-varint -- --output v.json  # write JSON
//!   zig build bench-micro-varint -- --list           # list scenarios
//!
//! Hot path refs:
//!   * src/utils.zig:83-102   readVarInt
//!   * src/utils.zig:109-127  writeVarInt

const std = @import("std");
const Io = std.Io;
const framework = @import("framework");
const utils = @import("fts_storage").utils;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // ops_per_iteration is large because each varint call is sub-nanosecond;
    // 100k ops keep timer granularity (Io.Clock resolution) negligible against
    // the per-iteration wall time.
    const scenarios = [_]framework.Scenario{
        .{
            .name = "varint_encode_1byte",
            .ops_per_iteration = 100_000,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .run = runEncode1Byte,
        },
        .{
            .name = "varint_encode_10byte",
            .ops_per_iteration = 100_000,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .run = runEncode10Byte,
        },
        .{
            .name = "varint_decode_1byte",
            .ops_per_iteration = 100_000,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .run = runDecode1Byte,
        },
        .{
            .name = "varint_decode_10byte",
            .ops_per_iteration = 100_000,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .run = runDecode10Byte,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-varint"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

fn runEncode1Byte(ctx: *framework.Context) anyerror!void {
    var buf: [10]u8 = undefined;
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const n = try utils.writeVarInt(&buf, 42);
        std.mem.doNotOptimizeAway(n);
        std.mem.doNotOptimizeAway(buf[0]);
    }
}

fn runEncode10Byte(ctx: *framework.Context) anyerror!void {
    var buf: [10]u8 = undefined;
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const n = try utils.writeVarInt(&buf, std.math.maxInt(u64));
        std.mem.doNotOptimizeAway(n);
        std.mem.doNotOptimizeAway(buf[n - 1]);
    }
}

fn runDecode1Byte(ctx: *framework.Context) anyerror!void {
    var enc_buf: [10]u8 = undefined;
    const enc_len = try utils.writeVarInt(&enc_buf, 42);
    const data = enc_buf[0..enc_len];
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const r = try utils.readVarInt(data);
        std.mem.doNotOptimizeAway(r.val);
        std.mem.doNotOptimizeAway(r.bytes_read);
    }
}

fn runDecode10Byte(ctx: *framework.Context) anyerror!void {
    var enc_buf: [10]u8 = undefined;
    const enc_len = try utils.writeVarInt(&enc_buf, std.math.maxInt(u64));
    const data = enc_buf[0..enc_len];
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const r = try utils.readVarInt(data);
        std.mem.doNotOptimizeAway(r.val);
        std.mem.doNotOptimizeAway(r.bytes_read);
    }
}

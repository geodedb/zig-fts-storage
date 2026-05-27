// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! BM25 scoring micro-benchmarks.
//!
//! Two scenarios:
//!   * bm25_score_single: isolated arithmetic with fixed inputs.
//!     Establishes per-call ns baseline for the IDF + tf-norm formula.
//!   * bm25_score_norm_scan_16seg: simulates the per-segment norm
//!     lookup loop at search.zig:205-214 (O(segments) linear scan).
//!     Worst-case doc lives in the LAST of 16 norm maps.
//!
//! CLI:
//!   zig build bench-micro-bm25
//!   zig build bench-micro-bm25 -- --output bm.json
//!
//! Hot path refs:
//!   * src/search.zig:187-222  computeScore (BM25 formula)
//!   * src/search.zig:205-214  norm-table linear scan

const std = @import("std");
const Io = std.Io;
const framework = @import("framework");

const BM25_K1: f32 = 1.2;
const BM25_B: f32 = 0.75;

const NormMap = std.AutoHashMapUnmanaged(u64, u32);
const NORM_SEGMENTS = 16;
const NORM_ENTRIES_PER_SEG = 1000;
const TARGET_DOC_ID: u64 = 999_999; // present only in the LAST segment.

const BM25Ctx = struct {
    /// Pre-populated norm tables. Doc TARGET_DOC_ID lives in maps[15] only.
    maps: [NORM_SEGMENTS]NormMap,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Pre-populate norm tables. Use a fixed allocator that outlives the
    // scenarios (the arena above). Allocations here happen BEFORE
    // runScenarios is called, so they do not show up in alloc_count.
    var ctx_data = BM25Ctx{ .maps = undefined };
    for (&ctx_data.maps, 0..) |*m, seg_idx| {
        m.* = .{};
        var prng = std.Random.DefaultPrng.init(0xdeadbeef_cafef00d +% seg_idx);
        var i: u32 = 0;
        while (i < NORM_ENTRIES_PER_SEG) : (i += 1) {
            const doc_id: u64 = @as(u64, seg_idx) * NORM_ENTRIES_PER_SEG + i;
            const dl: u32 = 50 + prng.random().intRangeAtMost(u32, 0, 100);
            try m.put(allocator, doc_id, dl);
        }
    }
    // Plant TARGET_DOC_ID in the LAST segment only.
    try ctx_data.maps[NORM_SEGMENTS - 1].put(allocator, TARGET_DOC_ID, 75);

    const scenarios = [_]framework.Scenario{
        .{
            .name = "bm25_score_single",
            .ops_per_iteration = 1_000_000,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .run = runScoreSingle,
        },
        .{
            .name = "bm25_score_norm_scan_16seg",
            .ops_per_iteration = 100_000,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .user_data = @ptrCast(&ctx_data),
            .run = runNormScan16Seg,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro-bm25"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

inline fn bm25(tf: u32, df: u32, N: u32, dl: u32, avg_dl: u32) f32 {
    const N_f: f32 = @floatFromInt(N);
    const df_f: f32 = @floatFromInt(df);
    const idf_arg: f32 = (N_f - df_f + 0.5) / (df_f + 0.5) + 1.0;
    const idf: f32 = std.math.log(f32, std.math.e, idf_arg);
    const tf_f: f32 = @floatFromInt(tf);
    const dl_f: f32 = @floatFromInt(dl);
    const avg_dl_f: f32 = @floatFromInt(avg_dl);
    const tf_norm = tf_f * (BM25_K1 + 1.0) /
        (tf_f + BM25_K1 * (1.0 - BM25_B + BM25_B * dl_f / avg_dl_f));
    return idf * tf_norm;
}

fn runScoreSingle(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const s = bm25(3, 100, 10_000, 50, 50);
        std.mem.doNotOptimizeAway(s);
    }
}

fn runNormScan16Seg(ctx: *framework.Context) anyerror!void {
    const data: *BM25Ctx = @ptrCast(@alignCast(ctx.user_data.?));
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        // Linear scan across all 16 segments, exactly like search.zig:205-214.
        var dl_u32: u32 = 100; // DEFAULT_DOC_LEN fallback.
        for (&data.maps) |*m| {
            if (m.get(TARGET_DOC_ID)) |n| {
                dl_u32 = n;
                break;
            }
        }
        const s = bm25(3, 100, 10_000, dl_u32, 50);
        std.mem.doNotOptimizeAway(dl_u32);
        std.mem.doNotOptimizeAway(s);
    }
}

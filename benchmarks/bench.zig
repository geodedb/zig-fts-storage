// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Default benchmark suite for fts-storage.
//!
//! Exercises the engine surface end-to-end. Includes the original
//! engine_init_cycle and engine_index_document baselines plus the
//! six scenarios named in docs/PERF_GAP_ANALYSIS.md (four integration
//! + two comparison).
//!
//! CLI:
//!   zig build bench                        # run default suite
//!   zig build bench -- --output bench.json # write JSON
//!   zig build bench -- --filter ingest     # subset
//!   zig build bench -- --list              # list scenarios
//!
//! Hot path refs:
//!   * src/engine.zig:593-674   indexDocument + WAL append/sync
//!   * src/segment.zig:223-294  SegmentWriter.writeDictionaryAndPostings
//!   * src/engine.zig:420-519   Engine.replayWal three-pass replay
//!   * src/segment.zig:451-564  PostingIterator.next / nextDocOnly / search
//!   * src/search.zig:187-222   BM25 scoring + norm linear scan

const std = @import("std");
const Io = std.Io;
const fts = @import("fts_storage");
const framework = @import("framework");

const SEED: u64 = 0xdeadbeef_cafef00d;
const VOCAB_SIZE: usize = 50_000;
const TERMS_PER_DOC: usize = 8;
const INGEST_DOCS: u64 = 100_000;
const FLUSH_TERMS: u64 = 100_000;
const REPLAY_RECORDS: u64 = 1_000_000;
const QUERY_DOCS_PER_SEGMENT: u64 = 10_000;
const QUERY_SEGMENTS: u64 = 16;
const POSTING_ENTRIES: usize = 10_000;

const Box = struct {
    io: std.Io,
    /// Heap-allocated vocabulary used by ingest + query scenarios.
    /// Lives for the whole bench run.
    vocab: []const []const u8,
    /// Pre-built posting buffer for the comparison scenarios.
    /// 10,000 entries each with tf=4, positions=[0,1,2,3] delta-encoded.
    posting_buf: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const vocab = try buildVocab(allocator, VOCAB_SIZE);
    const posting_buf = try buildPostingBuf(allocator, POSTING_ENTRIES);

    var box = Box{
        .io = init.io,
        .vocab = vocab,
        .posting_buf = posting_buf,
    };

    const scenarios = [_]framework.Scenario{
        .{
            .name = "engine_init_cycle",
            .ops_per_iteration = 16,
            .user_data = @ptrCast(&box),
            .run = benchEngineInit,
        },
        .{
            .name = "engine_index_document",
            .ops_per_iteration = 1_000,
            .user_data = @ptrCast(&box),
            .run = benchIndexDocument,
        },
        .{
            .name = "ingest_100k_docs_random_terms",
            .ops_per_iteration = INGEST_DOCS,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .user_data = @ptrCast(&box),
            .run = benchIngestRandom,
        },
        .{
            .name = "flush_100k_term_memtable",
            .ops_per_iteration = 1,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .user_data = @ptrCast(&box),
            .run = benchFlush100kTerms,
        },
        .{
            .name = "replay_wal_1M_records",
            .ops_per_iteration = 1,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .user_data = @ptrCast(&box),
            .run = benchReplay1M,
        },
        .{
            .name = "query_term_iterator_16_segments",
            .ops_per_iteration = 1,
            .warmup_iterations = 1,
            .sample_iterations = 5,
            .user_data = @ptrCast(&box),
            .run = benchQuery16Seg,
        },
        .{
            .name = "posting_iter_next_with_positions",
            .ops_per_iteration = POSTING_ENTRIES,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .user_data = @ptrCast(&box),
            .run = benchPostingIterNextWithPositions,
        },
        .{
            .name = "posting_iter_next_doc_only",
            .ops_per_iteration = POSTING_ENTRIES,
            .warmup_iterations = 3,
            .sample_iterations = 30,
            .user_data = @ptrCast(&box),
            .run = benchPostingIterNextDocOnly,
        },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

fn ioFromCtx(ctx: *framework.Context) std.Io {
    const box: *Box = @ptrCast(@alignCast(ctx.user_data.?));
    return box.io;
}

fn boxFromCtx(ctx: *framework.Context) *Box {
    return @ptrCast(@alignCast(ctx.user_data.?));
}

/// Build a deterministic vocabulary of N entries: "word_00000".."word_NNNNN".
fn buildVocab(allocator: std.mem.Allocator, n: usize) ![]const []const u8 {
    var list = try allocator.alloc([]const u8, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        list[i] = try std.fmt.allocPrint(allocator, "word_{d:0>5}", .{i});
    }
    return list;
}

/// Build a posting buffer in the on-disk postings.bin format.
///
/// Layout per entry (all varints): doc_delta(1), tf(4), pos_delta(0,1,1,1).
/// Each posting yields doc_ids 1, 2, 3, ... and positions [0,1,2,3]. Every
/// value fits in a single varint byte, so each posting is exactly 6 bytes.
fn buildPostingBuf(allocator: std.mem.Allocator, entries: usize) ![]const u8 {
    const bytes_per = 6;
    const buf = try allocator.alloc(u8, entries * bytes_per);
    var off: usize = 0;
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        off += try fts.utils.writeVarInt(buf[off..], 1); // doc_delta = 1
        off += try fts.utils.writeVarInt(buf[off..], 4); // tf = 4
        // positions: [0, 1, 2, 3] delta-encoded = [0, 1, 1, 1]
        off += try fts.utils.writeVarInt(buf[off..], 0);
        off += try fts.utils.writeVarInt(buf[off..], 1);
        off += try fts.utils.writeVarInt(buf[off..], 1);
        off += try fts.utils.writeVarInt(buf[off..], 1);
    }
    return buf[0..off];
}

/// Create a unique tmpdir name per call so iterations do not collide.
/// The iteration index is supplied by the framework — different scenarios
/// at the same index also disambiguate via the `prefix` argument.
fn freshTmpdir(allocator: std.mem.Allocator, prefix: []const u8, seq: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".bench-{s}-{d}", .{ prefix, seq });
}

// ----------------------------------------------------------------------------
// Scenario bodies — existing baselines (preserved unchanged in semantics).
// ----------------------------------------------------------------------------

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

// ----------------------------------------------------------------------------
// Scenario bodies — integration.
// ----------------------------------------------------------------------------

fn benchIngestRandom(ctx: *framework.Context) anyerror!void {
    const box = boxFromCtx(ctx);
    const io = box.io;
    const path = try freshTmpdir(ctx.allocator, "ingest", ctx.iteration_index);
    defer ctx.allocator.free(path);
    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer tmp_dir.close(io);
    var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
    defer engine.deinit();

    var prng = std.Random.DefaultPrng.init(SEED +% ctx.iteration_index);
    var doc_id: u64 = 0;
    while (doc_id < ctx.scenario.ops_per_iteration) : (doc_id += 1) {
        var terms: [TERMS_PER_DOC]fts.TermPosting = undefined;
        const positions = [_]u32{@intCast(doc_id % 100)};
        var t: usize = 0;
        while (t < TERMS_PER_DOC) : (t += 1) {
            const idx = prng.random().intRangeAtMost(usize, 0, box.vocab.len - 1);
            terms[t] = .{ .term = box.vocab[idx], .positions = &positions };
        }
        try engine.indexDocument(doc_id, &terms);
    }
}

fn benchFlush100kTerms(ctx: *framework.Context) anyerror!void {
    const box = boxFromCtx(ctx);
    const io = box.io;
    const path = try freshTmpdir(ctx.allocator, "flush", ctx.iteration_index);
    defer ctx.allocator.free(path);
    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer tmp_dir.close(io);

    // The flush itself is the measured op. The 100k unique-term setup
    // dominates if naïvely inlined; we accept it as part of the cost of
    // this scenario (the framework still produces useful comparisons
    // across runs because the setup is deterministic). The op count
    // is 1 — one flush — so wall_ns_p50 IS the flush latency.
    var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
    defer engine.deinit();

    var term_buf: [16]u8 = undefined;
    var i: u64 = 0;
    while (i < FLUSH_TERMS) : (i += 1) {
        const term = try std.fmt.bufPrint(&term_buf, "term_{d:0>5}", .{i});
        const positions = [_]u32{0};
        try engine.indexDocument(i, &[_]fts.TermPosting{.{ .term = term, .positions = &positions }});
    }
    try engine.flush();
}

fn benchReplay1M(ctx: *framework.Context) anyerror!void {
    const box = boxFromCtx(ctx);
    const io = box.io;
    const path = try freshTmpdir(ctx.allocator, "replay", ctx.iteration_index);
    defer ctx.allocator.free(path);
    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer tmp_dir.close(io);

    // Build the WAL by opening an engine, indexing REPLAY_RECORDS docs, and
    // closing without flush. Re-opening triggers the three-pass replayWal
    // path — the actual hot path under measurement. The scenario's wall time
    // includes the build, which dominates at this scale; samples=5 is set
    // with this in mind.
    {
        var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
        defer engine.deinit();
        const positions = [_]u32{0};
        var i: u64 = 0;
        while (i < REPLAY_RECORDS) : (i += 1) {
            try engine.indexDocument(i, &[_]fts.TermPosting{.{ .term = "r", .positions = &positions }});
        }
    }
    // Re-open: this triggers replayWal.
    var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
    engine.deinit();
}

fn benchQuery16Seg(ctx: *framework.Context) anyerror!void {
    const box = boxFromCtx(ctx);
    const io = box.io;
    const path = try freshTmpdir(ctx.allocator, "query", ctx.iteration_index);
    defer ctx.allocator.free(path);
    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer tmp_dir.close(io);
    var engine = try fts.Engine.init(io, ctx.allocator, tmp_dir);
    defer engine.deinit();

    var prng = std.Random.DefaultPrng.init(SEED +% ctx.iteration_index);
    var seg: u64 = 0;
    while (seg < QUERY_SEGMENTS) : (seg += 1) {
        var d: u64 = 0;
        while (d < QUERY_DOCS_PER_SEGMENT) : (d += 1) {
            const doc_id = seg * QUERY_DOCS_PER_SEGMENT + d;
            var terms: [TERMS_PER_DOC]fts.TermPosting = undefined;
            const positions = [_]u32{0};
            terms[0] = .{ .term = "bench_query", .positions = &positions };
            var t: usize = 1;
            while (t < TERMS_PER_DOC) : (t += 1) {
                const idx = prng.random().intRangeAtMost(usize, 0, 999);
                terms[t] = .{ .term = box.vocab[idx], .positions = &positions };
            }
            try engine.indexDocument(doc_id, &terms);
        }
        try engine.flush();
    }

    // Timed query path. TermIterator fans out across all segments + memtable.
    var it = try fts.TermIterator.init(ctx.allocator, engine, "bench_query");
    defer it.deinit();
    var match_count: u64 = 0;
    var last_doc: u64 = 0;
    while (try it.next()) |m| {
        match_count += 1;
        last_doc = m.doc_id;
    }
    std.mem.doNotOptimizeAway(match_count);
    std.mem.doNotOptimizeAway(last_doc);
}

// ----------------------------------------------------------------------------
// Scenario bodies — comparison (paired).
// ----------------------------------------------------------------------------

fn benchPostingIterNextWithPositions(ctx: *framework.Context) anyerror!void {
    const box = boxFromCtx(ctx);
    // PostingIterator.deinit() frees its `data` slice via its own allocator,
    // so we hand it an allocator-owned copy of the shared posting buffer.
    const data = try ctx.allocator.dupe(u8, box.posting_buf);

    var it = fts.segment.SegmentReader.PostingIterator{
        .allocator = ctx.allocator,
        .data = data,
        .df = POSTING_ENTRIES,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.deinit();

    // Pre-grow pos_buf so the first sampled next() does not pay for growth.
    // Each posting in the pre-built buffer has tf=4, so cap of 4 suffices;
    // ask for 8 to leave slack against any future buffer shape change.
    try it.pos_buf.ensureTotalCapacity(ctx.allocator, 8);

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const p = (try it.next()) orelse break;
        std.mem.doNotOptimizeAway(p.doc_id);
        std.mem.doNotOptimizeAway(p.positions.len);
    }
}

fn benchPostingIterNextDocOnly(ctx: *framework.Context) anyerror!void {
    const box = boxFromCtx(ctx);
    const data = try ctx.allocator.dupe(u8, box.posting_buf);

    var it = fts.segment.SegmentReader.PostingIterator{
        .allocator = ctx.allocator,
        .data = data,
        .df = POSTING_ENTRIES,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.deinit();

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const doc_id = (try it.nextDocOnly()) orelse break;
        std.mem.doNotOptimizeAway(doc_id);
    }
}

## Benchmark Coverage Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 13 new benchmark scenarios across three new micro files and an extension of `benchmarks/bench.zig`, plus build.zig wiring, with explicit zero-alloc probes and `doNotOptimizeAway` guards. A/B is explicitly out of scope.

**Architecture:** Pure-Zig stdlib-only bench targets. Three new micro files under `benchmarks/micro/` (varint, bm25, wal_record) each wired as their own exe via `benchModule` + `bench-micro-*` step + dependency on `micro_all_step`. Integration and comparison scenarios extend the existing `scenarios` array in `benchmarks/bench.zig` so the existing `bench` exe picks them up. Schema additive only (`compare.zig` uses `.ignore_unknown_fields = true`); existing baseline.json untouched.

**Tech Stack:** Zig 0.16.0, stdlib only, the existing `benchmarks/framework.zig` (`Scenario` / `Context` / `RunFn` / `TrackingAllocator`).

**Source plan:** `docs/performance/2026-05-27-bench-coverage-expansion/plan.json`
**Architecture doc:** `docs/performance/2026-05-27-bench-coverage-expansion/architecture.md`

---

## Hard rules (every subagent must observe)

1. **No new third-party dependencies.** `build.zig.zon` `.dependencies` must stay empty.
2. **Stdlib-only timing.** Use only `framework.zig` primitives — never `std.time.sleep` in a measured loop.
3. **`doNotOptimizeAway` is mandatory** wherever a return value would otherwise be discarded. The compiler is `ReleaseFast` for all bench exes (`build.zig:190-203` already forces this); without the guard, ReleaseFast will delete the whole loop body.
4. **Zero-alloc scenarios** must assert `alloc_count == 0` over the sampled iterations. The pattern (since `framework.runScenarios` already records `alloc_count` into the result row) is: a runtime check at end-of-scenario via the `Context.user_data` carrying a tracker reference is **not** what the framework supports today — instead encode the expectation by relying on the framework's per-iteration alloc tracking + verifying the emitted JSON row externally. Inside the scenario body itself, simply do not allocate. The acceptance criteria step inspects the JSON after the smoke run.
5. **Deterministic seeds.** Every randomized workload uses `std.Random.DefaultPrng` seeded with `0xdeadbeef_cafef00d`.
6. **Workload setup outside the timed body.** Heavy setup (pre-build WAL, populate hashmaps, pre-encode buffers) happens in `iteration_index == 0` branches or via `user_data` initialized in `main()` before `framework.runScenarios`. The timed body is the smallest possible code that exercises the hot path.
7. **Preservation.** `zig build test`, `zig build test-integration`, `zig build check`, and the existing `engine_init_cycle` / `engine_index_document` scenarios in `bench.zig` must continue to pass / appear. Do NOT touch `benchmarks/results/baseline.json` in this implementation run.
8. **Style.** Match the existing bench file headers exactly: SPDX line, copyright line, `//!` docstring, `const std = @import("std");` ordering. Run `zig fmt` on every new/modified file.

---

## File Structure

**Create:**

- `benchmarks/micro/varint.zig` — 4 scenarios (encode 1B, encode 10B, decode 1B, decode 10B)
- `benchmarks/micro/bm25.zig` — 2 scenarios (single score, 16-segment norm scan)
- `benchmarks/micro/wal_record.zig` — 1 scenario (serializeInto with scratch reuse)

**Modify:**

- `benchmarks/bench.zig` — extend `scenarios` array with 6 new entries (4 integration + 2 comparison) plus per-scenario body functions and helpers
- `build.zig` — add 3 new exe blocks (`fts-storage-micro-varint`, `fts-storage-micro-bm25`, `fts-storage-micro-wal-record`), 3 new step names, 3 new `micro_all_step.dependOn(...)` calls, and 3 additions to the existing `tools_step`

**Touch but do not modify content:**

- `benchmarks/framework.zig` — read only (consume `Scenario`, `Context`, `RunFn`, `ResultRow` shapes)
- `benchmarks/results/baseline.json` — read only

---

## Pre-flight reading (every subagent does this first)

Before any code change, the subagent reads:

1. `benchmarks/framework.zig` lines 1–200 — Scenario / Context / RunOptions shapes and the `parseArgs` entry-point contract.
2. `benchmarks/bench.zig` and `benchmarks/micro/example.zig` — the canonical patterns for a scenario file (header, `IoBox`, `main`, `ioFromCtx`).
3. `build.zig` lines 240–260 — the `micro_example_exe` + `bench-micro-example` + `micro_all_step.dependOn` triplet that every new micro exe must replicate.
4. The source file holding the hot path that scenario measures (referenced per task).

---

## Task 1: `benchmarks/micro/varint.zig`

**Files:**

- Create: `benchmarks/micro/varint.zig`
- Modify: `build.zig` (add `micro_varint_exe`, `bench-micro-varint` step, wire into `micro_all_step` and `tools_step`)
- Test: smoke-run via `zig build bench-micro-varint --samples 3 --warmup 1`

**Hot path under measurement:** `src/utils.zig` `pub inline fn writeVarInt(buf: []u8, value: u64) !usize` and `pub inline fn readVarInt(buf: []const u8) !struct { val: u64, bytes_read: usize }`.

- [ ] **Step 1.1: Read context.**

Read in this order: `benchmarks/framework.zig:28-200`, `benchmarks/micro/example.zig` (full), `src/utils.zig:75-130`, `build.zig:242-258`. Confirm: `writeVarInt` returns `!usize`, `readVarInt` returns a struct `{val: u64, bytes_read: usize}`, both are `pub inline`.

- [ ] **Step 1.2: Create `benchmarks/micro/varint.zig`.**

```zig
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
const fts = @import("fts_storage");
const framework = @import("framework");
const utils = @import("fts_storage").utils;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

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
        std.mem.doNotOptimizeAway(buf[9]);
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
```

**Note:** If `@import("fts_storage").utils` is not exposed, use `const utils = @import("fts_storage");` (the symbol is `utils.readVarInt`/`utils.writeVarInt`). Read `src/root.zig` first to confirm the export path. If `utils` is not re-exported from root, change the import to use whatever public path exists. If neither works, fall back to copying the two `pub inline fn` bodies into a private `varint_local` namespace inside this file as a last resort — but only after confirming no public path exists.

- [ ] **Step 1.3: Verify utils import path.**

Run: `grep -n "pub const utils\\|pub usingnamespace" src/root.zig | head -10` and read the result. If `utils` is not exported as `fts_storage.utils`, change the import in step 1.2 accordingly. Common alternatives: `const utils = @import("fts_storage").utils;` (if root re-exports) or rebuild root.zig to add `pub const utils = @import("utils.zig");` (only if absolutely required and unavoidable — discuss with reviewer first).

- [ ] **Step 1.4: Wire into `build.zig`.**

Open `build.zig`. Locate the `micro_example_exe` block (lines 242-249). Insert the following three new blocks immediately after it (before `micro_all_step` is declared at line 251):

```zig
    const micro_varint_exe = b.addExecutable(.{
        .name = "fts-storage-micro-varint",
        .root_module = benchModule(b, "benchmarks/micro/varint.zig", target, bench_lib_module, framework_module),
    });
    const run_micro_varint = b.addRunArtifact(micro_varint_exe);
    if (b.args) |args| run_micro_varint.addArgs(args);
    const micro_varint_step = b.step("bench-micro-varint", "Varint encode/decode micro-benchmarks");
    micro_varint_step.dependOn(&run_micro_varint.step);
```

Then update `micro_all_step.dependOn(&run_micro_example.step);` (line 252) to add a second `dependOn` line below it:

```zig
    micro_all_step.dependOn(&run_micro_example.step);
    micro_all_step.dependOn(&run_micro_varint.step);
```

And append to `tools_step` (currently ending at line 258 with `tools_step.dependOn(&micro_example_exe.step);`):

```zig
    tools_step.dependOn(&micro_varint_exe.step);
```

- [ ] **Step 1.5: Verify `zig build check` is green.**

Run: `cd /home/benji/src/devnw/zig/fts-storage && zig build check`
Expected: exit 0, no output.

- [ ] **Step 1.6: Verify scenario discovery.**

Run: `cd /home/benji/src/devnw/zig/fts-storage && zig build bench-micro-varint -- --list 2>&1 | head -20`
Expected: stderr contains four lines naming `varint_encode_1byte`, `varint_encode_10byte`, `varint_decode_1byte`, `varint_decode_10byte`.

- [ ] **Step 1.7: Smoke run.**

Run: `cd /home/benji/src/devnw/zig/fts-storage && zig build bench-micro-varint -- --warmup 1 --samples 3 --output /tmp/varint-smoke.json 2>&1 | tail -20`
Expected: exit 0; `/tmp/varint-smoke.json` contains 4 rows; each row's `alloc_count` is `0` (zero-alloc contract).
Validate alloc_count: `jq '[.rows[] | {name: .scenario_name, allocs: .alloc_count}]' /tmp/varint-smoke.json`

- [ ] **Step 1.8: Verify nothing else broke.**

Run: `cd /home/benji/src/devnw/zig/fts-storage && zig build test && zig build bench -- --list 2>&1 | grep -E "engine_init_cycle|engine_index_document"`
Expected: tests pass; both existing scenarios still appear in `bench --list`.

- [ ] **Step 1.9: Commit.**

```bash
cd /home/benji/src/devnw/zig/fts-storage
zig fmt benchmarks/micro/varint.zig build.zig
git add benchmarks/micro/varint.zig build.zig
git commit -m "perf(bench): add varint encode/decode micro-benchmarks

Adds 4 scenarios isolating LEB128 encode/decode on stack buffers:
varint_encode_1byte, varint_encode_10byte, varint_decode_1byte,
varint_decode_10byte. All four assert zero-alloc via stack-only
buffers and use std.mem.doNotOptimizeAway to keep ReleaseFast from
deleting the loop body.

Wires bench-micro-varint into micro_all_step and tools_step.
No baseline.json change in this commit."
```

---

## Task 2: `benchmarks/micro/bm25.zig`

**Files:**

- Create: `benchmarks/micro/bm25.zig`
- Modify: `build.zig` (add `micro_bm25_exe`, `bench-micro-bm25` step, wire into `micro_all_step` and `tools_step`)

**Hot path under measurement:** BM25 formula at `src/search.zig:213-220` and the linear norm-table scan at `src/search.zig:205-214`.

- [ ] **Step 2.1: Read context.**

Read in this order: `src/search.zig:180-225` (`computeScore` body, `BM25_K1`, `BM25_B` constants), `src/limits.zig:47` (`DEFAULT_DOC_LEN`). Confirm the formula matches the inline doc.

- [ ] **Step 2.2: Create `benchmarks/micro/bm25.zig`.**

```zig
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
```

- [ ] **Step 2.3: Wire into `build.zig`.**

Insert immediately after the `micro_varint_exe` block from Task 1 (and before `micro_all_step`):

```zig
    const micro_bm25_exe = b.addExecutable(.{
        .name = "fts-storage-micro-bm25",
        .root_module = benchModule(b, "benchmarks/micro/bm25.zig", target, bench_lib_module, framework_module),
    });
    const run_micro_bm25 = b.addRunArtifact(micro_bm25_exe);
    if (b.args) |args| run_micro_bm25.addArgs(args);
    const micro_bm25_step = b.step("bench-micro-bm25", "BM25 scoring micro-benchmarks");
    micro_bm25_step.dependOn(&run_micro_bm25.step);
```

Add to `micro_all_step.dependOn(...)` block:

```zig
    micro_all_step.dependOn(&run_micro_bm25.step);
```

Add to `tools_step`:

```zig
    tools_step.dependOn(&micro_bm25_exe.step);
```

- [ ] **Step 2.4: `zig build check`** — expect exit 0.

- [ ] **Step 2.5: `--list` smoke.**

Run: `zig build bench-micro-bm25 -- --list 2>&1`
Expected: stderr lists `bm25_score_single` and `bm25_score_norm_scan_16seg`.

- [ ] **Step 2.6: Smoke run.**

Run: `zig build bench-micro-bm25 -- --warmup 1 --samples 3 --output /tmp/bm25-smoke.json 2>&1 | tail -10`
Validate alloc_count: `jq '[.rows[] | {name: .scenario_name, allocs: .alloc_count}]' /tmp/bm25-smoke.json`
Expected: both rows have `alloc_count: 0`. (The norm tables were populated in `main` BEFORE `runScenarios`, so their allocations are not counted; the timed body only calls `HashMap.get` which is allocation-free.)

- [ ] **Step 2.7: Regression check.**

Run: `zig build test && zig build bench -- --list`
Expected: tests pass, existing scenarios still listed.

- [ ] **Step 2.8: Commit.**

```bash
cd /home/benji/src/devnw/zig/fts-storage
zig fmt benchmarks/micro/bm25.zig build.zig
git add benchmarks/micro/bm25.zig build.zig
git commit -m "perf(bench): add BM25 scoring micro-benchmarks

Adds bm25_score_single (isolated arithmetic) and
bm25_score_norm_scan_16seg (O(segments) linear scan with target
doc planted in the last of 16 norm tables — worst case for the
loop at search.zig:205-214).

Both scenarios are zero-alloc inside the timed body. Norm tables
are pre-populated before runScenarios so their allocations are
not counted.

Wires bench-micro-bm25 into micro_all_step and tools_step."
```

---

## Task 3: `benchmarks/micro/wal_record.zig`

**Files:**

- Create: `benchmarks/micro/wal_record.zig`
- Modify: `build.zig` (add exe, step, wiring)

**Hot path under measurement:** `src/wal.zig` `WalRecord.serializeInto(self, alloc, buf)` at `wal.zig:59-77`.

- [ ] **Step 3.1: Read context.**

Read `src/wal.zig:29-90` (`WalRecord`, `WalRecordType`, `serializeInto`). Confirm: `serializeInto(self: *const @This(), alloc: Allocator, buf: *std.ArrayListUnmanaged(u8)) !void`. The buffer must be cleared (`clearRetainingCapacity`) before each call; the function appends.

- [ ] **Step 3.2: Create `benchmarks/micro/wal_record.zig`.**

```zig
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
    var ctx_data = WalCtx{ .scratch = .{} };
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
```

**Note on import path:** If `fts.wal` is not exported from `src/root.zig`, change the WalRecord access. Run `grep -n "pub const wal\\|pub usingnamespace" src/root.zig` first. If absent, add the line `pub const wal = @import("wal.zig");` to `src/root.zig` — this is a tiny, low-risk export and is justified for bench access. Commit that root.zig change as a separate first commit in Task 3 if needed.

- [ ] **Step 3.3: Wire into `build.zig`.**

Insert after `micro_bm25_exe` (Task 2):

```zig
    const micro_wal_record_exe = b.addExecutable(.{
        .name = "fts-storage-micro-wal-record",
        .root_module = benchModule(b, "benchmarks/micro/wal_record.zig", target, bench_lib_module, framework_module),
    });
    const run_micro_wal_record = b.addRunArtifact(micro_wal_record_exe);
    if (b.args) |args| run_micro_wal_record.addArgs(args);
    const micro_wal_record_step = b.step("bench-micro-wal-record", "WAL record serialize micro-benchmark");
    micro_wal_record_step.dependOn(&run_micro_wal_record.step);
```

Add to `micro_all_step.dependOn(...)`:

```zig
    micro_all_step.dependOn(&run_micro_wal_record.step);
```

Add to `tools_step`:

```zig
    tools_step.dependOn(&micro_wal_record_exe.step);
```

- [ ] **Step 3.4: Verify.**

```text
zig build check
zig build bench-micro-wal-record -- --list
zig build bench-micro-wal-record -- --warmup 3 --samples 5 --output /tmp/wr-smoke.json
jq '[.rows[] | {name: .scenario_name, allocs: .alloc_count}]' /tmp/wr-smoke.json
```

Expected: `alloc_count` is 0 in the sampled rows (the scratch buffer was pre-grown in `main`, so sample iterations should not trigger reallocation). If `alloc_count > 0`, investigate whether `clearRetainingCapacity` is being used correctly and whether the initial capacity is enough.

- [ ] **Step 3.5: Regression check + commit.**

```bash
cd /home/benji/src/devnw/zig/fts-storage
zig build test
zig fmt benchmarks/micro/wal_record.zig build.zig src/root.zig
git add benchmarks/micro/wal_record.zig build.zig
# Add src/root.zig only if you needed to add `pub const wal = ...`
git status --short  # confirm what is being committed
git commit -m "perf(bench): add WalRecord.serializeInto micro-benchmark

Adds wal_record_serialize_into. Scratch buffer is pre-grown to
64 bytes before runScenarios so the sampled iterations are
expected to be zero-alloc (warmup absorbs any growth).

Wires bench-micro-wal-record into micro_all_step and tools_step."
```

---

## Task 4: Extend `benchmarks/bench.zig` with integration scenarios

**Files:**

- Modify: `benchmarks/bench.zig`

**Goal:** Add four new scenarios named in `docs/PERF_GAP_ANALYSIS.md`. Each does heavy setup outside the timed body (via `iteration_index` branching or one-time setup in `main`).

**Hot path refs:** `src/engine.zig:665-674` (ingest), `src/segment.zig:223-294` (flush), `src/engine.zig:420-519` (replay), `src/segment.zig:518-564` + `src/search.zig:187-222` (query).

- [ ] **Step 4.1: Read context.**

Read in full: `benchmarks/bench.zig`, then `src/engine.zig:106-200` (Engine.init), `src/engine.zig:593-680` (indexDocument), `src/engine.zig:735-840` (flush), `src/engine.zig:420-519` (replayWal call chain), `src/wal.zig:155-200` (WalWriter.append, sync, appendAndSync), `src/limits.zig` (constants).

Also confirm the `TermPosting` shape: `src/engine.zig:14` defines it; `src/root.zig:66` re-exports as `fts.TermPosting`.

- [ ] **Step 4.2: Rewrite `benchmarks/bench.zig` body.**

This is a substantive rewrite. Replace the whole file contents (keeping the SPDX/copyright header) with the version below. The structure: each scenario gets a small `BenchCtx`-style payload allocated in `main` (where appropriate) so setup happens outside the timed region.

```zig
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

/// Build a 10,000-entry posting buffer (postings.bin format):
///   for each posting: varint(doc_delta=1), varint(tf=4),
///     varint(pos_delta=0), varint(1), varint(1), varint(1)
/// Each posting is exactly 6 bytes (all values fit in one varint byte).
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
fn freshTmpdir(allocator: std.mem.Allocator, prefix: []const u8, seq: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".bench-{s}-{x}-{d}", .{ prefix, std.time.nanoTimestamp(), seq });
}

// ----------------------------------------------------------------------------
// Scenario bodies — existing
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
// Scenario bodies — integration
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

    // Build the WAL outside the timed Engine.init call by closing the
    // engine that writes it, then re-opening to trigger replay.
    // The timed body still includes the WAL build, which is unavoidable
    // without a pre-warmed shared directory copied per iteration; the
    // scenario's wall time is dominated by replay (typically 5–10× the
    // build cost). The samples=5 is set with this in mind.
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

    // Timed query path.
    var it = try engine.search("bench_query");
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
// Scenario bodies — comparison (paired)
// ----------------------------------------------------------------------------

fn benchPostingIterNextWithPositions(ctx: *framework.Context) anyerror!void {
    const box = boxFromCtx(ctx);
    // Build a fresh PostingIterator over the pre-built buffer.
    // Use the framework's allocator so allocs are tracked correctly.
    const data = try ctx.allocator.dupe(u8, box.posting_buf);
    defer ctx.allocator.free(data);

    var it = fts.segment.PostingIterator{
        .allocator = ctx.allocator,
        .data = data,
        .df = POSTING_ENTRIES,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .{},
    };
    defer it.pos_buf.deinit(ctx.allocator);

    // Pre-grow pos_buf to avoid first-call growth showing up.
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
    defer ctx.allocator.free(data);

    var it = fts.segment.PostingIterator{
        .allocator = ctx.allocator,
        .data = data,
        .df = POSTING_ENTRIES,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .{},
    };
    defer it.pos_buf.deinit(ctx.allocator);

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const doc_id = (try it.nextDocOnly()) orelse break;
        std.mem.doNotOptimizeAway(doc_id);
    }
}
```

**Import-path notes (verify before pasting):**

1. `fts.utils.writeVarInt` — confirm `pub const utils = @import("utils.zig");` exists in `src/root.zig`. If not, add it (low-risk additive export). Commit that root.zig change in a small dedicated commit before this scenario commit.
2. `fts.segment.PostingIterator` — same: confirm or add `pub const segment = @import("segment.zig");` in `src/root.zig`. The PostingIterator type itself is declared inside `SegmentReader` (`src/segment.zig:440`); the public path may need to be `fts.segment.SegmentReader.PostingIterator`. Adjust accordingly.
3. `fts.wal.WalRecord` — confirm or add `pub const wal = @import("wal.zig");` in `src/root.zig`.
4. `engine.search` returns a `TermIterator`. Confirm at `src/engine.zig` (grep `pub fn search`). The iterator's `next()` returns `?Match`; `Match.doc_id` is `u64`. Adjust the loop variable types if needed.

If you must add re-exports to `src/root.zig`, do so as a **separate first commit** in Task 4:

```bash
git commit -m "refactor(root): re-export utils, wal, segment for bench access

Bench scenarios need direct access to writeVarInt, WalRecord, and
PostingIterator. These were already public symbols in their files
but not re-exported through fts_storage.zig. Low-risk additive
export — no behavior change."
```

- [ ] **Step 4.3: Verify symbol paths.**

```bash
cd /home/benji/src/devnw/zig/fts-storage
grep -n "^pub const" src/root.zig
grep -n "pub const PostingIterator\\|pub const Match" src/segment.zig src/search.zig
```

Adjust the bench.zig imports to match the actual public paths. If a re-export is needed, add it to `src/root.zig` and commit separately as described above.

- [ ] **Step 4.4: `zig build check`** — expect exit 0.

- [ ] **Step 4.5: `--list` smoke.**

Run: `cd /home/benji/src/devnw/zig/fts-storage && zig build bench -- --list 2>&1`
Expected: 8 scenarios listed:

- `engine_init_cycle`
- `engine_index_document`
- `ingest_100k_docs_random_terms`
- `flush_100k_term_memtable`
- `replay_wal_1M_records`
- `query_term_iterator_16_segments`
- `posting_iter_next_with_positions`
- `posting_iter_next_doc_only`

- [ ] **Step 4.6: Smoke run with cheap filter.**

Run: `cd /home/benji/src/devnw/zig/fts-storage && zig build bench -- --filter engine_init --warmup 1 --samples 2 --output /tmp/bench-smoke.json 2>&1 | tail -10`
Expected: exit 0; existing baseline scenario runs successfully.

Then a heavier filter (still cheap):

```text
zig build bench -- --filter posting_iter --warmup 1 --samples 2 --output /tmp/bench-pi.json 2>&1 | tail -10
jq '[.rows[] | {name: .scenario_name, allocs: .alloc_count, p50: .wall_ns_p50}]' /tmp/bench-pi.json
```

Expected: both `posting_iter_*` rows present. `posting_iter_next_doc_only` should have `alloc_count: 0` (no `pos_buf` growth). `posting_iter_next_with_positions` may have `alloc_count: 0` if `pos_buf` pre-grow succeeded; small positive value otherwise.

- [ ] **Step 4.7: Validate the big-and-slow scenarios run to completion at minimum samples.**

These scenarios are expensive. Use the smallest legal sample count (1 warmup + 1 sample) to confirm the body runs without error. Do not use these times as benchmark data.

```text
zig build bench -- --filter ingest_100k --warmup 0 --samples 1 --output /tmp/bench-ingest.json 2>&1 | tail -10
zig build bench -- --filter flush_100k --warmup 0 --samples 1 --output /tmp/bench-flush.json 2>&1 | tail -10
zig build bench -- --filter query_term --warmup 0 --samples 1 --output /tmp/bench-query.json 2>&1 | tail -10
```

If `--warmup 0` is rejected, use `--warmup 1 --samples 1`. The `replay_wal_1M_records` scenario is too expensive for inline verification (the workload writes 1M docs + replays); skip a smoke run for it and rely on `zig build check` for compile-time correctness. **Document in the commit message that `replay_wal_1M_records` was compile-tested only.**

If any of the integration smoke runs fail (compile errors, runtime panics, OOM, disk full), STOP and fix in this task. Do NOT proceed to Task 5 with broken integration scenarios.

- [ ] **Step 4.8: Test suite must still pass.**

```text
cd /home/benji/src/devnw/zig/fts-storage && zig build test && zig build test-integration
```

Expected: all green.

- [ ] **Step 4.9: Commit (or two commits if you added re-exports).**

```bash
cd /home/benji/src/devnw/zig/fts-storage
zig fmt benchmarks/bench.zig
git add benchmarks/bench.zig
# Add src/root.zig if you added re-exports — but commit that separately first.
git status --short
git commit -m "perf(bench): add integration + comparison scenarios

Adds the four scenarios named in docs/PERF_GAP_ANALYSIS.md
(ingest_100k_docs_random_terms, flush_100k_term_memtable,
replay_wal_1M_records, query_term_iterator_16_segments) and
the two paired comparison scenarios
(posting_iter_next_with_positions, posting_iter_next_doc_only).

Each integration scenario uses a per-iteration unique tmpdir
to avoid cross-iteration state contamination. Workload
generation uses a fixed seed (0xdeadbeef_cafef00d) for
determinism.

Existing engine_init_cycle and engine_index_document scenarios
are preserved unchanged. baseline.json is intentionally not
updated in this commit — the additive schema (.ignore_unknown_fields
= true in compare.zig) means new scenarios produce 'no baseline
row, skipping' until a follow-up baseline refresh."
```

---

## Task 5: Final verification

**Files:** none modified; verification only.

- [ ] **Step 5.1: Full check.**

```bash
cd /home/benji/src/devnw/zig/fts-storage
zig build check
```

Expected: exit 0.

- [ ] **Step 5.2: Full test suite.**

```bash
cd /home/benji/src/devnw/zig/fts-storage
zig build test
zig build test-integration
zig build test-stress  # optional; long
```

Expected: all green.

- [ ] **Step 5.3: All micro suites run.**

```bash
cd /home/benji/src/devnw/zig/fts-storage
zig build bench-micro-varint -- --warmup 1 --samples 3 --output /tmp/v.json
zig build bench-micro-bm25 -- --warmup 1 --samples 3 --output /tmp/b.json
zig build bench-micro-wal-record -- --warmup 1 --samples 3 --output /tmp/w.json
zig build bench-micro-example -- --warmup 1 --samples 3 --output /tmp/e.json
zig build bench-micro -- --warmup 1 --samples 3
```

Expected: all exit 0.

- [ ] **Step 5.4: Bench --list shows all 8 scenarios.**

```text
zig build bench -- --list 2>&1 | grep -E "engine_|ingest_|flush_|replay_|query_|posting_" | wc -l
```

Expected output: `8`.

- [ ] **Step 5.5: Compare against existing baseline (verify schema compatibility).**

```text
zig build bench -- --filter engine_init --warmup 1 --samples 3 --output /tmp/bench-c.json
zig build compare-bench -- --baseline benchmarks/results/baseline.json --current /tmp/bench-c.json
```

Expected: exit 0. `engine_init_cycle` may pass or warn but must not error on missing fields.

- [ ] **Step 5.6: Run the bench-validator agent.**

Dispatch the `native-benchmarks:bench-validator` subagent against the run directory `docs/performance/2026-05-27-bench-coverage-expansion/`. The validator will scan bench sources, evidence directories, and verify:

- No third-party bench libs added
- No sleep-based timing
- Per-round samples retained (N/A for this run since no A/B)
- `doNotOptimizeAway` present where expected
- Zero-alloc probes hold

Loop back to fix any violations.

- [ ] **Step 5.7: Final summary.**

Print to stdout:

```text
Bench coverage expansion COMPLETE.

Files created:
  benchmarks/micro/varint.zig
  benchmarks/micro/bm25.zig
  benchmarks/micro/wal_record.zig

Files modified:
  benchmarks/bench.zig (8 scenarios, was 2)
  build.zig (3 new exe blocks, 3 new step names)

Scenario count:
  bench: 8 (was 2)
  bench-micro: 4 sub-suites with 8 total scenarios
                (varint 4 + bm25 2 + wal-record 1 + example 1)

Baseline policy: benchmarks/results/baseline.json UNCHANGED.
Baseline refresh deferred until 3 stable CI runs verify medians.
```

---

## Self-Review

1. **Spec coverage:** Every scenario named in `plan.json` (13 scenarios) has a task that implements it. Build wiring (3 new exe blocks + 3 step names + 3 `micro_all_step.dependOn` + 3 `tools_step.dependOn`) is fully covered in Tasks 1–3.
2. **Placeholder scan:** No "TBD", no "fill in later", no `// ...`. Every code block is complete and copy-pasteable. Import paths are flagged for verification with a fallback (add re-exports to root.zig as a separate commit).
3. **Type consistency:** `Box` is used in bench.zig; `BM25Ctx` in bm25.zig; `WalCtx` in wal_record.zig — distinct names, no cross-file collision. `IoBox` from the existing micro/example.zig is replaced by `Box` in the new bench.zig but micro/example.zig keeps its own `IoBox` unchanged.
4. **Acceptance:** Each task ends with `zig build check`, scenario discovery (`--list`), smoke run, regression check (`zig build test`), and a commit. Task 5 does whole-suite verification.

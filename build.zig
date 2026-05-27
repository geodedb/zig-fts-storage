// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");

fn importedModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fts_storage", .module = module },
        },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer on test/stress/fuzz/integration artifacts (forces stress-suite optimize=Debug so races aren't optimised away)") orelse false;
    // SEC-EXT-0605: -Dasan=true enables every memory-safety / UB sanitizer
    // currently reachable through the Zig 0.16 Build API. AddressSanitizer
    // itself is not yet exposed as a Module-level flag (no
    // `Module.sanitize_address` field — only `sanitize_thread` and
    // `sanitize_c`). What we can do on 0.16:
    //
    //   * Zig safety builds (Debug / ReleaseSafe) already cover bounds,
    //     alignment, pointer-tag, and use-after-free-of-stack via the
    //     language. The unit / integration / fault-injection tests run in
    //     Debug by default, so those checks are always on.
    //   * Setting `sanitize_c = .full` switches any C TU we pull in (none
    //     today, but future ones) to UBSan with trap-on-undefined behaviour.
    //   * `-Dtsan=true` already exists for the race-detection axis.
    //
    // Treat `-Dasan=true` as the umbrella "max-safety" knob until upstream
    // Zig surfaces `sanitize_address` on Module. The CI `test-asan` job
    // wires it through so we exercise this path on every default-branch run;
    // promote to required once it has run clean for a release cycle.
    const asan = b.option(bool, "asan", "Enable max-safety sanitizers on test artifacts (SEC-EXT-0605)") orelse false;
    const no_cli = b.option(bool, "no-cli", "Skip building the CLI executable and the `run` step (library-only build for downstream consumers)") orelse false;

    // ------------------------------------------------------------------
    // Library module — primary public surface for downstream consumers.
    // ------------------------------------------------------------------
    const module = b.addModule("fts_storage", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const static_lib = b.addLibrary(.{
        .name = "fts-storage",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(static_lib);

    const build_step = b.step("build", "Build the standalone library and CLI");
    build_step.dependOn(&static_lib.step);

    // ------------------------------------------------------------------
    // CLI executable — links against the library module.
    // Disable with `-Dno-cli` for pure-library builds.
    // ------------------------------------------------------------------
    if (!no_cli) {
        const cli_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fts_storage", .module = module },
            },
        });
        const cli_exe = b.addExecutable(.{
            .name = "fts-storage",
            .root_module = cli_module,
        });
        b.installArtifact(cli_exe);
        build_step.dependOn(&cli_exe.step);

        const run_cli = b.addRunArtifact(cli_exe);
        if (b.args) |args| run_cli.addArgs(args);
        const run_step = b.step("run", "Run the CLI (forwards trailing args after `--`)");
        run_step.dependOn(&run_cli.step);
    }

    // ------------------------------------------------------------------
    // Check step — fast IDE feedback. Compiles unit tests without
    // running them.
    // ------------------------------------------------------------------
    const check_step = b.step("check", "Compile the library and tests without running them");
    const check_tests = b.addTest(.{
        .root_module = module,
    });
    check_step.dependOn(&check_tests.step);

    // ------------------------------------------------------------------
    // Test suites.
    // ------------------------------------------------------------------
    const unit_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = module,
    });
    if (tsan) unit_tests.root_module.sanitize_thread = true;
    if (asan) unit_tests.root_module.sanitize_c = .full;
    unit_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/integration.zig", target, optimize, module),
    });
    if (tsan) integration_tests.root_module.sanitize_thread = true;
    if (asan) integration_tests.root_module.sanitize_c = .full;
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // Fault-injection harness (WRK-022, GAP-0016, QUAL-0020, QUAL-0021).
    // Co-runs with the integration suite so a single `test-integration`
    // invocation exercises both the happy path and the deliberate-tamper
    // scenarios.
    const fault_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/fault_injection.zig", target, optimize, module),
    });
    if (tsan) fault_tests.root_module.sanitize_thread = true;
    if (asan) fault_tests.root_module.sanitize_c = .full;
    integration_step.dependOn(&b.addRunArtifact(fault_tests).step);

    // Stress runs Debug under TSan so races aren't optimised away.
    const stress_optimize: std.builtin.OptimizeMode = if (tsan) .Debug else .ReleaseFast;
    const stress_step = b.step("test-stress", "Run stress and load tests");
    const stress_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/stress.zig", target, stress_optimize, module),
    });
    if (tsan) stress_tests.root_module.sanitize_thread = true;
    if (asan) stress_tests.root_module.sanitize_c = .full;
    stress_step.dependOn(&b.addRunArtifact(stress_tests).step);

    // Adversarial deserializer harness (SEC-EXT-0504). A small, deterministic
    // corpus of malformed inputs aimed at every public byte-driven decoder
    // (Manifest.deserialize, WalRecord.deserialize, readVarInt). Pairs with
    // the coverage-guided `zig-fuzz` CI component, which uses the same entry
    // points under `zig test --fuzz`. Kept as a separate step so the regular
    // test pipeline stays fast and the fuzz pipeline stays advisory.
    const fuzz_step = b.step("test-fuzz", "Run adversarial deserializer fuzz harnesses");
    const fuzz_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/fuzz_targets.zig", target, optimize, module),
    });
    if (tsan) fuzz_tests.root_module.sanitize_thread = true;
    if (asan) fuzz_tests.root_module.sanitize_c = .full;
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const all_tests_step = b.step("test-all", "Run unit, integration, and stress suites");
    all_tests_step.dependOn(&b.addRunArtifact(unit_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(integration_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(stress_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // ------------------------------------------------------------------
    // Example — demonstrates library usage end-to-end.
    // ------------------------------------------------------------------
    const example_step = b.step("example", "Build and run the basic example");
    const example_exe = b.addExecutable(.{
        .name = "fts-storage-basic",
        .root_module = importedModule(b, "examples/basic.zig", target, optimize, module),
    });
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

    // ------------------------------------------------------------------
    // Benchmarks — see benchmarks/README.md.
    //
    // The benchmark framework (benchmarks/framework.zig) is library-
    // agnostic and depends only on the Zig stdlib. We expose it as its
    // own module so any bench source — including files in subdirectories
    // like benchmarks/micro/ — can `@import("framework")` it. Each suite
    // is then a standalone exe whose root module imports both the
    // framework and the project library. ReleaseFast is forced for all
    // benchmark exes so casual `zig build bench` invocations still
    // produce comparable numbers regardless of the top-level optimize
    // option.
    // ------------------------------------------------------------------

    const framework_module = b.addModule("framework", .{
        .root_source_file = b.path("benchmarks/framework.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // Force-build a ReleaseFast copy of the library for benchmarks
    // (WRK-024, PERF-0020, PERF-0025). Without this, `zig build bench`
    // links against whatever optimisation the top-level `-Doptimize`
    // selected — defaulting to Debug — which mixes safety-checked
    // library code into hot loops and produces numbers that compare
    // poorly across runs. Benchmarks need a stable optimisation level.
    const bench_lib_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_exe = b.addExecutable(.{
        .name = "fts-storage-bench",
        .root_module = benchModule(b, "benchmarks/bench.zig", target, bench_lib_module, framework_module),
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the default benchmark suite");
    bench_step.dependOn(&run_bench.step);

    const scale_bench_exe = b.addExecutable(.{
        .name = "fts-storage-scale-bench",
        .root_module = benchModule(b, "benchmarks/scale.zig", target, bench_lib_module, framework_module),
    });
    b.installArtifact(scale_bench_exe);
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| run_scale_bench.addArgs(args);
    const scale_bench_step = b.step("scale-bench", "Run the larger / longer benchmark grid");
    scale_bench_step.dependOn(&run_scale_bench.step);

    const compare_bench_exe = b.addExecutable(.{
        .name = "fts-storage-compare-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "framework", .module = framework_module },
            },
        }),
    });
    b.installArtifact(compare_bench_exe);
    const run_compare = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| run_compare.addArgs(args);
    const compare_step = b.step("compare-bench", "Diff two benchmark result files and gate on regressions");
    compare_step.dependOn(&run_compare.step);

    const micro_example_exe = b.addExecutable(.{
        .name = "fts-storage-micro-example",
        .root_module = benchModule(b, "benchmarks/micro/example.zig", target, bench_lib_module, framework_module),
    });
    const run_micro_example = b.addRunArtifact(micro_example_exe);
    if (b.args) |args| run_micro_example.addArgs(args);
    const micro_example_step = b.step("bench-micro-example", "Example micro-benchmark");
    micro_example_step.dependOn(&run_micro_example.step);

    const micro_varint_exe = b.addExecutable(.{
        .name = "fts-storage-micro-varint",
        .root_module = benchModule(b, "benchmarks/micro/varint.zig", target, bench_lib_module, framework_module),
    });
    const run_micro_varint = b.addRunArtifact(micro_varint_exe);
    if (b.args) |args| run_micro_varint.addArgs(args);
    const micro_varint_step = b.step("bench-micro-varint", "Varint encode/decode micro-benchmarks");
    micro_varint_step.dependOn(&run_micro_varint.step);

    const micro_bm25_exe = b.addExecutable(.{
        .name = "fts-storage-micro-bm25",
        .root_module = benchModule(b, "benchmarks/micro/bm25.zig", target, bench_lib_module, framework_module),
    });
    const run_micro_bm25 = b.addRunArtifact(micro_bm25_exe);
    if (b.args) |args| run_micro_bm25.addArgs(args);
    const micro_bm25_step = b.step("bench-micro-bm25", "BM25 scoring micro-benchmarks");
    micro_bm25_step.dependOn(&run_micro_bm25.step);

    const micro_all_step = b.step("bench-micro", "Run all micro-benchmarks");
    micro_all_step.dependOn(&run_micro_example.step);
    micro_all_step.dependOn(&run_micro_varint.step);
    micro_all_step.dependOn(&run_micro_bm25.step);

    const tools_step = b.step("tools", "Build benchmark tooling artifacts");
    tools_step.dependOn(&bench_exe.step);
    tools_step.dependOn(&scale_bench_exe.step);
    tools_step.dependOn(&compare_bench_exe.step);
    tools_step.dependOn(&micro_example_exe.step);
    tools_step.dependOn(&micro_varint_exe.step);
    tools_step.dependOn(&micro_bm25_exe.step);
}

fn benchModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    lib_module: *std.Build.Module,
    framework_module: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "fts_storage", .module = lib_module },
            .{ .name = "framework", .module = framework_module },
        },
    });
}

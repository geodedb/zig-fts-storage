# fts-storage

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0+-orange.svg)](https://ziglang.org/)

An append-only, crash-recoverable inverted-index storage engine for full-text search, written in pure Zig.

## Features

- Append-only WAL with CRC32C-checked records (durable, crash-recoverable)
- A/B atomic manifest with monotonic counter
- LSM-style immutable segments with delta+varint postings
- Tombstone-based deletes; tombstones consulted at search time
- WAL replay on startup; replay tolerant of clean truncation
- Pure Zig 0.16+ standard library; **zero external dependencies**
- Cross-platform (Linux, macOS, Windows)
- Well tested: unit, integration, and stress test suites

## Installation

### Using the Zig package manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .fts_storage = .{
        .url = "https://gitlab.com/devnw/zig/fts-storage/-/archive/v0.1.0/fts-storage-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const fts_storage = b.dependency("fts_storage", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("fts_storage", fts_storage.module("fts_storage"));
```

## Quick Start

```zig
const std = @import("std");
const Io = std.Io;
const fts = @import("fts_storage");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var dir = try Io.Dir.cwd().createDirPathOpen(io, "data", .{});
    defer dir.close(io);

    var engine = try fts.Engine.init(io, allocator, dir);
    defer engine.deinit();

    const term = fts.TermPosting{ .term = "hello", .positions = &[_]u32{ 1, 5 } };
    try engine.indexDocument(42, &[_]fts.TermPosting{term});
    try engine.flush();
}
```

See [`examples/basic.zig`](examples/basic.zig) for the canonical working
example. Build and run the CLI directly from the repo:

```bash
zig build run -- <args...>
```

## Requirements

- Zig 0.16.0 or later

## Building

```bash
make build         # library + CLI
make test          # unit + integration + stress
make example       # run examples/basic.zig
make run           # run the CLI
make dev           # quick fmt + check + unit tests
make ci            # full clean rebuild + test-all
```

`zig build -Dno-cli=true` produces a library-only build. `zig build
-Dtsan` rebuilds tests under ThreadSanitizer.

## Benchmarks

```bash
make bench           # default suite -> benchmarks/results/latest.json
make bench-compare   # diff against benchmarks/results/baseline.json
make bench-micro     # micro-benchmarks
make scale-bench     # larger grid
```

The benchmark framework lives in `benchmarks/framework.zig` and is
library-agnostic. See [`benchmarks/README.md`](benchmarks/README.md)
for the JSON schema, how to register a new scenario, and how the CI
regression gate is wired.

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability
reporting.

## License

This project is licensed under the Apache License 2.0 - see the
[LICENSE](LICENSE) file for details.

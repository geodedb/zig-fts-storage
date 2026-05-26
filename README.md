# fts-storage

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0+-orange.svg)](https://ziglang.org/)

A Zig library for fts-storage

## Features

- **Zero dependencies**: pure Zig standard library only
- **Library + CLI**: ships as both a Zig module and a standalone binary
- **Cross-platform**: Linux, macOS, Windows
- **Well tested**: unit, integration, and stress test suites

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
const fts_storage = @import("fts_storage");

pub fn main() !void {
    try fts_storage.init(.{ .debug = true });
}
```

Build and run the CLI directly from the repo:

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

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial project structure
- Core library implementation
- Unit and integration tests
- CI/CD pipeline
- Documentation

### Changed

- Segment files (terms.hash, postings.bin, tombstones.bin, norms.bin) are now
  written with a versioned, CRC32C-checksummed envelope (v2). Legacy naked
  segments remain readable forever (read-both). Older binaries opening v2
  segments fail loudly at their count guards rather than misparsing.

## [0.1.0] - 2026-05-26

### Added

- Initial release
- Core FTS storage engine: WAL + memtable + immutable segments + manifest
- BM25 ranking; phrase and proximity queries via positional postings
- AES-256-GCM segment-at-rest encryption (opt-in) and HMAC-SHA256 WAL envelope
- Field-level exclusion (FLE) and RLS/ABAC post-filter hook
- Adversarial deserializer fuzz harness and ASan CI job
- Benchmark framework with track-allocations + RSS sampling (Linux)
- Documentation and examples

[Unreleased]: https://gitlab.com/devnw/zig/fts_storage/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/fts_storage/-/releases/v0.1.0

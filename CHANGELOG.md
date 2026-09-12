# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.1.3] - 2026-07-10

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

### Fixed

- WAL: unknown record types now skip with the stream aligned (forward-compat
  skip actually works); torn tails are truncated before re-append so
  post-recovery writes stay replayable across a second crash.
- WAL forward-compat skip stays stream-aligned, and a corrupt payload-length
  field now terminates replay as a torn tail rather than desyncing the
  reader.
- WAL replay heals the txn-id allocator past uncommitted orphan brackets,
  preventing ghost-document resurrection via txn-id reuse. The heal also
  covers records skipped as unknown-type or due to an HMAC-backend failure,
  not just committed/aborted brackets.
- Posting decoding uses checked arithmetic on all disk-derived deltas —
  corrupt segments surface errors instead of panics/wraps in every build mode.
- Segment dictionary entries (df/offset/len) are validated against
  postings.bin extents at load, symmetrically for plaintext and AEAD paths.
- Manifest format_version is now enforced (fail-loud upgrade/downgrade gate).
- Segment files are fsynced before the manifest referencing them is published.
- compact() recomputes total_docs/avg_doc_len from the merged corpus,
  unskewing BM25 after deletes.
- `zig build test-all` now actually runs the fault-injection suite, which
  was previously wired only into `test-integration` and silently skipped.

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

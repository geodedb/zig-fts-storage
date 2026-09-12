// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! # fts-storage
//!
//! A pure-Zig append-only inverted-index storage engine.
//!
//! ## Capabilities
//!
//! - Append-only WAL with CRC32C-checked records (`wal.zig`)
//! - A/B atomic manifest with monotonic counter (`manifest.zig`)
//! - LSM-style immutable segments with delta+varint postings (`segment.zig`)
//! - Tombstone-based deletes (`segment.zig`, `search.zig`)
//! - Crash recovery via WAL replay (`engine.zig`)
//!
//! ## Quick Start
//!
//! ```zig
//! const std = @import("std");
//! const fts = @import("fts_storage");
//!
//! pub fn main() !void {
//!     var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     var dir = try std.fs.cwd().makeOpenPath("data", .{});
//!     defer dir.close();
//!     const io = std.Io.Threaded.global_single_threaded.io();
//!
//!     var engine = try fts.Engine.init(io, allocator, dir);
//!     defer engine.deinit();
//!
//!     const term = fts.TermPosting{ .term = "hello", .positions = &.{1, 5} };
//!     try engine.indexDocument(42, &.{term});
//!     try engine.flush();
//! }
//! ```
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

/// Library version. Keep in sync with build.zig.zon.
pub const version: []const u8 = "0.1.5";

pub const wal = @import("wal.zig");
pub const manifest = @import("manifest.zig");
pub const segment = @import("segment.zig");
pub const utils = @import("utils.zig");
pub const engine = @import("engine.zig");
pub const search = @import("search.zig");
pub const limits = @import("limits.zig");
pub const errors = @import("errors.zig");

// ============================================================================
// Public API surface — the real engine entry points
// ============================================================================

/// The append-only inverted-index storage engine.
pub const Engine = engine.Engine;

/// Opt-in configuration for `Engine.initWithConfig` (HMAC-SHA256 envelopes,
/// AES-256-GCM segment-at-rest encryption, and the single-writer
/// thread-identity check). Re-exported so embedders can construct it without
/// reaching into the `engine` namespace.
pub const EngineConfig = engine.EngineConfig;

/// A single (term, positions) pair handed to `Engine.indexDocument`.
pub const TermPosting = engine.TermPosting;

/// A (doc_id, terms) pair handed to `Engine.indexDocumentBatch`. The batch
/// API amortizes one fsync across the whole batch (PERF-0001, Phase B3).
pub const DocBatch = engine.DocBatch;

/// A streaming iterator over (doc_id, positions) matches for a search term.
pub const TermIterator = search.TermIterator;

// ============================================================================
// Unit Tests
// ============================================================================

test {
    std.testing.refAllDecls(@This());
    _ = @import("crypto_backend_smoke_test.zig");
}

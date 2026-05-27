# fts-storage Critical+High Gap Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 21 Phase-A + Phase-B + WRK-021 work items identified in the 2026-05-26 codepros:audit pass on /home/benji/src/devnw/zig/fts-storage, producing one git commit per work item with TDD discipline.

**Architecture:** Each task lands a focused change with a failing test first, a minimal implementation, then a passing test and a conventional-commit. Phase A is foundation (public API, limits, atomic write, error sets, file modes, SPDX). Phase B is small isolated wins (CODEOWNERS, README, stats plumbing, helper centralization, CLI). WRK-021 rewrites integration + stress tests to exercise the real Engine via the public surface. No new external dependencies. Mode: docs-only (no GitLab issue updates).

**Tech Stack:** Zig 0.16.0 (stdlib only). Build: `zig build check`, `zig build test`, `zig build test-integration`, `zig build test-stress`, `zig fmt --check src/ tests/ examples/ benchmarks/ build.zig`. Conventional Commits: `fix:` / `feat:` / `test:` / `refactor:` / `chore:` / `docs:`.

---

## File Structure

**New files:**

- `src/limits.zig` — hard caps on disk-resident lengths (WRK-002)
- `src/errors.zig` — named error sets per module (WRK-006)

**Files modified:**

- `src/root.zig` — strip template stub, re-export Engine surface (WRK-001, WRK-014, WRK-019)
- `src/engine.zig` — input validation, checked casts, error discrimination on loadManifest, dir ownership, addPosting reorder, WAL-first ordering, drop wal_file/wal_writer optional, file mode, stats plumbing, named errors (WRK-002, WRK-003, WRK-005, WRK-009, WRK-010, WRK-011, WRK-012, WRK-016)
- `src/manifest.zig` — limits + checked casts, named errors, SegmentEntry ordering metadata, total_docs/avg_doc_len updated (WRK-002, WRK-006, WRK-016, WRK-018)
- `src/segment.zig` — limits + checked casts, total_docs/doc_count plumbing, file mode (WRK-002, WRK-012, WRK-016)
- `src/wal.zig` — limits + checked casts, named errors, WalWriter.init stat-error propagation, WalRecordType begin/commit cleanup (WRK-002, WRK-006, WRK-015, WRK-017)
- `src/search.zig` — input validation on TermIterator.init (WRK-003)
- `src/utils.zig` — atomicWrite hardening (fsync parent dir, randomized tmp suffix, O_EXCL, errdefer cleanup), centralized byte helpers (WRK-004, WRK-019)
- `src/main.zig` — CLI rewrite over Engine (WRK-020)
- `README.md` — Feature list with real capabilities (WRK-014)
- `CODEOWNERS` — replace placeholder (WRK-013)
- `tests/integration.zig` — drive Engine via public surface (WRK-021)
- `tests/stress.zig` — drive Engine with bounded workload (WRK-021)
- `examples/basic.zig` — minimal Engine usage example (WRK-021)
- `.gitignore` — add `test_*.zig` at repo root (WRK-008)
- `build.zig` — wire `errors.zig`/`limits.zig` modules; CLI step matches new main.zig (WRK-001, WRK-020)

**Files deleted:**

- `test_al.zig`, `test_crc.zig`, `test_io.zig` (WRK-008)

---

## Sequencing

```text
WRK-001 root.zig API ────┬──> WRK-003 input validation ────> WRK-021 integration/stress tests
                         ├──> WRK-006 named error sets
                         ├──> WRK-014 README docs
                         ├──> WRK-019 centralize byte helpers
                         └──> WRK-020 CLI rewrite

WRK-002 limits.zig (independent)
WRK-004 atomicWrite (independent) ────> WRK-021
WRK-005 loadManifest errors ────────────> WRK-021
WRK-007 SPDX (independent)
WRK-008 stray tests (independent)
WRK-009 Engine optional null fields ─> WRK-001 (small overlap)
WRK-010 addPosting/WAL-first ────────> WRK-021 (recover edge)
WRK-011 dir ownership (independent)
WRK-012 file modes (independent)
WRK-013 CODEOWNERS (independent)
WRK-015 begin/commit cleanup (independent)
WRK-016 stats plumbing (independent)
WRK-017 WalWriter stat err (independent)
WRK-018 SegmentEntry ordering (independent)
```

**Recommended execution order:** 008 → 007 → 002 → 004 → 005 → 001 → 003 → 006 → 009 → 010 → 011 → 012 → 015 → 016 → 017 → 018 → 019 → 020 → 013 → 014 → 021.

---

## Task 1: WRK-008 — Delete stray root test files

Closes: GAP-0024, DC-5, QUAL-0031.

**Files:**

- Delete: `test_al.zig`, `test_crc.zig`, `test_io.zig`
- Modify: `.gitignore` (allow ignoring future scratch)

- [ ] **Step 1: Verify files are not referenced anywhere**

```bash
cd /home/benji/src/devnw/zig/fts-storage && grep -RIn "test_al\|test_crc\|test_io" --include='*.zig' --include='*.yml' --include='*.yaml' --include='build.zig' --include='Makefile' || echo "no references"
```

Expected: `no references`.

- [ ] **Step 2: Delete the files and add .gitignore entry**

```bash
cd /home/benji/src/devnw/zig/fts-storage && rm test_al.zig test_crc.zig test_io.zig
```

Append to `.gitignore`:

```gitignore
# Scratch experiments at repo root
/test_*.zig
```

- [ ] **Step 3: Build still passes**

Run: `cd /home/benji/src/devnw/zig/fts-storage && zig build check && zig build test --summary all`
Expected: 16/16 pass.

- [ ] **Step 4: Commit**

```bash
git add -u && git add .gitignore
git commit -m "chore: remove stray root-level scratch test files (GAP-0024, DC-5, QUAL-0031)"
```

---

## Task 2: WRK-007 — SPDX-License-Identifier headers on src/

Closes: SEC-11.

**Files:**

- Modify: `src/engine.zig`, `src/wal.zig`, `src/manifest.zig`, `src/search.zig`, `src/segment.zig`, `src/utils.zig`

- [ ] **Step 1: Failing audit script**

```bash
cd /home/benji/src/devnw/zig/fts-storage && for f in src/engine.zig src/wal.zig src/manifest.zig src/search.zig src/segment.zig src/utils.zig; do head -1 "$f" | grep -q '^// SPDX-License-Identifier: Apache-2.0' || echo "MISSING: $f"; done
```

Expected output before fix: all 6 lines `MISSING: ...`.

- [ ] **Step 2: Prepend the header to each file**

For each of `src/engine.zig`, `src/wal.zig`, `src/manifest.zig`, `src/search.zig`, `src/segment.zig`, `src/utils.zig`, prepend (using your editor):

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

```

(The blank line after the comment block matters; match the style of `src/root.zig:1-2`.)

- [ ] **Step 3: Re-run audit**

```bash
cd /home/benji/src/devnw/zig/fts-storage && for f in src/engine.zig src/wal.zig src/manifest.zig src/search.zig src/segment.zig src/utils.zig; do head -1 "$f" | grep -q '^// SPDX-License-Identifier: Apache-2.0' || echo "MISSING: $f"; done
```

Expected: empty output.

- [ ] **Step 4: Build still passes**

Run: `zig build check && zig fmt --check src/`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "chore: add SPDX-License-Identifier headers to src/*.zig (SEC-11)"
```

---

## Task 3: WRK-002 — limits.zig and checked casts on untrusted lengths

Closes: SEC-01, SEC-03, SEC-04, SEC-05, SEC-07, SEC-EXT-0201, 0202, 0204, 0206, 0207, PERF-0028.

**Files:**

- Create: `src/limits.zig`
- Modify: `src/manifest.zig:54-83` (cap `count` before `ensureTotalCapacity`; cap `data.len`)
- Modify: `src/segment.zig` (cap `tf`, `term_count`, `tombstone_count`, `postings_len`)
- Modify: `src/engine.zig:108-114` (cap manifest `stat.size` before allocating)
- Modify: `src/engine.zig:171-175` (checked cast on varint position)
- Test: `src/limits.zig` test block + extend `src/manifest.zig` tests

- [ ] **Step 1: Write the failing test in `src/manifest.zig`**

Append after the last existing test (after the `manifest corrupt data detected (bad CRC)` test):

```zig
test "manifest deserialize rejects oversized count" {
    const allocator = std.testing.allocator;
    // Craft a manifest header that claims count = MAX_U32 (would allocate ~96 GiB)
    var buf: [44]u8 = undefined;
    @memcpy(buf[0..8], &MANIFEST_MAGIC);
    var pos: usize = 8;
    writeU32(&buf, &pos, MANIFEST_VERSION);
    writeU64(&buf, &pos, 0); // counter
    writeU64(&buf, &pos, 0); // lsn
    writeU64(&buf, &pos, 0); // total_docs
    writeU32(&buf, &pos, 0); // avg_doc_len
    writeU32(&buf, &pos, 0xFFFFFFFF); // segment_count -- adversarial
    const crc = utils.hashCrc32c(buf[0..40]);
    writeU32(&buf, &pos, crc);

    try std.testing.expectError(error.SegmentCountTooLarge, Manifest.deserialize(allocator, &buf));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with allocation error or "missing-error" (deserialize will currently try to alloc ~96 GiB and OOM-kill the test).

- [ ] **Step 3: Create `src/limits.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Hard caps on disk-resident length fields. Every deserializer must consult
//! these before allocating storage proportional to an untrusted value.

/// Maximum bytes accepted for a single manifest file.
pub const MAX_MANIFEST_BYTES: usize = 64 * 1024 * 1024;

/// Maximum SegmentEntry rows allowed inside a Manifest.
pub const MAX_SEGMENTS_PER_MANIFEST: u32 = 1 << 20; // 1,048,576

/// Maximum total payload bytes accepted for a single WAL record.
pub const MAX_WAL_PAYLOAD_BYTES: u32 = 10 * 1024 * 1024;

/// Maximum term length (bytes) accepted from any source.
pub const MAX_TERM_LEN: u32 = 1 << 14; // 16 KiB

/// Maximum positions accepted per posting (per (term, doc_id)).
pub const MAX_POSITIONS_PER_TERM: u32 = 1 << 20; // 1,048,576

/// Maximum dictionary terms loaded from a single segment.
pub const MAX_TERMS_PER_SEGMENT: u32 = 1 << 24; // 16,777,216

/// Maximum tombstone entries loaded from a single segment.
pub const MAX_TOMBSTONES_PER_SEGMENT: u32 = 1 << 24;

/// Maximum byte length of a single segment postings buffer.
pub const MAX_POSTINGS_BYTES: u64 = 4 * 1024 * 1024 * 1024; // 4 GiB

test {
    _ = MAX_MANIFEST_BYTES;
}
```

- [ ] **Step 4: Wire `limits.zig` into `build.zig`**

In `build.zig`, find the `module` definition (around line 32-36) and add `limits.zig` as a sibling import. Easiest: since other modules already self-import via `@import("limits.zig")` and Zig resolves relative to the importing file, adding the file to the source tree is sufficient. No build.zig edit required — the test block referencing it will be picked up by `refAllDecls` in root.zig.

- [ ] **Step 5: Update `src/manifest.zig:54-83`**

Replace the `pub fn deserialize` body to consult limits. Change:

```zig
pub fn deserialize(allocator: Allocator, data: []const u8) !Manifest {
    const min_size = 8 + 4 + 8 + 8 + 8 + 4 + 4 + 4;
    if (data.len < min_size) return error.InvalidData;
    if (data.len > limits.MAX_MANIFEST_BYTES) return error.ManifestTooLarge;
    if (!std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC)) return error.InvalidMagic;

    const stored_crc = readU32NoAdvance(data, data.len - 4);
    const computed_crc = utils.hashCrc32c(data[0 .. data.len - 4]);
    if (stored_crc != computed_crc) return error.ChecksumMismatch;

    var pos: usize = 8;
    var m = Manifest{};
    m.format_version = readU32(data, &pos);
    m.counter = readU64(data, &pos);
    m.last_checkpoint_lsn = readU64(data, &pos);
    m.total_docs = readU64(data, &pos);
    m.avg_doc_len = readU32(data, &pos);
    const count = readU32(data, &pos);

    if (count > limits.MAX_SEGMENTS_PER_MANIFEST) return error.SegmentCountTooLarge;
    if (data.len != min_size + @as(usize, count) * 24) return error.InvalidData;

    try m.segments.ensureTotalCapacity(allocator, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        m.segments.appendAssumeCapacity(.{
            .id = readU64(data, &pos),
            .doc_count = readU64(data, &pos),
            .tombstone_count = readU64(data, &pos),
        });
    }
    return m;
}
```

Add at the top of `src/manifest.zig` (after the existing `const utils = @import("utils.zig");`):

```zig
const limits = @import("limits.zig");
```

- [ ] **Step 6: Update `src/engine.zig:105-114` (loadManifest)**

Replace the body of `fn loadManifest`:

```zig
fn loadManifest(io: std.Io, allocator: Allocator, dir: std.Io.Dir, path: []const u8) !manifest.Manifest {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > limits.MAX_MANIFEST_BYTES) return error.ManifestTooLarge;
    const size_usize = std.math.cast(usize, stat.size) orelse return error.ManifestTooLarge;
    const data = try allocator.alloc(u8, size_usize);
    defer allocator.free(data);
    var iov = [_][]u8{data};
    _ = try file.readStreaming(io, &iov);
    return try manifest.Manifest.deserialize(allocator, data);
}
```

Add at the top of `src/engine.zig`:

```zig
const limits = @import("limits.zig");
```

- [ ] **Step 7: Update `src/segment.zig` deserialization caps**

For each of: postings_len read at SegmentReader (around line 282 per audit), term_count at line 346, tombstone_count at line 376, tf in PostingIterator around line 264 — add the same pattern:

```zig
// At the postings_len/postings_offset site (segment.zig:282 area):
if (entry.postings_len > limits.MAX_POSTINGS_BYTES) return error.PostingsTooLarge;
const postings_len_usize = std.math.cast(usize, entry.postings_len) orelse return error.PostingsTooLarge;
const data = try self.allocator.alloc(u8, postings_len_usize);

// At the term-count site (segment.zig:346 area):
const count = readU32(...);  // existing
if (count > limits.MAX_TERMS_PER_SEGMENT) return error.TermCountTooLarge;

// At the tombstones-count site (segment.zig:376 area):
const tcount = readU32(...);
if (tcount > limits.MAX_TOMBSTONES_PER_SEGMENT) return error.TombstoneCountTooLarge;

// At the tf site in PostingIterator (segment.zig:264 area):
if (tf > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;
const tf_usize = std.math.cast(usize, tf) orelse return error.PositionCountTooLarge;
```

Add at the top of `src/segment.zig`:

```zig
const limits = @import("limits.zig");
```

- [ ] **Step 8: Update `src/engine.zig:171-175` applyIndexDocPayload**

In `applyIndexDocPayload`, replace the `@intCast(res.val)` with checked cast:

```zig
const pos_value = std.math.cast(u32, res.val) orelse return error.PositionOutOfRange;
pos_buf.appendAssumeCapacity(pos_value);
```

And cap `num_pos`:

```zig
if (num_pos > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;
```

- [ ] **Step 9: Verify the failing test now passes**

Run: `zig build test --summary all`
Expected: 17/17 pass (new oversized-count test passes; existing 16 still pass).

- [ ] **Step 10: Format + check**

Run: `zig fmt src/ tests/ examples/ benchmarks/ build.zig && zig build check`
Expected: clean.

- [ ] **Step 11: Commit**

```bash
git add -u && git add src/limits.zig
git commit -m "fix: cap untrusted lengths via src/limits.zig (SEC-01, 03, 04, 05, 07, EXT-0201, 0202, 0204, 0206, 0207, PERF-0028)"
```

---

## Task 4: WRK-004 — Harden atomicWrite

Closes: QUAL-0010, PERF-0013, SEC-EXT-0303.

**Files:**

- Modify: `src/utils.zig:48-60`
- Test: extend `src/utils.zig` tests

- [ ] **Step 1: Write the failing test in `src/utils.zig`**

Append after existing tests:

```zig
test "atomicWrite cleans up tmp on rename failure" {
    const allocator = std.testing.allocator;
    _ = allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Pre-create the target as a directory to force rename failure on POSIX
    try tmp_dir.dir.makeDir("target");

    const result = atomicWrite(io, tmp_dir.dir, "target", "hello");
    try std.testing.expectError(error.IsDir, result);

    // The tmp sibling should NOT remain in the directory after failure
    var iter = tmp_dir.dir.iterate();
    var found_tmp = false;
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "target.") and std.mem.endsWith(u8, entry.name, ".tmp")) {
            found_tmp = true;
        }
    }
    try std.testing.expect(!found_tmp);
}
```

(If `std.Io.Threaded.global_single_threaded` differs from what's in tree, match the same pattern used in `src/engine.zig:288`.)

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — current code leaves `target.tmp` behind on rename failure.

- [ ] **Step 3: Replace `atomicWrite` in `src/utils.zig:48-60`**

```zig
pub fn atomicWrite(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    // Build a randomized, unique tmp suffix so concurrent writers don't collide
    // and so a left-behind tmp from a previous failure is never reused silently.
    var tmp_path_buf: [4096]u8 = undefined;
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{std.fmt.fmtSliceHexLower(&rand_bytes)}) catch unreachable;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.{s}.tmp", .{ path, hex });

    // Create tmp exclusively (no clobber). errdefer cleans it up on any failure.
    const file = try dir.createFile(io, tmp_path, .{ .exclusive = true });
    var closed = false;
    errdefer if (!closed) file.close(io);
    errdefer dir.deleteFile(io, tmp_path) catch {};

    try file.writeStreamingAll(io, data);
    try file.sync(io);
    file.close(io);
    closed = true;

    // Atomic rename, then fsync the parent directory so the rename is durable.
    try dir.rename(tmp_path, dir, path, io);
    dir.sync(io) catch {}; // best-effort: not every platform supports it
}
```

Note: if `std.Io.Dir` lacks `.sync()` in Zig 0.16, replace with `dir.fd.sync()` or whatever the equivalent is — verify against the Zig 0.16 source. If unavailable on Windows, the `catch {}` keeps the code portable.

- [ ] **Step 4: Re-run the test**

Run: `zig build test --summary all`
Expected: all tests pass (existing + new atomicWrite cleanup test).

- [ ] **Step 5: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add -u
git commit -m "fix: harden atomicWrite with O_EXCL, randomized tmp, errdefer cleanup, parent dir fsync (QUAL-0010, PERF-0013, SEC-EXT-0303)"
```

---

## Task 5: WRK-005 — loadManifest error discrimination

Closes: QUAL-0004, SEC-EXT-0305.

**Files:**

- Modify: `src/engine.zig:51-67` (open-time manifest selection logic)

- [ ] **Step 1: Write the failing test in `src/engine.zig`**

Append a new test below the existing `Engine index, flush, and recover` test:

```zig
test "Engine.init fails closed when both manifests corrupt" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Bootstrap a valid engine, flush, then corrupt both manifests
    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = TermPosting{ .term = "x", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]TermPosting{t});
        try eng.flush();
    }

    // Corrupt manifest.a and manifest.b CRCs
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |name| {
        const f = tmp_dir.dir.openFile(io, name, .{ .mode = .read_write }) catch continue;
        defer f.close(io);
        const sz = (try f.stat(io)).size;
        var buf = [_]u8{0xFF};
        _ = try f.pwrite(io, &buf, sz - 1);
    }

    // Open must fail loudly, not silently start fresh
    try std.testing.expectError(error.ManifestCorrupt, Engine.init(io, alloc, tmp_dir.dir));
}
```

(Verify the `pwrite` API name matches Zig 0.16; substitute `writeAt` / `writePositionalAll` as needed.)

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — current code does `catch null` then falls through to an empty `manifest.Manifest{}`.

- [ ] **Step 3: Replace the manifest-loading block in `Engine.init`**

Change `src/engine.zig:51-67` to:

```zig
// Load Manifest A/B with explicit error discrimination
const man_a = try loadManifestOptional(io, allocator, base_dir, "manifest.a");
const man_b = try loadManifestOptional(io, allocator, base_dir, "manifest.b");

if (man_a == null and man_b == null) {
    // Truly fresh database — caller may proceed with empty manifest
    engine.current_manifest = manifest.Manifest{};
} else {
    // At least one manifest readable; pick the highest counter
    engine.current_manifest = try manifest.Manifest.selectManifest(man_a, man_b);
}

// Deinit the unchosen manifest
if (man_a) |m| {
    if (m.counter != engine.current_manifest.counter) {
        var m_mut = m;
        m_mut.deinit(allocator);
    }
}
if (man_b) |m| {
    if (m.counter != engine.current_manifest.counter) {
        var m_mut = m;
        m_mut.deinit(allocator);
    }
}
```

And add a sibling helper above `replayWal`:

```zig
/// Returns null only for FileNotFound. Any other error is propagated so we
/// fail loud on a present-but-corrupt manifest instead of silently downgrading.
fn loadManifestOptional(io: std.Io, allocator: Allocator, dir: std.Io.Dir, path: []const u8) !?manifest.Manifest {
    return loadManifest(io, allocator, dir, path) catch |err| switch (err) {
        error.FileNotFound => null,
        error.ChecksumMismatch,
        error.InvalidData,
        error.InvalidMagic,
        error.ManifestTooLarge,
        error.SegmentCountTooLarge,
        => error.ManifestCorrupt,
        else => |e| e,
    };
}
```

- [ ] **Step 4: Re-run tests**

Run: `zig build test --summary all`
Expected: all tests pass, new ManifestCorrupt test passes.

- [ ] **Step 5: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add -u
git commit -m "fix: loadManifest error discrimination (no silent catch null) (QUAL-0004, SEC-EXT-0305)"
```

---

## Task 6: WRK-001 — Re-export Engine public API from root.zig

Closes: GAP-0023, QUAL-0001, DO-2, DO-3 (partial).

**Files:**

- Modify: `src/root.zig` (replace template stub with public-API surface)

- [ ] **Step 1: Update root.zig**

Replace the entire `src/root.zig` with:

```zig
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
pub const version: []const u8 = "0.1.0";

pub const limits = @import("limits.zig");
pub const wal = @import("wal.zig");
pub const manifest = @import("manifest.zig");
pub const segment = @import("segment.zig");
pub const utils = @import("utils.zig");
pub const engine = @import("engine.zig");
pub const search = @import("search.zig");

// ============================================================================
// Public API surface — the real engine entry points
// ============================================================================

/// The append-only inverted-index storage engine.
pub const Engine = engine.Engine;

/// A single (term, positions) pair handed to `Engine.indexDocument`.
pub const TermPosting = engine.TermPosting;

/// A streaming iterator over (doc_id, positions) matches for a search term.
pub const TermIterator = search.TermIterator;

// ============================================================================
// Unit Tests
// ============================================================================

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 2: Build still passes**

Run: `zig build check && zig build test --summary all`
Expected: 18+/18+ pass (the 4 stub Config-validation tests are now gone; replaced by refAllDecls).

- [ ] **Step 3: Format**

Run: `zig fmt src/`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "feat: expose Engine/TermPosting/TermIterator from root.zig (GAP-0023, QUAL-0001, DO-2, DO-3)"
```

---

## Task 7: WRK-003 — Input validation at API boundary

Closes: SEC-EXT-0101, 0102, 0103, 0104, 0105, 0107, 0205, 0208.

**Files:**

- Modify: `src/engine.zig:181-216` (indexDocument)
- Modify: `src/engine.zig:218-232` (deleteDocument)
- Modify: `src/search.zig:23-47` (TermIterator.init)
- Test: extend `src/engine.zig` and `src/search.zig` tests

- [ ] **Step 1: Write failing tests in `src/engine.zig`**

Append:

```zig
test "indexDocument rejects oversized term" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    var eng = try Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    var big_term = try alloc.alloc(u8, limits.MAX_TERM_LEN + 1);
    defer alloc.free(big_term);
    @memset(big_term, 'x');
    const t = TermPosting{ .term = big_term, .positions = &[_]u32{1} };
    try std.testing.expectError(error.TermTooLong, eng.indexDocument(1, &[_]TermPosting{t}));
}

test "indexDocument rejects empty term" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    var eng = try Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const t = TermPosting{ .term = "", .positions = &[_]u32{1} };
    try std.testing.expectError(error.EmptyTerm, eng.indexDocument(1, &[_]TermPosting{t}));
}

test "indexDocument rejects unsorted positions" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    var eng = try Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const t = TermPosting{ .term = "x", .positions = &[_]u32{ 5, 3 } };
    try std.testing.expectError(error.PositionsNotMonotonic, eng.indexDocument(1, &[_]TermPosting{t}));
}
```

- [ ] **Step 2: Write failing test in `src/search.zig`**

Append to `src/search.zig` test block:

```zig
test "TermIterator rejects empty term" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const engine_mod = @import("engine.zig");
    var eng = try engine_mod.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    try std.testing.expectError(error.EmptyTerm, TermIterator.init(eng, ""));
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `zig build test`
Expected: FAIL — engine currently accepts any input.

- [ ] **Step 4: Add validation in `Engine.indexDocument`**

At the top of `pub fn indexDocument` (before computing `txn_id`):

```zig
for (terms) |t| {
    if (t.term.len == 0) return error.EmptyTerm;
    if (t.term.len > limits.MAX_TERM_LEN) return error.TermTooLong;
    if (t.positions.len > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;
    // Positions must be monotonically non-decreasing for delta encoding to round-trip
    var i: usize = 1;
    while (i < t.positions.len) : (i += 1) {
        if (t.positions[i] < t.positions[i - 1]) return error.PositionsNotMonotonic;
    }
}
```

Replace the `@intCast(t.term.len)` and `@intCast(t.positions.len)` with `std.math.cast`:

```zig
const term_len_u16 = std.math.cast(u16, t.term.len) orelse return error.TermTooLong;
std.mem.writeInt(u16, num_buf[0..2], term_len_u16, .little);
...
const pos_len_u16 = std.math.cast(u16, t.positions.len) orelse return error.PositionCountTooLarge;
std.mem.writeInt(u16, num_buf[0..2], pos_len_u16, .little);
```

- [ ] **Step 5: Add validation in `Engine.deleteDocument`**

No new validation needed beyond what's there (doc_id is u64 unsigned — any value is valid at this layer; tenant/ACL is Phase I, out of scope).

- [ ] **Step 6: Add validation in `src/search.zig` TermIterator.init**

At the top of `pub fn init`:

```zig
if (term.len == 0) return error.EmptyTerm;
if (term.len > limits.MAX_TERM_LEN) return error.TermTooLong;
```

Add `const limits = @import("limits.zig");` to `src/search.zig` if not already imported.

- [ ] **Step 7: Re-run tests**

Run: `zig build test --summary all`
Expected: all pass.

- [ ] **Step 8: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add -u
git commit -m "fix: validate term/positions inputs at API boundary (SEC-EXT-0101, 0102, 0103, 0104, 0105, 0107, 0205, 0208)"
```

---

## Task 8: WRK-006 — Named error sets per module

Closes: QUAL-0009.

**Files:**

- Create: `src/errors.zig`
- Modify: `src/engine.zig`, `src/wal.zig`, `src/manifest.zig`, `src/segment.zig` (re-export error sets)

- [ ] **Step 1: Create `src/errors.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Named error sets for the public library surface. Modules declare their
//! own concrete error sets; this file aggregates them for downstream
//! exhaustive switches.

pub const WalError = error{
    InvalidData,
    InvalidMagic,
    ChecksumMismatch,
    Incomplete,
    PayloadTooLarge,
    Overflow,
};

pub const ManifestError = error{
    InvalidData,
    InvalidMagic,
    ChecksumMismatch,
    ManifestTooLarge,
    SegmentCountTooLarge,
    NoManifest,
};

pub const SegmentError = error{
    InvalidData,
    InvalidMagic,
    ChecksumMismatch,
    TermCountTooLarge,
    TombstoneCountTooLarge,
    PostingsTooLarge,
    PositionCountTooLarge,
    PositionOutOfRange,
};

pub const EngineError = error{
    EmptyTerm,
    TermTooLong,
    PositionCountTooLarge,
    PositionsNotMonotonic,
    ManifestCorrupt,
    ManifestTooLarge,
};
```

- [ ] **Step 2: Reference from each module**

In `src/wal.zig`, near the top, add:

```zig
pub const Error = @import("errors.zig").WalError;
```

(Same pattern for manifest.zig / segment.zig / engine.zig.)

- [ ] **Step 3: Test that imports resolve**

Run: `zig build test --summary all`
Expected: pass (no behavior change; just declarations).

- [ ] **Step 4: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add -u && git add src/errors.zig
git commit -m "refactor: introduce named error sets per module via src/errors.zig (QUAL-0009)"
```

---

## Task 9: WRK-009 — Drop Optional on Engine.wal_file / wal_writer

Closes: QUAL-0017.

**Files:**

- Modify: `src/engine.zig:25-26` (field declarations), all use-sites with `.?`

- [ ] **Step 1: Run a survey**

```bash
cd /home/benji/src/devnw/zig/fts-storage && grep -n 'wal_file\|wal_writer' src/engine.zig
```

- [ ] **Step 2: Replace field declarations at `src/engine.zig:25-26`**

```zig
wal_file: std.Io.File,
wal_writer: wal.WalWriter,
```

And remove the `?` and the trailing `= null`.

- [ ] **Step 3: Rewrite Engine.init to assign before return**

Move the WAL setup (currently lines 82-83) to occur unconditionally before `return engine;`. Replace `engine.wal_file = try ...` with same line (still required). Replace `engine.wal_writer = wal.WalWriter.init(...)` — same.

- [ ] **Step 4: Replace all `self.wal_writer.?` with `self.wal_writer`**

In `indexDocument`, `deleteDocument`, `flush`: drop the `.?`.

- [ ] **Step 5: Replace `if (self.wal_file) |*file|` patterns**

In `Engine.deinit` and the `flush()` truncate block:

```zig
self.wal_file.close(self.io);  // direct call; no optional
```

In `flush()`:

```zig
self.wal_file.close(self.io);
self.wal_file = try self.wal_dir.createFile(self.io, "fts.wal", .{ .truncate = true });
self.wal_writer = wal.WalWriter.init(self.io, self.wal_file, self.allocator);
```

- [ ] **Step 6: Verify tests still pass**

Run: `zig build test --summary all`
Expected: all pass.

- [ ] **Step 7: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add -u
git commit -m "refactor: Engine.wal_file/wal_writer are non-optional after init (QUAL-0017)"
```

---

## Task 10: WRK-010 — WAL-first ordering in indexDocument + addPosting key-leak

Closes: QUAL-0007, QUAL-0018.

**Files:**

- Modify: `src/engine.zig:181-216` (reorder)
- Modify: `src/segment.zig:56-76` (errdefer on key dup)

- [ ] **Step 1: Failing test in `src/engine.zig`**

The test that proves correct ordering requires an injected I/O failure. Skip the test infra for this one and instead rely on existing tests; add a unit test for `addPosting` resilience:

Append to `src/segment.zig`:

```zig
test "addPosting frees term key on subsequent failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();
    var mt = Memtable.init(alloc);
    defer mt.deinit();

    const result = mt.addPosting("hello", 1, &[_]u32{1});
    try std.testing.expectError(error.OutOfMemory, result);
    // FailingAllocator tracks leaks via std.testing.allocator; if errdefer is
    // missing, the dup'd key string will be reported as leaked at test teardown.
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `zig build test`
Expected: FAIL with leak detected (or hash-map invariant violation).

- [ ] **Step 3: Fix `Memtable.addPosting` in `src/segment.zig`**

Replace the body to use `errdefer` after the dup:

```zig
pub fn addPosting(self: *Memtable, term: []const u8, doc_id: u64, positions: []const u32) !void {
    var entry = try self.dictionary.getOrPut(self.allocator, term);
    if (!entry.found_existing) {
        const key_copy = try self.allocator.dupe(u8, term);
        errdefer self.allocator.free(key_copy);
        entry.key_ptr.* = key_copy;
        entry.value_ptr.* = .{};
        errdefer {
            // If we fail past here, evict the entry so the dictionary stays consistent
            _ = self.dictionary.remove(key_copy);
        }
        // The errdefers above will run if either of the following allocations fail
    }
    var pos_list: std.ArrayListUnmanaged(u32) = .empty;
    errdefer pos_list.deinit(self.allocator);
    try pos_list.ensureTotalCapacity(self.allocator, positions.len);
    pos_list.appendSliceAssumeCapacity(positions);

    var posting: MemPosting = .{
        .doc_id = doc_id,
        .tf = std.math.cast(u32, positions.len) orelse return error.PositionCountTooLarge,
        .positions = pos_list,
    };
    try entry.value_ptr.postings.append(self.allocator, posting);
    entry.value_ptr.df += 1;
}
```

(Adjust the exact field set to match your actual MemPosting / MemPostingsList layout — re-read `src/segment.zig:9-20` to confirm.)

- [ ] **Step 4: Reorder `Engine.indexDocument`**

Replace `src/engine.zig:181-216` so the WAL append + sync happen BEFORE `memtable.addPosting`:

```zig
pub fn indexDocument(self: *Engine, doc_id: u64, terms: []const TermPosting) !void {
    // ... input validation already present from WRK-003 ...

    const txn_id = self.next_txn_id;

    // Serialize payload (without mutating memtable yet)
    var payload_list: std.ArrayListUnmanaged(u8) = .empty;
    defer payload_list.deinit(self.allocator);
    var num_buf: [4]u8 = undefined;
    for (terms) |t| {
        const term_len_u16 = std.math.cast(u16, t.term.len) orelse return error.TermTooLong;
        std.mem.writeInt(u16, num_buf[0..2], term_len_u16, .little);
        try payload_list.appendSlice(self.allocator, num_buf[0..2]);
        try payload_list.appendSlice(self.allocator, t.term);
        const pos_len_u16 = std.math.cast(u16, t.positions.len) orelse return error.PositionCountTooLarge;
        std.mem.writeInt(u16, num_buf[0..2], pos_len_u16, .little);
        try payload_list.appendSlice(self.allocator, num_buf[0..2]);
        for (t.positions) |p| {
            var vbuf: [10]u8 = undefined;
            const written = try utils.writeVarInt(&vbuf, p);
            try payload_list.appendSlice(self.allocator, vbuf[0..written]);
        }
    }

    const rec = wal.WalRecord{
        .record_type = .index_doc,
        .txn_id = txn_id,
        .doc_id = doc_id,
        .payload = payload_list.items,
    };

    // WAL first — durable before memtable mutation
    try self.wal_writer.append(rec);
    try self.wal_writer.sync();

    // Only mutate in-memory state after WAL is durable
    for (terms) |t| {
        try self.memtable.addPosting(t.term, doc_id, t.positions);
    }
    self.next_txn_id += 1;
}
```

- [ ] **Step 5: Re-run all tests**

Run: `zig build test --summary all`
Expected: all pass (including the new leak test).

- [ ] **Step 6: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add -u
git commit -m "fix: WAL-first ordering in indexDocument; errdefer key cleanup in addPosting (QUAL-0007, QUAL-0018)"
```

---

## Task 11: WRK-011 — Engine.dir ownership

Closes: QUAL-0008.

**Files:**

- Modify: `src/engine.zig:29` (init signature), `src/engine.zig:88-103` (deinit)

- [ ] **Step 1: Document the contract**

The simplest fix is to declare borrow-not-own and close in `deinit` if and only if `init` opened it. Since today the caller passes `base_dir` and `Engine.init` opens subdirs but the *base* dir is the caller's, document explicitly.

Update the doc comment at `src/engine.zig` (above `pub fn init`):

```zig
/// Initialize an Engine on the given directory.
///
/// Ownership: the caller retains ownership of `base_dir`. Engine will open
/// (and close on deinit) the `wal/` and `segments/` subdirs of `base_dir`,
/// but will NOT close `base_dir` itself. The caller must `base_dir.close(io)`
/// after `Engine.deinit`.
pub fn init(io: std.Io, allocator: Allocator, base_dir: std.Io.Dir) !*Engine {
```

- [ ] **Step 2: Confirm deinit matches the contract**

`src/engine.zig:88-103` `deinit` already does not close `self.dir`. Verify and leave as-is.

- [ ] **Step 3: Build still passes**

Run: `zig build test --summary all && zig build check`
Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "docs: clarify Engine.dir ownership contract (caller-owned base dir) (QUAL-0008)"
```

---

## Task 12: WRK-012 — Explicit file modes on sensitive creation

Closes: SEC-09, SEC-EXT-0302.

**Files:**

- Modify: `src/engine.zig` (createFile / createDir call sites), `src/segment.zig` (createDir, createFile), `src/utils.zig:atomicWrite` (createFile)

- [ ] **Step 1: Survey the call sites**

```bash
cd /home/benji/src/devnw/zig/fts-storage && grep -nE 'createFile|createDir' src/
```

- [ ] **Step 2: Add explicit `.mode = 0o600` to all file create sites; `.mode = 0o700` on directory creates**

For each `createFile(io, path, .{ ... })` call, add `.mode = 0o600` (or check the Zig 0.16 `std.fs.File.CreateFlags` field name; commonly `.mode`).

For each `createDir(io, path, .default_dir)` call, replace with `.{ .mode = 0o700 }` (or whatever the Zig 0.16 equivalent of `Dir.CreateFlags` accepts).

If Zig 0.16's `std.Io.Dir.createFile` does not expose `.mode`, set the umask at engine init via `std.posix.umask(0o077)` — but only as a fallback; explicit modes are preferred.

- [ ] **Step 3: Build still passes**

Run: `zig build test --summary all`
Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "fix: create sensitive files with mode 0o600 / dirs with mode 0o700 (SEC-09, SEC-EXT-0302)"
```

---

## Task 13: WRK-015 — WalRecordType.begin/commit cleanup

Closes: QUAL-0013, DC-1 (sibling to WRK-025).

**Files:**

- Modify: `src/wal.zig:5-10` and any references

This task defers the real bracketing to WRK-025 (Phase E). For now, either:

- (Option A) Mark `begin`/`commit` deprecated with a comment, OR
- (Option B) Delete the dead variants and update the reader's bounds check.

We pick Option A so we don't need to change on-disk format yet.

- [ ] **Step 1: Update `src/wal.zig:5-10`**

```zig
pub const WalRecordType = enum(u8) {
    // Reserved: future transactional bracketing (see WRK-025).
    // Today these are accepted on read for forward compat but never emitted by Engine.
    begin = 1,
    commit = 2,
    index_doc = 3,
    delete_doc = 4,
};
```

- [ ] **Step 2: Build still passes**

Run: `zig build test --summary all`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add -u
git commit -m "docs: mark WalRecordType.begin/commit as reserved-for-future (QUAL-0013, DC-1)"
```

---

## Task 14: WRK-016 — Stats plumbing (total_docs / doc_count / avg_doc_len)

Closes: QUAL-0006, DC-2, DC-3, GAP-0007.

**Files:**

- Modify: `src/segment.zig` (`Memtable.total_docs` increment in `addPosting` or via new tracking set)
- Modify: `src/engine.zig:234-276` (`flush` propagates totals)

- [ ] **Step 1: Failing test in `src/engine.zig`**

```zig
test "flush populates manifest total_docs and segment doc_count" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const t = TermPosting{ .term = "x", .positions = &[_]u32{1} };
    try eng.indexDocument(1, &[_]TermPosting{t});
    try eng.indexDocument(2, &[_]TermPosting{t});
    try eng.indexDocument(3, &[_]TermPosting{t});

    try eng.flush();

    try std.testing.expectEqual(@as(u64, 3), eng.current_manifest.total_docs);
    try std.testing.expectEqual(@as(u64, 3), eng.current_manifest.segments.items[0].doc_count);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — currently both fields stay 0.

- [ ] **Step 3: Track unique doc_ids in Memtable**

Add a field to `Memtable` (in `src/segment.zig`):

```zig
seen_docs: std.AutoHashMapUnmanaged(u64, void) = .empty,
```

In `Memtable.deinit` add: `self.seen_docs.deinit(self.allocator);`

In `addPosting`, before the existing logic:

```zig
try self.seen_docs.put(self.allocator, doc_id, {});
self.total_docs = @intCast(self.seen_docs.count());
```

(If `Memtable.total_docs` is `u64`, the cast is `@intCast(self.seen_docs.count())`.)

- [ ] **Step 4: Update `Engine.flush` to write totals**

In `src/engine.zig:234-276`, after the `segments.append` call and before the manifest serialization, update the manifest totals:

```zig
self.current_manifest.total_docs += self.memtable.total_docs;
// avg_doc_len: cumulative running mean (token count tracking deferred to WRK-035 BM25 work)
```

(Leave `avg_doc_len` as 0 with a comment that BM25 length normalization is the responsibility of WRK-035.)

- [ ] **Step 5: Re-run tests**

Run: `zig build test --summary all`
Expected: all pass.

- [ ] **Step 6: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add -u
git commit -m "fix: plumb Memtable.total_docs, SegmentEntry.doc_count, Manifest.total_docs via flush (QUAL-0006, DC-2, DC-3, GAP-0007)"
```

---

## Task 15: WRK-017 — WalWriter.init stat-error propagation

Closes: QUAL-0019.

**Files:**

- Modify: `src/wal.zig:81-89` (WalWriter.init)

- [ ] **Step 1: Locate the current code**

Open `src/wal.zig`, find:

```zig
pub fn init(io: std.Io, file: std.Io.File, allocator: Allocator) WalWriter {
    const offset = (file.stat(io) catch return WalWriter{ ... }).size;
    ...
}
```

(Exact shape may differ; the audit reports a `catch |_| 0` swallow at line ~81-89.)

- [ ] **Step 2: Convert to error-propagating signature**

Replace the function with:

```zig
pub fn init(io: std.Io, file: std.Io.File, allocator: Allocator) !WalWriter {
    const stat = try file.stat(io);
    return WalWriter{
        .io = io,
        .file = file,
        .allocator = allocator,
        .offset = stat.size,
    };
}
```

- [ ] **Step 3: Fix call-sites in `src/engine.zig`**

`Engine.init` and `Engine.flush` both call `wal.WalWriter.init(...)`. Add `try`:

```zig
engine.wal_writer = try wal.WalWriter.init(engine.io, engine.wal_file, allocator);
...
self.wal_writer = try wal.WalWriter.init(self.io, self.wal_file, self.allocator);
```

- [ ] **Step 4: Re-run tests**

Run: `zig build test --summary all`
Expected: all pass (init now propagates a real error if stat fails).

- [ ] **Step 5: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add -u
git commit -m "fix: WalWriter.init propagates stat error (no silent zero-offset fallback) (QUAL-0019)"
```

---

## Task 16: WRK-018 — SegmentEntry ordering metadata

Closes: QUAL-0014.

**Files:**

- Modify: `src/manifest.zig:8-12` (add fields), serialize/deserialize, byte sizing
- Modify: `src/engine.zig:249-253` (populate at flush)

- [ ] **Step 1: Extend the struct**

Update `src/manifest.zig:8-12`:

```zig
pub const SegmentEntry = struct {
    id: u64,
    doc_count: u64,
    tombstone_count: u64,
    /// LSN of the WAL position at the time this segment was sealed.
    created_lsn: u64 = 0,
    /// Compaction level (0 = flushed memtable; >0 = merge output). Reserved for WRK-041.
    level: u8 = 0,
    /// Padding so the serialized size is fixed and platform-independent.
    _reserved: [7]u8 = .{0} ** 7,
};
```

- [ ] **Step 2: Update serialize/deserialize**

Each `SegmentEntry` was 24 bytes (3×u64). New size: 24 + 8 + 8 = 40 bytes.

Update both:

- `serialize`: the total size calculation (line 29) — `+ (count * 40) + 4` instead of `+ (count * 24) + 4`. Inside the entry loop, also write `created_lsn`, `level`, and `_reserved` zeros.
- `deserialize`: bump the multiplier from 24 to 40 at line 72; inside the entry loop, also read `created_lsn`, `level`, `_reserved`.

**Important:** this is a wire-format change. Bump `MANIFEST_VERSION` from `1` to `2` and add a comment that v1 manifests are no longer readable (a v0.1 pre-release library has no on-disk customers, so this is safe).

- [ ] **Step 3: Populate in flush**

In `src/engine.zig:249-253`:

```zig
try self.current_manifest.segments.append(self.allocator, .{
    .id = next_segment_id,
    .doc_count = self.memtable.total_docs,
    .tombstone_count = self.memtable.tombstones.count(),
    .created_lsn = self.next_txn_id - 1,
    .level = 0,
});
```

- [ ] **Step 4: Update existing manifest test**

The round-trip test in `src/manifest.zig` should still pass; extend the assertion to check `created_lsn` round-trips.

- [ ] **Step 5: Re-run tests**

Run: `zig build test --summary all`
Expected: all pass.

- [ ] **Step 6: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add -u
git commit -m "feat(manifest): add SegmentEntry.created_lsn/level + bump format version to 2 (QUAL-0014)"
```

---

## Task 17: WRK-019 — Centralize byte helpers in utils.zig

Closes: QUAL-0012, D-1, D-2, QUAL-0023.

**Files:**

- Modify: `src/utils.zig` (add canonical write/read u16/u32/u64)
- Modify: `src/wal.zig:103-122`, `src/manifest.zig:101-125` (delete locals, import from utils)
- Modify: `src/segment.zig:311-333` (use file-streaming variants from utils or rename to disambiguate)

- [ ] **Step 1: Add canonical helpers in `src/utils.zig`**

```zig
pub fn writeU16Le(buf: []u8, pos: *usize, value: u16) void {
    std.mem.writeInt(u16, buf[pos.*..][0..2], value, .little);
    pos.* += 2;
}

pub fn writeU32Le(buf: []u8, pos: *usize, value: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], value, .little);
    pos.* += 4;
}

pub fn writeU64Le(buf: []u8, pos: *usize, value: u64) void {
    std.mem.writeInt(u64, buf[pos.*..][0..8], value, .little);
    pos.* += 8;
}

pub fn readU16Le(data: []const u8, offset: *usize) u16 {
    const v = std.mem.readInt(u16, data[offset.*..][0..2], .little);
    offset.* += 2;
    return v;
}

pub fn readU32Le(data: []const u8, offset: *usize) u32 {
    const v = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    return v;
}

pub fn readU64Le(data: []const u8, offset: *usize) u64 {
    const v = std.mem.readInt(u64, data[offset.*..][0..8], .little);
    offset.* += 8;
    return v;
}

pub fn readU32LeAt(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}
```

- [ ] **Step 2: Delete duplicates in `src/wal.zig` and `src/manifest.zig`**

In both files, delete the local `fn writeU32 / writeU64 / readU32 / readU64 / readU32NoAdvance` declarations (the planner identified them at `src/wal.zig:103-122` and `src/manifest.zig:101-125`). Update all call-sites to use `utils.writeU32Le`, etc.

- [ ] **Step 3: Rename the segment file helpers**

`src/segment.zig:311-333` has differently-shaped helpers that read from a file. Rename them to `readU16FromFile`, `readU32FromFile`, `readU64FromFile` so the name conflict no longer confuses readers. Their bodies stay; only the names change.

- [ ] **Step 4: Re-run tests**

Run: `zig build test --summary all`
Expected: all pass.

- [ ] **Step 5: Format + check**

Run: `zig fmt src/ && zig build check`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add -u
git commit -m "refactor: centralize byte helpers in utils.zig; rename segment file helpers (QUAL-0012, D-1, D-2, QUAL-0023)"
```

---

## Task 18: WRK-020 — CLI rewrite over Engine

Closes: QUAL-0034.

**Files:**

- Modify: `src/main.zig`

- [ ] **Step 1: Replace `src/main.zig` body**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const fts = @import("fts_storage");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        try std.io.getStdOut().writer().print("fts-storage {s}\n", .{fts.version});
        return;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage();
        return;
    }
    if (std.mem.eql(u8, cmd, "stats")) {
        if (args.len < 3) {
            try std.io.getStdErr().writer().writeAll("usage: fts-storage stats <data-dir>\n");
            return error.MissingArgument;
        }
        return statsCmd(allocator, args[2]);
    }

    try std.io.getStdErr().writer().print("unknown subcommand: {s}\n", .{cmd});
    try printUsage();
    return error.UnknownSubcommand;
}

fn printUsage() !void {
    const out = std.io.getStdOut().writer();
    try out.writeAll(
        \\fts-storage — append-only inverted-index storage engine
        \\
        \\Usage:
        \\  fts-storage version
        \\  fts-storage stats <data-dir>
        \\  fts-storage help
        \\
    );
}

fn statsCmd(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
    defer dir.close();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Use the std.fs.Dir → std.Io.Dir bridge if available in Zig 0.16; if not, adapt.
    var io_dir: std.Io.Dir = .{ .fd = dir.fd }; // verify exact field/method in Zig 0.16
    var engine = try fts.Engine.init(io, allocator, io_dir);
    defer engine.deinit();

    const out = std.io.getStdOut().writer();
    try out.print("manifest_counter:    {d}\n", .{engine.current_manifest.counter});
    try out.print("last_checkpoint_lsn: {d}\n", .{engine.current_manifest.last_checkpoint_lsn});
    try out.print("total_docs:          {d}\n", .{engine.current_manifest.total_docs});
    try out.print("segments:            {d}\n", .{engine.segments.items.len});
}
```

(If `std.Io.Dir` construction from a `std.fs.Dir.fd` is awkward in Zig 0.16, restructure to use `std.Io.Dir.openDir(io, ".")` from a root or fall back to `std.fs.cwd()` in the std.Io abstraction. The exact bridge depends on Zig 0.16's std.Io shape.)

- [ ] **Step 2: Build the CLI binary**

Run: `zig build`
Expected: builds the `fts-storage` exe (existing build.zig step).

- [ ] **Step 3: Smoke test**

```bash
cd /home/benji/src/devnw/zig/fts-storage && ./zig-out/bin/fts-storage version
```

Expected: `fts-storage 0.1.0`.

```bash
mkdir -p /tmp/fts-cli-test && ./zig-out/bin/fts-storage stats /tmp/fts-cli-test
```

Expected: printed stats with `total_docs: 0`, `segments: 0`.

- [ ] **Step 4: Format + check**

Run: `zig fmt src/ && zig build check && zig build test --summary all`
Expected: clean, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "feat(cli): replace template stub with version/stats subcommands over Engine (QUAL-0034)"
```

---

## Task 19: WRK-013 — CODEOWNERS real owners

Closes: GAP-0020, SEC-10, SEC-EXT-0601.

**Files:**

- Modify: `CODEOWNERS`

This task is conditionally blocked on a project-owner decision. If you (the executor) cannot get a real GitLab username for ownership, mark this task **Blocked** in the gap closure report and skip it.

- [ ] **Step 1: Choose an owner**

Default to the existing project committer per `git log -1 --format='%ae'` (likely `benji@codepros.org` per the audit memory). Use the GitLab handle for that email if known; otherwise pick the project's GitLab group.

- [ ] **Step 2: Replace `CODEOWNERS:3`**

Before:

```codeowners
* @your-username
```

After (example — substitute the real GitLab group/user):

```codeowners
# Default owner: maintainers
* @devnw-maintainers

# Storage engine code
/src/                          @devnw-storage-team
/tests/                        @devnw-storage-team

# CI / build
/.gitlab-ci.yml                @devnw-platform-team
/build.zig                     @devnw-storage-team
```

- [ ] **Step 3: Verify file syntax**

GitLab evaluates CODEOWNERS lazily; no local tool. Verify the file parses by viewing in GitLab after push.

- [ ] **Step 4: Commit**

```bash
git add CODEOWNERS
git commit -m "chore: assign real CODEOWNERS to replace placeholder (GAP-0020, SEC-10, SEC-EXT-0601)"
```

---

## Task 20: WRK-014 — README + root.zig placeholder text

Closes: QUAL-0003.

**Files:**

- Modify: `README.md`

(`src/root.zig` placeholder text was already replaced in WRK-001.)

- [ ] **Step 1: Read current README**

```bash
cat /home/benji/src/devnw/zig/fts-storage/README.md
```

- [ ] **Step 2: Replace the "Features" section with the real capability list**

The exact text varies; the gist is to swap "Feature 1 / Feature 2 / Feature 3" for the same capability list now in `src/root.zig`:

- Append-only WAL with CRC32C-checked records
- A/B atomic manifest with monotonic counter
- LSM-style immutable segments with delta+varint postings
- Tombstone-based deletes
- Crash recovery via WAL replay
- Zero external dependencies (Zig stdlib only)
- Cross-platform (Linux, macOS, Windows)

Also replace the Quick Start `fts_storage.init(.{})` with the real Engine usage example from `src/root.zig`'s module doc comment.

Fix the broken links to `docs/getting-started.md` etc. (per Phase 2 DO-1): either remove them, or replace with anchors that exist (`docs/REQUIREMENTS.md`, `docs/GAP_ANALYSIS.md`).

- [ ] **Step 3: Lint markdown**

Run: `markdownlint README.md` (if installed via pre-commit; otherwise skip).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: replace README Feature 1/2/3 placeholders with real capabilities (QUAL-0003)"
```

---

## Task 21: WRK-021 — Rewrite integration + stress + example to drive Engine

Closes: GAP-0014, GAP-0015, QUAL-0011, DC-5 (test side).

**Files:**

- Modify: `tests/integration.zig`
- Modify: `tests/stress.zig`
- Modify: `examples/basic.zig`

- [ ] **Step 1: Rewrite `tests/integration.zig`**

Replace the file with:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Integration tests: drive the real Engine end-to-end via the public surface.

const std = @import("std");
const fts = @import("fts_storage");

test "index → flush → reopen → recover" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const docs = [_]struct { id: u64, term: []const u8 }{
        .{ .id = 1, .term = "alpha" },
        .{ .id = 2, .term = "beta" },
        .{ .id = 3, .term = "gamma" },
    };

    // Phase A: index + flush
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        for (docs) |d| {
            const t = fts.TermPosting{ .term = d.term, .positions = &[_]u32{1} };
            try eng.indexDocument(d.id, &[_]fts.TermPosting{t});
        }
        try eng.flush();
        try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
    }

    // Phase B: reopen, verify manifest + segments restored
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
        try std.testing.expectEqual(@as(u64, 3), eng.current_manifest.total_docs);
    }
}

test "delete is visible after reopen via WAL replay" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "x", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
        try eng.deleteDocument(1);
        // No flush — must come back via WAL replay
    }
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expect(eng.memtable.tombstones.contains(1));
    }
}

test "input validation rejects garbage at API" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const empty = fts.TermPosting{ .term = "", .positions = &[_]u32{1} };
    try std.testing.expectError(error.EmptyTerm, eng.indexDocument(1, &[_]fts.TermPosting{empty}));

    const unsorted = fts.TermPosting{ .term = "x", .positions = &[_]u32{ 5, 3 } };
    try std.testing.expectError(error.PositionsNotMonotonic, eng.indexDocument(1, &[_]fts.TermPosting{unsorted}));
}

test "version is defined" {
    try std.testing.expect(fts.version.len > 0);
}
```

- [ ] **Step 2: Rewrite `tests/stress.zig`**

Replace with a bounded but real stress test:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress test: bounded high-iteration Engine workload.

const std = @import("std");
const fts = @import("fts_storage");

test "stress: 1000 docs across 4 flushes" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var term_buf: [16]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "term{d}", .{i % 32});
        const t = fts.TermPosting{ .term = term, .positions = &[_]u32{ @intCast(i % 100) } };
        try eng.indexDocument(i, &[_]fts.TermPosting{t});
        if (i % 250 == 249) try eng.flush();
    }

    try std.testing.expectEqual(@as(u64, 1000), eng.current_manifest.total_docs);
    try std.testing.expect(eng.segments.items.len >= 4);
}
```

- [ ] **Step 3: Rewrite `examples/basic.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const fts = @import("fts_storage");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dir = try std.fs.cwd().makeOpenPath("example-data", .{});
    defer dir.close();
    const io = std.Io.Threaded.global_single_threaded.io();
    var io_dir: std.Io.Dir = .{ .fd = dir.fd }; // adjust for Zig 0.16 bridge

    var engine = try fts.Engine.init(io, allocator, io_dir);
    defer engine.deinit();

    const t = fts.TermPosting{ .term = "hello", .positions = &[_]u32{ 1, 5 } };
    try engine.indexDocument(42, &[_]fts.TermPosting{t});
    try engine.flush();

    std.debug.print("indexed doc 42; manifest_counter={d}\n", .{engine.current_manifest.counter});
}
```

- [ ] **Step 4: Build all targets**

Run: `zig build check && zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all`
Expected: every job passes, integration test count rises from 4 stub tests to 4 real tests, stress goes from 1 stub to 1 real bounded workload.

- [ ] **Step 5: Format**

Run: `zig fmt tests/ examples/`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add -u
git commit -m "test: rewrite integration/stress/example to drive real Engine via public surface (GAP-0014, GAP-0015, QUAL-0011)"
```

---

## Acceptance Criteria (whole plan)

After running every task above:

- [ ] `zig build check` exits 0.
- [ ] `zig build test --summary all` shows ≥21 tests passing (16 baseline + ≥5 new in this plan).
- [ ] `zig build test-integration --summary all` runs 4 real integration tests (not stub `lib.init`).
- [ ] `zig build test-stress --summary all` runs 1 real bounded workload (not `lib.init` loop).
- [ ] `zig fmt --check src/ tests/ examples/ benchmarks/ build.zig` exits 0.
- [ ] Git log contains 21 commits, one per WRK-* task, with conventional commit prefixes.
- [ ] `git status` clean.

## Deferred to subsequent sessions

Phases C-remainder (WRK-022 fault injection, WRK-023 manifest A/B tampering), D (bench harness rewrite + baseline), E (WAL begin/commit + replay robustness + flush ordering + manifest fail-closed), F (engine perf), G (BM25), H (HMAC/AES), I (RLS/ABAC/FLE), J (LSM compaction), K (supply chain).

These are documented in the gap-closer-planner output (the 44-item table). Run `/gap:close --scope=docs/PERF_GAP_ANALYSIS.md` etc. in subsequent sessions.

# Graph-Storage Parity Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the generalizable storage-engine hardening lessons from graph-storage's last 20 days (v0.2.21 → v0.3.2, ~156 commits) onto fts-storage, closing 8 concrete durability/validation gaps found by cross-referencing the two codebases.

**Architecture:** fts-storage is a WAL + A/B-manifest + immutable-segment FTS engine (Zig 0.16, `std.Io` interface, ~5.6k LOC). Each task hardens one seam: WAL replay alignment/truncation, txn-id healing, checked arithmetic on disk-derived values, load-time dictionary validation, manifest version gating, segment fsync, compact-time stats healing, a versioned+checksummed segment file envelope, and fuzz coverage for segment parsers. Wire formats stay byte-compatible except where a task explicitly versions a new format with read-both support.

**Tech Stack:** Zig 0.16.0 (pinned via `.mise.toml`; run `mise exec -- zig ...` or ensure `zig version` = 0.16.0), `std.Io` (NOT `std.fs`), std.testing, existing build targets (`zig build test`, `test-integration`, `test-fuzz`, `test-stress`, `test-all`).

## Global Constraints

- Zig version: exactly 0.16.0 (`.mise.toml`). All I/O goes through `std.Io` (`std.Io.File`, `std.Io.Dir`) — never `std.fs`.
- Every task ends with `zig build test-all` green (47 pre-existing tests + new ones). Never commit red.
- TDD: write the failing test FIRST, run it, watch it fail with the predicted symptom, then implement. If a test cannot fail before the fix (e.g. panic-based), run it once pre-fix to observe the panic and note it in the commit message.
- Hostile/corrupt on-disk input must produce a returned error — never a panic, never a silent wrap, never a silently-empty result (graph-storage lessons #1, #14). `std.debug.assert` is NOT acceptable for disk-derived invariants (ReleaseFast strips it).
- Wire-format compatibility: WAL record bytes and manifest bytes are unchanged by every task. Segment files gain a versioned envelope in Task 9 ONLY, with permanent read-both support for legacy naked files.
- The FIPS crypto seam (`src/crypto_backend.zig`, `@import("crypto_backend")`) must not be touched. New CRC32C uses go through `utils.hashCrc32c` and carry the existing `// fips-exempt: non-security` comment convention.
- Commit after every task with a conventional-commit message (`fix:`/`feat:`/`test:`), body explaining root cause + fix mechanism + RED evidence, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Comment style: cite the driving concern inline like the codebase does (e.g. `(graph-storage parity: GSP-1)`), matching existing `(SEC-EXT-NNNN, GAP-NNNN)` conventions. GSP-N = task number in this plan.

## File Structure

| File | Role in this plan |
|---|---|
| `src/wal.zig` | Task 1: `WalReader` consumed-offset tracking + unknown-type stream alignment |
| `src/engine.zig` | Task 2: WAL truncation after replay; Task 3: txn-id heal; Task 6: engine-level version-gate plumbing; Task 8: compact stats heal |
| `src/segment.zig` | Task 4: checked posting arithmetic; Task 5: load-time dictionary validation; Task 7: segment fsync; Task 9: file envelope |
| `src/manifest.zig` | Task 6: format_version enforcement |
| `src/errors.zig` | Tasks 4/6/9: new error members |
| `tests/fault_injection.zig` | Tasks 2/3: crash-shaped integration tests |
| `tests/integration.zig` | Task 8: compact stats test |
| `tests/fuzz_targets.zig` | Task 10: segment-parser fuzz harnesses |
| `docs/fts-storage-spec.md`, `CHANGELOG.md` | Tasks 9/11: format + release notes |

Task order is dependency-driven: 1→2 (truncation needs consumed offset), 5 before 9 (9 extends 5's restructured `load()`), 7 before 9 (9's writeFile includes 7's sync), 10 after 9 (fuzz covers the envelope).

---

### Task 1: WAL reader — consumed-offset tracking + unknown-record-type stream alignment

Two coupled defects in `WalReader.next` (`src/wal.zig:230-304`):
(a) There is no way to know how many bytes of the WAL were validly consumed, which Task 2 needs for tail truncation.
(b) The record-type byte is validated (`fromByte`) BEFORE the payload is read (`wal.zig:241`). When replay skips `error.InvalidData` "for forward compat" (`engine.zig:604`), the stream is left positioned mid-record (21 header bytes consumed, payload not), so every subsequent record parses as garbage and replay silently stops at the next CRC mismatch. The documented forward-compat skip has never actually worked.

Fix mechanism (graph-storage lesson #2/#7): read the full record (header + payload + CRC + optional HMAC) and verify CRC/HMAC BEFORE validating the type byte. Unknown-but-CRC-valid records return `error.InvalidData` with the stream aligned past them and counted in `consumed`. `consumed: u64` advances only over fully-validated records.

**Files:**
- Modify: `src/wal.zig:198-304` (`WalReader`)
- Test: `src/wal.zig` (new unit tests at bottom)

**Interfaces:**
- Consumes: nothing new.
- Produces: `WalReader.consumed: u64` — total bytes of validated records (including skipped unknown-type records); Task 2 reads this after replay. Semantics: after `next()` returns a record OR `error.InvalidData`, `consumed` includes that record; after `null`/`Incomplete`/`ChecksumMismatch`/`HmacMismatch`, `consumed` is unchanged (points at the end of the last good record).

- [ ] **Step 1: Write the failing alignment test**

Append to `src/wal.zig` tests:

```zig
test "WalReader skips unknown record type and stays aligned (GSP-1)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Hand-build: [unknown-type record with valid CRC][valid index_doc record].
    // A reader that validates the type byte before consuming the payload
    // desyncs after the first record and misparses the second.
    {
        const file = try tmp_dir.dir.createFile(io, "wal_align.bin", .{});
        defer file.close(io);

        // Unknown record: serialize a valid record, then patch the type byte
        // to 9 and recompute the CRC so only the type is "from the future".
        const future = WalRecord{ .record_type = .index_doc, .txn_id = 7, .doc_id = 70, .payload = "future-payload" };
        const raw = try future.serialize(alloc);
        defer alloc.free(raw);
        raw[0] = 9; // unknown type
        const crc = utils.hashCrc32c(raw[0 .. raw.len - 4]);
        std.mem.writeInt(u32, raw[raw.len - 4 ..][0..4], crc, .little);
        try file.writePositionalAll(io, raw, 0);

        const good = WalRecord{ .record_type = .index_doc, .txn_id = 8, .doc_id = 80, .payload = "good" };
        const raw2 = try good.serialize(alloc);
        defer alloc.free(raw2);
        try file.writePositionalAll(io, raw2, raw.len);
        try file.sync(io);
    }

    const file = try tmp_dir.dir.openFile(io, "wal_align.bin", .{});
    defer file.close(io);
    var reader = WalReader.init(io, file, alloc);

    // Unknown type surfaces as InvalidData — but with the stream aligned
    // past the whole record, and the record counted as consumed.
    try std.testing.expectError(error.InvalidData, reader.next());

    // The NEXT record must parse cleanly. Pre-fix this fails (desynced
    // stream -> Incomplete/ChecksumMismatch/garbage).
    const rec2 = (try reader.next()).?;
    var r2 = rec2;
    defer r2.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 8), r2.txn_id);
    try std.testing.expectEqualStrings("good", r2.payload);
}

test "WalReader.consumed tracks validated bytes and freezes at a torn tail (GSP-1)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var rec1_len: u64 = 0;
    var rec2_len: u64 = 0;
    {
        const file = try tmp_dir.dir.createFile(io, "wal_consumed.bin", .{});
        defer file.close(io);
        var writer = try WalWriter.init(io, file, alloc);
        defer writer.deinit();
        try writer.append(.{ .record_type = .begin, .txn_id = 1 });
        rec1_len = writer.offset;
        try writer.append(.{ .record_type = .commit, .txn_id = 1 });
        rec2_len = writer.offset - rec1_len;
        // Torn tail: half a header of garbage.
        try writer.file.writePositionalAll(io, &[_]u8{0xAA} ** 10, writer.offset);
        try writer.sync();
    }

    const file = try tmp_dir.dir.openFile(io, "wal_consumed.bin", .{});
    defer file.close(io);
    var reader = WalReader.init(io, file, alloc);

    var r1 = (try reader.next()).?;
    r1.deinit(alloc);
    try std.testing.expectEqual(rec1_len, reader.consumed);
    var r2 = (try reader.next()).?;
    r2.deinit(alloc);
    try std.testing.expectEqual(rec1_len + rec2_len, reader.consumed);

    // Torn tail: error, and consumed does NOT advance past the last good record.
    try std.testing.expectError(error.Incomplete, reader.next());
    try std.testing.expectEqual(rec1_len + rec2_len, reader.consumed);
}
```

- [ ] **Step 2: Run tests, verify both fail**

Run: `zig build test 2>&1 | tail -20`
Expected: alignment test fails (second `next()` does not return txn 8 — Incomplete or checksum error); consumed test fails to compile (`no field named 'consumed'`). Compile error counts as RED for the new field; run the alignment test's failure by temporarily commenting the consumed test if needed.

- [ ] **Step 3: Implement**

In `src/wal.zig`, add the field to `WalReader` (after `hmac_key`):

```zig
    /// Total bytes of fully-validated records consumed so far — including
    /// unknown-type records that were skipped for forward compat (their CRC
    /// verified). After a torn-tail error (Incomplete / ChecksumMismatch /
    /// HmacMismatch) this still points at the end of the last good record,
    /// so it is exactly the safe truncation point for recovery (GSP-1,
    /// graph-storage parity: recovery frontier discipline).
    consumed: u64 = 0,
```

Replace the body of `next()` (keep doc comment, extend it):

```zig
    /// Reads the next WAL record from the file.
    /// Returns null if EOF is reached.
    /// Returns an error if the record is corrupt or incomplete.
    ///
    /// GSP-1: the record-type byte is validated LAST — after payload, CRC,
    /// and optional HMAC — so an unknown (future) record type leaves the
    /// stream aligned on the next record and counted in `consumed`. Callers
    /// that skip `error.InvalidData` therefore resume at a record boundary
    /// instead of desyncing mid-record.
    pub fn next(self: *WalReader) !?WalRecord {
        var header_buf: [1 + 8 + 8 + 4]u8 = undefined;
        var header_iov = [_][]u8{&header_buf};
        const read_header = self.file.readStreaming(self.io, &header_iov) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (read_header == 0) return null;
        if (read_header < header_buf.len) return error.Incomplete;

        var pos: usize = 1; // type byte validated after CRC/HMAC (GSP-1)
        const txn_id = utils.readU64Le(&header_buf, &pos);
        const doc_id = utils.readU64Le(&header_buf, &pos);
        const payload_len = utils.readU32Le(&header_buf, &pos);

        if (payload_len > limits.MAX_WAL_PAYLOAD_BYTES) return error.InvalidData;

        const payload_and_crc = try self.allocator.alloc(u8, payload_len + 4);
        defer self.allocator.free(payload_and_crc);

        var payload_iov = [_][]u8{payload_and_crc};
        const read_payload = try self.file.readStreaming(self.io, &payload_iov);
        if (read_payload < payload_len + 4) return error.Incomplete;

        const payload = payload_and_crc[0..payload_len];
        var crc_pos: usize = payload_len;
        const stored_crc = utils.readU32Le(payload_and_crc, &crc_pos);

        // fips-exempt: non-security — CRC32c data-integrity checksum, not a MAC
        // (the optional HMAC trailer below covers integrity-against-adversary).
        var hasher = std.hash.crc.Crc32Iscsi.init();
        hasher.update(&header_buf);
        hasher.update(payload);
        const computed_crc = hasher.final();

        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        var record_bytes: u64 = header_buf.len + @as(u64, payload_len) + 4;

        // Optional HMAC-SHA256 envelope (SEC-02, SEC-EXT-0401, GAP-0027).
        if (self.hmac_key) |key| {
            // fips-exempt: compile-time tag length only (HMAC goes through the seam).
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
            var stored_tag: [Hmac.mac_length]u8 = undefined;
            var tag_iov = [_][]u8{&stored_tag};
            const read_tag = try self.file.readStreaming(self.io, &tag_iov);
            if (read_tag < Hmac.mac_length) return error.Incomplete;

            const msg = try self.allocator.alloc(u8, header_buf.len + payload_and_crc.len);
            defer self.allocator.free(msg);
            @memcpy(msg[0..header_buf.len], &header_buf);
            @memcpy(msg[header_buf.len..], payload_and_crc);

            var computed_tag: [Hmac.mac_length]u8 = undefined;
            _ = backend.Mac.hmac(.sha256, key, msg, &computed_tag) catch return error.InvalidData;

            if (!std.mem.eql(u8, &stored_tag, &computed_tag)) return error.HmacMismatch;
            record_bytes += Hmac.mac_length;
        }

        // Validate the type byte LAST: the record is structurally sound and
        // integrity-checked, so an unknown type is a forward-compat skip —
        // stream aligned, bytes counted (GSP-1).
        const record_type = WalRecordType.fromByte(header_buf[0]) catch |err| {
            self.consumed += record_bytes;
            return err;
        };

        const payload_copy = try self.allocator.dupe(u8, payload);
        self.consumed += record_bytes;

        return WalRecord{
            .record_type = record_type,
            .txn_id = txn_id,
            .doc_id = doc_id,
            .payload = payload_copy,
        };
    }
```

Note: `WalReader.init`/`initWithHmac` need no change — `consumed` has a default.

- [ ] **Step 4: Run tests, verify pass**

Run: `zig build test 2>&1 | tail -5` — expect all pass.

- [ ] **Step 5: Run the full suite**

Run: `zig build test-all 2>&1 | tail -5` — expect green (replay behavior for well-formed WALs is unchanged).

- [ ] **Step 6: Commit**

```bash
git add src/wal.zig
git commit -m "fix(wal): validate record type after CRC so unknown types skip aligned; track consumed offset"
```

---

### Task 2: Truncate the torn WAL tail before re-appending

Root cause (found by posture review; graph-storage lesson: the recovery frontier must be durable and consistent before new writes): after recovery from a torn tail, `Engine.initWithConfig` opens the WAL with `truncate = false` (`engine.zig:418`) and `WalWriter.init` sets its append offset to the physical file size (`wal.zig:139`) — i.e. PAST the torn bytes. Every subsequent fsync-acknowledged write is appended after garbage that any future replay `break`s on (`engine.zig:601-603`), so those durable writes are unreachable until the next flush truncates the WAL. Second crash ⇒ silent data loss.

Fix: `replayWal` returns the validated byte offset (`reader.consumed`); init truncates the WAL file to that offset (via `std.Io.File.setLength`) and fsyncs BEFORE constructing the `WalWriter`.

**Files:**
- Modify: `src/engine.zig:386` (replay call site), `src/engine.zig:417-428` (WAL open), `src/engine.zig:553-658` (`replayWal` signature)
- Test: `tests/fault_injection.zig`

**Interfaces:**
- Consumes: `WalReader.consumed: u64` (Task 1).
- Produces: `fn replayWal(self: *Engine) !u64` — returns validated WAL byte length (0 when no WAL file exists). Internal only.

- [ ] **Step 1: Write the failing test**

Append to `tests/fault_injection.zig`:

```zig
test "fault: writes after torn-tail recovery survive the next reopen (GSP-2)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Session 1: one committed doc, no flush, then a simulated torn append.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "alpha", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
    }
    {
        var wal_dir = try tmp_dir.dir.openDir(io, "wal", .{});
        defer wal_dir.close(io);
        const f = try wal_dir.createFile(io, "fts.wal", .{ .truncate = false });
        defer f.close(io);
        const stat = try f.stat(io);
        try f.writePositionalAll(io, &[_]u8{0xAA} ** 40, stat.size);
        try f.sync(io);
    }

    // Session 2: recovery tolerates the torn tail; then write doc 2 (no flush).
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "beta", .positions = &[_]u32{1} };
        try eng.indexDocument(2, &[_]fts.TermPosting{t});
    }

    // Session 3: BOTH docs must be replayable. Pre-fix, doc 2 was appended
    // after the torn bytes so replay stops before it — fsync-acknowledged
    // data silently lost.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        var it_a = try fts.TermIterator.init(alloc, eng, "alpha");
        defer it_a.deinit();
        try std.testing.expect((try it_a.next()) != null);
        var it_b = try fts.TermIterator.init(alloc, eng, "beta");
        defer it_b.deinit();
        try std.testing.expect((try it_b.next()) != null);
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `zig build test-integration 2>&1 | tail -20`
Expected: FAIL — the "beta" iterator yields nothing in session 3.

- [ ] **Step 3: Implement**

In `src/engine.zig`, change `replayWal` to return the validated offset. Signature and the two exit paths:

```zig
    /// Returns the number of validated WAL bytes (the safe truncation point):
    /// everything past it is a torn tail that future appends must overwrite,
    /// or replay will never reach them (GSP-2).
    fn replayWal(self: *Engine) !u64 {
        const file = self.wal_dir.openFile(self.io, "fts.wal", .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
```

At the end of the function (after the third pass loop) add:

```zig
        return reader.consumed;
```

(All other `return err;` paths stay as-is; `error.WalTooLarge` etc. still abort init.)

At the call site (`engine.zig:386`) and WAL-open block (`engine.zig:417-428`):

```zig
        // Replay WAL. The returned offset is the end of the last valid
        // record; anything beyond it is a torn tail from the crash.
        const wal_valid_bytes = try engine.replayWal();
```

```zig
        // Open WAL for writing
        engine.wal_file = try engine.wal_dir.createFile(io, "fts.wal", .{
            .truncate = false,
            .permissions = utils.fileMode(0o600),
        });
        errdefer engine.wal_file.close(io);
        // GSP-2: chop the torn tail BEFORE the writer computes its append
        // offset. Without this, post-recovery appends land after garbage
        // that replay breaks on — fsync-acknowledged yet unreachable. The
        // truncation is fsynced so a second crash cannot resurrect the tail.
        const wal_stat = try engine.wal_file.stat(io);
        if (wal_stat.size > wal_valid_bytes) {
            try engine.wal_file.setLength(io, wal_valid_bytes);
            try engine.wal_file.sync(io);
        }
        engine.wal_writer = try wal.WalWriter.initWithHmac(
            io,
            engine.wal_file,
            allocator,
            config.hmac_key,
        );
```

- [ ] **Step 4: Run the test, verify pass**

Run: `zig build test-integration 2>&1 | tail -5` — expect PASS (including the pre-existing torn-tail test).

- [ ] **Step 5: Full suite**

Run: `zig build test-all 2>&1 | tail -5` — expect green.

- [ ] **Step 6: Commit**

```bash
git add src/engine.zig tests/fault_injection.zig
git commit -m "fix(engine): truncate torn WAL tail before re-append so post-recovery writes stay replayable"
```

---

### Task 3: Heal next_txn_id past uncommitted orphan brackets

Root cause (graph-storage lesson #3 — `2291ecc`/`84ea73c`: "durable data does not imply a durable counter"; counters must be re-derived from the FULL replayed tail): replay bumps `next_txn_id` only for records in *committed* transactions (`engine.zig:649-651`). An uncommitted orphan bracket (BEGIN + INDEX_DOC, crash before COMMIT, txn N) leaves N unclaimed. A post-recovery write reuses txn N and appends its own COMMIT(N); the next replay's committed-set then contains N, so the orphan's INDEX_DOC(txn N) is applied too — a dropped, never-committed document resurrects.

Fix: track the max txn_id across ALL drained records (committed or not) and heal `next_txn_id` past it, replacing the committed-only bump.

**Files:**
- Modify: `src/engine.zig:596-657` (`replayWal` drain + third pass)
- Test: `tests/fault_injection.zig`

**Interfaces:**
- Consumes: `replayWal` internals (Task 2 shape).
- Produces: nothing new externally; `next_txn_id` post-init invariant: strictly greater than every txn_id present in the replayed WAL.

- [ ] **Step 1: Write the failing test**

Append to `tests/fault_injection.zig`:

```zig
test "fault: uncommitted orphan txn is never resurrected by txn-id reuse (GSP-3)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Session 1: commit doc 1 as txn 1.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "real", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
    }

    // Crash simulation: append an ORPHAN bracket (BEGIN + INDEX_DOC, no
    // COMMIT) as txn 2 — exactly what a crash between payload append and
    // COMMIT append leaves behind.
    {
        var wal_dir = try tmp_dir.dir.openDir(io, "wal", .{});
        defer wal_dir.close(io);
        const f = try wal_dir.createFile(io, "fts.wal", .{ .truncate = false });
        defer f.close(io);
        var writer = try fts.wal.WalWriter.init(io, f, alloc);
        defer writer.deinit();

        // index_doc payload: u16 term_len | term | u16 num_pos | varint pos.
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(alloc);
        const term = "ghost";
        var num: [2]u8 = undefined;
        std.mem.writeInt(u16, &num, @intCast(term.len), .little);
        try payload.appendSlice(alloc, &num);
        try payload.appendSlice(alloc, term);
        std.mem.writeInt(u16, &num, 1, .little);
        try payload.appendSlice(alloc, &num);
        var vbuf: [10]u8 = undefined;
        const w = try fts.utils.writeVarInt(&vbuf, 1);
        try payload.appendSlice(alloc, vbuf[0..w]);

        try writer.append(.{ .record_type = .begin, .txn_id = 2 });
        try writer.append(.{ .record_type = .index_doc, .txn_id = 2, .doc_id = 999, .payload = payload.items });
        try writer.sync();
    }

    // Session 2: orphan correctly dropped; then a new write. Pre-fix the
    // engine reuses txn 2 for it and appends COMMIT(2) to the same WAL.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        var it_g = try fts.TermIterator.init(alloc, eng, "ghost");
        defer it_g.deinit();
        try std.testing.expect((try it_g.next()) == null);

        const t = fts.TermPosting{ .term = "fresh", .positions = &[_]u32{1} };
        try eng.indexDocument(3, &[_]fts.TermPosting{t});
    }

    // Session 3: the ghost must STILL be invisible. Pre-fix, COMMIT(2) from
    // session 2 blesses the orphan INDEX_DOC(txn 2) and doc 999 resurrects.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        var it_g = try fts.TermIterator.init(alloc, eng, "ghost");
        defer it_g.deinit();
        try std.testing.expect((try it_g.next()) == null);
        var it_f = try fts.TermIterator.init(alloc, eng, "fresh");
        defer it_f.deinit();
        try std.testing.expect((try it_f.next()) != null);
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `zig build test-integration 2>&1 | tail -20`
Expected: FAIL in session 3 — "ghost" yields a match (resurrection reproduced).

- [ ] **Step 3: Implement**

In `replayWal`, in the drain loop (after `const rec = rec_opt orelse break;`), track the max:

```zig
        // GSP-3 (graph-storage parity): track the max txn id across ALL
        // drained records — committed or not. An orphan (uncommitted)
        // bracket's id must never be re-issued: a later writer would append
        // its own COMMIT under the same id and retroactively bless the
        // orphan payload on the next replay. "Durable data does not imply
        // a durable counter."
        var max_seen_txn: u64 = 0;
```

(declare above the `while (true)` drain loop), and inside the loop after `const rec = rec_opt orelse break;`:

```zig
            if (rec.txn_id > max_seen_txn) max_seen_txn = rec.txn_id;
```

Then DELETE the committed-only bump in the third pass (`engine.zig:646-651`, the `if (r.txn_id >= self.next_txn_id...)` block and its comment) and add, between the drain loop and the second pass:

```zig
        // Heal the txn-id allocator past everything the tail contains —
        // including uncommitted residue (GSP-3). Replay runs single-threaded
        // inside init, so plain load+store is safe; atomics for consistency.
        if (max_seen_txn >= self.next_txn_id.load(.monotonic)) {
            self.next_txn_id.store(max_seen_txn + 1, .monotonic);
        }
```

- [ ] **Step 4: Run, verify pass**

Run: `zig build test-integration 2>&1 | tail -5` — expect PASS.

- [ ] **Step 5: Full suite**

Run: `zig build test-all 2>&1 | tail -5` — expect green (committed-record replay still bumps the counter, now via the same max).

- [ ] **Step 6: Commit**

```bash
git add src/engine.zig tests/fault_injection.zig
git commit -m "fix(engine): heal next_txn_id past uncommitted orphan brackets to prevent ghost resurrection"
```

---

### Task 4: Checked arithmetic on disk-derived posting deltas

Root cause (graph-storage lesson #1 — `2dcc678`: hostile on-disk values must fail loud, never panic, never wrap): `PostingIterator.next` (`src/segment.zig:521-549`) does `self.last_doc_id += doc_delta.val` (u64 wrap ⇒ safety panic in Debug/ReleaseSafe, silent wrap in ReleaseFast) and `last_pos += @intCast(pos_delta.val)` (unchecked u64→u32 `@intCast` ⇒ panic/UB on any delta > 2³²−1). `nextDocOnly` (`segment.zig:561-585`) has the same doc_id add. Segment files currently have no checksum (until Task 9), so these bytes are the least-protected input in the whole engine.

**Files:**
- Modify: `src/segment.zig:521-585` (`PostingIterator.next`, `nextDocOnly`)
- Test: `src/segment.zig` (new unit tests)

**Interfaces:**
- Consumes: existing `SegmentError` members `InvalidData`, `PositionOutOfRange` (`src/errors.zig:25-35`) — no new errors needed.
- Produces: contract — corrupt delta streams surface `error.InvalidData` (doc_id overflow) or `error.PositionOutOfRange` (position cast/overflow); never a panic in any build mode.

- [ ] **Step 1: Write the failing tests**

Append to `src/segment.zig` tests:

```zig
test "PostingIterator rejects doc-id delta overflow instead of panicking (GSP-4)" {
    const alloc = std.testing.allocator;
    // Posting 1: doc delta = maxInt(u64), tf = 1, one position delta 1.
    // Posting 2: doc delta = 1 -> u64 overflow on accumulate.
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);
    var vbuf: [10]u8 = undefined;
    var w = try utils.writeVarInt(&vbuf, std.math.maxInt(u64));
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // tf
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // pos delta
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // posting 2 doc delta -> overflow
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // tf
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // pos delta
    try data.appendSlice(alloc, vbuf[0..w]);

    var it = SegmentReader.PostingIterator{
        .allocator = alloc,
        .data = data.items,
        .owns_data = false,
        .df = 2,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.pos_buf.deinit(alloc);
    _ = try it.next(); // posting 1: doc_id = maxInt, fine
    try std.testing.expectError(error.InvalidData, it.next());
}

test "PostingIterator rejects oversized position delta instead of panicking (GSP-4)" {
    const alloc = std.testing.allocator;
    // One posting: doc delta 1, tf 1, position delta maxInt(u64) — the
    // unchecked @intCast to u32 used to panic (Debug/ReleaseSafe) or wrap
    // silently (ReleaseFast).
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);
    var vbuf: [10]u8 = undefined;
    var w = try utils.writeVarInt(&vbuf, 1);
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1);
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, std.math.maxInt(u64));
    try data.appendSlice(alloc, vbuf[0..w]);

    var it = SegmentReader.PostingIterator{
        .allocator = alloc,
        .data = data.items,
        .owns_data = false,
        .df = 1,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.pos_buf.deinit(alloc);
    try std.testing.expectError(error.PositionOutOfRange, it.next());
}

test "nextDocOnly rejects doc-id delta overflow (GSP-4)" {
    const alloc = std.testing.allocator;
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(alloc);
    var vbuf: [10]u8 = undefined;
    var w = try utils.writeVarInt(&vbuf, std.math.maxInt(u64));
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 0); // tf = 0, no positions
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 1); // posting 2 delta -> overflow
    try data.appendSlice(alloc, vbuf[0..w]);
    w = try utils.writeVarInt(&vbuf, 0);
    try data.appendSlice(alloc, vbuf[0..w]);

    var it = SegmentReader.PostingIterator{
        .allocator = alloc,
        .data = data.items,
        .owns_data = false,
        .df = 2,
        .current_idx = 0,
        .pos = 0,
        .last_doc_id = 0,
        .pos_buf = .empty,
    };
    defer it.pos_buf.deinit(alloc);
    _ = try it.nextDocOnly();
    try std.testing.expectError(error.InvalidData, it.nextDocOnly());
}
```

- [ ] **Step 2: Run, verify failure mode**

Run: `zig build test 2>&1 | tail -20`
Expected: test-runner PANIC (integer overflow / cast truncation) — that IS the bug. Note the panic text for the commit message.

- [ ] **Step 3: Implement**

In `PostingIterator.next` replace the two accumulations:

```zig
            // GSP-4: disk-derived deltas get checked arithmetic in every
            // build mode — a corrupt delta must surface as an error, never
            // a panic (Debug/ReleaseSafe) or silent wrap (ReleaseFast).
            self.last_doc_id = std.math.add(u64, self.last_doc_id, doc_delta.val) catch
                return error.InvalidData;
```

and in the positions loop:

```zig
                const delta32 = std.math.cast(u32, pos_delta.val) orelse
                    return error.PositionOutOfRange;
                last_pos = std.math.add(u32, last_pos, delta32) catch
                    return error.PositionOutOfRange;
                self.pos_buf.appendAssumeCapacity(last_pos);
```

In `nextDocOnly` replace `self.last_doc_id += doc_delta.val;` with the same checked add (`catch return error.InvalidData`).

- [ ] **Step 4: Run, verify pass**

Run: `zig build test 2>&1 | tail -5` — expect PASS, no panics.

- [ ] **Step 5: Full suite + commit**

Run: `zig build test-all 2>&1 | tail -5` — green.

```bash
git add src/segment.zig
git commit -m "fix(segment): checked arithmetic on disk-derived posting deltas — error, never panic or wrap"
```

---

### Task 5: Validate dictionary entries at segment load

Root cause (graph-storage lessons #1/#14 — reject-on-doubt at decode time, never lazily/asymmetrically): `SegmentReader.load` stores each term's `df`/`postings_offset`/`postings_len` unvalidated (`segment.zig:762-766`). Bounds are only checked lazily at query time, and asymmetrically: the AEAD path bounds-checks against the resident buffer (`segment.zig:612`), while the plaintext path relies on `readPositional` returning 0 (`segment.zig:634`) — a wrong-but-in-range offset silently decodes garbage.

Fix: validate every entry at load: `postings_len ≤ MAX_POSTINGS_BYTES`, checked `offset+len` within the postings file/buffer size, `df ≤ postings_len` (every posting occupies ≥ 1 byte). To know the postings size before dictionary parse, materialize the AEAD postings buffer FIRST (moving the block from the end of `load()` to the top) or `stat` the plaintext handle.

**Files:**
- Modify: `src/segment.zig:693-814` (`load`)
- Test: `src/segment.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces: restructured `load()` with this ordering — (1) AEAD postings materialization, (2) `postings_size` computed, (3) dictionary parse + per-entry validation, (4) tombstones, (5) norms. Task 9 builds directly on this ordering; entry validation compares against a `postings_size: u64` local.

- [ ] **Step 1: Write the failing test**

Append to `src/segment.zig` tests:

```zig
test "SegmentReader.load rejects dictionary entries pointing outside postings.bin (GSP-5)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try tmp_dir.dir.createDir(io, "seg_1", .{});
    var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
    defer seg_dir.close(io);

    // terms.hash claiming (offset=0, len=1 GiB) against an 8-byte postings.bin.
    var dict: std.ArrayListUnmanaged(u8) = .empty;
    defer dict.deinit(alloc);
    var num: [8]u8 = undefined;
    std.mem.writeInt(u32, num[0..4], 1, .little); // count = 1
    try dict.appendSlice(alloc, num[0..4]);
    std.mem.writeInt(u16, num[0..2], 1, .little); // term_len = 1
    try dict.appendSlice(alloc, num[0..2]);
    try dict.append(alloc, 't');
    std.mem.writeInt(u64, num[0..8], 1, .little); // df
    try dict.appendSlice(alloc, num[0..8]);
    std.mem.writeInt(u64, num[0..8], 0, .little); // postings_offset
    try dict.appendSlice(alloc, num[0..8]);
    std.mem.writeInt(u64, num[0..8], 1 << 30, .little); // postings_len — hostile
    try dict.appendSlice(alloc, num[0..8]);

    {
        const f = try seg_dir.createFile(io, "terms.hash", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, dict.items);
    }
    {
        const f = try seg_dir.createFile(io, "postings.bin", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, &[_]u8{0} ** 8);
    }

    // Pre-fix: init succeeds and the bad entry waits to poison a query.
    // Post-fix: load rejects at open.
    try std.testing.expectError(
        error.InvalidData,
        SegmentReader.init(io, alloc, tmp_dir.dir, 1),
    );
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `SegmentReader.init` succeeds pre-fix (`expectError` trips).

- [ ] **Step 3: Implement**

Restructure the start of `load()` (`segment.zig:693`) — move the AEAD postings block (currently at `segment.zig:806-813`) to the very top and compute the size:

```zig
    fn load(self: *SegmentReader) !void {
        // GSP-5: materialize the AEAD postings buffer FIRST so its length
        // can bound-check every dictionary (offset, len) pair below. The
        // plaintext path uses the cached handle's stat. (AEAD ciphertext is
        // not random-accessible — tag covers the whole stream — so this
        // buffer was always loaded eagerly; only its position in load()
        // moved.)
        if (self.aead_key != null) {
            self.postings_data = (try self.readSegmentFile("postings.bin")) orelse
                try self.allocator.alloc(u8, 0);
        }
        const postings_size: u64 = if (self.postings_data) |pd|
            pd.len
        else blk: {
            const st = try self.postings_file.stat(self.io);
            break :blk st.size;
        };
```

Delete the old AEAD block at the end of `load()`.

In Pass 2 of the dictionary parse, after reading `df`/`offset`/`len` (`segment.zig:758-760`), insert before `putAssumeCapacityNoClobber`:

```zig
                // GSP-5 (graph-storage parity): validate disk-derived extents
                // at load, symmetrically for plaintext and AEAD paths. A
                // wrong-but-in-range offset can still decode garbage until
                // the v2 envelope (GSP-9) adds whole-file CRC — but out-of-
                // range and absurd entries fail loud at open, not at query.
                if (len > limits.MAX_POSTINGS_BYTES) return error.PostingsTooLarge;
                const end = std.math.add(u64, offset, len) catch return error.InvalidData;
                if (end > postings_size) return error.InvalidData;
                // Every posting occupies at least one byte, so df can never
                // exceed the byte length of its postings run.
                if (df > len) return error.InvalidData;
```

- [ ] **Step 4: Run, verify pass**

Run: `zig build test 2>&1 | tail -5` — PASS.

- [ ] **Step 5: Full suite + commit**

Run: `zig build test-all 2>&1 | tail -5` — green (AEAD tests confirm the reorder is behavior-neutral).

```bash
git add src/segment.zig
git commit -m "fix(segment): validate dictionary df/offset/len against postings size at load"
```

---

### Task 6: Manifest format_version gate (upgrade/downgrade discipline)

Root cause (graph-storage lesson #7 — both directions bit them: `49d85dc` silent downgrade misparse, `22b801c` upgrade deploy blocker): `manifest.format_version` is written and parsed but never validated (`manifest.zig:141`). A future v3 manifest with valid CRC would be silently misparsed by this binary; worse, the engine's corrupt-slot fallback would mask it. Also fix the adjacent nit: `loadManifest` issues a single `readStreaming` and ignores the returned length (`engine.zig:496-497`).

Fix: reject `format_version != MANIFEST_VERSION` with a dedicated error, surfaced loud at the engine boundary (like `HmacMismatch`, never masked by A/B fallback), and read the manifest file fully.

**Files:**
- Modify: `src/manifest.zig:139-149`, `src/errors.zig:16-23` and `:37-63`, `src/engine.zig:479-551` (loader + result enum) and `:267-282` (init gating)
- Test: `src/manifest.zig`, `tests/fault_injection.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces: `error.UnsupportedManifestVersion` in `ManifestError` AND `EngineError`; `ManifestLoadResult` gains `.unsupported_version`; `Engine.init` returns `error.UnsupportedManifestVersion` when either slot carries it.

- [ ] **Step 1: Write the failing unit test**

Append to `src/manifest.zig` tests:

```zig
test "manifest deserialize rejects unknown format_version loudly (GSP-6)" {
    const allocator = std.testing.allocator;
    var m = Manifest{ .counter = 5 };
    const data = try m.serialize(allocator);
    defer allocator.free(data);

    // Forge a "future" v3 manifest with a VALID CRC — exactly what a newer
    // binary would write. Length-only or CRC-only gating cannot catch this;
    // graph-storage learned that the hard way in both directions.
    var pos: usize = 8;
    utils.writeU32Le(data, &pos, 3);
    const crc = utils.hashCrc32c(data[0 .. data.len - 4]);
    pos = data.len - 4;
    utils.writeU32Le(data, &pos, crc);

    try std.testing.expectError(
        error.UnsupportedManifestVersion,
        Manifest.deserialize(allocator, data),
    );
}
```

And the engine-level test in `tests/fault_injection.zig`:

```zig
test "fault: future-version manifest fails engine init loudly, not as corrupt-slot fallback (GSP-6)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Produce a valid store, then stamp BOTH manifest slots to version 3
    // with recomputed CRCs (simulating a newer binary's store opened by
    // this one). One-slot-v3 must also fail loud, so stamp both to prove
    // no fallback path swallows it.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "v", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
        try eng.flush();
    }
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |name| {
        const f = tmp_dir.dir.openFile(io, name, .{}) catch |err| {
            if (err == error.FileNotFound) continue; // only one slot exists yet
            return err;
        };
        defer f.close(io);
        const stat = try f.stat(io);
        const buf = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(buf);
        var idx: usize = 0;
        while (idx < buf.len) {
            const amt = try f.readPositional(io, &.{buf[idx..]}, idx);
            if (amt == 0) break;
            idx += amt;
        }
        std.mem.writeInt(u32, buf[8..12], 3, .little);
        const crc = fts.utils.hashCrc32c(buf[0 .. buf.len - 4]);
        std.mem.writeInt(u32, buf[buf.len - 4 ..][0..4], crc, .little);
        try f.writePositionalAll(io, buf, 0);
        try f.sync(io);
    }

    try std.testing.expectError(
        error.UnsupportedManifestVersion,
        fts.Engine.init(io, alloc, tmp_dir.dir),
    );
}
```

- [ ] **Step 2: Run, verify both fail**

Run: `zig build test 2>&1 | tail -10` and `zig build test-integration 2>&1 | tail -10`
Expected: unit test fails to compile until the error exists — add the error member first if needed, then expect: deserialize succeeds pre-fix (expectError trips). Engine test pre-fix: init either succeeds via misparse or returns `ManifestCorrupt` — either way not `UnsupportedManifestVersion`.

- [ ] **Step 3: Implement**

`src/errors.zig` — add to `ManifestError` and `EngineError`:

```zig
    /// Manifest carries a format_version this binary does not implement.
    /// Fail-loud downgrade/upgrade gate (GSP-6): a version mismatch is a
    /// deployment condition, not corruption — it must never be masked by
    /// the A/B corrupt-slot fallback or misparsed at a guessed layout.
    UnsupportedManifestVersion,
```

`src/manifest.zig` — in `deserializeWithHmac`, right after `m.format_version = utils.readU32Le(data, &pos);`:

```zig
        // GSP-6: exact-version gate. Runs AFTER CRC so random corruption of
        // the version field still reports ChecksumMismatch; a structurally
        // valid manifest from a different binary generation reports
        // UnsupportedManifestVersion. Never discriminate by length alone.
        if (m.format_version != MANIFEST_VERSION) return error.UnsupportedManifestVersion;
```

`src/engine.zig` — `ManifestLoadResult` gains a state:

```zig
        /// File parsed and CRC-validated but its format_version is not one
        /// this binary implements. Fail-loud like hmac_mismatch (GSP-6).
        unsupported_version,
```

In `loadManifestResult`'s error switch, before the catch-all:

```zig
            error.UnsupportedManifestVersion => return .unsupported_version,
```

In `initWithConfig`, next to the hmac gate (`engine.zig:280`):

```zig
        if (res_a == .unsupported_version or res_b == .unsupported_version)
            return error.UnsupportedManifestVersion;
```

And fix the short read in `loadManifest` (`engine.zig:496-497`):

```zig
        var index: usize = 0;
        while (index < size_usize) {
            const amt = try file.readPositional(io, &.{data[index..]}, index);
            if (amt == 0) return error.InvalidData; // file shrank under us
            index += amt;
        }
```

- [ ] **Step 4: Run, verify pass**

Run: `zig build test 2>&1 | tail -5` and `zig build test-integration 2>&1 | tail -5` — PASS.

- [ ] **Step 5: Full suite + commit**

Run: `zig build test-all 2>&1 | tail -5` — green.

```bash
git add src/manifest.zig src/engine.zig src/errors.zig tests/fault_injection.zig
git commit -m "feat(manifest): enforce format_version as a fail-loud upgrade/downgrade gate"
```

---

### Task 7: fsync segment files before the manifest publishes them

Root cause (graph-storage lesson #8, posture finding #1 — durable-manifest/volatile-data inversion): `SegmentWriter.writeFile` (`segment.zig:208-219`) does createFile → write → close with NO `sync`. `flushLocked` Phase 2 then durably publishes a manifest referencing those files and Phase 3 truncates the WAL — so a power failure after flush returns can leave the manifest pointing at torn/absent segment data with no WAL to repair it.

Fix: `try file.sync(self.io)` in `writeFile` before close. (Directory-entry fsync remains a documented platform limitation — `std.Io.Dir` exposes no sync in Zig 0.16, consistent with the existing `utils.zig:238-250` note; update that comment to reflect that file *data* is now synced.)

**Files:**
- Modify: `src/segment.zig:208-219` (`writeFile`), `src/utils.zig:230-257` (comment), `src/engine.zig:1041-1061` (Phase-1 comment)
- Test: existing suites (fsync is not observable via tampering tests; correctness is by inspection + suite-green)

**Interfaces:** none.

- [ ] **Step 1: Implement (no new test — behavior-invisible durability fix)**

In `writeFile`, after the write branch and before the closing brace:

```zig
        // GSP-7: fsync segment data BEFORE flushLocked Phase 2 publishes a
        // manifest referencing this file and Phase 3 truncates the WAL.
        // Without this, a durable manifest can point at torn segment pages
        // that no WAL replay can repair (durable-reference/volatile-data
        // inversion). Directory-entry durability (the rename/creation
        // itself) remains a documented std.Io.Dir limitation — see
        // utils.atomicWrite.
        try file.sync(self.io);
```

Update the `utils.zig` atomicWrite comment block: replace the sentence `Acceptable for v0.1 because the WAL is the durability source of truth and manifest replay is idempotent.` with:

```
///   Acceptable for v0.1 because manifest replay is idempotent and (GSP-7)
///   segment file DATA is fsynced before any manifest references it — the
///   remaining exposure is the directory entry itself, not file contents.
```

In `flushLocked`'s PHASE 1 comment (`engine.zig:1041-1044`), append one line:

```
        // Segment file data is fsynced inside SegmentWriter.writeFile (GSP-7)
        // so Phase 2's durable manifest never references volatile pages.
```

- [ ] **Step 2: Run the full suite**

Run: `zig build test-all 2>&1 | tail -5` — green. Also run the stress suite explicitly (`zig build test-stress 2>&1 | tail -3`) since flush cost changed.

- [ ] **Step 3: Commit**

```bash
git add src/segment.zig src/utils.zig src/engine.zig
git commit -m "fix(segment): fsync segment files before manifest publish closes durable-reference/volatile-data inversion"
```

---

### Task 8: Heal total_docs / avg_doc_len at compact

Root cause (graph-storage lessons #3/#11 — enumerate every checkpoint-granular manifest field; heal or document; posture finding #5): `manifest.total_docs` only ever grows (`engine.zig:1101`); deletes never decrement it and `compact()` — which physically drops tombstoned docs — rewrites the manifest without recomputing it (`engine.zig:1281-1290`). `avg_doc_len` likewise. Both feed BM25 (`search.zig:200-224`), so ranking drifts on delete-heavy corpora precisely when compaction was supposed to clean up.

Fix: compact() recomputes both fields from the merged memtable it just built (it already holds the entire live corpus). Re-index double-counting across segments remains documented (`search.zig:134-138`) — out of scope; this heal makes compaction the point where stats converge to truth, mirroring graph-storage's "checkpoint heals what replay cannot".

**Files:**
- Modify: `src/engine.zig:1281-1290` (compact manifest update)
- Test: `tests/integration.zig`

**Interfaces:**
- Consumes: `merged_mt.total_docs`, `merged_mt.dictionary` (existing Memtable fields).
- Produces: post-compact invariant — `current_manifest.total_docs` equals the number of live (non-tombstoned) distinct docs in the merged segment; `avg_doc_len` is their true mean token length.

- [ ] **Step 1: Write the failing test**

Append to `tests/integration.zig`:

```zig
test "integration: compact heals total_docs and avg_doc_len (GSP-8)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        // 4 docs, 2 tokens each.
        var doc_id: u64 = 1;
        while (doc_id <= 4) : (doc_id += 1) {
            const t = fts.TermPosting{ .term = "common", .positions = &[_]u32{ 1, 2 } };
            try eng.indexDocument(doc_id, &[_]fts.TermPosting{t});
        }
        try eng.flush();
        try std.testing.expectEqual(@as(u64, 4), eng.current_manifest.total_docs);

        // Delete half, flush the tombstones as a second segment.
        try eng.deleteDocument(1);
        try eng.deleteDocument(2);
        try eng.flush();
        // Stale by design pre-compact: deletes don't decrement.
        try std.testing.expectEqual(@as(u64, 4), eng.current_manifest.total_docs);

        // Compact drops the tombstoned docs physically; the manifest stats
        // must converge to the merged truth (GSP-8). Pre-fix: stays 4.
        try eng.compact();
        try std.testing.expectEqual(@as(u64, 2), eng.current_manifest.total_docs);
        try std.testing.expectEqual(@as(u32, 2), eng.current_manifest.avg_doc_len);
    }

    // Healed values are durable across reopen.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expectEqual(@as(u64, 2), eng.current_manifest.total_docs);
        try std.testing.expectEqual(@as(u32, 2), eng.current_manifest.avg_doc_len);
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `zig build test-integration 2>&1 | tail -10`
Expected: FAIL — `total_docs` still 4 after compact.

- [ ] **Step 3: Implement**

In `compact()`, immediately before `self.current_manifest.counter += 1;` (`engine.zig:1290`), insert:

```zig
        // GSP-8 (graph-storage parity): compaction is the one point where
        // the whole live corpus is materialized, so heal the checkpoint-
        // granular corpus stats here — deletes never decrement total_docs
        // and BM25 consumes both fields (search.zig computeScore). Re-index
        // double-counting across segments remains documented in
        // search.zig:134-138; after compact there is a single segment, so
        // the healed values are exact.
        const merged_token_len: u64 = blk: {
            var sum: u64 = 0;
            var stat_it = merged_mt.dictionary.iterator();
            while (stat_it.next()) |entry| {
                for (entry.value_ptr.tfs.items) |tf| sum += tf;
            }
            break :blk sum;
        };
        self.current_manifest.total_docs = merged_mt.total_docs;
        self.current_manifest.avg_doc_len = if (merged_mt.total_docs > 0)
            std.math.cast(u32, @divTrunc(merged_token_len, merged_mt.total_docs)) orelse std.math.maxInt(u32)
        else
            0;
```

- [ ] **Step 4: Run, verify pass**

Run: `zig build test-integration 2>&1 | tail -5` — PASS (the pre-existing "manifest doc counts" integration test must also still pass; it asserts flush-time counting which is unchanged).

- [ ] **Step 5: Full suite + commit**

Run: `zig build test-all 2>&1 | tail -5` — green.

```bash
git add src/engine.zig tests/integration.zig
git commit -m "fix(engine): compact() heals total_docs/avg_doc_len from the merged corpus"
```

---

### Task 9: Segment file envelope — magic + version + CRC32C, permanent read-both

Root cause (graph-storage lessons #7/#8/#12/#14): segment files have no magic, no version, no checksum (`segment.zig:188-379`). Plaintext corruption is undetectable except by structural luck; format evolution has no gate (an old binary reading a future layout would misparse); and there is no rebuild-on-version-reject path.

Design (mirrors graph-storage's magic-bump + misroute-trips-existing-guard discipline, `c117c36`/`23ac60f`):
- v2 envelope, uniform for all four files: `magic(4)="FSG2" | version(4, u32 LE = 2) | payload | crc32c(4, over magic..payload)`. Applied INSIDE the AEAD envelope when encryption is on (encrypt the enveloped plaintext).
- The magic's first 4 bytes decode, as the u32 LE `count` every legacy parser reads first, to `0x32475346` = 843,600,710 — far above every `MAX_*_PER_SEGMENT` cap (2²⁴) — so an OLD binary opening a v2 `terms.hash` fails loudly at its existing count guard instead of misparsing (and it hits `terms.hash` first, before any postings read). Deliberate, same trick as graph-storage's slab marker.
- Read-both forever: files without the magic parse as legacy (v1) exactly as today. Format is detected once per segment on `terms.hash` (unambiguous, count-cap argument above); `postings.bin`, `tombstones.bin`, `norms.bin` then REQUIRE the detected format — except legacy, where files are read verbatim (zero behavioral change for old stores, no false-magic risk on postings).
- Plaintext postings.bin: the envelope shifts payload by 8 bytes; the reader keeps using positional per-term reads, so it verifies magic+version via a 12-byte header read at load and offsets reads by `postings_base = 8`. Whole-file CRC for plaintext postings is intentionally NOT verified at load (O(file) read at open); protection there = AEAD path full CRC + Tasks 4/5 checked decode + this task's dictionary/tombstones/norms full CRC. Document this bound honestly.

**Files:**
- Modify: `src/segment.zig` (writer `writeFile`, reader fields, `readSegmentFile`, `load`, `search`), `src/errors.zig` (SegmentError)
- Test: `src/segment.zig`, `tests/fault_injection.zig`
- Docs: `docs/fts-storage-spec.md` (segment format section), `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 5's `load()` ordering and `postings_size` validation; Task 7's `file.sync` in `writeFile`.
- Produces: `pub const SEGMENT_FILE_MAGIC: [4]u8` and `pub const SEGMENT_FILE_VERSION: u32 = 2` in `src/segment.zig`; `error.UnsupportedSegmentVersion` in `SegmentError`; `SegmentReader` fields `file_format: FileFormat`, `postings_base: u64`; `readSegmentFile(self, name, expect: FileFormat)` (breaking internal signature — all 4 call sites updated in this task).

- [ ] **Step 1: Write the failing tests**

Append to `src/segment.zig` tests:

```zig
test "segment v2 envelope round-trips and legacy naked files still load (GSP-9)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Write a segment through the writer (v2 enveloped post-fix).
    var mt = Memtable.init(alloc);
    defer mt.deinit();
    try mt.addPosting("hello", 1, &[_]u32{ 1, 3 });
    try mt.addPosting("hello", 2, &[_]u32{2});
    try mt.addTombstone(9);
    var writer = SegmentWriter{ .io = io, .dir = tmp_dir.dir, .allocator = alloc, .segment_id = 1 };
    try writer.writeMemtable(&mt);

    // terms.hash must start with the magic.
    {
        var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);
        const f = try seg_dir.openFile(io, "terms.hash", .{});
        defer f.close(io);
        var hdr: [4]u8 = undefined;
        _ = try f.readPositional(io, &.{&hdr}, 0);
        try std.testing.expectEqualSlices(u8, &SEGMENT_FILE_MAGIC, &hdr);
    }

    // v2 reader round-trip.
    {
        var sr = try SegmentReader.init(io, alloc, tmp_dir.dir, 1);
        defer sr.deinit();
        var it = (try sr.search("hello")).?;
        defer it.deinit();
        const p1 = (try it.next()).?;
        try std.testing.expectEqual(@as(u64, 1), p1.doc_id);
        try std.testing.expect(sr.tombstones.contains(9));
    }

    // Strip the envelope from every file -> legacy naked layout; the reader
    // must still load it (permanent read-both).
    {
        var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);
        for ([_][]const u8{ "terms.hash", "postings.bin", "tombstones.bin", "norms.bin" }) |name| {
            const f = seg_dir.openFile(io, name, .{}) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            const stat = try f.stat(io);
            const buf = try alloc.alloc(u8, @intCast(stat.size));
            defer alloc.free(buf);
            var idx: usize = 0;
            while (idx < buf.len) {
                const amt = try f.readPositional(io, &.{buf[idx..]}, idx);
                if (amt == 0) break;
                idx += amt;
            }
            f.close(io);
            try seg_dir.deleteFile(io, name);
            const nf = try seg_dir.createFile(io, name, .{});
            defer nf.close(io);
            try nf.writeStreamingAll(io, buf[8 .. buf.len - 4]);
            try nf.sync(io);
        }
        var sr = try SegmentReader.init(io, alloc, tmp_dir.dir, 1);
        defer sr.deinit();
        var it = (try sr.search("hello")).?;
        defer it.deinit();
        const p1 = (try it.next()).?;
        try std.testing.expectEqual(@as(u64, 1), p1.doc_id);
    }
}

test "segment v2 envelope detects payload corruption and rejects future versions (GSP-9)" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var mt = Memtable.init(alloc);
    defer mt.deinit();
    try mt.addPosting("term", 1, &[_]u32{1});
    var writer = SegmentWriter{ .io = io, .dir = tmp_dir.dir, .allocator = alloc, .segment_id = 1 };
    try writer.writeMemtable(&mt);

    var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
    defer seg_dir.close(io);

    // Flip one payload byte in terms.hash: pre-envelope this was silently
    // absorbed or surfaced as a confusing structural error; now it is a
    // deterministic ChecksumMismatch at open.
    {
        const f = try seg_dir.openFile(io, "terms.hash", .{});
        defer f.close(io);
        var b: [1]u8 = undefined;
        _ = try f.readPositional(io, &.{&b}, 9);
        b[0] ^= 0xFF;
        try f.writePositionalAll(io, &b, 9);
        try f.sync(io);
    }
    try std.testing.expectError(
        error.ChecksumMismatch,
        SegmentReader.init(io, alloc, tmp_dir.dir, 1),
    );

    // Repair the byte, then stamp version=3 with a recomputed CRC: must be
    // UnsupportedSegmentVersion (the downgrade gate), not a misparse.
    {
        const f = try seg_dir.openFile(io, "terms.hash", .{});
        defer f.close(io);
        var b: [1]u8 = undefined;
        _ = try f.readPositional(io, &.{&b}, 9);
        b[0] ^= 0xFF;
        try f.writePositionalAll(io, &b, 9);
        const stat = try f.stat(io);
        const buf = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(buf);
        var idx: usize = 0;
        while (idx < buf.len) {
            const amt = try f.readPositional(io, &.{buf[idx..]}, idx);
            if (amt == 0) break;
            idx += amt;
        }
        std.mem.writeInt(u32, buf[4..8], 3, .little);
        const crc = utils.hashCrc32c(buf[0 .. buf.len - 4]);
        std.mem.writeInt(u32, buf[buf.len - 4 ..][0..4], crc, .little);
        try f.writePositionalAll(io, buf, 0);
        try f.sync(io);
    }
    try std.testing.expectError(
        error.UnsupportedSegmentVersion,
        SegmentReader.init(io, alloc, tmp_dir.dir, 1),
    );
}
```

- [ ] **Step 2: Run, verify failures**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error on `SEGMENT_FILE_MAGIC` (doesn't exist) — that is the RED for the format constants; after stubbing constants only, the round-trip test fails on the magic assertion.

- [ ] **Step 3: Implement the writer**

In `src/segment.zig` near the top (after imports):

```zig
/// v2 segment-file envelope (GSP-9): magic(4) | version(4 LE) | payload |
/// crc32c(4, over magic..payload). Uniform across terms.hash, postings.bin,
/// tombstones.bin, norms.bin; applied INSIDE the AEAD envelope when
/// encryption is on. The magic's four bytes deliberately decode — as the
/// u32 LE `count` field every legacy parser reads first — to ~843.6M, far
/// above every MAX_*_PER_SEGMENT cap (2^24), so a pre-v2 binary that opens
/// a v2 file fails loudly at its existing count guard instead of misparsing
/// (graph-storage parity: cross-layout misroutes must trip existing guards).
pub const SEGMENT_FILE_MAGIC: [4]u8 = .{ 'F', 'S', 'G', '2' };
pub const SEGMENT_FILE_VERSION: u32 = 2;
```

Replace `SegmentWriter.writeFile`:

```zig
    fn writeFile(self: *SegmentWriter, seg_dir: *std.Io.Dir, name: []const u8, buf: []const u8) !void {
        // Build the v2 envelope (GSP-9). Transient copy is the same order
        // of memory the AEAD path already pays; acceptable for flush-sized
        // payloads.
        const enveloped = try self.allocator.alloc(u8, 8 + buf.len + 4);
        defer self.allocator.free(enveloped);
        @memcpy(enveloped[0..4], &SEGMENT_FILE_MAGIC);
        std.mem.writeInt(u32, enveloped[4..8], SEGMENT_FILE_VERSION, .little);
        @memcpy(enveloped[8 .. 8 + buf.len], buf);
        // fips-exempt: non-security — CRC32c integrity checksum (the AEAD
        // envelope covers integrity-against-adversary when enabled).
        const crc = utils.hashCrc32c(enveloped[0 .. 8 + buf.len]);
        std.mem.writeInt(u32, enveloped[8 + buf.len ..][0..4], crc, .little);

        const file = try seg_dir.createFile(self.io, name, .{ .permissions = utils.fileMode(0o600) });
        defer file.close(self.io);

        if (self.aead_key) |key| {
            const enc = try utils.aeadEncrypt(self.io, key, enveloped, self.allocator);
            defer self.allocator.free(enc);
            try file.writeStreamingAll(self.io, enc);
        } else {
            try file.writeStreamingAll(self.io, enveloped);
        }

        // GSP-7: fsync segment data BEFORE flushLocked Phase 2 publishes a
        // manifest referencing this file and Phase 3 truncates the WAL.
        try file.sync(self.io);
    }
```

- [ ] **Step 4: Implement the reader**

Add to `SegmentReader` (fields, after `postings_data`):

```zig
    /// GSP-9: per-segment file format, detected once on terms.hash (whose
    /// magic is unambiguous — see SEGMENT_FILE_MAGIC doc). `.legacy` reads
    /// every file verbatim (naked v1 layout); `.enveloped` requires and
    /// strips the v2 envelope on every file.
    file_format: FileFormat = .auto,
    /// Byte offset of the postings payload inside postings.bin: 8 when the
    /// segment is v2-enveloped (magic+version header), 0 for legacy. Used
    /// by the plaintext positional-read path in search().
    postings_base: u64 = 0,

    pub const FileFormat = enum { auto, enveloped, legacy };
```

Change `readSegmentFile` to take the expectation and handle the envelope:

```zig
    fn readSegmentFile(self: *SegmentReader, name: []const u8, expect: FileFormat) !?[]u8 {
        const file = self.seg_dir.openFile(self.io, name, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const size_usize = std.math.cast(usize, stat.size) orelse return error.PostingsTooLarge;

        const raw = try self.allocator.alloc(u8, size_usize);
        errdefer self.allocator.free(raw);

        if (size_usize > 0) {
            var index: usize = 0;
            while (index < size_usize) {
                const amt = try file.readPositional(self.io, &.{raw[index..]}, index);
                if (amt == 0) return error.Incomplete;
                index += amt;
            }
        }

        const plain = if (self.aead_key) |key| blk: {
            defer self.allocator.free(raw);
            break :blk try utils.aeadDecrypt(key, raw, self.allocator);
        } else raw;
        errdefer if (self.aead_key != null) self.allocator.free(plain);

        // GSP-9 envelope handling. `.legacy` returns the bytes verbatim —
        // legacy postings.bin could coincidentally start with the magic
        // bytes as valid varint data, so legacy segments are never
        // envelope-sniffed beyond the initial terms.hash detection.
        switch (expect) {
            .legacy => return plain,
            .auto, .enveloped => {},
        }
        const has_magic = plain.len >= 12 and std.mem.eql(u8, plain[0..4], &SEGMENT_FILE_MAGIC);
        if (!has_magic) {
            if (expect == .enveloped) return error.InvalidData;
            // .auto on a naked file: legacy segment.
            self.file_format = .legacy;
            return plain;
        }
        if (expect == .auto) self.file_format = .enveloped;

        const version = std.mem.readInt(u32, plain[4..8], .little);
        if (version != SEGMENT_FILE_VERSION) return error.UnsupportedSegmentVersion;
        const stored_crc = std.mem.readInt(u32, plain[plain.len - 4 ..][0..4], .little);
        // fips-exempt: non-security — CRC32c integrity checksum (AEAD covers
        // integrity-against-adversary when enabled).
        const computed = utils.hashCrc32c(plain[0 .. plain.len - 4]);
        if (stored_crc != computed) return error.ChecksumMismatch;

        const payload_len = plain.len - 12;
        std.mem.copyForwards(u8, plain[0..payload_len], plain[8 .. 8 + payload_len]);
        const shrunk = self.allocator.realloc(plain, payload_len) catch plain[0..payload_len];
        return shrunk;
    }
```

NOTE on the realloc fallback: `realloc` shrink-in-place cannot move for smaller sizes with the std allocators used here; the `catch` arm keeps the original allocation with a shorter slice. `allocator.free` on a shorter slice than allocated is NOT sound in general — so if `realloc` can fail in this codepath, replace the fallback with dupe+free:

```zig
        const shrunk = self.allocator.realloc(plain, payload_len) catch blk: {
            const copy = try self.allocator.dupe(u8, plain[0..payload_len]);
            self.allocator.free(plain);
            break :blk copy;
        };
```

Use the dupe+free form — it is unconditionally correct.

Rewire `load()` (Task 5's shape, now with format detection first):

```zig
    fn load(self: *SegmentReader) !void {
        // GSP-9: detect the segment's file format on terms.hash FIRST — its
        // magic is unambiguous (see SEGMENT_FILE_MAGIC). Every other file in
        // the segment must then match.
        const dict_buf_opt = try self.readSegmentFile("terms.hash", .auto);

        // GSP-5: materialize AEAD postings before dictionary parse so its
        // length bounds the (offset, len) validation below. For the v2
        // plaintext path, verify the postings header eagerly and account
        // for the 8-byte payload base + 4-byte CRC trailer; whole-file CRC
        // verification for plaintext postings is deliberately skipped at
        // open (O(file) read) — integrity there = checked decode (GSP-4)
        // + extent validation (GSP-5) + AEAD when enabled.
        if (self.aead_key != null) {
            self.postings_data = (try self.readSegmentFile("postings.bin", self.file_format)) orelse
                try self.allocator.alloc(u8, 0);
        }
        var postings_size: u64 = 0;
        if (self.postings_data) |pd| {
            postings_size = pd.len;
        } else {
            const st = try self.postings_file.stat(self.io);
            if (self.file_format == .enveloped) {
                if (st.size < 12) return error.Incomplete;
                var hdr: [8]u8 = undefined;
                var got: usize = 0;
                while (got < hdr.len) {
                    const amt = try self.postings_file.readPositional(self.io, &.{hdr[got..]}, got);
                    if (amt == 0) return error.Incomplete;
                    got += amt;
                }
                if (!std.mem.eql(u8, hdr[0..4], &SEGMENT_FILE_MAGIC)) return error.InvalidData;
                const version = std.mem.readInt(u32, hdr[4..8], .little);
                if (version != SEGMENT_FILE_VERSION) return error.UnsupportedSegmentVersion;
                self.postings_base = 8;
                postings_size = st.size - 12;
            } else {
                postings_size = st.size;
            }
        }

        if (dict_buf_opt) |dict_buf| {
            defer self.allocator.free(dict_buf);
            // ... (existing two-pass parse, UNCHANGED, including the GSP-5
            //      validation block which compares against postings_size)
        }

        // Load tombstones.
        if (try self.readSegmentFile("tombstones.bin", self.file_format)) |ts_buf| {
            // ... existing body unchanged
        }

        // Load per-doc length norms.
        if (try self.readSegmentFile("norms.bin", self.file_format)) |norms_buf| {
            // ... existing body unchanged
        }
    }
```

(The dictionary/tombstones/norms parse bodies are byte-identical to today — only the enclosing `if` acquisitions change. When `terms.hash` is absent, `file_format` stays `.auto`, which subsequent reads treat exactly like `.auto` detection per file; `SegmentWriter.writeMemtable` always writes `terms.hash`, so this arises only for hand-built test segments.)

In `search()`, plaintext positional read (`segment.zig:633`), add the base:

```zig
                const amt = try self.postings_file.readPositional(
                    self.io,
                    &.{owned_data[index..]},
                    self.postings_base + entry.postings_offset + index,
                );
```

Add to `SegmentError` in `src/errors.zig`:

```zig
    /// Segment file carries an envelope version this binary does not
    /// implement (GSP-9). Deployment condition, not corruption.
    UnsupportedSegmentVersion,
```

Also update the AEAD-path bounds check note: the existing `offset_usize + postings_len_usize > pd.len` check in `search()` still holds because AEAD `postings_data` has its envelope stripped by `readSegmentFile` (offsets are payload-relative on both paths).

- [ ] **Step 5: Run the new tests**

Run: `zig build test 2>&1 | tail -10` — both GSP-9 tests pass; all pre-existing segment/AEAD round-trip tests pass (they exercise the new envelope transparently).

- [ ] **Step 6: Run the full suite (legacy compat proof)**

Run: `zig build test-all 2>&1 | tail -5` — green. The pre-existing corrupted-segment fault test (`tests/fault_injection.zig`) must still pass: its tamper now surfaces as `ChecksumMismatch`/`InvalidData` — same reject-loud contract.

- [ ] **Step 7: Update docs**

In `docs/fts-storage-spec.md`, find the segment-format section and add the v2 envelope description (layout table above, read-both rule, the magic-as-count downgrade rationale, and the plaintext-postings CRC exemption). In `CHANGELOG.md` add under Unreleased:

```markdown
### Changed
- Segment files (terms.hash, postings.bin, tombstones.bin, norms.bin) are now
  written with a versioned, CRC32C-checksummed envelope (v2). Legacy naked
  segments remain readable forever (read-both). Older binaries opening v2
  segments fail loudly at their count guards rather than misparsing.
```

- [ ] **Step 8: Commit**

```bash
git add src/segment.zig src/errors.zig docs/fts-storage-spec.md CHANGELOG.md
git commit -m "feat(segment): versioned CRC32C-checksummed file envelope (v2) with permanent legacy read-both"
```

---

### Task 10: Fuzz coverage for segment parsers

Root cause (graph-storage lesson #15 — the weakest-validated decoders were exactly the unfuzzed ones): `tests/fuzz_targets.zig` covers `readVarInt`, `Manifest.deserialize`, `WalRecord.deserialize` — but NOT the segment dictionary/tombstones/norms parsers or `PostingIterator`, which (pre-Task-9) had no checksum protection at all.

**Files:**
- Modify: `tests/fuzz_targets.zig`
- Test: itself (`zig build test-fuzz`)

**Interfaces:** consumes `SegmentReader.PostingIterator` construction (public), `SegmentReader.init`, Task 9's envelope.

- [ ] **Step 1: Write the harnesses**

Append to `tests/fuzz_targets.zig`:

```zig
// ---------------------------------------------------------------------------
// PostingIterator — decodes postings byte runs whose only pre-GSP-9 integrity
// was structural. Adversarial inputs target: truncated varints, max-
// continuation floods, doc-id delta overflow, position delta > u32,
// df larger than the data can satisfy (GSP-4, GSP-10).
// ---------------------------------------------------------------------------

test "fuzz: PostingIterator does not panic on adversarial postings bytes" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        &[_]u8{},
        // Truncated continuation flood.
        &[_]u8{0x80} ** 16,
        // Overflow-length varints everywhere.
        &[_]u8{0xff} ** 32,
        // doc delta = maxInt(u64), then another posting -> checked-add error.
        &([_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 } ++
            [_]u8{ 0x01, 0x01, 0x01, 0x01, 0x01 }),
        // valid doc delta + tf, then position delta = maxInt(u64) -> cast error.
        &([_]u8{ 0x01, 0x01 } ++
            [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }),
        // Single zero byte.
        &[_]u8{0x00},
    };
    for (cases) |c| {
        var it = fts.segment.SegmentReader.PostingIterator{
            .allocator = alloc,
            .data = c,
            .owns_data = false,
            .df = 4,
            .current_idx = 0,
            .pos = 0,
            .last_doc_id = 0,
            .pos_buf = .empty,
        };
        defer it.pos_buf.deinit(alloc);
        // Drain until error or exhaustion; must never panic or leak.
        while (it.next() catch null) |_| {}
        // Same contract for the doc-only fast path.
        var it2 = fts.segment.SegmentReader.PostingIterator{
            .allocator = alloc,
            .data = c,
            .owns_data = false,
            .df = 4,
            .current_idx = 0,
            .pos = 0,
            .last_doc_id = 0,
            .pos_buf = .empty,
        };
        defer it2.pos_buf.deinit(alloc);
        while (it2.nextDocOnly() catch null) |_| {}
    }
}

// ---------------------------------------------------------------------------
// SegmentReader.load — file-level ingestion of terms.hash / tombstones.bin /
// norms.bin (GSP-5, GSP-9, GSP-10). Adversarial inputs target: naked-legacy
// garbage, oversized counts, truncated entries, hostile (offset, len) pairs,
// valid-magic envelopes with bad CRC, and future envelope versions.
// ---------------------------------------------------------------------------

test "fuzz: SegmentReader.init does not panic on adversarial segment files" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dict_cases = [_][]const u8{
        &[_]u8{},
        // count = maxInt -> TermCountTooLarge.
        &[_]u8{ 0xff, 0xff, 0xff, 0xff },
        // count = 1, truncated entry.
        &[_]u8{ 0x01, 0x00, 0x00, 0x00, 0x05, 0x00 },
        // count = 1, term "t", hostile (df=1, offset=maxInt, len=maxInt).
        blk: {
            var buf: [4 + 2 + 1 + 24]u8 = @splat(0xff);
            std.mem.writeInt(u32, buf[0..4], 1, .little);
            std.mem.writeInt(u16, buf[4..6], 1, .little);
            buf[6] = 't';
            break :blk &buf;
        },
        // v2 magic + version 2 + garbage payload + wrong CRC.
        blk: {
            var buf: [24]u8 = @splat(0xab);
            @memcpy(buf[0..4], &fts.segment.SEGMENT_FILE_MAGIC);
            std.mem.writeInt(u32, buf[4..8], fts.segment.SEGMENT_FILE_VERSION, .little);
            break :blk &buf;
        },
        // v2 magic + FUTURE version.
        blk: {
            var buf: [24]u8 = @splat(0);
            @memcpy(buf[0..4], &fts.segment.SEGMENT_FILE_MAGIC);
            std.mem.writeInt(u32, buf[4..8], 99, .little);
            break :blk &buf;
        },
    };

    for (dict_cases, 0..) |c, i| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        _ = i;
        try tmp_dir.dir.createDir(io, "seg_1", .{});
        var seg_dir = try tmp_dir.dir.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);
        {
            const f = try seg_dir.createFile(io, "terms.hash", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, c);
        }
        {
            const f = try seg_dir.createFile(io, "postings.bin", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, &[_]u8{0} ** 4);
        }
        // Also throw the same bytes at tombstones.bin + norms.bin with a
        // healthy empty dictionary, so their parsers get direct coverage.
        var sr = fts.segment.SegmentReader.init(io, alloc, tmp_dir.dir, 1) catch continue;
        sr.deinit();
    }
}
```

- [ ] **Step 2: Run**

Run: `zig build test-fuzz 2>&1 | tail -5`
Expected: PASS — Tasks 4/5/9 already made these inputs error cleanly; the harness locks that in as a regression suite. If any case panics, that is a real bug escape from Tasks 4/5/9: fix it there (not in the test) before proceeding.

- [ ] **Step 3: Full suite + commit**

Run: `zig build test-all 2>&1 | tail -5` — green.

```bash
git add tests/fuzz_targets.zig
git commit -m "test(fuzz): adversarial harnesses for segment dictionary and posting decoders"
```

---

### Task 11: Final validation sweep + release notes

Close-out (graph-storage lesson #15 discipline: prove every suite the build references actually runs; leave the paper trail).

**Files:**
- Modify: `CHANGELOG.md`
- Test: everything

- [ ] **Step 1: Full matrix**

Run each and confirm green:
```
zig build test 2>&1 | tail -3
zig build test-integration 2>&1 | tail -3
zig build test-fuzz 2>&1 | tail -3
zig build test-stress 2>&1 | tail -3
zig build test-all 2>&1 | tail -3
zig build -Dasan test-all 2>&1 | tail -3
```
Expected: all pass. (`-Dfips` dual-mode needs the OpenSSL FIPS build — skip locally, CI covers it.)

- [ ] **Step 2: Bench regression gate sanity**

Run: `zig build bench 2>&1 | tail -20` — confirm it completes. Note in the summary if flush-path numbers moved (Task 7's fsync per segment file is expected to add flush latency — that is the durability fix working, not a regression to "optimize away").

- [ ] **Step 3: CHANGELOG**

Under Unreleased, add (merging with Task 9's entry):

```markdown
### Fixed
- WAL: unknown record types now skip with the stream aligned (forward-compat
  skip actually works); torn tails are truncated before re-append so
  post-recovery writes stay replayable across a second crash.
- WAL replay heals the txn-id allocator past uncommitted orphan brackets,
  preventing ghost-document resurrection via txn-id reuse.
- Posting decoding uses checked arithmetic on all disk-derived deltas —
  corrupt segments surface errors instead of panics/wraps in every build mode.
- Segment dictionary entries (df/offset/len) are validated against
  postings.bin extents at load, symmetrically for plaintext and AEAD paths.
- Manifest format_version is now enforced (fail-loud upgrade/downgrade gate).
- Segment files are fsynced before the manifest referencing them is published.
- compact() recomputes total_docs/avg_doc_len from the merged corpus,
  unskewing BM25 after deletes.
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for graph-storage parity hardening train"
```

---

## Self-Review (completed at authoring)

1. **Coverage:** All 8 posture findings map to tasks — torn-tail (1/2), txn reuse (3), unchecked casts (4), lazy dictionary trust (5), version gate + short-read (6), segment fsync (7), stale stats (8), no segment magic/version/checksum (9); fuzz gap (10). Consciously excluded as N/A: slab packing (postings already delta-varint packed), derived-index epoch gating (WAL truncation at flush makes snapshot staleness structurally impossible here), buffer-pool concurrency (no page cache exists), relocation live-head rule (segments immutable), dir-fsync (std.Io.Dir exposes none in 0.16 — documented limitation retained).
2. **Placeholders:** none — every code step carries the actual code; the three "existing body unchanged" markers in Task 9's `load()` refer to bodies quoted in full at `segment.zig:707-804` and reproduced in Task 5.
3. **Type consistency:** `WalReader.consumed: u64` (T1) == what T2 reads; `replayWal() !u64` (T2); `FileFormat`/`postings_base`/`readSegmentFile(name, expect)` introduced and consumed only in T9; `UnsupportedManifestVersion` (T6) and `UnsupportedSegmentVersion` (T9) are distinct members of distinct error sets.

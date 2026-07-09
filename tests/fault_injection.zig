// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Fault-injection harness for fts-storage (WRK-022, GAP-0016, QUAL-0020,
//! QUAL-0021).
//!
//! These tests deliberately tamper with on-disk state to validate that the
//! Engine recovers, fails-closed, or skips torn data as the design demands.
//! They complement the in-tree unit tests in src/engine.zig (truncated WAL
//! tail, both manifests corrupt) by exercising additional scenarios
//! (corrupted segment file, A/B selective tampering).

const std = @import("std");
const fts = @import("fts_storage");

test "fault: truncated WAL tail survives recovery" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "alpha", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
        try eng.indexDocument(2, &[_]fts.TermPosting{t});
    }

    var wal_dir = try tmp_dir.dir.openDir(io, "wal", .{});
    defer wal_dir.close(io);
    const f = try wal_dir.openFile(io, "fts.wal", .{ .mode = .read_write });
    defer f.close(io);
    const sz = (try f.stat(io)).size;
    try f.setLength(io, sz - 3);

    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();
    try std.testing.expect(eng.memtable.dictionary.contains("alpha"));
}

test "fault: corrupted segment file rejected on open" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "bravo", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
        try eng.flush();
    }

    // Corrupt the freshly-flushed segment's terms.hash file. Any byte
    // overwrite in the segment's header or hash table should make
    // SegmentReader.init fail at open time.
    {
        var seg_root = try tmp_dir.dir.openDir(io, "segments", .{});
        defer seg_root.close(io);
        var seg_dir = try seg_root.openDir(io, "seg_1", .{});
        defer seg_dir.close(io);
        const tf = try seg_dir.openFile(io, "terms.hash", .{ .mode = .read_write });
        defer tf.close(io);
        const buf = [_]u8{0xFF};
        try tf.writePositionalAll(io, &buf, 0);
    }

    // Reopen — must propagate an error rather than silently continue with a
    // segment whose contents are unverifiable.
    const result = fts.Engine.init(io, alloc, tmp_dir.dir);
    if (result) |e| {
        e.deinit();
        try std.testing.expect(false); // should not reach
    } else |_| {
        // Pass — any error is acceptable so long as recovery did not
        // silently accept the corrupted segment.
    }
}

test "fault: one corrupt manifest, engine selects the valid one" {
    // WRK-023 (GAP-0028): when only one of manifest.{a,b} is corrupt,
    // recovery must fall back to the valid copy rather than fail closed.
    // The "both corrupt" failure-mode is asserted by the unit test in
    // src/engine.zig; this complements it by exercising selective tampering.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Bootstrap with two flushes so both manifest.a and manifest.b are on
    // disk (the A/B rotation alternates by counter parity).
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "x", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
        try eng.flush();
        try eng.indexDocument(2, &[_]fts.TermPosting{t});
        try eng.flush();
    }

    // The A/B rotation writes counter=1 to manifest.b (odd parity) and
    // counter=2 to manifest.a (even parity). Corrupt the older slot
    // (manifest.b, counter=1) — the engine must still recover the latest
    // committed state from manifest.a (counter=2, 2 segments).
    {
        const f = try tmp_dir.dir.openFile(io, "manifest.b", .{ .mode = .read_write });
        defer f.close(io);
        const sz = (try f.stat(io)).size;
        const buf = [_]u8{0xFF};
        try f.writePositionalAll(io, &buf, sz - 1);
    }

    // Reopen — must succeed by selecting manifest.a and load both segments.
    var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 2), eng.segments.items.len);
}

test "fault: both manifests corrupt fails closed" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = fts.TermPosting{ .term = "x", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]fts.TermPosting{t});
        try eng.flush();
        try eng.indexDocument(2, &[_]fts.TermPosting{t});
        try eng.flush();
    }

    const corrupt_byte = [_]u8{0xFF};
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |name| {
        const f = tmp_dir.dir.openFile(io, name, .{ .mode = .read_write }) catch continue;
        defer f.close(io);
        const sz = (try f.stat(io)).size;
        try f.writePositionalAll(io, &corrupt_byte, sz - 1);
    }

    try std.testing.expectError(error.ManifestCorrupt, fts.Engine.init(io, alloc, tmp_dir.dir));
}

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
        // Scope the iterator so its shared lock is released before the
        // write below — TermIterator holds the engine rw-lock shared for
        // its whole lifetime, and indexDocument needs it exclusive.
        {
            var it_g = try fts.TermIterator.init(alloc, eng, "ghost");
            defer it_g.deinit();
            try std.testing.expect((try it_g.next()) == null);
        }

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

test "fault: skipped unknown-type WAL record still heals txn allocator (GSP-3 follow-up)" {
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

    // Simulate a forward-compat record from a newer binary: a fully
    // CRC-valid record whose type byte (9) this binary doesn't recognize.
    // WalReader.next() skips it via error.InvalidData but still advances
    // `consumed` (GSP-1) -- so these bytes survive on disk and their
    // txn_id (2) must never be reissued to a new write.
    {
        var wal_dir = try tmp_dir.dir.openDir(io, "wal", .{});
        defer wal_dir.close(io);
        const f = try wal_dir.createFile(io, "fts.wal", .{ .truncate = false });
        defer f.close(io);
        const stat = try f.stat(io);

        const future = fts.wal.WalRecord{ .record_type = .index_doc, .txn_id = 2, .doc_id = 999, .payload = "future-payload" };
        const raw = try future.serialize(alloc);
        defer alloc.free(raw);
        raw[0] = 9; // unknown type
        const crc = fts.utils.hashCrc32c(raw[0 .. raw.len - 4]);
        std.mem.writeInt(u32, raw[raw.len - 4 ..][0..4], crc, .little);

        try f.writePositionalAll(io, raw, stat.size);
        try f.sync(io);
    }

    // Session 2: reopen. Pre-fix, the skipped record's txn_id (2) never
    // reaches `max_seen_txn` (it's fed only by records that survive into
    // the drained `all` list), so `next_txn_id` stays at 2 and the very
    // next write reuses txn 2 -- the crisp pre/post-fix observable.
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expect(eng.next_txn_id.load(.monotonic) >= 3);

        const t = fts.TermPosting{ .term = "fresh", .positions = &[_]u32{1} };
        try eng.indexDocument(3, &[_]fts.TermPosting{t});
    }

    // Session 3: must reopen cleanly and "fresh" must be visible. (The
    // unknown-type record never gets its payload parsed at all, so no
    // ghost term can appear here regardless -- the load-bearing assertion
    // is `next_txn_id` in session 2 above.)
    {
        var eng = try fts.Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        var it_f = try fts.TermIterator.init(alloc, eng, "fresh");
        defer it_f.deinit();
        try std.testing.expect((try it_f.next()) != null);
    }
}

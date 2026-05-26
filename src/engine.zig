// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const manifest = @import("manifest.zig");
const wal = @import("wal.zig");
const segment = @import("segment.zig");
const limits = @import("limits.zig");

pub const Error = @import("errors.zig").EngineError;

pub const TermPosting = struct {
    term: []const u8,
    positions: []const u32,
};

pub const Engine = struct {
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,

    wal_dir: std.Io.Dir,
    seg_dir: std.Io.Dir,

    current_manifest: manifest.Manifest,
    memtable: segment.Memtable,
    segments: std.ArrayListUnmanaged(segment.SegmentReader),

    wal_file: std.Io.File,
    wal_writer: wal.WalWriter,
    next_txn_id: u64 = 1,

    /// Initialize an Engine on the given directory.
    ///
    /// Ownership: the caller retains ownership of `base_dir`. Engine will open
    /// (and close on deinit) the `wal/` and `segments/` subdirs of `base_dir`,
    /// but will NOT close `base_dir` itself. The caller must `base_dir.close(io)`
    /// after `Engine.deinit`.
    pub fn init(io: std.Io, allocator: Allocator, base_dir: std.Io.Dir) !*Engine {
        var engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);

        engine.allocator = allocator;
        engine.io = io;
        engine.dir = base_dir;
        engine.memtable = segment.Memtable.init(allocator);
        engine.segments = .empty;

        // Ensure subdirectories exist. Dir mode 0o700 (owner-only) keeps the
        // WAL and segment data unreadable to other local users on POSIX
        // systems (SEC-09, SEC-EXT-0302). On platforms where `Permissions` is
        // a zero-sized enum (Windows, WASI) this collapses to default_dir.
        base_dir.createDir(io, "wal", utils.dirMode(0o700)) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        base_dir.createDir(io, "segments", utils.dirMode(0o700)) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        engine.wal_dir = try base_dir.openDir(io, "wal", .{});
        engine.seg_dir = try base_dir.openDir(io, "segments", .{});

        // Load Manifest A/B. Distinguish between "absent" (FileNotFound) and
        // "corrupt" (any other deserialize failure). A present-but-corrupt
        // manifest must fail closed rather than silently start fresh, which
        // would silently lose every previously flushed segment.
        const man_a = try loadManifestOptional(io, allocator, base_dir, "manifest.a");
        const man_b = try loadManifestOptional(io, allocator, base_dir, "manifest.b");

        if (man_a == null and man_b == null) {
            engine.current_manifest = manifest.Manifest{};
        } else {
            engine.current_manifest = try manifest.Manifest.selectManifest(man_a, man_b);
        }

        // Deinit whichever manifest was not selected
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

        // Load segments
        try engine.segments.ensureTotalCapacity(allocator, engine.current_manifest.segments.items.len);
        for (engine.current_manifest.segments.items) |seg_entry| {
            const seg_reader = try segment.SegmentReader.init(io, allocator, engine.seg_dir, seg_entry.id);
            engine.segments.appendAssumeCapacity(seg_reader);
        }

        engine.next_txn_id = engine.current_manifest.last_checkpoint_lsn + 1;

        // Replay WAL
        try engine.replayWal();

        // Open WAL for writing
        engine.wal_file = try engine.wal_dir.createFile(io, "fts.wal", .{
            .truncate = false,
            .permissions = utils.fileMode(0o600),
        });
        engine.wal_writer = try wal.WalWriter.init(io, engine.wal_file, allocator);

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.wal_file.close(self.io);
        self.wal_dir.close(self.io);

        for (self.segments.items) |*seg_reader| {
            seg_reader.deinit();
        }
        self.segments.deinit(self.allocator);
        self.seg_dir.close(self.io);

        self.current_manifest.deinit(self.allocator);
        self.memtable.deinit();
        self.allocator.destroy(self);
    }

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

    /// Returns null only for FileNotFound. Any other error (checksum mismatch,
    /// invalid magic, truncated payload, oversize manifest) is mapped to
    /// error.ManifestCorrupt so a present-but-corrupt manifest fails closed
    /// instead of being silently treated as "no manifest" (QUAL-0004,
    /// SEC-EXT-0305).
    fn loadManifestOptional(
        io: std.Io,
        allocator: Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) !?manifest.Manifest {
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

    fn replayWal(self: *Engine) !void {
        const file = self.wal_dir.openFile(self.io, "fts.wal", .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(self.io);

        var reader = wal.WalReader.init(self.io, file, self.allocator);
        while (try reader.next()) |rec| {
            var r = rec;
            defer r.deinit(self.allocator);

            // Only process records if their txn_id > last_checkpoint_lsn
            if (r.txn_id <= self.current_manifest.last_checkpoint_lsn) continue;

            if (r.txn_id >= self.next_txn_id) {
                self.next_txn_id = r.txn_id + 1;
            }

            switch (r.record_type) {
                .index_doc => {
                    try self.applyIndexDocPayload(r.doc_id, r.payload);
                },
                .delete_doc => {
                    try self.memtable.addTombstone(r.doc_id);
                },
                else => {},
            }
        }
    }

    fn applyIndexDocPayload(self: *Engine, doc_id: u64, payload: []const u8) !void {
        var pos: usize = 0;
        var pos_buf: std.ArrayListUnmanaged(u32) = .empty;
        defer pos_buf.deinit(self.allocator);

        while (pos < payload.len) {
            // Read term length
            if (pos + 2 > payload.len) return error.InvalidData;
            const term_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
            pos += 2;

            if (pos + term_len > payload.len) return error.InvalidData;
            const term = payload[pos .. pos + term_len];
            pos += term_len;

            // Read num positions
            if (pos + 2 > payload.len) return error.InvalidData;
            const num_pos = std.mem.readInt(u16, payload[pos..][0..2], .little);
            pos += 2;

            if (num_pos > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;

            pos_buf.clearRetainingCapacity();
            try pos_buf.ensureTotalCapacity(self.allocator, num_pos);

            var i: u16 = 0;
            while (i < num_pos) : (i += 1) {
                const res = try utils.readVarInt(payload[pos..]);
                const pos_value = std.math.cast(u32, res.val) orelse return error.PositionOutOfRange;
                pos_buf.appendAssumeCapacity(pos_value);
                pos += res.bytes_read;
            }

            try self.memtable.addPosting(term, doc_id, pos_buf.items);
        }
    }

    pub fn indexDocument(self: *Engine, doc_id: u64, terms: []const TermPosting) !void {
        // Validate inputs at the API boundary before any side effects
        // (SEC-EXT-0101, 0102, 0103, 0104, 0105, 0107, 0205, 0208).
        for (terms) |t| {
            if (t.term.len == 0) return error.EmptyTerm;
            if (t.term.len > limits.MAX_TERM_LEN) return error.TermTooLong;
            if (t.positions.len > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;
            var i: usize = 1;
            while (i < t.positions.len) : (i += 1) {
                if (t.positions[i] < t.positions[i - 1]) return error.PositionsNotMonotonic;
            }
        }

        const txn_id = self.next_txn_id;

        // Serialize payload first; no memtable mutation yet.
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

        // WAL first — durable before in-memory mutation. If WAL append/sync
        // fails the memtable stays untouched and the next flush cannot diverge
        // from the durable log (QUAL-0007).
        try self.wal_writer.append(rec);
        try self.wal_writer.sync();

        // Only mutate memtable after WAL is durable. Bump next_txn_id last so
        // a partial failure does not consume a txn id.
        for (terms) |t| {
            try self.memtable.addPosting(t.term, doc_id, t.positions);
        }
        self.next_txn_id += 1;
    }

    pub fn deleteDocument(self: *Engine, doc_id: u64) !void {
        const txn_id = self.next_txn_id;
        self.next_txn_id += 1;

        try self.memtable.addTombstone(doc_id);

        const rec = wal.WalRecord{
            .record_type = .delete_doc,
            .txn_id = txn_id,
            .doc_id = doc_id,
        };

        try self.wal_writer.append(rec);
        try self.wal_writer.sync();
    }

    pub fn flush(self: *Engine) !void {
        if (self.memtable.dictionary.count() == 0 and self.memtable.tombstones.count() == 0) return;

        const next_segment_id = self.current_manifest.counter + 1;

        var writer = segment.SegmentWriter{
            .io = self.io,
            .dir = self.seg_dir,
            .allocator = self.allocator,
            .segment_id = next_segment_id,
        };

        try writer.writeMemtable(&self.memtable);

        // Add to manifest
        try self.current_manifest.segments.append(self.allocator, .{
            .id = next_segment_id,
            .doc_count = self.memtable.total_docs,
            .tombstone_count = self.memtable.tombstones.count(),
        });

        // Plumb running totals up to the manifest (QUAL-0006, DC-2, DC-3,
        // GAP-0007). avg_doc_len is intentionally left at zero here; the
        // length-weighted aggregation is deferred to WRK-035 (BM25 length
        // normalization) which needs per-doc length tracking the memtable
        // does not yet capture.
        self.current_manifest.total_docs += self.memtable.total_docs;

        self.current_manifest.counter += 1;
        self.current_manifest.last_checkpoint_lsn = self.next_txn_id - 1;

        // Atomic write Manifest
        const man_file = if (self.current_manifest.counter % 2 == 0) "manifest.a" else "manifest.b";
        try self.current_manifest.writeToFile(self.io, self.dir, man_file, self.allocator);

        // Truncate WAL
        self.wal_file.close(self.io);
        self.wal_file = try self.wal_dir.createFile(self.io, "fts.wal", .{
            .truncate = true,
            .permissions = utils.fileMode(0o600),
        });
        self.wal_writer = try wal.WalWriter.init(self.io, self.wal_file, self.allocator);

        // Open SegmentReader and add to segments list
        const seg_reader = try segment.SegmentReader.init(self.io, self.allocator, self.seg_dir, next_segment_id);
        try self.segments.append(self.allocator, seg_reader);

        // Clear memtable
        self.memtable.deinit();
        self.memtable = segment.Memtable.init(self.allocator);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Engine index, flush, and recover" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();

        const t1 = TermPosting{ .term = "hello", .positions = &[_]u32{ 1, 5 } };
        const t2 = TermPosting{ .term = "world", .positions = &[_]u32{2} };

        try eng.indexDocument(1, &[_]TermPosting{ t1, t2 });
        try eng.indexDocument(2, &[_]TermPosting{t1});
        try eng.deleteDocument(2);

        // Before flush: documents in memtable, 0 segments
        try std.testing.expectEqual(@as(usize, 2), eng.memtable.dictionary.count());
        try std.testing.expectEqual(@as(usize, 1), eng.memtable.tombstones.count());
        try std.testing.expectEqual(@as(usize, 0), eng.segments.items.len);

        try eng.flush();

        // After flush: 1 segment, memtable empty
        try std.testing.expectEqual(@as(usize, 0), eng.memtable.dictionary.count());
        try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
        try std.testing.expectEqual(@as(usize, 1), eng.current_manifest.counter);
    }

    {
        // Re-open engine
        var eng2 = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng2.deinit();

        // Manifest should have loaded the segment
        try std.testing.expectEqual(@as(usize, 1), eng2.current_manifest.counter);
        try std.testing.expectEqual(@as(usize, 1), eng2.segments.items.len);

        // Memtable should be empty (WAL was truncated on flush)
        try std.testing.expectEqual(@as(usize, 0), eng2.memtable.dictionary.count());
        try std.testing.expectEqual(@as(usize, 0), eng2.memtable.tombstones.count());

        // Index another document to test WAL recovery
        const t3 = TermPosting{ .term = "test", .positions = &[_]u32{10} };
        try eng2.indexDocument(3, &[_]TermPosting{t3});
    }

    {
        // Re-open engine again without flushing
        var eng3 = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng3.deinit();

        // Manifest loaded 1 segment
        try std.testing.expectEqual(@as(usize, 1), eng3.current_manifest.counter);
        try std.testing.expectEqual(@as(usize, 1), eng3.segments.items.len);

        // WAL replayed doc 3
        try std.testing.expectEqual(@as(usize, 1), eng3.memtable.dictionary.count());
        try std.testing.expect(eng3.memtable.dictionary.contains("test"));
    }
}

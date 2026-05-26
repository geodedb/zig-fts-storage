// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const manifest = @import("manifest.zig");
const wal = @import("wal.zig");
const segment = @import("segment.zig");

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

    wal_file: ?std.Io.File = null,
    wal_writer: ?wal.WalWriter = null,
    next_txn_id: u64 = 1,

    pub fn init(io: std.Io, allocator: Allocator, base_dir: std.Io.Dir) !*Engine {
        var engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);

        engine.allocator = allocator;
        engine.io = io;
        engine.dir = base_dir;
        engine.memtable = segment.Memtable.init(allocator);
        engine.segments = .empty;

        // Ensure subdirectories exist
        base_dir.createDir(io, "wal", .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        base_dir.createDir(io, "segments", .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        engine.wal_dir = try base_dir.openDir(io, "wal", .{});
        engine.seg_dir = try base_dir.openDir(io, "segments", .{});

        // Load Manifest A/B
        const man_a = loadManifest(io, allocator, base_dir, "manifest.a") catch null;
        const man_b = loadManifest(io, allocator, base_dir, "manifest.b") catch null;
        engine.current_manifest = manifest.Manifest.selectManifest(man_a, man_b) catch manifest.Manifest{};

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
        engine.wal_file = try engine.wal_dir.createFile(io, "fts.wal", .{ .truncate = false });
        engine.wal_writer = wal.WalWriter.init(io, engine.wal_file.?, allocator);

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        if (self.wal_file) |*file| {
            file.close(self.io);
        }
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
        const data = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(data);
        var iov = [_][]u8{data};
        _ = try file.readStreaming(io, &iov);
        return try manifest.Manifest.deserialize(allocator, data);
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

            pos_buf.clearRetainingCapacity();
            try pos_buf.ensureTotalCapacity(self.allocator, num_pos);

            var i: u16 = 0;
            while (i < num_pos) : (i += 1) {
                const res = try utils.readVarInt(payload[pos..]);
                pos_buf.appendAssumeCapacity(@intCast(res.val));
                pos += res.bytes_read;
            }

            try self.memtable.addPosting(term, doc_id, pos_buf.items);
        }
    }

    pub fn indexDocument(self: *Engine, doc_id: u64, terms: []const TermPosting) !void {
        const txn_id = self.next_txn_id;
        self.next_txn_id += 1;

        // Serialize payload
        var payload_list: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_list.deinit(self.allocator);

        var num_buf: [4]u8 = undefined;
        for (terms) |t| {
            std.mem.writeInt(u16, num_buf[0..2], @intCast(t.term.len), .little);
            try payload_list.appendSlice(self.allocator, num_buf[0..2]);
            try payload_list.appendSlice(self.allocator, t.term);

            std.mem.writeInt(u16, num_buf[0..2], @intCast(t.positions.len), .little);
            try payload_list.appendSlice(self.allocator, num_buf[0..2]);

            for (t.positions) |p| {
                var vbuf: [10]u8 = undefined;
                const written = try utils.writeVarInt(&vbuf, p);
                try payload_list.appendSlice(self.allocator, vbuf[0..written]);
            }

            try self.memtable.addPosting(t.term, doc_id, t.positions);
        }

        const rec = wal.WalRecord{
            .record_type = .index_doc,
            .txn_id = txn_id,
            .doc_id = doc_id,
            .payload = payload_list.items,
        };

        try self.wal_writer.?.append(rec);
        try self.wal_writer.?.sync();
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

        try self.wal_writer.?.append(rec);
        try self.wal_writer.?.sync();
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

        self.current_manifest.counter += 1;
        self.current_manifest.last_checkpoint_lsn = self.next_txn_id - 1;

        // Atomic write Manifest
        const man_file = if (self.current_manifest.counter % 2 == 0) "manifest.a" else "manifest.b";
        try self.current_manifest.writeToFile(self.io, self.dir, man_file, self.allocator);

        // Truncate WAL
        if (self.wal_file) |*f| {
            f.close(self.io);
        }
        self.wal_file = try self.wal_dir.createFile(self.io, "fts.wal", .{ .truncate = true });
        self.wal_writer = wal.WalWriter.init(self.io, self.wal_file.?, self.allocator);

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

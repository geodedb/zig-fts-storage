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
    /// Optional FLE-style field tag. When set, the caller may pass an
    /// `excluded_fields` list to `Engine.indexDocumentExcluding` so the
    /// engine refuses to ingest postings tagged with a sensitive field
    /// (GAP-0010). Default null preserves the prior un-tagged behavior.
    field: ?[]const u8 = null,
};

/// Opt-in security knobs for `Engine.initWithConfig`. Every field defaults to
/// the pre-WRK-037 / WRK-038 behavior so existing callers, on-disk layouts,
/// and unit tests continue to work unchanged.
pub const EngineConfig = struct {
    /// If set, every WAL record and manifest carries a trailing 32-byte
    /// HMAC-SHA256 envelope computed over (existing bytes || crc).
    /// Reads verify the tag and return `error.HmacMismatch` on failure
    /// (SEC-02, SEC-EXT-0401, GAP-0027). Caller retains key ownership.
    hmac_key: ?[]const u8 = null,

    /// If set, segment data files (postings.bin, terms.hash, norms.bin,
    /// tombstones.bin) are encrypted with AES-256-GCM. Must be exactly 32
    /// bytes (the AES-256 key length). Each file gets a fresh random 12-byte
    /// nonce stored at the head, then ciphertext, then the 16-byte tag at
    /// the tail (GAP-0009, SEC-EXT-0402). Caller retains key ownership.
    aead_key: ?[]const u8 = null,
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

    /// Engine-wide aggregated tombstone set. Built at init from every segment's
    /// tombstones plus the memtable's tombstones; updated incrementally on
    /// deleteDocument. Lets TermIterator.isDeleted run in O(1) instead of
    /// scanning every segment per matched doc (PERF-0006, WRK-031).
    all_tombstones: std.AutoHashMapUnmanaged(u64, void) = .empty,

    wal_file: std.Io.File,
    wal_writer: wal.WalWriter,
    next_txn_id: u64 = 1,

    /// Optional HMAC-SHA256 key for WAL + manifest envelopes (SEC-02,
    /// SEC-EXT-0401, GAP-0027). Null = unchanged on-disk format. Caller owns
    /// the key memory; the engine merely borrows the slice.
    hmac_key: ?[]const u8 = null,

    /// Optional AES-256-GCM key for segment-at-rest encryption (GAP-0009,
    /// SEC-EXT-0402). Null = plaintext segments. Must be 32 bytes when set.
    aead_key: ?[]const u8 = null,

    /// Initialize an Engine on the given directory.
    ///
    /// Ownership: the caller retains ownership of `base_dir`. Engine will open
    /// (and close on deinit) the `wal/` and `segments/` subdirs of `base_dir`,
    /// but will NOT close `base_dir` itself. The caller must `base_dir.close(io)`
    /// after `Engine.deinit`.
    ///
    /// SECURITY (SEC-EXT-0301): the caller MUST ensure `base_dir` and its
    /// `wal/` and `segments/` subtrees are not writable by adversaries.
    /// Reads pass `follow_symlinks = false` so a symlink swap on an existing
    /// file is rejected, but Zig 0.16's `std.Io.Dir.CreateFileOptions` does
    /// not expose an O_NOFOLLOW equivalent — so a pre-positioned symlink at
    /// a path the engine will *create* (`manifest.{a,b}.tmp`, `fts.wal`,
    /// `segments/seg_*/...`) would be followed. The owner-only `0o700` dir
    /// permissions on `wal/` and `segments/` mitigate the local-user case,
    /// but the parent `base_dir` is the caller's responsibility.
    pub fn init(io: std.Io, allocator: Allocator, base_dir: std.Io.Dir) !*Engine {
        return initWithConfig(io, allocator, base_dir, .{});
    }

    /// Initialize an Engine with optional opt-in security features
    /// (HMAC-SHA256 envelopes, AES-256-GCM segment-at-rest encryption).
    /// With a default-initialized config this is byte-for-byte equivalent to
    /// `init` (SEC-02, SEC-EXT-0401, SEC-EXT-0402, GAP-0009, GAP-0027).
    pub fn initWithConfig(
        io: std.Io,
        allocator: Allocator,
        base_dir: std.Io.Dir,
        config: EngineConfig,
    ) !*Engine {
        // Fail fast on misconfigured keys so the error surface stays close to
        // the caller. AES-256-GCM requires a 32-byte key; refusing other
        // lengths up front avoids a confusing failure deep in flush().
        if (config.aead_key) |k| {
            if (k.len != 32) return error.InvalidKey;
        }

        var engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);

        engine.allocator = allocator;
        engine.io = io;
        engine.dir = base_dir;
        engine.hmac_key = config.hmac_key;
        engine.aead_key = config.aead_key;
        engine.memtable = segment.Memtable.init(allocator);
        errdefer engine.memtable.deinit();
        engine.segments = .empty;
        errdefer {
            for (engine.segments.items) |*seg_reader| seg_reader.deinit();
            engine.segments.deinit(allocator);
        }
        engine.all_tombstones = .empty;
        errdefer engine.all_tombstones.deinit(allocator);

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
        errdefer engine.wal_dir.close(io);
        engine.seg_dir = try base_dir.openDir(io, "segments", .{});
        errdefer engine.seg_dir.close(io);

        // Load Manifest A/B. Distinguish between "absent" (FileNotFound) and
        // "corrupt" (any other deserialize failure). The A/B rotation is
        // designed so that one corrupt slot does not block recovery — fall
        // back to the still-valid copy. Only if BOTH are corrupt do we fail
        // closed, since silently starting fresh would drop every previously
        // flushed segment (WRK-023, GAP-0028, SEC-EXT-0304).
        const res_a = loadManifestResult(io, allocator, base_dir, "manifest.a", config.hmac_key);
        const res_b = loadManifestResult(io, allocator, base_dir, "manifest.b", config.hmac_key);

        // HMAC mismatch on EITHER slot is treated as fail-loud: a tampered or
        // wrong-key manifest must not be silently masked by falling back to
        // the other slot (SEC-02, SEC-EXT-0401, GAP-0027). The A/B fallback
        // is explicitly designed to recover from bit rot, not tampering.
        if (res_a == .hmac_mismatch or res_b == .hmac_mismatch) return error.HmacMismatch;

        if (res_a == .corrupt and res_b == .corrupt) return error.ManifestCorrupt;

        const man_a: ?manifest.Manifest = if (res_a == .ok) res_a.ok else null;
        const man_b: ?manifest.Manifest = if (res_b == .ok) res_b.ok else null;

        if (man_a == null and man_b == null) {
            engine.current_manifest = manifest.Manifest{};
        } else {
            engine.current_manifest = try manifest.Manifest.selectManifest(man_a, man_b);
        }
        errdefer engine.current_manifest.deinit(allocator);

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

        // Load segments. Each successful SegmentReader is appended to
        // engine.segments before the next is attempted, so the errdefer
        // above will tear down whatever was loaded if a later segment
        // fails to open (WRK-022).
        try engine.segments.ensureTotalCapacity(allocator, engine.current_manifest.segments.items.len);
        for (engine.current_manifest.segments.items) |seg_entry| {
            const seg_reader = try segment.SegmentReader.initWithAead(
                io,
                allocator,
                engine.seg_dir,
                seg_entry.id,
                config.aead_key,
            );
            engine.segments.appendAssumeCapacity(seg_reader);
        }

        engine.next_txn_id = engine.current_manifest.last_checkpoint_lsn + 1;

        // Replay WAL
        try engine.replayWal();

        // Build the engine-wide aggregated tombstone set so isDeleted is O(1)
        // (PERF-0006, WRK-031). Walk every segment's tombstones plus the
        // memtable's tombstones (memtable may have been populated by WAL
        // replay above).
        for (engine.segments.items) |*seg_reader| {
            var ts_it = seg_reader.tombstones.iterator();
            while (ts_it.next()) |entry| {
                try engine.all_tombstones.put(allocator, entry.key_ptr.*, {});
            }
        }
        var mt_it = engine.memtable.tombstones.iterator();
        while (mt_it.next()) |entry| {
            try engine.all_tombstones.put(allocator, entry.key_ptr.*, {});
        }

        // Open WAL for writing
        engine.wal_file = try engine.wal_dir.createFile(io, "fts.wal", .{
            .truncate = false,
            .permissions = utils.fileMode(0o600),
        });
        errdefer engine.wal_file.close(io);
        engine.wal_writer = try wal.WalWriter.initWithHmac(
            io,
            engine.wal_file,
            allocator,
            config.hmac_key,
        );

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.wal_writer.deinit();
        self.wal_file.close(self.io);
        self.wal_dir.close(self.io);

        for (self.segments.items) |*seg_reader| {
            seg_reader.deinit();
        }
        self.segments.deinit(self.allocator);
        self.seg_dir.close(self.io);

        self.current_manifest.deinit(self.allocator);
        self.memtable.deinit();
        self.all_tombstones.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn loadManifest(
        io: std.Io,
        allocator: Allocator,
        dir: std.Io.Dir,
        path: []const u8,
        hmac_key: ?[]const u8,
    ) !manifest.Manifest {
        // SEC-EXT-0301: refuse to follow symlinks so an adversary with
        // directory write access cannot redirect manifest reads at a sensitive
        // file (e.g. swap manifest.a for a symlink to /etc/passwd).
        const file = try dir.openFile(io, path, .{ .follow_symlinks = false });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.size > limits.MAX_MANIFEST_BYTES) return error.ManifestTooLarge;
        const size_usize = std.math.cast(usize, stat.size) orelse return error.ManifestTooLarge;
        const data = try allocator.alloc(u8, size_usize);
        defer allocator.free(data);
        var iov = [_][]u8{data};
        _ = try file.readStreaming(io, &iov);
        return try manifest.Manifest.deserializeWithHmac(allocator, data, hmac_key);
    }

    /// Three-state result for a single manifest slot. Used by Engine.init to
    /// distinguish "absent" from "present but corrupt" so the A/B rotation
    /// can fall back to the surviving copy when only one slot is damaged
    /// (WRK-023, GAP-0028).
    const ManifestLoadResult = union(enum) {
        /// File opened, parsed, and CRC-validated successfully.
        ok: manifest.Manifest,
        /// File did not exist on disk (FileNotFound). Normal on first boot.
        absent,
        /// File existed but failed to parse (bad CRC, bad magic, truncated,
        /// or oversize). Caller decides whether to fail closed (both slots
        /// corrupt) or fall through (other slot still valid).
        corrupt,
        /// File existed and parsed, but the trailing HMAC tag did not verify
        /// against the engine's configured key. Distinct from `corrupt` so the
        /// caller can fail loud rather than silently fall back to the other
        /// slot — wrong key / tampering must not be hidden.
        hmac_mismatch,
    };

    /// Three-state result with a fourth out-of-band `hmac_mismatch`. HMAC
    /// failures get their own slot because — unlike a CRC mismatch which can
    /// be the result of bit rot — an HMAC mismatch with a correct key strongly
    /// implies tampering or a wrong key, and the caller must surface it
    /// rather than silently fall through to "this slot is unusable"
    /// (SEC-02, SEC-EXT-0401, GAP-0027).
    fn loadManifestResult(
        io: std.Io,
        allocator: Allocator,
        dir: std.Io.Dir,
        path: []const u8,
        hmac_key: ?[]const u8,
    ) ManifestLoadResult {
        if (loadManifest(io, allocator, dir, path, hmac_key)) |m| {
            return .{ .ok = m };
        } else |err| switch (err) {
            error.FileNotFound => return .absent,
            // Surface HMAC mismatch separately so a wrong key fails loud
            // instead of being indistinguishable from generic corruption.
            error.HmacMismatch => return .hmac_mismatch,
            // Treat any parse / validation failure as "this slot is
            // unusable". The caller only fails closed when *both* slots
            // are unusable; one corrupt slot still allows recovery from
            // the other (WRK-023). Lumping IO / OOM in here is acceptable
            // because the alternative — propagating those errors — would
            // surface a fail-closed even when the other slot is healthy,
            // which is exactly the silent-data-loss regression A/B
            // rotation exists to prevent.
            else => return .corrupt,
        }
    }

    fn replayWal(self: *Engine) !void {
        // SEC-EXT-0301: O_NOFOLLOW on the WAL — an attacker with write access
        // to the wal/ directory must not be able to redirect replay through a
        // symlink.
        const file = self.wal_dir.openFile(self.io, "fts.wal", .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(self.io);

        var reader = wal.WalReader.initWithHmac(self.io, file, self.allocator, self.hmac_key);

        // WRK-025 (GAP-0012, GAP-0013): WAL replay groups records by txn_id
        // and applies payload records (index_doc / delete_doc) only if their
        // matching COMMIT was observed. A crash mid-indexDocument leaves the
        // BEGIN+payload on disk without a COMMIT — those records must be
        // dropped on recovery so the memtable never reflects partial state.
        //
        // First pass: drain the file into a flat list, tolerating a torn tail
        // exactly like the pre-bracketing replay did (PERF-0014, PERF-0019,
        // SEC-EXT-0211, SEC-EXT-0212). InvalidData (unknown record type) is
        // skipped for forward-compat so a newer record type doesn't brick
        // rollback to an older binary. HMAC mismatch (SEC-02, SEC-EXT-0401)
        // is the one error that must NOT be swallowed: a wrong key or a
        // tampered WAL has to surface, not be silently dropped.
        //
        // Memory note: this currently buffers every record. For v0.1 the
        // per-record cap (10 MiB) × bounded WAL length is acceptable;
        // streaming two-pass replay is deferred (WRK-025 follow-up).
        var all: std.ArrayListUnmanaged(wal.WalRecord) = .empty;
        defer {
            for (all.items) |*r| r.deinit(self.allocator);
            all.deinit(self.allocator);
        }

        while (true) {
            const rec_opt = reader.next() catch |err| switch (err) {
                error.Incomplete,
                error.EndOfStream,
                error.ChecksumMismatch,
                => break,
                error.InvalidData => continue,
                else => return err,
            };
            const rec = rec_opt orelse break;
            try all.append(self.allocator, rec);
        }

        // Second pass: build the set of committed txn_ids.
        var committed: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer committed.deinit(self.allocator);
        for (all.items) |r| {
            if (r.record_type == .commit) {
                try committed.put(self.allocator, r.txn_id, {});
            }
        }

        // Third pass: apply payload records whose txn was committed and
        // sits past the checkpoint. begin/commit themselves contribute no
        // payload to apply.
        for (all.items) |r| {
            if (r.txn_id <= self.current_manifest.last_checkpoint_lsn) continue;
            if (!committed.contains(r.txn_id)) continue;
            if (r.txn_id >= self.next_txn_id) self.next_txn_id = r.txn_id + 1;
            switch (r.record_type) {
                .index_doc => try self.applyIndexDocPayload(r.doc_id, r.payload),
                .delete_doc => try self.memtable.addTombstone(r.doc_id),
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

    /// Field-Level Encryption (FLE) field-exclusion guard.
    ///
    /// Refuses to ingest a `TermPosting` whose `field` tag matches any entry
    /// in `excluded_fields`. The check runs before WAL append or memtable
    /// mutation so a rejected batch leaves the engine state unchanged
    /// (WRK-040, GAP-0010).
    ///
    /// We chose explicit `error.FieldExcluded` over silent skipping because
    /// silently dropping a sensitive field would let a misconfigured caller
    /// believe the field was indexed when it was not — the resulting search
    /// results would be incomplete in a way the caller could not detect.
    /// Returning the error forces the caller to handle the policy decision
    /// at the call site (filter, redact, or refuse) rather than rely on the
    /// engine's silence as documentation.
    pub fn indexDocumentExcluding(
        self: *Engine,
        doc_id: u64,
        terms: []const TermPosting,
        excluded_fields: []const []const u8,
    ) !void {
        for (terms) |t| {
            if (t.field) |f| {
                for (excluded_fields) |ef| {
                    if (std.mem.eql(u8, f, ef)) return error.FieldExcluded;
                }
            }
        }
        return self.indexDocument(doc_id, terms);
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
        //
        // WRK-025 (GAP-0012, GAP-0013): bracket the payload with BEGIN and
        // COMMIT records sharing the same txn_id. Replay applies the payload
        // only if it observes the matching COMMIT, so a crash between BEGIN
        // and COMMIT leaves no partial state on recovery. fsync once at the
        // end of the bracket — that is the durability boundary.
        const begin_rec = wal.WalRecord{
            .record_type = .begin,
            .txn_id = txn_id,
            .doc_id = 0,
            .payload = "",
        };
        try self.wal_writer.append(begin_rec);
        try self.wal_writer.append(rec);
        const commit_rec = wal.WalRecord{
            .record_type = .commit,
            .txn_id = txn_id,
            .doc_id = 0,
            .payload = "",
        };
        try self.wal_writer.append(commit_rec);
        try self.wal_writer.sync();

        // Only mutate memtable after WAL is durable. Bump next_txn_id last so
        // a partial failure does not consume a txn id.
        for (terms) |t| {
            try self.memtable.addPosting(t.term, doc_id, t.positions);
        }
        self.next_txn_id += 1;

        // Auto-flush so memtable memory is bounded regardless of caller
        // behavior (SEC-EXT-0702). The threshold is currently a compile-time
        // constant; configurable per-engine threshold is deferred.
        if (self.memtable.total_docs >= limits.DEFAULT_MEMTABLE_FLUSH_THRESHOLD_DOCS) {
            try self.flush();
        }
    }

    pub fn deleteDocument(self: *Engine, doc_id: u64) !void {
        const txn_id = self.next_txn_id;
        self.next_txn_id += 1;

        try self.memtable.addTombstone(doc_id);
        // Mirror into the engine-wide aggregated set so isDeleted is O(1)
        // (PERF-0006, WRK-031). Safe to keep the memtable entry on a later
        // error since a stale tombstone is a no-op when the doc is absent.
        try self.all_tombstones.put(self.allocator, doc_id, {});

        const rec = wal.WalRecord{
            .record_type = .delete_doc,
            .txn_id = txn_id,
            .doc_id = doc_id,
        };

        // WRK-025 (GAP-0012, GAP-0013): bracket the delete with BEGIN/COMMIT
        // so a torn write between BEGIN and COMMIT is rolled back on replay.
        const begin_rec = wal.WalRecord{
            .record_type = .begin,
            .txn_id = txn_id,
            .doc_id = 0,
            .payload = "",
        };
        try self.wal_writer.append(begin_rec);
        try self.wal_writer.append(rec);
        const commit_rec = wal.WalRecord{
            .record_type = .commit,
            .txn_id = txn_id,
            .doc_id = 0,
            .payload = "",
        };
        try self.wal_writer.append(commit_rec);
        try self.wal_writer.sync();

        // Symmetrical auto-flush check (SEC-EXT-0702). Deletes alone won't
        // bump total_docs but a delete that follows a burst of indexing may
        // push us over the threshold here.
        if (self.memtable.total_docs >= limits.DEFAULT_MEMTABLE_FLUSH_THRESHOLD_DOCS) {
            try self.flush();
        }
    }

    pub fn flush(self: *Engine) !void {
        if (self.memtable.dictionary.count() == 0 and self.memtable.tombstones.count() == 0) return;

        const next_segment_id = self.current_manifest.counter + 1;

        // PHASES 1 and 2 are guarded by errdefers so a partial failure
        // (segment on disk but no manifest referencing it, or in-memory
        // manifest mutated but not durably persisted) is rolled back.
        // PHASE 3 runs after `phase2_done = true`, by which point the
        // manifest is durable and the segment is officially live — so the
        // unwinding errdefers must check the flag before firing (QUAL-0005).
        var phase2_done: bool = false;

        // Snapshot pre-flush manifest state so we can restore on failure.
        const old_total_docs = self.current_manifest.total_docs;
        const old_counter = self.current_manifest.counter;
        const old_last_checkpoint_lsn = self.current_manifest.last_checkpoint_lsn;

        // PHASE 1: write the segment to disk. Until the manifest pointing at
        // this segment is durable the segment is provisional — if anything
        // after this point fails we must remove it so it does not become an
        // orphan referenced by no manifest.
        //
        // Pre-format the segment directory name so the errdefer below cannot
        // itself fail — defer expressions cannot contain `return`/`try`.
        var seg_name_buf: [32]u8 = undefined;
        const seg_name = std.fmt.bufPrint(&seg_name_buf, "seg_{d}", .{next_segment_id}) catch unreachable;

        var writer = segment.SegmentWriter{
            .io = self.io,
            .dir = self.seg_dir,
            .allocator = self.allocator,
            .segment_id = next_segment_id,
            .aead_key = self.aead_key,
        };
        try writer.writeMemtable(&self.memtable);
        errdefer if (!phase2_done) {
            self.seg_dir.deleteTree(self.io, seg_name) catch {};
        };

        // Add to manifest. created_lsn carries the last txn that contributed
        // to this segment so downstream consumers can order segments by
        // sealing LSN (QUAL-0014, WRK-018). level=0 marks a freshly flushed
        // memtable; non-zero levels are reserved for future tiered
        // compaction (WRK-041).
        try self.current_manifest.segments.append(self.allocator, .{
            .id = next_segment_id,
            .doc_count = self.memtable.total_docs,
            .tombstone_count = self.memtable.tombstones.count(),
            .created_lsn = self.next_txn_id - 1,
            .level = 0,
        });
        errdefer if (!phase2_done) {
            _ = self.current_manifest.segments.pop();
        };

        // Plumb running totals up to the manifest (QUAL-0006, DC-2, DC-3,
        // GAP-0007). avg_doc_len is updated here using a length-weighted
        // rolling average across segments so BM25 length normalization has
        // a stable corpus statistic (WRK-035, GAP-0005, GAP-0006).
        //
        // Snapshot pre-update avg/total so the errdefer below can restore.
        const old_avg_doc_len = self.current_manifest.avg_doc_len;

        // Compute total token length of the memtable about to be sealed:
        // sum of tf across every (term, posting). This matches what
        // SegmentWriter.writeNorms persists per-doc.
        const total_doc_len_seg: u64 = blk: {
            var sum: u64 = 0;
            var it = self.memtable.dictionary.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.postings.items) |p| sum += p.tf;
            }
            break :blk sum;
        };

        self.current_manifest.total_docs += self.memtable.total_docs;
        self.current_manifest.counter += 1;
        self.current_manifest.last_checkpoint_lsn = self.next_txn_id - 1;

        // Rolling, length-weighted average: prev_total_len = old_avg * old_doc_count,
        // new_avg = (prev_total_len + this_seg_total_len) / new_doc_count.
        // Guard against div-by-zero when total_docs ends up zero (shouldn't
        // happen post-update, but cheap to be defensive).
        if (self.current_manifest.total_docs > 0) {
            const prev_total_len: u64 = @as(u64, old_avg_doc_len) * old_total_docs;
            const new_avg: u64 = @divTrunc(prev_total_len + total_doc_len_seg, self.current_manifest.total_docs);
            self.current_manifest.avg_doc_len = std.math.cast(u32, new_avg) orelse std.math.maxInt(u32);
        }
        errdefer if (!phase2_done) {
            self.current_manifest.total_docs = old_total_docs;
            self.current_manifest.counter = old_counter;
            self.current_manifest.last_checkpoint_lsn = old_last_checkpoint_lsn;
            self.current_manifest.avg_doc_len = old_avg_doc_len;
        };

        // PHASE 2: durably write the manifest. After this returns successfully
        // the segment is officially live and the errdefers above must NOT fire
        // for any subsequent failure.
        const man_file = if (self.current_manifest.counter % 2 == 0) "manifest.a" else "manifest.b";
        try self.current_manifest.writeToFileWithHmac(
            self.io,
            self.dir,
            man_file,
            self.allocator,
            self.hmac_key,
        );
        phase2_done = true;

        // PHASE 3: best-effort cleanup of staging state. WAL truncation and
        // SegmentReader open can still fail (e.g. ENOSPC, EMFILE) but the
        // durable storage is consistent — the in-memory layer just becomes
        // temporarily stale and the next operation will hit the same error.
        //
        // Truncate WAL. The records it contained are now redundant with the
        // segment + manifest pair.
        self.wal_writer.deinit();
        self.wal_file.close(self.io);
        self.wal_file = try self.wal_dir.createFile(self.io, "fts.wal", .{
            .truncate = true,
            .permissions = utils.fileMode(0o600),
        });
        self.wal_writer = try wal.WalWriter.initWithHmac(
            self.io,
            self.wal_file,
            self.allocator,
            self.hmac_key,
        );

        // Open SegmentReader and add to segments list.
        const seg_reader = try segment.SegmentReader.initWithAead(
            self.io,
            self.allocator,
            self.seg_dir,
            next_segment_id,
            self.aead_key,
        );
        try self.segments.append(self.allocator, seg_reader);

        // Clear memtable.
        self.memtable.deinit();
        self.memtable = segment.Memtable.init(self.allocator);
    }

    /// Manually merge every existing segment into one. Tombstoned docs are
    /// folded into the merged segment by exclusion (they simply don't appear
    /// in any posting list of the new segment), so the engine-wide tombstone
    /// set can be cleared afterwards.
    ///
    /// This is the minimum-viable form of WRK-041 (GAP-0003). Background
    /// scheduling, leveled compaction (L0 -> L1 -> ...), and concurrent
    /// query stability during compaction are explicitly deferred. The new
    /// merged segment is marked `level = 1` to distinguish it from raw
    /// flushed memtables; future tiered compaction can rely on this.
    ///
    /// No-op if fewer than 2 segments exist.
    pub fn compact(self: *Engine) !void {
        if (self.segments.items.len <= 1) return;

        // Build a fresh in-memory memtable holding every (term, doc_id,
        // positions) tuple from the existing segments, skipping any doc_id
        // present in the engine-wide tombstone set.
        var merged_mt = segment.Memtable.init(self.allocator);
        defer merged_mt.deinit();

        for (self.segments.items) |*seg_reader| {
            var term_it = seg_reader.dictionary.iterator();
            while (term_it.next()) |entry| {
                const term = entry.key_ptr.*;
                if (try seg_reader.search(term)) |iter_val| {
                    var post_it = iter_val;
                    defer post_it.deinit();
                    while (try post_it.next()) |posting| {
                        if (self.all_tombstones.contains(posting.doc_id)) continue;
                        try merged_mt.addPosting(term, posting.doc_id, posting.positions);
                    }
                }
            }
        }

        // Write the merged memtable as a new segment. Use a counter-derived
        // segment id (matches `flush`'s naming scheme) so the on-disk path
        // never collides with a pre-existing seg_*.
        const new_segment_id = self.current_manifest.counter + 1;
        var writer = segment.SegmentWriter{
            .io = self.io,
            .dir = self.seg_dir,
            .allocator = self.allocator,
            .segment_id = new_segment_id,
            .aead_key = self.aead_key,
        };
        try writer.writeMemtable(&merged_mt);

        // Snapshot old segment ids so we can delete their on-disk directories
        // after the manifest swap commits.
        const old_segments_to_delete = try self.allocator.alloc(u64, self.current_manifest.segments.items.len);
        defer self.allocator.free(old_segments_to_delete);
        for (self.current_manifest.segments.items, 0..) |s, i| old_segments_to_delete[i] = s.id;

        // Replace the manifest's segment list with just the merged entry.
        self.current_manifest.segments.clearRetainingCapacity();
        try self.current_manifest.segments.append(self.allocator, .{
            .id = new_segment_id,
            .doc_count = merged_mt.total_docs,
            .tombstone_count = 0,
            .created_lsn = self.next_txn_id - 1,
            .level = 1,
        });
        self.current_manifest.counter += 1;
        const man_file = if (self.current_manifest.counter % 2 == 0) "manifest.a" else "manifest.b";
        try self.current_manifest.writeToFileWithHmac(
            self.io,
            self.dir,
            man_file,
            self.allocator,
            self.hmac_key,
        );

        // Close old SegmentReaders, open the new merged one.
        for (self.segments.items) |*sr| sr.deinit();
        self.segments.clearRetainingCapacity();
        const new_reader = try segment.SegmentReader.initWithAead(
            self.io,
            self.allocator,
            self.seg_dir,
            new_segment_id,
            self.aead_key,
        );
        try self.segments.append(self.allocator, new_reader);

        // Delete old segment directories. Best-effort: failure to delete a
        // stale directory does not invalidate the merged segment, it just
        // leaks disk space until the next process boot can clean up.
        for (old_segments_to_delete) |sid| {
            var name_buf: [32]u8 = undefined;
            const seg_name = std.fmt.bufPrint(&name_buf, "seg_{d}", .{sid}) catch continue;
            self.seg_dir.deleteTree(self.io, seg_name) catch {};
        }

        // Aggregated tombstones are now baked into the merged segment by
        // exclusion, so drop them.
        self.all_tombstones.deinit(self.allocator);
        self.all_tombstones = .empty;
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

test "Engine.init tolerates truncated WAL tail" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Phase A: index 3 docs, then deliberately truncate the WAL mid-record.
    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = TermPosting{ .term = "x", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]TermPosting{t});
        try eng.indexDocument(2, &[_]TermPosting{t});
        try eng.indexDocument(3, &[_]TermPosting{t});
    }

    // Truncate the WAL by 3 bytes (well inside the last record's CRC region)
    // to simulate a crash mid-write.
    {
        var wal_dir = try tmp_dir.dir.openDir(io, "wal", .{});
        defer wal_dir.close(io);
        const f = try wal_dir.openFile(io, "fts.wal", .{ .mode = .read_write });
        defer f.close(io);
        const sz = (try f.stat(io)).size;
        try f.setLength(io, sz - 3);
    }

    // Phase B: reopen — must succeed; recovery should find at least the first
    // doc (the last record is torn, earlier ones must replay cleanly).
    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expect(eng.memtable.dictionary.contains("x"));
    }
}

test "Engine.init fails closed when both manifests corrupt" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Bootstrap a valid engine and flush twice so both manifest.a and
    // manifest.b exist on disk (the manifest A/B rotation alternates by
    // counter parity, so two flushes guarantees both slots are populated).
    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = TermPosting{ .term = "x", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]TermPosting{t});
        try eng.flush();
        try eng.indexDocument(2, &[_]TermPosting{t});
        try eng.flush();
    }

    // Corrupt both manifest files in place. Flipping the trailing byte
    // breaks the CRC suffix that loadManifest validates.
    const corrupt_byte = [_]u8{0xFF};
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |name| {
        const f = tmp_dir.dir.openFile(io, name, .{ .mode = .read_write }) catch continue;
        defer f.close(io);
        const sz = (try f.stat(io)).size;
        try f.writePositionalAll(io, &corrupt_byte, sz - 1);
    }

    // Reopen — must fail loud, not silently start fresh. Silent fail-open
    // here would drop every previously flushed segment from view, masking
    // tampering or storage corruption (SEC-EXT-0304, GAP-0028).
    try std.testing.expectError(error.ManifestCorrupt, Engine.init(io, alloc, tmp_dir.dir));
}

test "HMAC: WAL roundtrip with key" {
    // SEC-02, SEC-EXT-0401, GAP-0027: opt-in HMAC-SHA256 envelopes on WAL
    // and manifest. Same key roundtrips cleanly; wrong key must fail loud
    // with error.HmacMismatch rather than silently falling through.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const key = "test-hmac-key-32-bytes-padding!!";
    {
        var eng = try Engine.initWithConfig(io, alloc, tmp_dir.dir, .{ .hmac_key = key });
        defer eng.deinit();
        const t = TermPosting{ .term = "secret", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]TermPosting{t});
        try eng.flush();
    }

    // Reopen with same key — succeeds.
    {
        var eng = try Engine.initWithConfig(io, alloc, tmp_dir.dir, .{ .hmac_key = key });
        defer eng.deinit();
        try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);
    }

    // Reopen with WRONG key — must fail loud.
    {
        const result = Engine.initWithConfig(
            io,
            alloc,
            tmp_dir.dir,
            .{ .hmac_key = "different-key-32-bytes-padding!!" },
        );
        try std.testing.expectError(error.HmacMismatch, result);
    }
}

test "AES-GCM: segment encryption roundtrip" {
    // WRK-038, GAP-0009, SEC-EXT-0402: opt-in AES-256-GCM segment-at-rest
    // encryption. Same key roundtrips cleanly; absent key must fail to
    // open a previously-encrypted segment.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Exactly 32 bytes = Aes256Gcm key length.
    const key = "32-bytes-of-aes-gcm-key-PLEASE!!";
    try std.testing.expectEqual(@as(usize, 32), key.len);

    {
        var eng = try Engine.initWithConfig(io, alloc, tmp_dir.dir, .{ .aead_key = key });
        defer eng.deinit();
        const t = TermPosting{ .term = "ciphertext", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]TermPosting{t});
        try eng.flush();
    }

    // Reopen with same key — succeeds, segment loads and search works.
    {
        var eng = try Engine.initWithConfig(io, alloc, tmp_dir.dir, .{ .aead_key = key });
        defer eng.deinit();
        try std.testing.expectEqual(@as(usize, 1), eng.segments.items.len);

        // Confirm the encrypted postings are actually queryable.
        const search = @import("search.zig");
        var iter = try search.TermIterator.init(alloc, eng, "ciphertext");
        defer iter.deinit();
        const m = (try iter.next()).?;
        try std.testing.expectEqual(@as(u64, 1), m.doc_id);
    }

    // Reopen with NO key — must fail. The exact error depends on which
    // path detects the mismatch first: AEAD tag verification fails with
    // AuthenticationFailed, but the size/count check in the dictionary
    // parser may trip first with InvalidData or Incomplete.
    {
        const result = Engine.initWithConfig(io, alloc, tmp_dir.dir, .{});
        try std.testing.expect(std.meta.isError(result));
    }
}

test "FLE: indexDocumentExcluding rejects excluded field" {
    // WRK-040, GAP-0010: field-exclusion guard refuses to ingest a posting
    // whose `field` tag matches any entry in `excluded_fields`. The error
    // is explicit (`error.FieldExcluded`) rather than a silent skip — a
    // silently dropped sensitive field would mask a policy misconfiguration.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();

    const ssn_post = TermPosting{ .term = "ssn", .positions = &[_]u32{1}, .field = "ssn" };
    const excluded = [_][]const u8{"ssn"};
    try std.testing.expectError(
        error.FieldExcluded,
        eng.indexDocumentExcluding(1, &[_]TermPosting{ssn_post}, &excluded),
    );

    // A non-excluded field is ingested normally.
    const name_post = TermPosting{ .term = "alice", .positions = &[_]u32{2}, .field = "name" };
    try eng.indexDocumentExcluding(2, &[_]TermPosting{name_post}, &excluded);
    try std.testing.expect(eng.memtable.dictionary.contains("alice"));

    // A null-field posting bypasses the field check (the caller did not
    // opt into field tagging for this term).
    const untagged = TermPosting{ .term = "untagged", .positions = &[_]u32{3} };
    try eng.indexDocumentExcluding(3, &[_]TermPosting{untagged}, &excluded);
    try std.testing.expect(eng.memtable.dictionary.contains("untagged"));
}

test "WAL replay drops uncommitted (no COMMIT) records" {
    // WRK-025 (GAP-0012, GAP-0013): a BEGIN + payload pair on disk without
    // its matching COMMIT must not be applied on replay. Simulate a crash
    // between BEGIN and COMMIT by manually appending a BEGIN + INDEX_DOC
    // pair for a "ghost" doc, with no COMMIT to seal them.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Bootstrap with one real, committed indexDocument.
    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        const t = TermPosting{ .term = "real", .positions = &[_]u32{1} };
        try eng.indexDocument(1, &[_]TermPosting{t});
    }

    // Manually append BEGIN(txn=999) + INDEX_DOC(txn=999, doc=42, term="ghost")
    // with NO COMMIT to the WAL.
    {
        var wal_dir = try tmp_dir.dir.openDir(io, "wal", .{});
        defer wal_dir.close(io);
        const f = try wal_dir.openFile(io, "fts.wal", .{ .mode = .read_write });
        defer f.close(io);
        const sz = (try f.stat(io)).size;

        const begin = wal.WalRecord{
            .record_type = .begin,
            .txn_id = 999,
            .doc_id = 0,
            .payload = "",
        };

        // Build the index_doc payload by hand: term_len(u16=5) | "ghost" |
        // num_pos(u16=1) | varint(1).
        var pbuf: std.ArrayListUnmanaged(u8) = .empty;
        defer pbuf.deinit(alloc);
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, 5, .little);
        try pbuf.appendSlice(alloc, &len_buf);
        try pbuf.appendSlice(alloc, "ghost");
        std.mem.writeInt(u16, &len_buf, 1, .little);
        try pbuf.appendSlice(alloc, &len_buf);
        var vbuf: [10]u8 = undefined;
        const written = try utils.writeVarInt(&vbuf, 1);
        try pbuf.appendSlice(alloc, vbuf[0..written]);

        const idx = wal.WalRecord{
            .record_type = .index_doc,
            .txn_id = 999,
            .doc_id = 42,
            .payload = pbuf.items,
        };

        const begin_bytes = try begin.serialize(alloc);
        defer alloc.free(begin_bytes);
        const idx_bytes = try idx.serialize(alloc);
        defer alloc.free(idx_bytes);

        try f.writePositionalAll(io, begin_bytes, sz);
        try f.writePositionalAll(io, idx_bytes, sz + begin_bytes.len);
    }

    // Reopen — "real" must be present (its txn was committed); "ghost" must
    // be absent (its txn never committed, so it was dropped on replay).
    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expect(eng.memtable.dictionary.contains("real"));
        try std.testing.expect(!eng.memtable.dictionary.contains("ghost"));
    }
}

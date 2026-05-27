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

/// One unit of work for `Engine.indexDocumentBatch` — a doc_id and its
/// terms, identical in shape to a single `indexDocument` call.
///
/// PERF-0001 / Phase B3: `indexDocumentBatch` writes every record in the
/// batch to the WAL without intervening fsyncs and issues exactly ONE
/// fsync at the end. Throughput on an fsync-bound disk scales near-linearly
/// with batch size up to the disk's IO queue depth. Concrete numbers from
/// the bench-coverage-expansion baselines (2026-05-27): a 64-record batch
/// amortizes one ~5 ms fsync across 64 docs, giving an ~12 800 docs/s
/// ceiling vs the per-record 186 docs/s ceiling — a ~69x gain when the
/// caller is in a position to batch.
///
/// Crash semantics are unchanged: each (doc_id, terms) entry is still
/// bracketed with BEGIN / COMMIT WAL records sharing one txn_id, so a
/// crash mid-batch leaves the WAL with whatever records were durable at
/// the moment fsync returned (zero of them, if the crash preceded fsync;
/// all of them, otherwise). Partial-batch durability is not exposed.
pub const DocBatch = struct {
    doc_id: u64,
    terms: []const TermPosting,
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

    /// Engine-wide aggregated per-doc length map. Built at init by walking
    /// every segment's `norms` map in segments-list order (oldest segment
    /// first); updated on flush by inserting the new segment's norms.
    /// Insertion uses `getOrPutValue`, so the first segment to record a norm
    /// for a given doc_id wins — matching the historical break-on-first-match
    /// loop in `TermIterator.computeScore` (`src/search.zig:208-214`).
    ///
    /// Lets `computeScore`'s per-doc length lookup run in O(1) instead of
    /// O(segments). At 16 segments the bench `bm25_score_norm_scan_16seg`
    /// reports ~19.5 MOPS vs ~2.2 GOPS for the single-segment formula —
    /// fundamentally the wrong shape for any non-toy query path.
    ///
    /// Memtable docs (between flushes) are intentionally absent here; the
    /// computeScore call site falls back to `limits.DEFAULT_DOC_LEN` in
    /// that case, preserving the prior behavior bit-for-bit.
    all_norms: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    wal_file: std.Io.File,
    wal_writer: wal.WalWriter,
    /// Atomic transaction counter. Phase B1 of the concurrency-model
    /// decision (PERF-0027, see `docs/concurrency-model-decision.md`).
    /// `fetchAdd(1, .monotonic)` is enough — every caller needs a unique
    /// id but no happens-before relationship with anything else; the WAL
    /// append that follows provides the durability boundary.
    next_txn_id: std.atomic.Value(u64) = .{ .raw = 1 },

    /// Optional HMAC-SHA256 key for WAL + manifest envelopes (SEC-02,
    /// SEC-EXT-0401, GAP-0027). Null = unchanged on-disk format. Caller owns
    /// the key memory; the engine merely borrows the slice.
    hmac_key: ?[]const u8 = null,

    /// Optional AES-256-GCM key for segment-at-rest encryption (GAP-0009,
    /// SEC-EXT-0402). Null = plaintext segments. Must be 32 bytes when set.
    aead_key: ?[]const u8 = null,

    /// Thread that owns this Engine instance. Captured in `init`; every
    /// mutating method asserts the caller is on the same thread in debug
    /// builds (SEC-EXT-0701). The Engine is single-threaded by contract —
    /// callers are responsible for serializing access. This assertion turns
    /// silent data races (which Zig's memory model leaves UB-shaped) into
    /// a loud test-time panic so the contract is auditable.
    owning_thread: std.Thread.Id = 0,

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
    ///
    /// THREAD CONTRACT (SEC-EXT-0701): the Engine is single-threaded by
    /// design. The owning thread is captured at `init` time and every
    /// mutating method (`indexDocument`, `deleteDocument`, `flush`,
    /// `compact`, `deinit`) asserts the caller is on that thread in debug
    /// builds. Callers that need multi-threaded read access must serialize
    /// behind their own mutex — search-time data structures
    /// (`SegmentReader.dictionary`, the engine-wide tombstone set) are
    /// otherwise not protected against concurrent mutation.
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
        // SEC-EXT-0701: capture the calling thread so every mutating method
        // can debug-assert it has not been smuggled to another thread.
        engine.owning_thread = std.Thread.getCurrentId();
        engine.memtable = segment.Memtable.init(allocator);
        errdefer engine.memtable.deinit();
        engine.segments = .empty;
        errdefer {
            for (engine.segments.items) |*seg_reader| seg_reader.deinit();
            engine.segments.deinit(allocator);
        }
        engine.all_tombstones = .empty;
        errdefer engine.all_tombstones.deinit(allocator);
        engine.all_norms = .empty;
        errdefer engine.all_norms.deinit(allocator);

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
        //
        // SEC-EXT-0209: a single corrupt segment file must not block engine
        // init — that would turn any storage-layer corruption (bit rot,
        // truncated tail, partial write at crash) into a denial-of-
        // service-on-restart. Rename the broken directory to
        // `seg_<id>.corrupt` so an operator can inspect/recover it offline,
        // log the failure, and proceed with the surviving segments. The
        // manifest's segment list is not mutated here — a future flush will
        // rewrite the manifest and quietly drop the orphaned entry, or the
        // operator can repair the segment and restart.
        //
        // BUT: quarantine is intentionally gated by whether the caller has
        // configured the AEAD key for this engine. With no key, a load
        // failure could mean "segment was encrypted and caller forgot to
        // pass the key" — silently quarantining in that case would destroy
        // the user's data. Fail loud instead. Once `aead_key` is set, a
        // load failure can only mean genuine corruption (the AEAD tag would
        // catch wrong-key tampering), so quarantine is safe.
        try engine.segments.ensureTotalCapacity(allocator, engine.current_manifest.segments.items.len);
        for (engine.current_manifest.segments.items) |seg_entry| {
            const seg_reader = segment.SegmentReader.initWithAead(
                io,
                allocator,
                engine.seg_dir,
                seg_entry.id,
                config.aead_key,
            ) catch |err| {
                // HMAC mismatch must NEVER be quarantined — wrong-key /
                // tampering has to surface, not be silently walked past
                // (SEC-02, SEC-EXT-0401, GAP-0027).
                if (err == error.HmacMismatch) return err;

                // Without AEAD configured, refuse to quarantine: the load
                // failure is more likely a "you forgot to pass aead_key"
                // configuration mistake than a corruption event. Preserve
                // the pre-quarantine fail-loud behavior so the caller sees
                // the original error.
                if (config.aead_key == null) return err;

                var name_buf: [40]u8 = undefined;
                const old_name = std.fmt.bufPrint(&name_buf, "seg_{d}", .{seg_entry.id}) catch {
                    std.log.warn(
                        "fts-storage: segment {d} corrupt ({s}); rename failed (name fmt)",
                        .{ seg_entry.id, @errorName(err) },
                    );
                    continue;
                };
                var bad_buf: [48]u8 = undefined;
                const bad_name = std.fmt.bufPrint(&bad_buf, "seg_{d}.corrupt", .{seg_entry.id}) catch {
                    std.log.warn(
                        "fts-storage: segment {d} corrupt ({s}); rename failed (bad name fmt)",
                        .{ seg_entry.id, @errorName(err) },
                    );
                    continue;
                };
                engine.seg_dir.rename(old_name, engine.seg_dir, bad_name, io) catch |rename_err| {
                    std.log.warn(
                        "fts-storage: segment {d} corrupt ({s}); rename to {s} failed ({s})",
                        .{ seg_entry.id, @errorName(err), bad_name, @errorName(rename_err) },
                    );
                    continue;
                };
                std.log.warn(
                    "fts-storage: segment {d} corrupt ({s}); quarantined to {s}",
                    .{ seg_entry.id, @errorName(err), bad_name },
                );
                continue;
            };
            engine.segments.appendAssumeCapacity(seg_reader);
        }

        engine.next_txn_id.store(engine.current_manifest.last_checkpoint_lsn + 1, .monotonic);

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

        // Build the engine-wide aggregated norms map so BM25's per-doc length
        // lookup is O(1) instead of O(segments). Walk segments in
        // segments-list order (oldest first) using `getOrPutValue` so the
        // first segment to record a norm for a given doc_id wins — matching
        // the historical break-on-first-match semantics in
        // `TermIterator.computeScore`. Memtable docs are intentionally absent;
        // computeScore falls back to `limits.DEFAULT_DOC_LEN` for those.
        for (engine.segments.items) |*seg_reader| {
            var n_it = seg_reader.norms.iterator();
            while (n_it.next()) |entry| {
                _ = try engine.all_norms.getOrPutValue(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
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

    /// SEC-EXT-0701: debug-only assertion that the calling thread matches
    /// the one captured by `init`. Compiled out of release builds via
    /// `std.debug.runtime_safety`. A mismatch indicates a violation of the
    /// single-thread contract — almost certainly a bug — so panicking is
    /// the right response: the alternative is the silent data race that
    /// Zig's memory model leaves as undefined behavior.
    fn assertOwnedByCurrentThread(self: *Engine) void {
        if (std.debug.runtime_safety) {
            std.debug.assert(self.owning_thread == std.Thread.getCurrentId());
        }
    }

    pub fn deinit(self: *Engine) void {
        self.assertOwnedByCurrentThread();
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
        self.all_norms.deinit(self.allocator);
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

        // SEC-EXT-0203: aggregate-payload cap. Each individual record is
        // already bounded by `MAX_WAL_PAYLOAD_BYTES` (10 MiB) but a long WAL
        // with millions of small records could still exhaust memory because
        // every record is held in `all` until the second/third pass. Refuse
        // to grow the in-memory buffer past `MAX_WAL_REPLAY_AGGREGATE_BYTES`
        // — a WAL that large indicates either a runaway producer or
        // adversarial input, both of which deserve a loud failure rather
        // than an OOM.
        var total_payload_bytes: u64 = 0;

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
            total_payload_bytes += @as(u64, rec.payload.len);
            if (total_payload_bytes > limits.MAX_WAL_REPLAY_AGGREGATE_BYTES) {
                // `rec` is not yet appended to `all`, so it would otherwise
                // leak; defer-cleanup tears down `all` but not this orphan.
                var rec_mut = rec;
                rec_mut.deinit(self.allocator);
                return error.WalTooLarge;
            }
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

        // PERF-0015 / PERF-0029: hoist the per-position scratch buffer up to
        // replayWal so it is allocated once across every replayed index_doc
        // record. Pre-WRK-044 each `applyIndexDocPayload` call freshly
        // allocated this list and tore it down at function exit; with N
        // records that meant 2N allocations on the hot recovery path.
        // `clearRetainingCapacity()` inside the callee gives us the same
        // semantic guarantee (each record starts with a clean buffer) at zero
        // ongoing allocation cost after the first record's positions are
        // sized.
        var pos_buf: std.ArrayListUnmanaged(u32) = .empty;
        defer pos_buf.deinit(self.allocator);

        // Third pass: apply payload records whose txn was committed and
        // sits past the checkpoint. begin/commit themselves contribute no
        // payload to apply.
        for (all.items) |r| {
            if (r.txn_id <= self.current_manifest.last_checkpoint_lsn) continue;
            if (!committed.contains(r.txn_id)) continue;
            // Replay runs single-threaded inside init, so a plain
            // load+store is safe; use atomic accessors for consistency
            // with the rest of the engine (Phase B1).
            if (r.txn_id >= self.next_txn_id.load(.monotonic)) {
                self.next_txn_id.store(r.txn_id + 1, .monotonic);
            }
            switch (r.record_type) {
                .index_doc => try self.applyIndexDocPayload(r.doc_id, r.payload, &pos_buf),
                .delete_doc => try self.memtable.addTombstone(r.doc_id),
                else => {},
            }
        }
    }

    fn applyIndexDocPayload(
        self: *Engine,
        doc_id: u64,
        payload: []const u8,
        pos_buf: *std.ArrayListUnmanaged(u32),
    ) !void {
        var pos: usize = 0;

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
        self.assertOwnedByCurrentThread();
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
        self.assertOwnedByCurrentThread();
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

        // Atomic claim of the next txn_id. fetchAdd returns the pre-add value,
        // which is the one this caller owns. .monotonic is sufficient: the
        // subsequent WAL append + sync provides the release boundary; no
        // other engine state ordering depends on this counter (Phase B1).
        const txn_id = self.next_txn_id.fetchAdd(1, .monotonic);

        // Serialize payload first; no memtable mutation yet.
        var payload_list: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_list.deinit(self.allocator);

        // PERF-0011: pre-size the payload buffer with an upper-bound estimate
        // so the inner loop never reallocates. Each term contributes
        //   2 (term_len) + term.len + 2 (num_pos) + positions.len * 5
        // where 5 is the worst-case varint width for a u32 position. This is
        // an upper bound; the actual encoded size is typically smaller because
        // positions encode in 1-2 varint bytes.
        var estimated: usize = 0;
        for (terms) |t| {
            estimated += 4 + t.term.len + (t.positions.len * 5);
        }
        try payload_list.ensureTotalCapacity(self.allocator, estimated);

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

        // Only mutate memtable after WAL is durable. Note the txn_id was
        // already atomically claimed at the top of this function via
        // fetchAdd, so even though we now know the txn was durable, the
        // increment has already happened. A partial failure between
        // fetchAdd and the memtable mutation skips a txn id — this is
        // tolerated (WAL replay only applies records bracketed by a
        // matching COMMIT, so a gap in the txn_id sequence is harmless).
        for (terms) |t| {
            try self.memtable.addPosting(t.term, doc_id, t.positions);
        }

        // Auto-flush so memtable memory is bounded regardless of caller
        // behavior (SEC-EXT-0702). The threshold is currently a compile-time
        // constant; configurable per-engine threshold is deferred.
        if (self.memtable.total_docs >= limits.DEFAULT_MEMTABLE_FLUSH_THRESHOLD_DOCS) {
            try self.flush();
        }
    }

    /// Index a batch of (doc_id, terms) pairs with a single trailing fsync.
    ///
    /// PERF-0001 / Phase B3: the dominant cost on the indexing hot path is
    /// the per-record `fsync` (the bench baseline at HEAD `9159059` shows
    /// 186 docs/s with one fsync per doc on znver2 / linux / ext4). This
    /// method amortizes a single fsync across every record in the batch,
    /// lifting the ceiling to roughly (batch_size * single-doc-throughput)
    /// up to the disk's IO queue depth.
    ///
    /// Each `DocBatch` entry receives the same BEGIN / payload / COMMIT
    /// bracketing as a single `indexDocument` call, so replay's
    /// "apply only if matching COMMIT observed" rule is preserved. A crash
    /// before the final `sync()` returns means none of the records in the
    /// batch are durable; after `sync()` returns, all of them are. The
    /// memtable is mutated only after `sync()` succeeds, so a sync failure
    /// leaves the engine state unchanged.
    pub fn indexDocumentBatch(self: *Engine, docs: []const DocBatch) !void {
        self.assertOwnedByCurrentThread();
        if (docs.len == 0) return;

        // Validate every doc's inputs up-front so a malformed entry deep in
        // the batch does not leave a partial WAL prefix on disk before the
        // final sync. Same checks as `indexDocument`.
        for (docs) |d| {
            for (d.terms) |t| {
                if (t.term.len == 0) return error.EmptyTerm;
                if (t.term.len > limits.MAX_TERM_LEN) return error.TermTooLong;
                if (t.positions.len > limits.MAX_POSITIONS_PER_TERM) return error.PositionCountTooLarge;
                var i: usize = 1;
                while (i < t.positions.len) : (i += 1) {
                    if (t.positions[i] < t.positions[i - 1]) return error.PositionsNotMonotonic;
                }
            }
        }

        // Reuse one payload buffer across the whole batch. Estimate
        // upper-bound capacity to avoid repeated reallocation on append.
        var payload_list: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_list.deinit(self.allocator);
        var max_estimated: usize = 0;
        for (docs) |d| {
            var per_doc: usize = 0;
            for (d.terms) |t| per_doc += 4 + t.term.len + (t.positions.len * 5);
            if (per_doc > max_estimated) max_estimated = per_doc;
        }
        try payload_list.ensureTotalCapacity(self.allocator, max_estimated);

        // First pass: claim txn_ids and append every WAL record. No sync.
        // We claim ids in a tight loop up front so the WAL is densely
        // packed with the batch's records.
        var num_buf: [4]u8 = undefined;
        for (docs) |d| {
            const txn_id = self.next_txn_id.fetchAdd(1, .monotonic);

            payload_list.clearRetainingCapacity();
            for (d.terms) |t| {
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

            try self.wal_writer.append(.{
                .record_type = .begin,
                .txn_id = txn_id,
                .doc_id = 0,
                .payload = "",
            });
            try self.wal_writer.append(.{
                .record_type = .index_doc,
                .txn_id = txn_id,
                .doc_id = d.doc_id,
                .payload = payload_list.items,
            });
            try self.wal_writer.append(.{
                .record_type = .commit,
                .txn_id = txn_id,
                .doc_id = 0,
                .payload = "",
            });
        }

        // ONE fsync covering the whole batch — the entire performance win.
        try self.wal_writer.sync();

        // Now mutate the memtable for every doc. WAL is already durable;
        // failures here cannot diverge replay from on-disk state because
        // every doc's COMMIT was already written and synced.
        for (docs) |d| {
            for (d.terms) |t| {
                try self.memtable.addPosting(t.term, d.doc_id, t.positions);
            }
        }

        // Auto-flush once if the batch pushed the memtable past the
        // threshold (SEC-EXT-0702). Single check at the end of the batch
        // matches the prior per-doc check semantics for any reasonable
        // batch size.
        if (self.memtable.total_docs >= limits.DEFAULT_MEMTABLE_FLUSH_THRESHOLD_DOCS) {
            try self.flush();
        }
    }

    pub fn deleteDocument(self: *Engine, doc_id: u64) !void {
        self.assertOwnedByCurrentThread();
        // Atomic claim (Phase B1).
        const txn_id = self.next_txn_id.fetchAdd(1, .monotonic);

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
        self.assertOwnedByCurrentThread();
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
            .created_lsn = self.next_txn_id.load(.monotonic) - 1,
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
        self.current_manifest.last_checkpoint_lsn = self.next_txn_id.load(.monotonic) - 1;

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

        // Fold the new segment's norms into the engine-wide aggregated map.
        // First-write-wins (`getOrPutValue`) preserves the historical
        // break-on-first-match semantics from the per-segment scan loop.
        var n_it = self.segments.items[self.segments.items.len - 1].norms.iterator();
        while (n_it.next()) |entry| {
            _ = try self.all_norms.getOrPutValue(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

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
        self.assertOwnedByCurrentThread();
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
            .created_lsn = self.next_txn_id.load(.monotonic) - 1,
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

        // Rebuild the aggregated norms map from the merged segment. The
        // historical first-segment-wins semantics is trivially preserved
        // because there is only one segment left after compact.
        self.all_norms.deinit(self.allocator);
        self.all_norms = .empty;
        var n_it = self.segments.items[0].norms.iterator();
        while (n_it.next()) |entry| {
            try self.all_norms.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
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

test "Engine.indexDocumentBatch — 64-doc batch matches per-doc semantics" {
    // Phase B3 group-commit gate. Pins three properties:
    //   1. After indexDocumentBatch, every doc in the batch is searchable.
    //   2. txn_id allocation is monotonic across the batch.
    //   3. A re-open replays the entire batch identically to N independent
    //      indexDocument calls — same memtable, same dictionary, same set of
    //      doc_ids visible to search.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const N: usize = 64;
    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();

        const txn_before = eng.next_txn_id.load(.monotonic);

        var docs_buf: [N]DocBatch = undefined;
        const positions = [_]u32{ 0, 1 };
        // Per-doc TermPosting array — share `term` slice across docs because
        // the engine copies on insert.
        var term_buf: [N]TermPosting = undefined;
        var i: usize = 0;
        while (i < N) : (i += 1) {
            term_buf[i] = .{ .term = "batch", .positions = &positions };
            docs_buf[i] = .{ .doc_id = 100 + i, .terms = term_buf[i .. i + 1] };
        }
        try eng.indexDocumentBatch(&docs_buf);

        try std.testing.expectEqual(txn_before + N, eng.next_txn_id.load(.monotonic));

        // Every doc must be searchable in the memtable.
        try std.testing.expect(eng.memtable.dictionary.contains("batch"));
        const list = eng.memtable.dictionary.get("batch").?;
        try std.testing.expectEqual(@as(u64, N), list.df);
    }

    {
        // Re-open: WAL replay must yield the same memtable state.
        var eng2 = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng2.deinit();
        try std.testing.expect(eng2.memtable.dictionary.contains("batch"));
        const list = eng2.memtable.dictionary.get("batch").?;
        try std.testing.expectEqual(@as(u64, N), list.df);
        // next_txn_id picks up where the batch left off (no gaps, all
        // bracketed by matching COMMIT records, so all were applied).
        try std.testing.expectEqual(@as(u64, N + 1), eng2.next_txn_id.load(.monotonic));
    }
}

test "Engine.indexDocumentBatch — empty batch is a no-op" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();
    const txn_before = eng.next_txn_id.load(.monotonic);
    try eng.indexDocumentBatch(&[_]DocBatch{});
    try std.testing.expectEqual(txn_before, eng.next_txn_id.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), eng.memtable.total_docs);
}

test "Engine.indexDocumentBatch — invalid doc rejects whole batch" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var eng = try Engine.init(io, alloc, tmp_dir.dir);
    defer eng.deinit();
    const txn_before = eng.next_txn_id.load(.monotonic);

    const good_pos = [_]u32{0};
    const bad_pos = [_]u32{ 2, 1 }; // not monotonic
    const t_good = TermPosting{ .term = "good", .positions = &good_pos };
    const t_bad = TermPosting{ .term = "bad", .positions = &bad_pos };
    const docs = [_]DocBatch{
        .{ .doc_id = 1, .terms = &[_]TermPosting{t_good} },
        .{ .doc_id = 2, .terms = &[_]TermPosting{t_bad} }, // poisons whole batch
    };
    try std.testing.expectError(error.PositionsNotMonotonic, eng.indexDocumentBatch(&docs));

    // No txn_ids consumed, no memtable mutation, no WAL records appended.
    try std.testing.expectEqual(txn_before, eng.next_txn_id.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), eng.memtable.total_docs);
}

test "Engine.all_norms aggregates across segments" {
    // BM25 norm lookup uses an engine-wide aggregated map (O(1)) instead of
    // a per-segment scan (O(segments)). This test pins three behaviors:
    //   1. On flush, the new segment's norms are folded into all_norms.
    //   2. First-segment-wins semantics is preserved across multi-segment
    //      writes — the oldest segment's value wins for shared doc_ids.
    //   3. On re-open, all_norms is rebuilt from disk.
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();

        // Segment 0: doc 1 with 3 positions (norm=3), doc 2 with 1 position
        const t1a = TermPosting{ .term = "alpha", .positions = &[_]u32{ 0, 1, 2 } };
        const t1b = TermPosting{ .term = "beta", .positions = &[_]u32{0} };
        try eng.indexDocument(1, &[_]TermPosting{t1a});
        try eng.indexDocument(2, &[_]TermPosting{t1b});
        try eng.flush();

        // After first flush, all_norms must hold both doc lengths.
        try std.testing.expectEqual(@as(?u32, 3), eng.all_norms.get(1));
        try std.testing.expectEqual(@as(?u32, 1), eng.all_norms.get(2));

        // Segment 1: doc 3 (norm=2), and doc 1 re-indexed with 5 positions.
        const t2a = TermPosting{ .term = "alpha", .positions = &[_]u32{ 10, 11, 12, 13, 14 } };
        const t2b = TermPosting{ .term = "gamma", .positions = &[_]u32{ 0, 1 } };
        try eng.indexDocument(1, &[_]TermPosting{t2a});
        try eng.indexDocument(3, &[_]TermPosting{t2b});
        try eng.flush();

        // After second flush: doc 1 is in BOTH segments but the older
        // segment's value wins (3, not 5) — first-segment-wins semantics.
        try std.testing.expectEqual(@as(?u32, 3), eng.all_norms.get(1));
        try std.testing.expectEqual(@as(?u32, 1), eng.all_norms.get(2));
        try std.testing.expectEqual(@as(?u32, 2), eng.all_norms.get(3));

        // Memtable doc is intentionally absent from all_norms (norms are
        // computed at flush time only). DEFAULT_DOC_LEN fallback applies.
        const t3 = TermPosting{ .term = "delta", .positions = &[_]u32{ 0, 1, 2, 3 } };
        try eng.indexDocument(4, &[_]TermPosting{t3});
        try std.testing.expectEqual(@as(?u32, null), eng.all_norms.get(4));
    }

    {
        // Re-open: all_norms must rebuild from disk (init walks segments).
        var eng = try Engine.init(io, alloc, tmp_dir.dir);
        defer eng.deinit();
        try std.testing.expectEqual(@as(?u32, 3), eng.all_norms.get(1));
        try std.testing.expectEqual(@as(?u32, 1), eng.all_norms.get(2));
        try std.testing.expectEqual(@as(?u32, 2), eng.all_norms.get(3));
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

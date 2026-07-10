// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const crypto_backend = @import("crypto_backend");

/// Returns a `std.Io.File.Permissions` (which is structurally the same as
/// `std.Io.Dir.Permissions`) carrying the requested POSIX mode bits on
/// POSIX platforms, or `.default_file` on platforms whose `Permissions`
/// is a zero-sized enum (Windows/WASI). Used by `Engine` to set 0o700 on
/// data subdirectories and 0o600 on sensitive files (SEC-09, SEC-EXT-0302).
pub fn fileMode(mode: u32) std.Io.File.Permissions {
    const P = std.Io.File.Permissions;
    // Windows/WASI variants of Permissions carry no POSIX mode bits and no
    // fromMode constructor — collapse to the platform default (the doc
    // comment above has always promised this; the guard makes it compile).
    // Note: `std.posix.mode_t` alone is not a reliable signal here — on
    // Windows it resolves to `u32` (an `.int`) even though `Permissions` is
    // the zero-sized DWORD-backed enum with no `fromMode`, since
    // `Permissions` special-cases `is_windows` ahead of the mode_t check.
    if (comptime !@hasDecl(P, "fromMode")) return .default_file;
    return P.fromMode(@intCast(mode));
}

/// Variant of `fileMode` for directory creation. Falls back to
/// `.default_dir` on platforms whose `Permissions` is zero-sized.
pub fn dirMode(mode: u32) std.Io.Dir.Permissions {
    const P = std.Io.Dir.Permissions;
    if (comptime !@hasDecl(P, "fromMode")) return .default_dir;
    return P.fromMode(@intCast(mode));
}

// ============================================================================
// Buffer-based little-endian integer helpers (WRK-019, QUAL-0012, D-1, D-2,
// QUAL-0023). Each `writeU*Le` advances `pos` past the bytes it wrote;
// each `readU*Le` advances `offset` past the bytes it read. `readU32LeAt`
// is the random-access variant that does not advance.
// ============================================================================

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

/// LEB128 decoding from a byte slice. Returns the value and bytes read.
///
/// PERF-0012: marked `inline` because this is the hottest single function on
/// the indexing/replay/segment-scan path — call sites in posting decode,
/// position decode, and WAL replay each invoke it once per position. Forcing
/// inlining removes the call/return overhead and lets the compiler hoist
/// `result` / `shift` into registers across consecutive invocations.
///
/// SEC-EXT-0210: the 10th byte (`shift == 63`) of a valid LEB128 u64 carries
/// only one extra bit. If any of the upper 7 bits of byte 10 are set, the
/// encoded value does not fit in a u64 — surface as `error.Overflow` rather
/// than silently truncating.
pub inline fn readVarInt(buf: []const u8) !struct { val: u64, bytes_read: usize } {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < buf.len) {
        const byte = buf[i];
        i += 1;
        // On the 10th byte (shift==63) only the lowest bit can fit into a u64.
        // Any of the upper 7 bits being set means the encoded value overflows
        // u64 — refuse rather than truncate (SEC-EXT-0210).
        if (shift == 63 and (byte & 0xfe) != 0) return error.Overflow;
        result |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) {
            return .{ .val = result, .bytes_read = i };
        }
        shift += 7;
        if (shift >= 64) return error.Overflow;
    }
    return error.EndOfStream;
}

/// LEB128 encoding to a byte slice. Returns the number of bytes written.
///
/// PERF-0012: marked `inline` to match `readVarInt` — encode runs once per
/// position during indexing and once per delta during segment flush, so the
/// call overhead would otherwise dominate at high throughput.
pub inline fn writeVarInt(buf: []u8, value: u64) !usize {
    var mut_val = value;
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return error.NoSpaceLeft;
        var byte: u8 = @truncate(mut_val);
        mut_val >>= 7;
        if (mut_val != 0) {
            byte |= 0x80;
            buf[i] = byte;
            i += 1;
        } else {
            buf[i] = byte;
            i += 1;
            break;
        }
    }
    return i;
}

/// A wrapper to hash data with CRC32C (Castagnoli polynomial).
///
/// PERF-0030: `std.hash.crc.Crc32Iscsi` is a generic LUT-based CRC. As of
/// Zig 0.16 the standard library does not auto-select a hardware-accelerated
/// path (no SSE4.2 `crc32q` / ARMv8 `crc32cx` dispatch). When this becomes a
/// bottleneck on long WAL payloads or large manifests, a hand-rolled
/// SIMD/intrinsic CRC32C should be vendored here; the surface stays the same
/// because callers only know the u32 result. Until then the table-driven
/// implementation is ~1.2 GiB/s on x86_64 which is still fast enough that
/// CRC is dominated by the surrounding I/O.
pub fn hashCrc32c(data: []const u8) u32 {
    // fips-exempt: non-security — CRC32c data-integrity checksum, never a MAC.
    return std.hash.crc.Crc32Iscsi.hash(data);
}

// ============================================================================
// AES-256-GCM helpers for opt-in segment-at-rest encryption (WRK-038,
// GAP-0009, SEC-EXT-0402).
//
// Wire format produced by `aeadEncrypt`:
//   nonce(12) || ciphertext(plaintext.len) || tag(16)
// Total overhead per encrypted file is 28 bytes. Each call generates a fresh
// random nonce from the engine's `std.Io.random` source — never reuse a
// nonce with the same key.
// ============================================================================

// fips-exempt: compile-time nonce/tag/key sizes only; the AEAD goes through the seam.
pub const AEAD_NONCE_LEN: usize = std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length;
// fips-exempt: compile-time tag size only; the AEAD goes through the seam.
pub const AEAD_TAG_LEN: usize = std.crypto.aead.aes_gcm.Aes256Gcm.tag_length;
// fips-exempt: compile-time key size only; the AEAD goes through the seam.
pub const AEAD_KEY_LEN: usize = std.crypto.aead.aes_gcm.Aes256Gcm.key_length;
pub const AEAD_OVERHEAD: usize = AEAD_NONCE_LEN + AEAD_TAG_LEN;

pub fn aeadEncrypt(
    io: std.Io,
    key: []const u8,
    plaintext: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (key.len != AEAD_KEY_LEN) return error.InvalidKey;
    // The `io` param is retained for the caller's signature; the CSPRNG now
    // routes through the seam (FIPS DRBG under -Dfips).
    _ = io;

    var nonce: [AEAD_NONCE_LEN]u8 = undefined;
    // FIPS-0004b: per-segment random nonce via the seam.
    crypto_backend.Csprng.bytes(&nonce) catch return error.OutOfMemory;

    const out = try allocator.alloc(u8, AEAD_NONCE_LEN + plaintext.len + AEAD_TAG_LEN);
    errdefer allocator.free(out);

    @memcpy(out[0..AEAD_NONCE_LEN], &nonce);

    var tag: [AEAD_TAG_LEN]u8 = undefined;
    var key_arr: [AEAD_KEY_LEN]u8 = undefined;
    @memcpy(&key_arr, key[0..AEAD_KEY_LEN]);
    // FIPS-0004b: segment AES-256-GCM seal via the seam.
    crypto_backend.Aead.seal(
        .aes_256_gcm,
        &key_arr,
        &nonce,
        "",
        plaintext,
        out[AEAD_NONCE_LEN .. AEAD_NONCE_LEN + plaintext.len],
        &tag,
    ) catch return error.OutOfMemory;
    @memcpy(out[AEAD_NONCE_LEN + plaintext.len ..], &tag);
    return out;
}

pub fn aeadDecrypt(
    key: []const u8,
    ciphertext: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (key.len != AEAD_KEY_LEN) return error.InvalidKey;
    if (ciphertext.len < AEAD_OVERHEAD) return error.CiphertextTooShort;

    var nonce: [AEAD_NONCE_LEN]u8 = undefined;
    @memcpy(&nonce, ciphertext[0..AEAD_NONCE_LEN]);

    const tag_off = ciphertext.len - AEAD_TAG_LEN;
    const ct = ciphertext[AEAD_NONCE_LEN..tag_off];

    var tag: [AEAD_TAG_LEN]u8 = undefined;
    @memcpy(&tag, ciphertext[tag_off..]);

    var key_arr: [AEAD_KEY_LEN]u8 = undefined;
    @memcpy(&key_arr, key[0..AEAD_KEY_LEN]);

    const out = try allocator.alloc(u8, ct.len);
    errdefer allocator.free(out);

    // FIPS-0004b: segment AES-256-GCM open via the seam (auth failure ->
    // AuthenticationFailed, preserving the existing caller contract).
    crypto_backend.Aead.open(.aes_256_gcm, &key_arr, &nonce, "", ct, &tag, out) catch return error.AuthenticationFailed;
    return out;
}

/// Performs an atomic file swap by writing to a temp file, fsyncing, and renaming.
///
/// Hardening (QUAL-0010, PERF-0013, SEC-EXT-0303):
/// - Tmp filename includes 8 random bytes of entropy so concurrent writers
///   and stale tmps from prior crashes never collide.
/// - Tmp is created with `O_EXCL` (`exclusive = true`) so we never clobber
///   an existing file we don't own.
/// - `errdefer` removes the tmp on any failure before rename completes.
/// - Rename is the durability point; we do not attempt a parent-dir fsync
///   because `std.Io.Dir` does not expose one in Zig 0.16.
///
/// Cross-platform semantics (QUAL-0028):
/// - **Linux / macOS / other POSIX:** `rename(2)` is atomic with respect to
///   readers — concurrent opens see either the old file or the new one,
///   never a partial write. Crash recovery: after fsync of the tmp, the
///   rename either lands or it doesn't; in both cases the on-disk state is
///   consistent. The lack of a parent-dir fsync means a crash *immediately*
///   after the rename returns can lose the rename itself on some
///   filesystems (ext4 default `data=ordered` mostly mitigates this; XFS
///   needs an explicit dirsync). Acceptable for v0.1 because manifest replay
///   is idempotent and (GSP-7) segment file DATA is fsynced before any
///   manifest references it — the remaining exposure is the directory
///   entry itself, not file contents.
/// - **Windows:** `MoveFileExW` / `ReplaceFileW` semantics. `std.Io.Dir.rename`
///   maps onto Win32 atomic replace where supported (NTFS, ReFS), which is
///   atomic w.r.t. other processes that open with `FILE_SHARE_*` flags.
///   FAT32 / network mounts may not provide atomicity. The same `errdefer
///   delete tmp` cleanup applies. Windows is **not** in the CI matrix today;
///   semantics above are based on the documented stdlib contract, not on a
///   passing CI run. A Windows job is a follow-up.
pub fn atomicWrite(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    var rand_bytes: [8]u8 = undefined;
    // fips-exempt: non-security — random suffix for atomic tmp-file naming
    // (collision avoidance), never a key.
    io.random(&rand_bytes);

    var tmp_path_buf: [4096]u8 = undefined;
    // Hand-format hex (Zig 0.16 has no std.fmt.fmtSliceHexLower).
    const hex_chars = "0123456789abcdef";
    var hex_buf: [16]u8 = undefined;
    for (rand_bytes, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    const tmp_path = try std.fmt.bufPrint(
        &tmp_path_buf,
        "{s}.{s}.tmp",
        .{ path, hex_buf[0..] },
    );

    // O_EXCL: fail if a file at tmp_path somehow already exists. 0o600
    // keeps the manifest tmp unreadable to other local users (SEC-09).
    const file = try dir.createFile(io, tmp_path, .{
        .exclusive = true,
        .permissions = fileMode(0o600),
    });
    var closed = false;
    errdefer if (!closed) file.close(io);
    errdefer dir.deleteFile(io, tmp_path) catch {};

    try file.writeStreamingAll(io, data);
    try file.sync(io);
    file.close(io);
    closed = true;

    try dir.rename(tmp_path, dir, path, io);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "varint encode/decode" {
    var buf: [10]u8 = undefined;
    const written = try writeVarInt(&buf, 1337);

    const res = try readVarInt(buf[0..written]);
    try std.testing.expectEqual(@as(u64, 1337), res.val);
    try std.testing.expectEqual(written, res.bytes_read);
}

test "varint large value" {
    var buf: [10]u8 = undefined;
    const expected: u64 = 0xFFFFFFFFFFFFFFFF;
    const written = try writeVarInt(&buf, expected);

    const res = try readVarInt(buf[0..written]);
    try std.testing.expectEqual(expected, res.val);
    try std.testing.expectEqual(written, res.bytes_read);
}

test "hashCrc32c" {
    const hash = hashCrc32c("test");
    // Crc32Iscsi of "test"
    try std.testing.expectEqual(@as(u32, 2258662080), hash);
}

test "atomicWrite cleans up tmp on rename failure" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Force rename to fail by creating "target" as a directory.
    try tmp_dir.dir.createDir(io, "target", .default_dir);

    const result = atomicWrite(io, tmp_dir.dir, "target", "hello");
    try std.testing.expectError(error.IsDir, result);

    // Confirm errdefer cleaned up the tmp file so no leftover ".tmp" remains.
    var iter = tmp_dir.dir.iterate();
    var found_tmp = false;
    while (try iter.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "target.") and
            std.mem.endsWith(u8, entry.name, ".tmp"))
        {
            found_tmp = true;
        }
    }
    try std.testing.expect(!found_tmp);
}

test "FIPS-0004b: aeadEncrypt/aeadDecrypt round-trips and rejects a flipped tag under the seam" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const key = [_]u8{0x37} ** AEAD_KEY_LEN;
    const blob = try aeadEncrypt(io, &key, "segment payload", a);
    defer a.free(blob);
    const pt = try aeadDecrypt(&key, blob, a);
    defer a.free(pt);
    try std.testing.expectEqualStrings("segment payload", pt);
    // Flip a ciphertext byte; GCM auth must fail.
    blob[AEAD_NONCE_LEN] ^= 0x01;
    try std.testing.expectError(error.AuthenticationFailed, aeadDecrypt(&key, blob, a));
}

// SEC-EXT-0504: coverage-guided fuzz entry point for the `zig-fuzz` CI
// component (`zig build test --fuzz`). Complements the deterministic
// adversarial corpus in tests/fuzz_targets.zig — that file is a separate
// build step (`test-fuzz`) not compiled into `zig build test`, so the
// coverage-guided fuzzer needs its own entry point living inside the `test`
// step. Outside `--fuzz` mode this runs once against an empty smoke input
// (see `std.testing.fuzz`'s no-corpus fallback), so it also runs as a
// normal, fast unit test.
test "fuzz: readVarInt never panics on arbitrary bytes" {
    const Ctx = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            const len = smith.slice(&buf);
            _ = readVarInt(buf[0..len]) catch return;
        }
    };
    try std.testing.fuzz(Ctx{}, Ctx.testOne, .{});
}

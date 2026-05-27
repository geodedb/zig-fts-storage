// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");

/// Returns a `std.Io.File.Permissions` (which is structurally the same as
/// `std.Io.Dir.Permissions`) carrying the requested POSIX mode bits on
/// POSIX platforms, or `.default_file` on platforms whose `Permissions`
/// is a zero-sized enum (Windows/WASI). Used by `Engine` to set 0o700 on
/// data subdirectories and 0o600 on sensitive files (SEC-09, SEC-EXT-0302).
pub fn fileMode(mode: u32) std.Io.File.Permissions {
    if (@typeInfo(std.posix.mode_t) == .int) {
        return std.Io.File.Permissions.fromMode(@intCast(mode));
    }
    return .default_file;
}

/// Variant of `fileMode` for directory creation. Falls back to
/// `.default_dir` on platforms whose `Permissions` is zero-sized.
pub fn dirMode(mode: u32) std.Io.Dir.Permissions {
    if (@typeInfo(std.posix.mode_t) == .int) {
        return std.Io.Dir.Permissions.fromMode(@intCast(mode));
    }
    return .default_dir;
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
pub fn readVarInt(buf: []const u8) !struct { val: u64, bytes_read: usize } {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < buf.len) {
        const byte = buf[i];
        i += 1;
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
pub fn writeVarInt(buf: []u8, value: u64) !usize {
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

/// A wrapper to hash data with CRC32C.
pub fn hashCrc32c(data: []const u8) u32 {
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

pub const AEAD_NONCE_LEN: usize = std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length;
pub const AEAD_TAG_LEN: usize = std.crypto.aead.aes_gcm.Aes256Gcm.tag_length;
pub const AEAD_KEY_LEN: usize = std.crypto.aead.aes_gcm.Aes256Gcm.key_length;
pub const AEAD_OVERHEAD: usize = AEAD_NONCE_LEN + AEAD_TAG_LEN;

pub fn aeadEncrypt(
    io: std.Io,
    key: []const u8,
    plaintext: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (key.len != AEAD_KEY_LEN) return error.InvalidKey;
    const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

    var nonce: [AEAD_NONCE_LEN]u8 = undefined;
    io.random(&nonce);

    const out = try allocator.alloc(u8, AEAD_NONCE_LEN + plaintext.len + AEAD_TAG_LEN);
    errdefer allocator.free(out);

    @memcpy(out[0..AEAD_NONCE_LEN], &nonce);

    var tag: [AEAD_TAG_LEN]u8 = undefined;
    var key_arr: [AEAD_KEY_LEN]u8 = undefined;
    @memcpy(&key_arr, key[0..AEAD_KEY_LEN]);
    Aes.encrypt(
        out[AEAD_NONCE_LEN .. AEAD_NONCE_LEN + plaintext.len],
        &tag,
        plaintext,
        "",
        nonce,
        key_arr,
    );
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
    const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

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

    try Aes.decrypt(out, ct, tag, "", nonce, key_arr);
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
pub fn atomicWrite(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    var rand_bytes: [8]u8 = undefined;
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

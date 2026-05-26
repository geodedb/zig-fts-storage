const std = @import("std");

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

/// Performs an atomic file swap by writing to a temp file, fsyncing, and renaming.
pub fn atomicWrite(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    var tmp_path_buf: [4096]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});

    // Write to tmp file
    const file = try dir.createFile(io, tmp_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    try file.sync(io);

    // Rename to target (atomic)
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

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
const std = @import("std");
const crypto_backend = @import("crypto_backend");

test "fts-storage crypto_backend seam resolves Mac (HMAC-SHA256)" {
    var tag: [32]u8 = undefined;
    // RFC 4231 Test Case 2: key "Jefe", data "what do ya want for nothing?".
    const n = try crypto_backend.Mac.hmac(.sha256, "Jefe", "what do ya want for nothing?", &tag);
    try std.testing.expectEqual(@as(usize, 32), n);
    const expect = [_]u8{
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e, 0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
        0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83, 0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    };
    try std.testing.expectEqualSlices(u8, &expect, &tag);
    crypto_backend.assertActive();
}

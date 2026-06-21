<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright (c) 2024-2026 CodePros -->

# FIPS-140-3 Mode (`-Dfips`)

## Flag semantics

`fts-storage` builds with a `-Dfips` flag (default `false`). When **off**,
security crypto routes through `src/std_shim.zig` (pure `std.crypto`) with zero
overhead, no `fips` dependency, and no OpenSSL link. When **on**
(`-Dfips=true -Dopenssl_path=<prefix>`), the same call sites route through the
linked OpenSSL 3.x FIPS-140-3 provider via the lazy `fips` package, and
`crypto_backend.assertActive()` hard-fails if the validated provider is absent.

```sh
zig build test --summary all && zig build test-integration --summary all
OPENSSL_CONF=/usr/local/ssl/ssl/openssl.cnf zig build test -Dfips=true -Dopenssl_path=/usr/local/ssl --summary all
# or:  make test-dual
```

This repo has exactly ONE local `build_options` instance for the `fips` flag
(GAP-0020-safe), threaded into the public module, CLI, and every test/bench root.

## Routed (security) call sites

| Site | Primitive | Seam call |
|------|-----------|-----------|
| `src/manifest.zig` `serializeWithHmac` | manifest integrity HMAC-SHA256 | `crypto_backend.Mac.hmac(.sha256, …)` |
| `src/manifest.zig` `deserializeWithHmac` | manifest integrity verification | `crypto_backend.Mac.hmac(.sha256, …)` |
| `src/utils.zig` `aeadEncrypt` nonce | per-segment random nonce | `crypto_backend.Csprng.bytes` |
| `src/utils.zig` `aeadEncrypt` | segment AES-256-GCM seal | `crypto_backend.Aead.seal(.aes_256_gcm, …)` |
| `src/utils.zig` `aeadDecrypt` | segment AES-256-GCM open | `crypto_backend.Aead.open(.aes_256_gcm, …)` |

## `fips-exempt` (allow-listed non-security) uses

| Site | Reason |
|------|--------|
| `src/manifest.zig` `Hmac.mac_length` | compile-time tag length only, not an algorithm choice |
| `src/manifest.zig` CRC32c (sign + verify) | framing checksum, not integrity-against-adversary (HMAC covers that) |
| `src/utils.zig` `hashCrc32c` | CRC32c data-integrity checksum, never a MAC |
| `src/utils.zig` `AEAD_*_LEN` consts | compile-time nonce/tag/key sizes only |
| `src/utils.zig` `atomicWrite` tmp-file entropy | random suffix for atomic tmp-file naming (collision avoidance), never a key |

## Behavior changes / removals under `-Dfips=true`

None. Manifest HMAC tag bytes and segment AES-256-GCM ciphertext/tag are
byte-identical under both modes (AES-256-GCM in both backends).

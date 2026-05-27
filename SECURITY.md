# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via email to: <security@codepros.dev>

Please include:

1. **Description** of the vulnerability
2. **Steps to reproduce** the issue
3. **Potential impact** assessment
4. **Suggested fix** (if you have one)

### What to Expect

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Resolution Timeline**: Depends on severity
  - Critical: 24-72 hours
  - High: 1-2 weeks
  - Medium: 2-4 weeks
  - Low: Next release cycle

### Disclosure Policy

- We follow responsible disclosure practices
- Security advisories will be published after fixes are available
- Credit will be given to reporters (unless anonymity is requested)

## Threat Model and Trust Boundaries

`fts-storage` is an embedded library, not a network service. Its threat model
reflects that — the trust boundary sits at the public API and at the
filesystem, not at a TCP socket. SEC-EXT-0704.

**What the library trusts:**

- **In-process callers.** The library has no authentication, no
  authorization, and no per-tenant isolation. Multi-tenant separation is the
  embedding application's responsibility — typically expressed via the
  `TermIterator` `AuthFilter` post-filter (RLS/ABAC, see SEC-EXT-0106).
- **The base directory's filesystem.** The library refuses to follow
  symlinks on existing files (`O_NOFOLLOW` via Zig's
  `follow_symlinks = false`), but Zig 0.16 does not expose an `O_NOFOLLOW`
  equivalent for *creating* files. The caller MUST ensure the parent
  `base_dir` and its `wal/` and `segments/` subdirectories are not writable
  by adversaries. The library sets `0o700` on data subdirectories and
  `0o600` on sensitive files to mitigate the local-user case.
- **The calling thread.** The Engine is single-threaded by contract.
  Mutating methods (`indexDocument`, `deleteDocument`, `flush`, `compact`,
  `deinit`) capture the owning thread at `init` and `std.debug.assert` on
  every entry in debug builds (SEC-EXT-0701). Callers that share an Engine
  across threads MUST provide their own mutex.

**What the library does NOT trust:**

- **On-disk bytes when HMAC is enabled.** With `EngineConfig.hmac_key` set,
  WAL records and manifests carry a trailing HMAC-SHA256 envelope and
  mismatches surface as `error.HmacMismatch` rather than silently falling
  back to a clean state (SEC-02, SEC-EXT-0401, GAP-0027).
- **External payload lengths.** Every deserializer consults
  `src/limits.zig` before allocating storage proportional to an untrusted
  value. WAL replay additionally enforces an aggregate-bytes cap
  (SEC-EXT-0203).
- **Term and position counts at the API boundary.** `indexDocument`
  validates term length, position count, and position monotonicity before
  any side effects (SEC-EXT-0101 through SEC-EXT-0107).

**Out-of-scope threats:**

- An adversary with code-execution on the embedding process (game over by
  definition).
- Side-channel timing attacks against BM25 scoring or auth filters.
- Filesystems that lie about `fsync` durability — the library is no more
  resilient than the underlying storage stack.

## Security Measures

This project implements:

- **Memory Safety**: Zig's compile-time memory safety checks
- **No Undefined Behavior**: Strict adherence to defined semantics
- **Dependency Scanning**: Automated security scanning in CI
- **Secret Detection**: Gitleaks scanning for leaked credentials
- **Opt-in HMAC envelopes**: WAL + manifest tampering detection
- **Opt-in AES-256-GCM segment encryption**: at-rest data confidentiality
- **Single-thread debug assertion**: catches contract violations early
- **Corrupt-segment quarantine**: bit rot on one segment does not block
  recovery; broken segments are renamed to `seg_<id>.corrupt` and skipped
  with a warning (SEC-EXT-0209). Only triggered when AEAD is configured,
  to avoid mistaking "caller forgot the key" for genuine corruption.

## Security Best Practices

When using this library:

1. Keep dependencies updated
2. Review security advisories regularly
3. Report any suspicious behavior
4. Follow secure coding guidelines

## Contact

For non-security issues, see [SUPPORT.md](SUPPORT.md).

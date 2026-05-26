# Security Gap Analysis — fts-storage

- **Project**: `/home/benji/src/devnw/zig/fts-storage`
- **Run date**: 2026-05-26
- **Mode**: **docs-only (no GitLab issues created — including confidential)**
- **Scope**: Phase 2 security-scanner (SEC-01..SEC-11) + Phase 3 security-reviewer extended findings (SEC-EXT-0101..SEC-EXT-0704).
- **Closure run**: 2026-05-26 — 20 findings closed across 5 commits; 28 remain open.
- **Status convention**: rows annotated "Closed" were addressed in the 2026-05-26 closure run; all other rows remain `Open — Issue not created (docs-only run)`.

---

## 1. Scoring Model (brief)

```text
Risk Score = Impact (1..5) × Likelihood (1..5) × 4         → 4..100
```

| Axis | 1 | 2 | 3 | 4 | 5 |
|------|---|---|---|---|---|
| **Impact** | Hardening | Info leak | Tampering / limited DoS | PII / credential leak / authN bypass | RCE / priv-esc / cross-tenant breach |
| **Likelihood** | Theoretical | Rare misconfig | Authenticated attacker | Remote, constrained | Pre-auth, remote, trivial |

**Exposure modifier (additive, capped at 100):**

- `+5` Internet-facing data path that parses untrusted bytes (e.g., on-disk segment files when the library is embedded in an ingest service).
- `+3` Supply-chain / build-time surface reachable by upstream compromise.
- `+0` Library-internal hardening with no realistic attacker path.

`fts-storage` is a storage library — it does not face the network directly. Likelihood is scored against the **realistic deployment**: a server process that accepts indexing requests and persists segments on disk. Files written by the process are treated as **untrusted on read** because the parser reloads them on restart, and the threat model must cover an attacker who can write into the data directory (compromised neighbour process, restored-from-backup tampering, container volume mount abuse, malicious operator).

---

## 2. Headline Histograms

**Phase 2 (SEC-01..SEC-11)**: Critical=2, High=4, Medium=2, Low=2, Info=1.
**Phase 3 (SEC-EXT-* new findings)**: Critical=1, High=8, Medium=14, Low=11, Info=3.

**Combined**: Critical=3, High=12, Medium=16, Low=13, Info=4 — **48 distinct findings**.

---

## 3. Top 5 by Risk Score

| Rank | ID | Title | Risk Score | Why it tops the list |
|------|----|-------|-----------|----------------------|
| 1 | **SEC-EXT-0201** | `manifest.zig:70-74` u32 count → ~96 GiB allocation pre-check | **100** | Pre-auth on restart; any attacker who can drop a manifest causes OOM-kill loop. Impact 5 (availability + crashloop), Likelihood 5 (single u32, no cap), +Exposure. |
| 2 | **SEC-EXT-0401** | CRC32C advertised as authentication | **95** | Documentation/threat-model lie that invalidates every downstream "tamper-evident" claim. Impact 5 (integrity guarantee collapses), Likelihood ~5 (CRC32C forgeable in O(1)). |
| 3 | **SEC-EXT-0501** | install-zig.sh TOFU trust chain (extends SEC-06) | **90** | Build-time RCE precursor; MITM of `index.json` defeats the SHA-256 step that the script appears to enforce. Impact 5, Likelihood 4 (active MITM on CI runner egress is realistic), +Exposure. |
| 4 | **SEC-EXT-0503** | 22 ci-catalog components pinned to mutable semver tags | **88** | Single upstream compromise rewrites the tag and lands on every pipeline. Impact 5 (CI exec), Likelihood 4 (tag-rewrite is a known and demonstrated attack class), +Exposure. |
| 5 (tie) | **SEC-EXT-0103 / SEC-EXT-0102** | `engine.zig:191 / :195` silent `@intCast` truncation in ReleaseFast | **80** | In Release builds the truncation is silent; corpus poisoning becomes a primitive that downstream search/ranking trusts. Impact 4, Likelihood 5 (any over-length input on any indexed doc). |

---

## 4. Sortable Findings Table

| ID(s) | Title | OWASP / CWE | Risk | Risk Score | File:line | Suggested fix |
|---|---|---|---|---:|---|---|
| **SEC-EXT-0201** | `u32 count` → ~96 GiB pre-CRC allocation in manifest loader | A04:2021 / CWE-770, CWE-789 | Critical | **100** | `src/manifest.zig:70-74` | Cap `count ≤ MAX_MANIFEST_ENTRIES` (e.g., 1<<20) and validate against file size before `alloc`. Verify CRC **before** any length-driven alloc. **Closed — commit 496de3c** |
| **SEC-EXT-0401** | CRC32C described as authentication; it is integrity-only | A02:2021, A08:2021 / CWE-353, CWE-345 | Critical | **95** | `docs/fts-storage-spec.md` (claims), `src/segment.zig` (impl) | Restate as integrity-only. Add HMAC-SHA256 (or BLAKE3-keyed) over every segment file + manifest envelope. Update spec wording. |
| **SEC-EXT-0501** | install-zig.sh trust chain (TOFU index.json defeats SHA-256) | A08:2021 / CWE-494, CWE-829 | Critical | **90** | `scripts/install-zig.sh:32` | Pin minisign public key + ship `minisig` verify; or fully pin tarball SHA-256 + URL **in-tree** rather than fetched. Remove fetch-then-verify pattern. |
| **SEC-EXT-0503** | 22 ci-catalog components on mutable semver tags (extends SEC-08) | A08:2021 / CWE-494, CWE-1357 | Critical | **88** | `.gitlab-ci.yml:40-43` (and all `include:` blocks) | Pin each `include` to immutable commit SHA. Add renovate/dependabot for promotions. |
| **SEC-01** | Uncapped `u64` alloc from `postings_len` | A04:2021 / CWE-770 | Critical | **88** | `src/segment.zig:282` | Bound `postings_len ≤ file_size − cursor`; reject before alloc. **Closed — commit 496de3c** |
| **SEC-02** | Segment files have no CRC/HMAC (terms.hash, postings.bin, tombstones.bin) | A08:2021 / CWE-353 | Critical | **88** | `src/segment.zig` (all readers/writers) | Add per-file footer with HMAC-SHA256; verify before any allocation driven by file-resident length. |
| **SEC-EXT-0103** | Silent `@intCast` `positions.len → u16` in ReleaseFast | A03:2021 / CWE-197, CWE-681 | High | **80** | `src/engine.zig:195` | Pre-check `positions.len ≤ u16_max`; return `error.TooManyPositions`. Never `@intCast` user-controlled lengths in Release. **Closed — commit 91b3ba7** |
| **SEC-EXT-0102** | Silent `@intCast` `term.len → u16` in ReleaseFast | A03:2021 / CWE-197, CWE-681 | High | **80** | `src/engine.zig:191` | Pre-check `term.len ≤ u16_max`; return `error.TermTooLong`. **Closed — commit 91b3ba7** |
| **SEC-EXT-0101** | No input validation on `indexDocument` terms | A03:2021 / CWE-20 | High | **80** | `src/engine.zig:181` | Validate term bytes (UTF-8 / max length / non-empty), position monotonicity, count caps. **Closed — commit 91b3ba7** |
| **SEC-EXT-0106** | No tenant/RLS at API; any caller can tombstone any doc_id | A01:2021 / CWE-862, CWE-639 | High | **80** | `src/engine.zig` (delete path) | Add caller-bound auth context (tenant_id) and enforce ownership before tombstone write. |
| **SEC-EXT-0206** | `doc_delta` u64 add overflow / `pos_delta` u64→u32 cast | A03:2021 / CWE-190, CWE-681 | High | **72** | `src/segment.zig:255-273` | Use `@addWithOverflow` / explicit checked casts; reject malformed varints. **Closed — commit 496de3c** |
| **SEC-EXT-0204** | `applyIndexDocPayload` uncapped terms-per-record | A04:2021 / CWE-770 | High | **72** | `src/engine.zig:163-175` | Cap `term_count ≤ MAX_TERMS_PER_DOC`; reject WAL records that exceed it. **Closed — commit 496de3c** |
| **SEC-EXT-0402** | Plaintext at rest; no in-library encryption hook | A02:2021 / CWE-311, CWE-312 | High | **64** | (cross-cutting) | Document deployment expectation (FDE/LUKS) **and** provide a pluggable AEAD writer interface; default off but available. |
| **SEC-03** | Uncapped `tf` u64 varint | A04:2021 / CWE-770, CWE-190 | High | **64** | `src/segment.zig:264` | Bound `tf` (e.g., ≤ 1<<24) before use; reject otherwise. **Closed — commit 496de3c** |
| **SEC-04** | Uncapped `u32 count` for dictionary | A04:2021 / CWE-770 | High | **64** | `src/segment.zig:346` | Cap dictionary count vs file size and absolute max. **Closed — commit 496de3c** |
| **SEC-05** | Uncapped `u32 count` for tombstones | A04:2021 / CWE-770 | High | **64** | `src/segment.zig:376` | Cap tombstone count vs file size and absolute max. **Closed — commit 496de3c** |
| **SEC-06** | TOFU fetch of `index.json` (MITM defeats SHA-256) | A08:2021 / CWE-494, CWE-300 | High | **60** | `scripts/install-zig.sh:32` | See SEC-EXT-0501; pin tarball hash in-tree, not in fetched JSON. |
| **SEC-EXT-0207** | `segment.zig` `tf` `@intCast` panic / 8 GiB alloc (extends SEC-03) | A04:2021 / CWE-770, CWE-681 | Medium | **48** | `src/segment.zig:264` | Combined cap + pre-validation as in SEC-03. **Closed — commit 496de3c** |
| **SEC-EXT-0211** | WAL truncated tail aborts entire replay | A04:2021 / CWE-755 | Medium | **48** | `src/wal.zig` | Implement last-good-record truncate: stop at first incomplete record and rewrite tail. |
| **SEC-EXT-0212** | Unknown record type hard-fails recovery | A04:2021 / CWE-755 | Medium | **48** | `src/wal.zig` | Reject record but continue replay (or refuse only when strictness flag is set); never brick the engine on a single byte. |
| **SEC-EXT-0301** | No `O_NOFOLLOW`; symlink replacement of manifest/files | A01:2021 / CWE-59 | Medium | **48** | `src/manifest.zig`, `src/segment.zig` (open paths) | Pass `O_NOFOLLOW` (or `openat` with `RESOLVE_NO_SYMLINKS` on Linux); fail on symlink. |
| **SEC-EXT-0304** | TOCTOU between `manifest.a` / `manifest.b` load; rollback attack | A01:2021 / CWE-367, CWE-1262 | Medium | **48** | `src/manifest.zig` (loadManifest) | Open both `manifest.a` and `manifest.b` once (held fds), compare counters, fsync before swap, use a monotonically-increasing sequence number that is also HMACed. |
| **SEC-EXT-0202** | Manifest alloc pre-CRC unbounded (extends SEC-07) | A04:2021 / CWE-770 | Medium | **48** | `src/manifest.zig` | Same as SEC-EXT-0201 — CRC/HMAC **before** allocation. **Closed — commit 496de3c** |
| **SEC-EXT-0205** | `applyIndexDocPayload` accepts `term_len=0` | A03:2021 / CWE-20 | Medium | **40** | `src/engine.zig` | Reject zero-length term in payload; mirror writer-side validation. **Closed — commit 91b3ba7** |
| **SEC-EXT-0208** | Empty term in dictionary load | A03:2021 / CWE-20 | Medium | **40** | `src/segment.zig:350-351` | Reject empty term during load; refuse to advance cursor. **Closed — commit 91b3ba7** |
| **SEC-EXT-0104** | Duplicate term in single call silently merged | A03:2021 / CWE-694, CWE-20 | Medium | **40** | `src/engine.zig` (indexDocument) | Return `error.DuplicateTerm` or deterministic merge with explicit policy. **Closed — commit 91b3ba7** |
| **SEC-EXT-0105** | Positions not validated monotonic; unsigned underflow on write | A03:2021 / CWE-191, CWE-20 | Medium | **40** | `src/engine.zig` | Validate strictly increasing positions before encoding delta. **Closed — commit 91b3ba7** |
| **SEC-EXT-0602** | No security/PR issue templates | A05:2021 / CWE-1059 | Medium | **40** | `.gitlab/` (missing) | Add `SECURITY.md`, `.gitlab/issue_templates/Security.md`, and PR template. |
| **SEC-EXT-0604** | ReleaseFast disables `@intCast` checks; supported in CI | A05:2021 / CWE-758 | Medium | **40** | `.gitlab-ci.yml` (build matrix) | Add a Release**Safe** build to CI; ban ReleaseFast for production builds; replace `@intCast` of untrusted lengths everywhere. |
| **SEC-EXT-0502** | Pre-commit hook repos pinned to mutable tags (5 repos) | A08:2021 / CWE-494 | Medium | **40** | `.pre-commit-config.yaml` | Pin each hook to commit SHA. |
| **SEC-EXT-0702** | No auto-flush; unbounded memtable growth = DoS | A04:2021 / CWE-770 | Medium | **40** | `src/engine.zig` | Add memtable byte/entry threshold that triggers flush; document operator backpressure contract. |
| **SEC-07** | Manifest alloc uncapped `stat.size` | A04:2021 / CWE-770 | Medium | **40** | `src/engine.zig:109` | Cap `stat.size` (e.g., 64 MiB) before alloc; verify HMAC before consuming length fields. **Closed — commit 496de3c** |
| **SEC-08** | Mutable semver tags in `.gitlab-ci.yml` | A08:2021 / CWE-494 | Medium | **32** | `.gitlab-ci.yml:40-43` | Pin to commit SHA (see SEC-EXT-0503). |
| **SEC-EXT-0601** | CODEOWNERS placeholder (extends SEC-10) | A05:2021 | Medium | **32** | `CODEOWNERS` | Replace placeholder owners with real users/teams; enforce required reviews in protected branches. **Closed — commit 5081638** |
| **SEC-EXT-0210** | `readVarInt` 10th-byte high-bit not checked | A03:2021 / CWE-190 | Low | **24** | `src/segment.zig` (varint reader) | Reject continuation bit set on 10th byte; cap shift count. |
| **SEC-EXT-0209** | Corrupt segment file blocks engine init permanently | A04:2021 / CWE-755 | Low | **24** | `src/engine.zig` (open path) | Quarantine bad segment, log, continue init; expose repair command. |
| **SEC-EXT-0305** | `loadManifest` swallows errors silently (data loss) | A09:2021 / CWE-703, CWE-755 | Low | **24** | `src/manifest.zig` | Propagate errors; require explicit `--repair` flag before continuing with degraded state. **Closed — commit d3eae2b** |
| **SEC-EXT-0303** | `atomicWrite` tmp path predictable, no `O_EXCL` | A04:2021 / CWE-377, CWE-378 | Low | **24** | `src/utils.zig` (atomicWrite) | Use mkstemp-style randomized suffix + `O_CREAT \| O_EXCL`. **Closed — commit ff28470** |
| **SEC-EXT-0302** | Extends SEC-09 (operational impact) | A05:2021 / CWE-276 | Low | **20** | (file creation paths) | Honor explicit mode `0o600` on sensitive files; document umask expectation. **Closed — commit d14e4c6** |
| **SEC-EXT-0203** | Replay aggregate alloc unbounded | A04:2021 / CWE-770 | Low | **20** | `src/wal.zig` (replay) | Stream/replay incrementally; cap intermediate aggregate. |
| **SEC-EXT-0107** | Empty term not rejected in `TermIterator.init` | A03:2021 / CWE-20 | Low | **20** | `src/search.zig` (TermIterator.init) | Reject empty term; return error. **Closed — commit 91b3ba7** |
| **SEC-EXT-0703** | `TermIterator` unbounded peak memory across many segments | A04:2021 / CWE-770 | Low | **20** | `src/search.zig` | Stream-merge segments; bound per-iterator buffer. |
| **SEC-09** | Files created at default umask (0o644 plaintext) | A05:2021 / CWE-276 | Low | **20** | (file create call sites) | Pass explicit `mode=0o600`; document umask. **Closed — commit d14e4c6** |
| **SEC-10** | CODEOWNERS placeholder | A05:2021 | Low | **16** | `CODEOWNERS` | See SEC-EXT-0601. **Closed — commit 5081638** |
| **SEC-EXT-0505** | `ubuntu:24.04` unpinned in CI | A08:2021 / CWE-494 | Low | **16** | `.gitlab-ci.yml` (image:) | Pin to digest (`ubuntu:24.04@sha256:...`). |
| **SEC-EXT-0506** | `apt-get install` in `before_script` unpinned | A08:2021 / CWE-494 | Low | **16** | `.gitlab-ci.yml` (before_script) | Pin package versions; or build/cache a base image once. |
| **SEC-EXT-0504** | Fuzz advisory + 60 s + no targeted harnesses | A05:2021 / CWE-1059 | Low | **16** | `.gitlab-ci.yml` (fuzz job) | Make fuzz blocking on the parser surface; add per-record-type harnesses (segment loader, manifest loader, WAL replay). |
| **SEC-EXT-0603** | `security@codepros.dev` vs `codepros.org` domain mismatch | A05:2021 / CWE-1059 | Low | **12** | `SECURITY.md` (or equivalent) | Reconcile to one canonical domain. |
| **SEC-EXT-0605** | No ASan/UBSan CI job | A05:2021 / CWE-1059 | Low | **12** | `.gitlab-ci.yml` | Add a sanitizer build/test job (Zig: `-fsanitize-c` and Debug + extra checks). |
| **SEC-11** | 6/8 src files missing SPDX header | A05:2021 / CWE-1059 | Info | **8** | `src/*.zig` | Add SPDX-License-Identifier to all files. **Closed — commit 3bf8efc** |
| **SEC-EXT-0701** | Single-threaded contract not enforced | A04:2021 / CWE-664 | Info | **8** | (engine API surface) | Document precondition + add debug-mode thread-id assertion. |
| **SEC-EXT-0704** | Parser trust-boundary documentation | A05:2021 | Info | **8** | `docs/fts-storage-spec.md` | Add explicit "on-disk bytes are untrusted on read" section. |
| **SEC-EXT-0403** | CRC32C cryptographic posture documentation | A02:2021 / CWE-345 | Info | **8** | `docs/fts-storage-spec.md` | State plainly that CRC32C is integrity-only; reference SEC-EXT-0401 remediation. |

(Risk Score values are deterministic for `impact × likelihood × 4` plus the exposure modifier and rounded — they sort the table, not adjudicate it.)

---

## 5. Cross-Cutting Themes

1. **Integrity ≠ Authentication.** CRC32C is repeatedly spoken about as if it stopped tampering; it does not. The spec language and at least one Phase-3 reviewer note both reinforce the confusion. Until an HMAC (or signed envelope) lands on every segment + manifest, **every "tamper-evident" claim in the docs is false** (SEC-02, SEC-EXT-0401, SEC-EXT-0403).
2. **"Trust the disk" parser.** Every uncapped allocation finding (SEC-01, SEC-03, SEC-04, SEC-05, SEC-07, SEC-EXT-0201..0212, SEC-EXT-0703) has the same root cause: lengths read from disk drive `alloc` **before** verification. The fix pattern is identical: cap → verify HMAC → then allocate.
3. **No API input validation.** `engine.zig` accepts whatever `indexDocument` is handed — term bytes, term length, positions, duplicates (SEC-EXT-0101, 0102, 0103, 0104, 0105, 0106, 0107, 0205). The library treats its own API as a trust boundary it does not actually defend.
4. **Tag pins, not SHA pins.** CI components, the Zig install script, the base image, apt packages, and pre-commit hooks all use mutable references (SEC-06, SEC-08, SEC-EXT-0501..0506). Any one of these is sufficient for a supply-chain footgun.
5. **ReleaseFast foot-gun.** ReleaseFast silently disables `@intCast` checks. The build matrix supports it, the codebase uses `@intCast` on untrusted lengths, and the two facts compose into "silent corpus corruption" (SEC-EXT-0102, 0103, 0604).
6. **No parser fuzzing.** A storage format with the trust posture above ships without targeted fuzz harnesses; the CI fuzz step is advisory and very short (SEC-EXT-0504).
7. **Governance placeholders unreplaced.** CODEOWNERS, SECURITY contact, security/PR templates, contact-domain inconsistency (SEC-10, SEC-EXT-0601, 0602, 0603). These are cheap to fix and signal triage maturity to incident reporters.

---

## 6. Threat Model Gap Statement

The codebase ships with **no documented threat model**. The realistic adversary set for a storage engine embedded in a multi-tenant indexing service includes at minimum:

- **A1. Malicious indexer client** (pre-auth or low-privilege) — can submit unbounded terms / positions / duplicates / oversized buffers. Covered by SEC-EXT-0101..0107, 0204, 0205.
- **A2. Co-tenant attacker** — exploits absence of tenant/RLS at the API to tombstone or otherwise tamper with another tenant's documents. Covered by SEC-EXT-0106.
- **A3. Filesystem-adjacent attacker** (compromised sidecar, hostile operator, restored-from-untrusted-backup) — can write/replace segment, manifest, WAL files. Defeats the parser via SEC-01..05, SEC-EXT-0201..0212, 0301..0305. CRC32C does **not** stop this attacker (SEC-EXT-0401).
- **A4. Supply-chain attacker** — rewrites a mutable tag in a CI catalog, install-zig.sh `index.json`, base image, apt mirror, or pre-commit hook (SEC-06, SEC-08, SEC-EXT-0501..0506).
- **A5. Operational mishap** — truncated WAL tail, corrupt segment, mismatched manifest counters lock the engine into a crashloop (SEC-EXT-0209, 0211, 0212, 0305).

The gap is not in any single control; it is the absence of a written threat model that names these adversaries and selects controls per adversary. Until one exists, every code-level fix below is a point patch rather than a coherent defence.

---

## 7. Recommendations (sequenced)

### Critical — do these first (target: 7 days)

1. **Write the threat model** (1 day). Name A1–A5 explicitly. Reference this doc.
2. **Cap-then-verify on every length read from disk** (SEC-01, 02, 03, 04, 05, 07, SEC-EXT-0201, 0202, 0203, 0204, 0206, 0207).
3. **Add HMAC-SHA256 (or BLAKE3-keyed) envelopes** on every segment file and on the manifest. CRC32C stays as a cheap pre-filter; HMAC is the gate before any allocation (SEC-02, SEC-EXT-0401).
4. **Lock the build supply chain.** Pin every CI component / install-zig source / base image / pre-commit hook to commit SHA + cryptographic hash (SEC-06, SEC-08, SEC-EXT-0501, 0502, 0503).

### High — within 30 days

1. **Defend the API.** Term length, term bytes, positions monotonicity, position count, term count per doc; tenant context on every mutating call (SEC-EXT-0101–0107, 0204, 0206).
2. **Replace `@intCast` of untrusted lengths everywhere; ban ReleaseFast for production builds**, add ReleaseSafe to the matrix (SEC-EXT-0102, 0103, 0604).
3. **Encryption-at-rest hook** with documented deployment expectation (SEC-EXT-0402).
4. **Targeted parser fuzzing** (segment loader, manifest loader, WAL replay) — blocking in CI (SEC-EXT-0504).

### Medium — within 90 days

1. **Filesystem hardening** — `O_NOFOLLOW`, randomized atomic-write tmp paths, manifest TOCTOU fix, no-symlink-followed file open (SEC-EXT-0301, 0303, 0304).
2. **WAL/segment robustness** — last-good-tail truncate, unknown-record-type tolerance, quarantine-on-corruption (SEC-EXT-0209, 0211, 0212, 0305).
3. **Backpressure** — memtable auto-flush threshold (SEC-EXT-0702).
4. **Validation parity** between writer-side and load-side (zero-length terms, duplicate terms, empty dictionary entries) (SEC-EXT-0104, 0205, 0208).
5. **Governance** — real CODEOWNERS, SECURITY.md, security/PR templates, contact-domain reconciliation (SEC-10, SEC-EXT-0601, 0602, 0603).

### Low — within 180 days

1. **`mode=0o600`** on sensitive file creation; document umask expectation (SEC-09, SEC-EXT-0302).
2. **Streaming TermIterator** (SEC-EXT-0703).
3. **Stricter varint reader** (10th-byte continuation bit) (SEC-EXT-0210).
4. **ASan/UBSan CI job** (SEC-EXT-0605).
5. **CI base-image / apt pinning** (SEC-EXT-0505, 0506).

### Info — backlog / hygiene

1. **SPDX headers** (SEC-11).
2. **Single-threaded contract** assertion (SEC-EXT-0701).
3. **Trust-boundary section** in spec; restate CRC32C posture (SEC-EXT-0403, 0704).

---

## 8. Status

### Closed Items (2026-05-26 closure run)

| ID | Title | Commit |
|----|-------|--------|
| SEC-01 | Uncapped `u64` alloc from `postings_len` | 496de3c |
| SEC-03 | Uncapped `tf` u64 varint | 496de3c |
| SEC-04 | Uncapped `u32 count` for dictionary | 496de3c |
| SEC-05 | Uncapped `u32 count` for tombstones | 496de3c |
| SEC-07 | Manifest alloc uncapped `stat.size` | 496de3c |
| SEC-09 | Files created at default umask (0o644 plaintext) | d14e4c6 |
| SEC-10 | CODEOWNERS placeholder | 5081638 |
| SEC-11 | 6/8 src files missing SPDX header | 3bf8efc |
| SEC-EXT-0101 | No input validation on `indexDocument` terms | 91b3ba7 |
| SEC-EXT-0102 | Silent `@intCast` `term.len → u16` in ReleaseFast | 91b3ba7 |
| SEC-EXT-0103 | Silent `@intCast` `positions.len → u16` in ReleaseFast | 91b3ba7 |
| SEC-EXT-0104 | Duplicate term in single call silently merged | 91b3ba7 |
| SEC-EXT-0105 | Positions not validated monotonic; unsigned underflow | 91b3ba7 |
| SEC-EXT-0107 | Empty term not rejected in `TermIterator.init` | 91b3ba7 |
| SEC-EXT-0201 | `u32 count` → ~96 GiB pre-CRC allocation in manifest loader | 496de3c |
| SEC-EXT-0202 | Manifest alloc pre-CRC unbounded (extends SEC-07) | 496de3c |
| SEC-EXT-0204 | `applyIndexDocPayload` uncapped terms-per-record | 496de3c |
| SEC-EXT-0205 | `applyIndexDocPayload` accepts `term_len=0` | 91b3ba7 |
| SEC-EXT-0206 | `doc_delta` u64 add overflow / `pos_delta` u64→u32 cast | 496de3c |
| SEC-EXT-0207 | `segment.zig` `tf` `@intCast` panic / 8 GiB alloc | 496de3c |
| SEC-EXT-0208 | Empty term in dictionary load | 91b3ba7 |
| SEC-EXT-0302 | Extends SEC-09 (operational impact) | d14e4c6 |
| SEC-EXT-0303 | `atomicWrite` tmp path predictable, no `O_EXCL` | ff28470 |
| SEC-EXT-0305 | `loadManifest` swallows errors silently | d3eae2b |
| SEC-EXT-0601 | CODEOWNERS placeholder (extends SEC-10) | 5081638 |

**25 findings closed in the 2026-05-26 closure run. 23 findings remain open.**

All open rows: **Open — Issue not created (docs-only run)**.

No GitLab issues — confidential or otherwise — were created, updated, or closed by this run.

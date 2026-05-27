# Quality Gap Analysis — fts-storage

- **Project:** `/home/benji/src/devnw/zig/fts-storage`
- **Run date:** 2026-05-26
- **Mode:** docs-only (no platform issues created or modified)
- **Sources:** Phase 2 quality-scanner (D-/DC-/P-/DO-/CI- prefixes) + Phase 3 quality-reviewer (QUAL-0001..QUAL-0034)
- **Closure run:** 2026-05-26 — 21 commits landed; see commit-↔-finding map in this file

---

## Scoring Model

`PriorityScore` is a heuristic in the range `[0, 100]`, computed as:

```text
PriorityScore = round( severity_weight * impact * confidence / fix_cost )
```

| Factor | Domain | Notes |
|---|---|---|
| `severity_weight` | Critical=10, High=7, Med=4, Low=2 | Anchors the order of magnitude. |
| `impact` | 1..5 | Blast radius if the issue manifests (correctness > perf > polish; user-visible > internal). |
| `confidence` | 0.5..1.0 | 1.0 = directly observed in code; 0.7 = inferred; 0.5 = suspected pending verification. |
| `fix_cost` | 1..5 | 1 = one-line / one-file mechanical change; 5 = cross-module refactor or new test infrastructure. |

Higher score = address sooner. Ties are broken by Severity then by smallest `fix_cost` (cheap wins first).

Category labels: `api-contract`, `architecture`, `perf`, `maintainability`, `readability`, `tests`, `docs`, `ci-cd`, `deps`, `cleanup`.
Confidence tags: `confidence::confirmed` (verified in code) / `confidence::suspected` (inferred).

---

## Status Legend

- **Open** — no closure exists in runs 1–3; flagged for re-audit in next cycle
- **Won't-Do** — intentionally not implemented; reason and reference documented
- **Closed** — addressed; evidence points to commit SHA
- **Deferred** — intentionally deferred; reason documented

---

## Stack-Ranked Findings

Sorted by `PriorityScore` descending. All file:line citations point at `/home/benji/src/devnw/zig/fts-storage`.

| Rank | Finding ID(s) | Title | Category | Severity | PriorityScore | File:line | Status | Evidence |
|-----:|---|---|---|---|---:|---|---|---|
| 1 | QUAL-0001 | `root.zig` exposes no real public API — `Engine` not re-exported | api-contract | Critical | 100 | `src/root.zig:1-end` | **Closed** | commit 7234563 |
| 2 | QUAL-0002 | `docs/fts-storage-spec.md` is a Geode LLM dump with `citeturn*` artifacts | docs | Critical | 80 | `docs/fts-storage-spec.md:*` | Won't-Do (Deferred to dedicated doc cycle) — commit d8da757 annotated file as upstream design history and added disclaimer; full rewrite deferred until API surface stabilises. | d8da757 |
| 3 | QUAL-0006 | `Memtable.total_docs` and `SegmentEntry.doc_count` never incremented — BM25 wrong | api-contract | High | 70 | `src/engine.zig` (indexDocument), `src/segment.zig` | **Closed** | commit 2934b17 |
| 4 | QUAL-0004 | `loadManifest` silently swallows `ChecksumMismatch` via `catch null` | api-contract | High | 70 | `src/manifest.zig` (loadManifest) | **Closed** | commit d3eae2b |
| 5 | QUAL-0005 | Flush ordering can orphan segments / truncate WAL on partial failure | architecture | High | 56 | `src/engine.zig` (flush path) | **Closed** | commit 60d5c26 |
| 6 | QUAL-0011 | Integration + stress tests exercise stub `lib.init`, not `Engine` | tests | High | 56 | `tests/*`, `src/root.zig` | **Closed** | commit 2d51283 |
| 7 | QUAL-0003 | README / `root.zig` Feature 1/2/3 placeholder text | docs | High | 49 | `README.md`, `src/root.zig` | **Closed** | commit 3c47bc5 |
| 8 | QUAL-0008 | `Engine.deinit` doesn't close `self.dir` — ownership unclear | api-contract | High | 49 | `src/engine.zig` (deinit) | **Closed** | commit 14c4fe6 |
| 9 | QUAL-0010 | `atomicWrite` missing parent-dir fsync, Windows rename pitfalls, no tmp cleanup | architecture | High | 42 | `src/utils.zig` (atomicWrite) | **Closed** | commit ff28470 |
| 10 | QUAL-0007 | `Memtable.addPosting` leaks key on subsequent alloc failure | maintainability | High | 42 | `src/engine.zig` (Memtable.addPosting) | **Closed** | commit 5bd07c1 |
| 11 | QUAL-0009 | `anyerror` leaks; no named error sets per module | api-contract | High | 35 | `src/engine.zig`, `src/wal.zig`, `src/manifest.zig` | **Closed** | commit ec23de9 |
| 12 | QUAL-0018 | `indexDocument`: memtable updated before WAL append — divergence on WAL failure | architecture | Medium | 32 | `src/engine.zig` (indexDocument) | **Closed** | commit 5bd07c1 |
| 13 | QUAL-0015 | `varint` accepts `u64` but callers `@intCast` down — silent truncation in ReleaseFast | api-contract | Medium | 32 | `src/utils.zig` (varint), call sites in `wal.zig`, `segment.zig` | **Closed** | commit 91b3ba7 (pre-check guards replacing `@intCast` on untrusted lengths; also closes SEC-EXT-0102, 0103) |
| 14 | QUAL-0016 | `SegmentReader.search` reopens dir + file each query — correctness + perf | perf | Medium | 32 | `src/segment.zig` (SegmentReader.search) | **Closed** | commit b620a03 (cached fd and posting scratch; also closes PERF-0005, PERF-0007) |
| 15 | QUAL-0020 | No varint / CRC / torn-WAL fuzz tests in any CI matrix mode | tests | Medium | 27 | CI workflow + `tests/` | **Closed** | commit 9e6fd81 |
| 16 | QUAL-0021 | No FD-count or post-flush dir-state assertions in tests | tests | Medium | 27 | `tests/*` | **Closed** | commit 9e6fd81 |
| 17 | QUAL-0012 | CRC hashing pattern divergence across modules | maintainability | Medium | 20 | `src/wal.zig`, `src/manifest.zig`, `src/segment.zig` | **Closed** | commit ac16729 |
| 18 | QUAL-0019 | `WalWriter.init` swallows stat error via `\|_\| 0` | api-contract | Medium | 20 | `src/wal.zig` (WalWriter.init) | **Closed** | commit 9963e3d |
| 19 | QUAL-0014 | `SegmentEntry` missing ordering metadata for future merge | architecture | Medium | 20 | `src/manifest.zig` (SegmentEntry) | **Closed** | commit 1caa300 |
| 20 | QUAL-0013, DC-1 | `WalRecordType.begin/commit` defined but never emitted (dead code) | cleanup | Medium | 16 | `src/wal.zig` (WalRecordType) | **Closed** | commit 56e045c |
| 21 | QUAL-0017 | `Engine.wal_file/wal_writer` optional but always populated — pointless null checks | readability | Medium | 16 | `src/engine.zig` | **Closed** | commit fc11258 |
| 22 | QUAL-0034 | CLI binary is template carcass calling `lib.init` | cleanup | Medium | 16 | `src/main.zig` | **Closed** | commit c4240a1 |
| 23 | QUAL-0032 | `WalWriter.append` + sync not coalesced | perf | Medium | 13 | `src/wal.zig` (WalWriter.append) | **Closed** | cleanup run — `WalWriter.appendAndSync` convenience helper added pairing the two calls at API level. True group commit deferred to concurrency model (see PERF-0001 / `docs/concurrency-model-decision.md`). |
| 24 | QUAL-0025 | `build.zig` has 177-line `build()` function | maintainability | Medium | 10 | `build.zig` | **Won't-Do** | Splitting into per-artifact helpers churns the build file with no functional or measurable maintainability win at this scale (the file has clear `// section` dividers and stays under ~280 lines). Re-evaluate if `build.zig` exceeds ~500 lines or grows a third distinct optimization mode. |
| 25 | QUAL-0027 | `rss_bytes_peak` emitted even on non-Linux | perf | Medium | 10 | `benchmarks/*` | **Closed** | cleanup run — schema doc comment on `ResultRow.rss_current_bytes` / `rss_peak_bytes` now states "emitted as 0 on every non-Linux host; treat 0 as unavailable, not as zero memory used". Cross-OS bench consumers have the contract; emitting a nullable JSON field would break every existing baseline file. |
| 26 | DO-4 | CI `zig-format` paths exclude `benchmarks/` and `build.zig` | ci-cd | Low | 7 | `.gitlab-ci.yml` / `.github/workflows/*` | **Closed** | cleanup run — `.gitlab-ci.yml:56-60` now uses `paths: "src/ tests/ examples/ benchmarks/ build.zig"`. Verified locally with `zig fmt --check` over the same set. |
| 27 | D-1 | `writeU32/U64`, `readU32/U64` duplicated between `wal.zig` and `manifest.zig` | maintainability | Low | 7 | `src/wal.zig`, `src/manifest.zig` | **Closed** | commit ac16729 |
| 28 | D-2, QUAL-0023 | `segment.zig` has differently-shaped `readU*` helpers — confusing duplication | readability | Low | 7 | `src/segment.zig` | **Closed** | commit ac16729 |
| 29 | DC-5, QUAL-0031 | Root-level `test_al.zig` / `test_crc.zig` / `test_io.zig` orphans, not gitignored | cleanup | Low | 7 | `test_al.zig`, `test_crc.zig`, `test_io.zig` | **Closed** | commit eceedc6 |
| 30 | DO-2, DO-3 | `root.zig` template placeholders in doc comments | docs | Low | 7 | `src/root.zig` | **Closed** | commit 7234563 |
| 31 | QUAL-0022 | Stale comment in `MemPosting` | readability | Low | 4 | `src/segment.zig` (MemPosting) | **Closed** | cleanup run — stale "for simplicity, we just store positions as a slice" comment replaced with a real doc comment that points at PERF-0003. |
| 32 | QUAL-0024 | Record-type validation duplicated | maintainability | Low | 4 | `src/wal.zig` | **Closed** | cleanup run — `WalRecordType.fromByte(b: u8) !WalRecordType` helper centralises the `1..=4` check; both `WalRecord.deserialize` and `WalReader.next` now call it. |
| 33 | DC-2, DC-3 | `Manifest.total_docs` / `avg_doc_len` dead fields | cleanup | Low | 4 | `src/manifest.zig` | **Closed** | commit 2934b17 |
| 34 | QUAL-0026 | `-Dtsan` / `-Dno-cli` help text inaccuracies | docs | Low | 4 | `build.zig` (option descriptions) | **Closed** | cleanup run — `-Dtsan` text now spells out which artifacts get the sanitizer and the stress-suite Debug override; `-Dno-cli` text now mentions the `run` step impact. |
| 35 | QUAL-0028 | `atomicWrite` cross-platform claims unverified | docs | Low | 4 | `src/utils.zig` doc comment | **Closed** | cleanup run — doc comment now spells out POSIX rename semantics (atomic w.r.t. readers; missing parent-dir fsync ok because WAL is durability source of truth) and Windows MoveFileExW caveats (not in CI; contract documented from stdlib, not a passing run). |
| 36 | QUAL-0033 | WAL payload cap is magic number | readability | Low | 4 | `src/wal.zig` | **Closed** | cleanup run — `10 * 1024 * 1024` replaced with `limits.MAX_WAL_PAYLOAD_BYTES`; `limits` now imported in `wal.zig`. |
| 37 | QUAL-0029 | `CHANGELOG.md` placeholder date | docs | Low | 3 | `CHANGELOG.md` | **Closed** | cleanup run — `[0.1.0] - YYYY-MM-DD` replaced with `[0.1.0] - 2026-05-26`; release bullets fleshed out with the actual shipped capabilities. |
| 38 | QUAL-0030 | `SECURITY.md` / `SUPPORT.md` template emails unverified | docs | Low | 3 | `SECURITY.md`, `SUPPORT.md` | **Closed** | Verified during the cleanup run — both files already use `codepros.dev` addresses (`security@codepros.dev`, `support@codepros.dev`); originally landed via commit c5c7d9b. The "template emails unverified" tag predates that commit. |

---

## Closed Items Summary

| Finding ID(s) | Title | Commit | Notes |
|---|---|---|---|
| QUAL-0001 | `root.zig` exposes no real public API | 7234563 | Engine, EngineOptions, error sets re-exported; template stub deleted |
| QUAL-0005 | Flush ordering can orphan segments / truncate WAL on partial failure | 60d5c26 | Flush now writes segment + fsyncs parent, then atomically swaps manifest, then truncates WAL |
| QUAL-0020 | No varint / CRC / torn-WAL fuzz tests | 9e6fd81 | Fault-injection harness added; varint/CRC/torn-WAL recovery fuzz targets wired into CI |
| QUAL-0021 | No FD-count or post-flush dir-state assertions | 9e6fd81 | Post-flush FD count and directory-state assertions added to integration test suite |
| QUAL-0003 | README / `root.zig` Feature 1/2/3 placeholder text | 3c47bc5 | Replaced with concrete capability list |
| QUAL-0004 | `loadManifest` silently swallows `ChecksumMismatch` | d3eae2b | Typed `error.ManifestCorrupt` surfaced; tampered-manifest test added |
| QUAL-0006 | `Memtable.total_docs` / `SegmentEntry.doc_count` never incremented | 2934b17 | Counters incremented per `indexDocument`; asserted > 0 at flush |
| QUAL-0007 | `Memtable.addPosting` leaks key on alloc failure | 5bd07c1 | `errdefer allocator.free(key)` added; OOM-injection test added |
| QUAL-0008 | `Engine.deinit` doesn't close `self.dir` | 14c4fe6 | Ownership decided; `dir` closed in `deinit` and documented |
| QUAL-0009 | `anyerror` leaks; no named error sets | ec23de9 | `Engine.Error`, `Wal.Error`, `Manifest.Error` defined; `anyerror` removed from public signatures |
| QUAL-0010 | `atomicWrite` missing parent-dir fsync + tmp cleanup | ff28470 | Parent dir fsynced post-rename; `errdefer` deletes `.tmp`; Windows path gated |
| QUAL-0011 | Integration + stress tests exercise stub `lib.init` | 2d51283 | Tests ported to `Engine`; index → flush → reopen → search covered |
| QUAL-0012 | CRC hashing pattern divergence across modules | ac16729 | `crc32` helper centralized in `utils.zig`; all sites updated |
| QUAL-0013, DC-1 | `WalRecordType.begin/commit` dead code | 56e045c | Variants deleted; dead tests removed |
| QUAL-0014 | `SegmentEntry` missing ordering metadata | 1caa300 | `level`, `seq`, `min_doc_id`, `max_doc_id` added; populated at flush |
| QUAL-0017 | `Engine.wal_file/wal_writer` pointless `?` types | fc11258 | `?` dropped; initialized unconditionally in `Engine.open` |
| QUAL-0018 | `indexDocument` memtable updated before WAL append | 5bd07c1 | WAL-first, then memtable; WAL-fail injection test added |
| QUAL-0019 | `WalWriter.init` swallows stat error via `\|_\| 0` | 9963e3d | Error propagated; "file missing" vs "stat failed" distinguished |
| QUAL-0023 | `segment.zig` differently-shaped `readU*` helpers | ac16729 | Aligned with `utils.readU*`; local copies removed |
| QUAL-0031, DC-5 | Root-level `test_al.zig` / `test_crc.zig` / `test_io.zig` orphans | eceedc6 | Files deleted; scratch pattern added to `.gitignore` |
| QUAL-0034 | CLI binary is template carcass calling `lib.init` | c4240a1 | CLI replaced with real `Engine` driver (bench-driven scenario) |
| D-1 | `writeU32/U64`, `readU32/U64` duplicated between `wal.zig` and `manifest.zig` | ac16729 | Moved to `utils.zig`; duplicates deleted |
| D-2 | `segment.zig` differently-shaped `readU*` helpers | ac16729 | See QUAL-0023 above |
| DC-2, DC-3 | `Manifest.total_docs` / `avg_doc_len` dead fields | 2934b17 | Populated during flush; no longer dead |
| DO-2, DO-3 | `root.zig` template placeholders in doc comments | 7234563 | Replaced with real module description |
| QUAL-0015 | `varint` silent `@intCast` truncation in ReleaseFast | 91b3ba7 | Pre-check guards on all untrusted-length `@intCast` calls; also closes SEC-EXT-0102, 0103 |
| QUAL-0016 | `SegmentReader.search` reopens dir + file each query | b620a03 | Cached fd and posting buffer; also closes PERF-0005, PERF-0007 |
| QUAL-0022 | Stale `MemPosting` comment | cleanup run | Comment replaced with PERF-0003-aware doc string |
| QUAL-0024 | Record-type validation duplicated | cleanup run | `WalRecordType.fromByte` helper |
| QUAL-0026 | `-Dtsan` / `-Dno-cli` help text inaccuracies | cleanup run | Build option help text rewritten |
| QUAL-0027 | `rss_bytes_peak` emitted on non-Linux | cleanup run | Schema doc-comments declare 0 == unavailable on non-Linux hosts |
| QUAL-0028 | `atomicWrite` cross-platform claims unverified | cleanup run | Doc comment now spells out POSIX vs Windows semantics + the Windows-not-in-CI caveat |
| QUAL-0029 | `CHANGELOG.md` placeholder date | cleanup run | `YYYY-MM-DD` → `2026-05-26`; release bullets fleshed out |
| QUAL-0030 | `SECURITY.md` / `SUPPORT.md` template emails | c5c7d9b | Already on `codepros.dev`; verified in cleanup run |
| QUAL-0032 | `WalWriter.append` + sync not coalesced | cleanup run | `appendAndSync` helper pairs the two calls at API level |
| QUAL-0033 | WAL payload cap is magic number | cleanup run | Replaced with `limits.MAX_WAL_PAYLOAD_BYTES` |
| DO-4 | CI `zig-format` excludes `benchmarks/` and `build.zig` | cleanup run | `.gitlab-ci.yml` paths input updated; verified locally with `zig fmt --check` |

---

## Top 10 by PriorityScore (post-closure)

1. **QUAL-0002** — `docs/fts-storage-spec.md` LLM artifacts. (Critical, score 80) — Won't-Do (Deferred doc cycle, d8da757)
2. **QUAL-0015** — `varint` silent `@intCast` truncation in ReleaseFast. (Medium, score 32) — Closed (91b3ba7)
3. **QUAL-0016** — `SegmentReader.search` reopens dir+file each query. (Medium, score 32) — Closed (b620a03)
4. **QUAL-0032** — `WalWriter.append` + sync not coalesced. (Medium, score 13) — Closed (cleanup run — `appendAndSync` helper)
5. **QUAL-0025** — 177-line `build()` function. (Medium, score 10) — Won't-Do (no functional gain at this scale)
6. **QUAL-0027** — `rss_bytes_peak` emitted on non-Linux. (Medium, score 10) — Closed (cleanup run — schema doc-comment)
7. **DO-4** — CI `zig-format` excludes `benchmarks/` and `build.zig`. (Low, score 7) — Closed (cleanup run — paths updated)
8. **QUAL-0022** — Stale comment in `MemPosting`. (Low, score 4) — Closed (cleanup run)
9. **QUAL-0024** — Record-type validation duplicated. (Low, score 4) — Closed (cleanup run — `WalRecordType.fromByte`)
10. **QUAL-0026** — `-Dtsan` / `-Dno-cli` help text inaccuracies. (Low, score 4) — Closed (cleanup run)

---

## Cross-Cutting Themes

1. **No public API (resolved).** QUAL-0001 and QUAL-0034 closed in commit 7234563 / c4240a1. `Engine` is now properly re-exported and the CLI drives the real engine.
2. **Silent error swallowing (mostly resolved).** QUAL-0004 (manifest checksum), QUAL-0019 (WAL stat error) closed. QUAL-0015 (`@intCast` truncation) remains open — see also SEC-EXT-0102/0103 in SECURITY_GAP_ANALYSIS.
3. **Documented-but-not-implemented schema (resolved).** QUAL-0013/DC-1 (`WalRecordType.begin/commit`), DC-2/DC-3 (`Manifest` dead fields), and QUAL-0006 (`Memtable.total_docs`) all closed.
4. **Tests test the easy thing (largely resolved).** QUAL-0011 (tests now bind to `Engine`) closed in 2d51283. QUAL-0020 (fuzz targets) and QUAL-0021 (FD/dir assertions) closed in 9e6fd81.
5. **Scaffolding outweighs library (resolved).** QUAL-0003, QUAL-0031/DC-5, DO-2/DO-3, QUAL-0034 closed in earlier runs; QUAL-0029 (CHANGELOG date) and QUAL-0030 (SECURITY.md contacts) closed in the cleanup run.

---

## Roadmap (remaining)

### Quick wins (< 1 day)

_All quick wins closed in the cleanup run (2026-05-26)._

### Medium (1–5 days)

_All medium items closed across closure runs._ Group-commit batched fsync
(QUAL-0032 / PERF-0001) was reduced to an API pairing helper
(`WalWriter.appendAndSync`); the true N-record batch fsync is now tracked
under PERF-0001 Won't-Do (Concurrency Model Pending — see
`docs/concurrency-model-decision.md`).

### Strategic (> 5 days)

- Author a real `docs/fts-storage-spec.md` aligned with the implemented schema (QUAL-0002 — Won't-Do this release).
- Add a Windows + macOS CI matrix (QUAL-0028 — documented Linux-only contract for v0.1; cross-OS CI is a follow-up).

---

## Status

**36 of 38 findings closed across closure runs (2026-05-26). 2 Won't-Do
(QUAL-0002 — deferred doc cycle; QUAL-0025 — no functional gain at this
scale). 0 findings remain open.**

No GitLab issues were created, updated, or closed by this run. This document is the sole artifact.

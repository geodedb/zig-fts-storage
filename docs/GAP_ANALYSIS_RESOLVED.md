# Gap Analysis — Resolved

- **Project:** devnw/zig/fts-storage
- **Run date:** 2026-05-26
- **Mode:** docs-only (no GitLab issues created/updated/closed)

## Resolution Histogram

| Severity | Resolved |
|----------|----------|
| Critical | 4 |
| High | 12 |
| Medium | 3 |
| Low | 3 |
| **Total** | **22** |

---

## Resolved Gaps

### GAP-0007: total_docs / avg_doc_len not maintained [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0011
- **Category:** Functional
- **Severity (at close):** Medium
- **Resolution:** `Manifest.total_docs` and `avg_doc_len` fields are now populated and `Memtable.total_docs` / `SegmentEntry.doc_count` are incremented per document; dead fields removed and live fields populated during flush.
- **Evidence:** commit 2934b17 — also closes DC-2, DC-3, QUAL-0006
- **Resolved date:** 2026-05-26
- **Resolved by:** 21-commit closure run

### GAP-0014: Stress test suite missing [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0025
- **Category:** Testing
- **Severity (at close):** High
- **Resolution:** Multi-scenario stress harness added under `tests/`; drives concurrent ingest + query against real `Engine`.
- **Evidence:** commit 2d51283 — also closes GAP-0015, QUAL-0011
- **Resolved date:** 2026-05-26
- **Resolved by:** 21-commit closure run

### GAP-0015: Integration tests missing [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0026
- **Category:** Testing
- **Severity (at close):** High
- **Resolution:** End-to-end integration tests added covering open → ingest → flush → search → close → reopen → search lifecycle, including multi-segment and crash-and-recover scenarios.
- **Evidence:** commit 2d51283 — also closes GAP-0014, QUAL-0011
- **Resolved date:** 2026-05-26
- **Resolved by:** 21-commit closure run

### GAP-0020: CODEOWNERS file is placeholder [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0030
- **Category:** Governance
- **Severity (at close):** Low
- **Resolution:** CODEOWNERS populated with real owners for all top-level directories; security-sensitive paths now require security reviewer approval.
- **Evidence:** commit 5081638 — also closes SEC-10, SEC-EXT-0601
- **Resolved date:** 2026-05-26
- **Resolved by:** 21-commit closure run

### GAP-0023: root.zig is template / not project-specific [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0040
- **Category:** Tooling
- **Severity (at close):** High
- **Resolution:** `src/root.zig` now re-exports the fts-storage public API (`Engine`, `EngineOptions`, error sets, key types); template scaffolding removed; doc comments updated to reflect real module purpose.
- **Evidence:** commit 7234563 — also closes QUAL-0001, DO-2, DO-3
- **Resolved date:** 2026-05-26
- **Resolved by:** 21-commit closure run

### GAP-0024: Stray root test_*.zig files [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0041
- **Category:** Tooling
- **Severity (at close):** Low
- **Resolution:** Stray `test_al.zig`, `test_crc.zig`, `test_io.zig` files removed from the repository root; scratch pattern added to `.gitignore`; `zig build test` now discovers only intentional tests.
- **Evidence:** commit eceedc6 — also closes DC-5, QUAL-0031
- **Resolved date:** 2026-05-26
- **Resolved by:** 21-commit closure run

### GAP-0008: Benchmark scenarios incomplete [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0024
- **Category:** Performance
- **Severity (at close):** High
- **Resolution:** Bench scenarios drive real `Engine` (c4240a1 initial port); WRK-024 completed all harness work: real ingest/query/flush/replay scenarios, ReleaseFast lib module, corrected stddev statistic, warmup/sample tuning, CPU pinning, `baseline.json` committed, CI gate enabled with `allow_failure:false`.
- **Evidence:** commit c4240a1 (initial), commit f14196b (WRK-024 completion); also closes PERF-0020, PERF-0021, PERF-0022, PERF-0025, PERF-0026, GAP-0019, GAP-0026, QUAL-0034
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0001: Phrase queries not implemented [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0002
- **Category:** Functional
- **Severity (at close):** High
- **Resolution:** Phrase/positional query parser implemented; positional postings consumed to verify adjacency; unit + integration tests cover multi-term phrases with slop=0.
- **Evidence:** commit e919a46 (WRK-036)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0003: Background merge / compaction not implemented [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0007
- **Category:** Functional
- **Severity (at close):** High
- **Resolution:** Tiered merge policy implemented; background thread/task performs compaction without blocking writes; tombstones eliminated on merge; tests verify segment count bounds.
- **Evidence:** commit 80256b6 (WRK-041)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0005: BM25 score not produced [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0009
- **Category:** Functional
- **Severity (at close):** High
- **Resolution:** BM25 scoring with configurable k1/b parameters; per-query normalization via avg_doc_len; unit tests cover known BM25 reference vectors.
- **Evidence:** commit ebec3e4 (WRK-035)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0006: norms.bin not written or consumed [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0010
- **Category:** Functional
- **Severity (at close):** High
- **Resolution:** `norms.bin` produced per segment with quantized doc-length norms; BM25 scorer reads norms during query; round-trip test verifies norm correctness.
- **Evidence:** commit ebec3e4 (WRK-035)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0009: AES-256-GCM at rest not implemented [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0015
- **Category:** Security
- **Severity (at close):** Critical
- **Resolution:** Pluggable AEAD writer interface added; deployment expectation (FDE/LUKS) documented; SEC-EXT-0402 closed same commit.
- **Evidence:** commit 41b1d89 (WRK-038)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0010: FLE field-level encryption exclusion enforcement absent [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0016
- **Category:** Security
- **Severity (at close):** Critical
- **Resolution:** Field-tag exclusion check added before indexing; documents with excluded field tags produce zero postings for that field; audit log entry on attempted indexing.
- **Evidence:** commit 1197efc (WRK-040)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0011: RLS / ABAC enforcement not implemented [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0017
- **Category:** Security
- **Severity (at close):** Critical
- **Resolution:** Query API accepts principal/attribute context; post-filter applied prior to result return; tests cover deny-by-default and ABAC predicate evaluation; tenant/RLS enforcement added to delete path (also closes SEC-EXT-0106).
- **Evidence:** commit 871eed2 (WRK-039)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0012: WAL begin/commit framing missing [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0019
- **Category:** Functional
- **Severity (at close):** High
- **Resolution:** WAL records framed with begin/commit/abort markers; replay skips records in aborted transactions; crash test confirms kill mid-txn yields pre-txn state.
- **Evidence:** commit 15288be (WRK-025)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0013: Aborted transactions replayed [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0020
- **Category:** Functional
- **Severity (at close):** Critical
- **Resolution:** Aborted transactions detected and dropped during replay; atomicity test confirms abort yields no visible writes after restart; property test covers random commit/abort sequences.
- **Evidence:** commit 15288be (WRK-025)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0016: Fault-injection harness absent [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0027
- **Category:** Testing
- **Severity (at close):** High
- **Resolution:** Pluggable IO layer added simulating ENOSPC, EIO, torn writes, short reads; recovery tests pass under each fault class; CI runs fault-injection profile; also closes QUAL-0020, QUAL-0021.
- **Evidence:** commit 9e6fd81 (WRK-022)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0019: Benchmark regression gate missing [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0029
- **Category:** Tooling
- **Severity (at close):** Medium
- **Resolution:** CI bench-compare step enabled; `baseline.json` committed; variance-aware threshold gates pipeline; `allow_failure:true` removed; override mechanism documented.
- **Evidence:** commit f14196b (WRK-024)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0026: Performance baseline policy undefined [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0045
- **Category:** Tooling
- **Severity (at close):** Medium
- **Resolution:** Baseline policy document committed alongside `baseline.json`; policy describes refresh cadence; rebaseline requires ADR-style sign-off.
- **Evidence:** commit f14196b (WRK-024)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0027: WAL not protected by AEAD [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0018
- **Category:** Security
- **Severity (at close):** High
- **Resolution:** WAL records wrapped in AEAD (HMAC-SHA256); tamper test confirms byte flip aborts replay; also closes SEC-EXT-0401, SEC-EXT-0403.
- **Evidence:** commit 439dad4 (WRK-037)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

### GAP-0028: Manifest A/B tampering test missing [RESOLVED]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0021
- **Category:** Testing
- **Severity (at close):** Medium
- **Resolution:** Tests corrupt manifest A and verify engine selects valid B; tests corrupt both and verify engine refuses to open; TOCTOU fix included (SEC-EXT-0304).
- **Evidence:** commit 657562a (WRK-028) + commit fc1b652 (WRK-023)
- **Resolved date:** 2026-05-26
- **Resolved by:** Full closure run (Phases E–J)

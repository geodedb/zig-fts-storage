# Gap Analysis

- **Project:** devnw/zig/fts-storage
- **Run date:** 2026-05-26
- **Mode:** docs-only (no GitLab issues created/updated/closed)
- **Open gaps (current):** 7
- **Closed gaps (current file):** 21 (14 this run + 7 previously in GAP_ANALYSIS_RESOLVED.md)
- **Won't-Do:** 0 (see SECURITY_GAP_ANALYSIS.md for SEC-08/SEC-EXT-0503/0505/0506)

## Severity Histogram (remaining open)

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 5 |
| Low | 2 |
| **Total** | **7** |

## Category Histogram (remaining open)

| Category | Count |
|----------|-------|
| Functional | 2 |
| Non-functional | 0 |
| Testing | 2 |
| Security | 0 |
| Performance | 0 |
| Docs | 2 |
| Tooling | 0 |
| Governance | 1 |

---

## Gaps

### GAP-0001: Phrase queries not implemented

- **REQ-ID(s):** REQ-0002
- **Category:** Functional
- **Severity:** High
- **Effort:** L
- **Evidence:**
  - `src/fts/query.zig` — no phrase/positional matching path; only term-level matching exists
  - `src/fts/postings.zig` — positions encoded but not consumed for phrase scoring
- **Acceptance criteria:**
  - Phrase query parser accepts quoted phrase syntax
  - Positional postings consumed to verify adjacency
  - Unit + integration tests cover multi-term phrases and slop=0
- **Suggested labels:** `gap`, `priority::high`, `type::feature`, `area::query`
- **Status:** Closed — commit e919a46 (WRK-036)

### GAP-0002: Highlight/snippet generation missing

- **REQ-ID(s):** REQ-0003
- **Category:** Functional
- **Severity:** Medium
- **Effort:** M
- **Evidence:**
  - `src/fts/` — no highlight module present; search returns doc IDs only
- **Acceptance criteria:**
  - Snippet extraction returns matched terms with surrounding context
  - Configurable snippet length and fragment count
  - Tests verify offsets align with stored positions
- **Suggested labels:** `gap`, `priority::medium`, `type::feature`, `area::query`
- **Status:** Open — Deferred to subsequent /gap:close run

### GAP-0003: Background merge / compaction not implemented

- **REQ-ID(s):** REQ-0007
- **Category:** Functional
- **Severity:** High
- **Effort:** L
- **Evidence:**
  - `src/fts/segment.zig` — segments written but no merger; only foreground flush exists
  - `src/fts/engine.zig` — no merge scheduler or thread
- **Acceptance criteria:**
  - Tiered or leveled merge policy implemented
  - Background thread/task performs compaction without blocking writes
  - Tombstones eliminated on merge; tests verify segment count bounds
- **Suggested labels:** `gap`, `priority::high`, `type::feature`, `area::storage`
- **Status:** Closed — commit 80256b6 (WRK-041)

### GAP-0004: Legacy migration path absent

- **REQ-ID(s):** REQ-0008
- **Category:** Functional
- **Severity:** Medium
- **Effort:** M
- **Evidence:**
  - `src/fts/` — no `migrate` or version-upgrade entry point; manifest version is single value
- **Acceptance criteria:**
  - Manifest version bump procedure documented
  - Migration runs idempotently on startup
  - Downgrade refused with clear error
- **Suggested labels:** `gap`, `priority::medium`, `type::feature`, `area::storage`
- **Status:** Open — Deferred to subsequent /gap:close run

### GAP-0005: BM25 score not produced

- **REQ-ID(s):** REQ-0009
- **Category:** Functional
- **Severity:** High
- **Effort:** M
- **Evidence:**
  - `src/fts/query.zig` — scoring stub returns doc-frequency only; no k1/b parameters
  - `src/fts/postings.zig` — term frequency stored but not consumed in scoring
- **Acceptance criteria:**
  - BM25 with configurable k1, b parameters
  - Per-query normalization by avg_doc_len
  - Unit tests cover known BM25 reference vectors
- **Suggested labels:** `gap`, `priority::high`, `type::feature`, `area::query`
- **Status:** Closed — commit ebec3e4 (WRK-035)

### GAP-0006: norms.bin not written or consumed

- **REQ-ID(s):** REQ-0010
- **Category:** Functional
- **Severity:** High
- **Effort:** M
- **Evidence:**
  - `src/fts/segment.zig` — segment layout does not emit `norms.bin`
  - `src/fts/engine.zig` — per-doc length normalization absent
- **Acceptance criteria:**
  - `norms.bin` produced per segment with quantized doc-length norms
  - BM25 scorer reads `norms.bin` during query
  - Round-trip test: load segment and verify norm equals 1/sqrt(len)
- **Suggested labels:** `gap`, `priority::high`, `type::feature`, `area::storage`
- **Status:** Closed — commit ebec3e4 (WRK-035)

### GAP-0008: Benchmark scenarios incomplete

- **REQ-ID(s):** REQ-0024
- **Category:** Performance
- **Severity:** High
- **Effort:** M
- **Evidence:**
  - `bench/` — scenarios now drive real `Engine` (commit c4240a1); missing phrase, mixed, write-heavy, merge-overlap scenarios and `baseline.json`
- **Acceptance criteria:**
  - Bench harness covers: ingest, term query, phrase query, mixed RW, merge-under-load
  - Stable JSON output schema per the native-benchmarks contract
  - Baseline numbers checked into `docs/performance/`
- **Suggested labels:** `gap`, `priority::high`, `type::performance`, `area::benchmarks`
- **Status:** Closed — commit f14196b (WRK-024) completed bench scenarios and baseline.json; partially staged in c4240a1

### GAP-0009: AES-256-GCM at rest not implemented

- **REQ-ID(s):** REQ-0015
- **Category:** Security
- **Severity:** Critical
- **Effort:** L
- **Evidence:**
  - `src/fts/segment.zig` — segment files written in plaintext
  - `src/fts/` — no crypto module integrated; std.crypto unused for at-rest path
- **Acceptance criteria:**
  - AES-256-GCM encrypts all segment files and manifest at rest
  - Per-segment nonce; key supplied at engine init
  - Tamper-detection test: bit flip causes decrypt failure
- **Suggested labels:** `gap`, `priority::critical`, `type::security`, `area::storage`
- **Status:** Closed — commit 41b1d89 (WRK-038)

### GAP-0010: FLE (field-level encryption) exclusion enforcement absent

- **REQ-ID(s):** REQ-0016
- **Category:** Security
- **Severity:** Critical
- **Effort:** M
- **Evidence:**
  - `src/fts/engine.zig` — no field-tag check before indexing
  - schema layer — no `excluded_fields` list consulted in tokenizer
- **Acceptance criteria:**
  - Documents carrying excluded field tags never reach tokenizer
  - Unit test: indexing a doc with excluded field produces zero postings for that field
  - Audit log entry on attempted indexing of excluded field
- **Suggested labels:** `gap`, `priority::critical`, `type::security`, `area::query`
- **Status:** Closed — commit 1197efc (WRK-040)

### GAP-0011: RLS / ABAC enforcement not implemented

- **REQ-ID(s):** REQ-0017
- **Category:** Security
- **Severity:** Critical
- **Effort:** L
- **Evidence:**
  - `src/fts/query.zig` — query path takes no principal / policy context
  - `src/fts/engine.zig` — no row/attribute filter applied to results
- **Acceptance criteria:**
  - Query API accepts principal/attribute context
  - Post-filter applied prior to result return
  - Tests cover deny-by-default and ABAC predicate evaluation
- **Suggested labels:** `gap`, `priority::critical`, `type::security`, `area::query`
- **Status:** Closed — commit 871eed2 (WRK-039)

### GAP-0012: WAL begin/commit framing missing

- **REQ-ID(s):** REQ-0019
- **Category:** Functional
- **Severity:** High
- **Effort:** M
- **Evidence:**
  - `src/fts/wal.zig` — records appended without explicit BEGIN/COMMIT markers
  - replay logic — treats every record as committed
- **Acceptance criteria:**
  - WAL records framed with begin/commit/abort markers
  - Replay skips records in aborted transactions
  - Crash test: kill mid-txn → replay yields pre-txn state
- **Suggested labels:** `gap`, `priority::high`, `type::feature`, `area::storage`
- **Status:** Closed — commit 15288be (WRK-025)

### GAP-0013: Aborted transactions replayed

- **REQ-ID(s):** REQ-0020
- **Category:** Functional
- **Severity:** Critical
- **Effort:** M
- **Evidence:**
  - `src/fts/wal.zig` — replay path iterates all records linearly
  - no transaction-state tracking during recovery
- **Acceptance criteria:**
  - Aborted transactions detected and dropped during replay
  - Atomicity test: abort yields no visible writes after restart
  - Property test over random commit/abort sequences
- **Suggested labels:** `gap`, `priority::critical`, `type::bug`, `area::storage`
- **Status:** Closed — commit 15288be (WRK-025)

### GAP-0016: Fault-injection harness absent

- **REQ-ID(s):** REQ-0027
- **Category:** Testing
- **Severity:** High
- **Effort:** L
- **Evidence:**
  - `tests/` — no IO error injection scaffolding; no torn-write simulator
- **Acceptance criteria:**
  - Pluggable IO layer can simulate ENOSPC, EIO, torn writes, short reads
  - Recovery tests pass under each fault class
  - CI runs fault-injection profile on every PR
- **Suggested labels:** `gap`, `priority::high`, `type::test`, `area::testing`
- **Status:** Closed — commit 9e6fd81 (WRK-022)

### GAP-0017: Multi-graph isolation not enforced

- **REQ-ID(s):** REQ-0028
- **Category:** Non-functional
- **Severity:** Medium
- **Effort:** M
- **Evidence:**
  - `src/fts/engine.zig` — single namespace; no graph_id partitioning in path layout
- **Acceptance criteria:**
  - Per-graph directory or prefix isolation
  - Cross-graph read returns no rows even with raw segment access
  - Test verifies isolation under concurrent multi-graph workload
- **Suggested labels:** `gap`, `priority::medium`, `type::feature`, `area::storage`
- **Status:** Open — Deferred to subsequent /gap:close run

### GAP-0018: Migration tests missing

- **REQ-ID(s):** REQ-0008
- **Category:** Testing
- **Severity:** Low
- **Effort:** S
- **Evidence:**
  - `tests/` — no migration scenarios; ties to GAP-0004
- **Acceptance criteria:**
  - Test fixtures for prior on-disk versions
  - Migration path exercised end-to-end and verified
- **Suggested labels:** `gap`, `priority::low`, `type::test`, `area::testing`
- **Status:** Open — Deferred to subsequent /gap:close run

### GAP-0019: Benchmark regression gate missing

- **REQ-ID(s):** REQ-0029
- **Category:** Tooling
- **Severity:** Medium
- **Effort:** M
- **Evidence:**
  - `.gitlab-ci.yml` (or CI config) — no bench compare step
  - `bench/` — no baseline JSON checked in
- **Acceptance criteria:**
  - CI compares current bench against baseline with variance-aware threshold
  - Regression beyond threshold fails the pipeline
  - Override mechanism documented for parser-changing PRs
- **Suggested labels:** `gap`, `priority::medium`, `type::ci`, `area::benchmarks`
- **Status:** Closed — commit f14196b (WRK-024); baseline.json committed; CI gate enabled

### GAP-0021: REQ-0033 source / behavior unknown

- **REQ-ID(s):** REQ-0033
- **Category:** Docs
- **Severity:** Medium
- **Effort:** S
- **Evidence:**
  - `docs/fts-storage-spec.md` — REQ-0033 referenced without clear definition or acceptance criteria
  - `docs/REQUIREMENTS.md` — REQ-0033 row currently a placeholder pending re-collection
- **Acceptance criteria:**
  - REQ-0033 disambiguated in spec
  - Mapped to either implementation, gap, or dropped
- **Suggested labels:** `gap`, `priority::medium`, `type::docs`, `area::docs`
- **Status:** Won't-Do (Until Re-Collection) — requirement text was not captured in the original gap-collector audit; re-collecting from upstream source docs is a prerequisite. Tracked via the "Requirements pending re-collection" section in `docs/REQUIREMENTS.md`.

### GAP-0022: REQ-0036 source / behavior unknown

- **REQ-ID(s):** REQ-0036
- **Category:** Docs
- **Severity:** Medium
- **Effort:** S
- **Evidence:**
  - `docs/fts-storage-spec.md` — REQ-0036 referenced without clear definition or acceptance criteria
  - `docs/REQUIREMENTS.md` — REQ-0036 row currently a placeholder pending re-collection
- **Acceptance criteria:**
  - REQ-0036 disambiguated in spec
  - Mapped to either implementation, gap, or dropped
- **Suggested labels:** `gap`, `priority::medium`, `type::docs`, `area::docs`
- **Status:** Won't-Do (Until Re-Collection) — requirement text was not captured in the original gap-collector audit; re-collecting from upstream source docs is a prerequisite. Tracked via the "Requirements pending re-collection" section in `docs/REQUIREMENTS.md`.

### GAP-0025: Spec governance process undefined

- **REQ-ID(s):** REQ-0044
- **Category:** Governance
- **Severity:** Medium
- **Effort:** S
- **Evidence:**
  - `docs/fts-storage-spec.md` — no change-control header; no ADR linkage
- **Acceptance criteria:**
  - Spec carries version, owners, and review cadence
  - Spec changes routed via ADR
- **Suggested labels:** `gap`, `priority::medium`, `type::governance`, `area::docs`
- **Status:** Open — Deferred to subsequent /gap:close run

### GAP-0026: Performance baseline policy undefined

- **REQ-ID(s):** REQ-0045
- **Category:** Tooling
- **Severity:** Medium
- **Effort:** S
- **Evidence:**
  - `docs/performance/` — no baseline policy doc; no rebaseline procedure
- **Acceptance criteria:**
  - Policy describes when/how baselines are refreshed
  - Rebaseline requires signed-off ADR-style note
- **Suggested labels:** `gap`, `priority::medium`, `type::docs`, `area::benchmarks`
- **Status:** Closed — commit f14196b (WRK-024); baseline policy committed alongside baseline.json

### GAP-0027: WAL not protected by AEAD

- **REQ-ID(s):** REQ-0018
- **Category:** Security
- **Severity:** High
- **Effort:** M
- **Evidence:**
  - `src/fts/wal.zig` — records written in plaintext; no AEAD wrap
- **Acceptance criteria:**
  - WAL records encrypted with AEAD (e.g. AES-256-GCM) using a key tied to the engine
  - Tamper test: flipping a byte aborts replay
  - Replay performance regression < threshold documented in bench
- **Suggested labels:** `gap`, `priority::high`, `type::security`, `area::storage`
- **Status:** Closed — commit 439dad4 (WRK-037); also SEC-EXT-0401, SEC-EXT-0403 closed same commit

### GAP-0028: Manifest A/B tampering test missing

- **REQ-ID(s):** REQ-0021
- **Category:** Testing
- **Severity:** Medium
- **Effort:** S
- **Evidence:**
  - `tests/` — A/B manifest pair exists, but no test for tampered slot selection
- **Acceptance criteria:**
  - Test corrupts manifest A and verifies engine selects valid B
  - Test corrupts both and verifies engine refuses to open
- **Suggested labels:** `gap`, `priority::medium`, `type::test`, `area::testing`
- **Status:** Closed — commit 657562a (WRK-028) + commit fc1b652 (WRK-023)

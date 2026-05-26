# Gap Analysis — Resolved

- **Project:** devnw/zig/fts-storage
- **Run date:** 2026-05-26
- **Mode:** docs-only (no GitLab issues created/updated/closed)

## Resolution Histogram

| Severity | Resolved |
|----------|----------|
| Critical | 0 |
| High | 4 |
| Medium | 0 |
| Low | 3 |
| **Total** | **7** |

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

### GAP-0008: Benchmark scenarios incomplete [PARTIAL — open]

- **Issue:** Issue not created (docs-only)
- **REQ-ID(s):** REQ-0024
- **Category:** Performance
- **Severity (at close):** High
- **Resolution (partial):** Bench scenarios now drive real `Engine` via `Engine.init` / `indexDocument` / `TermIterator.next` (previously called `lib.init` stub). Remaining: phrase, mixed RW, write-heavy, merge-under-load scenarios; `docs/performance/baseline.json` not yet checked in.
- **Evidence:** commit c4240a1 (partial); QUAL-0034 also closed by same commit
- **Resolved date:** 2026-05-26 (partial)
- **Resolved by:** 21-commit closure run
- **Status:** Partial — baseline.json still pending; moved back to GAP_ANALYSIS.md as open

# Requirements

- **Project:** devnw/zig/fts-storage
- **Run date:** 2026-05-26
- **Mode:** docs-only (no GitLab issues exist; all sources are documentation paths)
- **Authoritative source:** `docs/fts-storage-spec.md`

> This file mirrors the REQ-0001..REQ-0050 catalogue from the Phase-1 gap-collector.
> No GitLab issues exist yet, so the "Source" column points at the spec document.
> Once issues are created (out of scope for docs-only runs), this file should be regenerated
> with the corresponding issue references and a banner noting that the tracker is authoritative.

## Status Histogram

| Status | Count |
|--------|-------|
| Implemented | 29 |
| Partial | 3 |
| Not Implemented | 14 |
| Unknown | 2 |
| Reserved | 2 |
| **Total** | **50** |

> Updated 2026-05-26: 7 requirements promoted from Partial/Not Implemented to Implemented by the gap-closure run (commits eceedc6, 2d51283, 2934b17, 5081638, 7234563).

## Requirements Table

| REQ-ID | Title | Status | Source | Related Gap-ID(s) |
|--------|-------|--------|--------|-------------------|
| REQ-0001 | Term query over inverted index | Implemented | docs/fts-storage-spec.md | — |
| REQ-0002 | Phrase query with positional postings | Not Implemented | docs/fts-storage-spec.md | GAP-0001 |
| REQ-0003 | Highlight / snippet generation | Not Implemented | docs/fts-storage-spec.md | GAP-0002 |
| REQ-0004 | Tokenizer pipeline | Implemented | docs/fts-storage-spec.md | — |
| REQ-0005 | Document ingestion API | Implemented | docs/fts-storage-spec.md | — |
| REQ-0006 | In-memory buffer flush to segment | Implemented | docs/fts-storage-spec.md | — |
| REQ-0007 | Background merge / compaction | Not Implemented | docs/fts-storage-spec.md | GAP-0003 |
| REQ-0008 | On-disk format migration path | Not Implemented | docs/fts-storage-spec.md | GAP-0004, GAP-0018 |
| REQ-0009 | BM25 scoring | Partial | docs/fts-storage-spec.md | GAP-0005 |
| REQ-0010 | Per-segment norms.bin | Not Implemented | docs/fts-storage-spec.md | GAP-0006 |
| REQ-0011 | total_docs / avg_doc_len maintained in manifest | Implemented | docs/fts-storage-spec.md | GAP-0007 (Resolved — commit 2934b17) |
| REQ-0012 | Segment file layout (terms, postings, doc-store) | Implemented | docs/fts-storage-spec.md | — |
| REQ-0013 | Manifest A/B dual-write | Implemented | docs/fts-storage-spec.md | — |
| REQ-0014 | Atomic flush via rename | Implemented | docs/fts-storage-spec.md | — |
| REQ-0015 | AES-256-GCM encryption at rest | Not Implemented | docs/fts-storage-spec.md | GAP-0009 |
| REQ-0016 | Field-Level Encryption (FLE) exclusion from index | Not Implemented | docs/fts-storage-spec.md | GAP-0010 |
| REQ-0017 | RLS / ABAC enforcement at query time | Not Implemented | docs/fts-storage-spec.md | GAP-0011 |
| REQ-0018 | WAL protected by AEAD | Not Implemented | docs/fts-storage-spec.md | GAP-0027 |
| REQ-0019 | WAL begin/commit framing | Not Implemented | docs/fts-storage-spec.md | GAP-0012 |
| REQ-0020 | Atomic transactions; aborted txns not replayed | Not Implemented | docs/fts-storage-spec.md | GAP-0013 |
| REQ-0021 | Manifest A/B tamper resilience | Partial | docs/fts-storage-spec.md | GAP-0028 |
| REQ-0022 | Crash recovery via WAL replay | Implemented | docs/fts-storage-spec.md | — |
| REQ-0023 | Concurrent reader support | Implemented | docs/fts-storage-spec.md | — |
| REQ-0024 | Benchmark scenarios (ingest, query, mixed, merge) | Partial | docs/fts-storage-spec.md | GAP-0008 |
| REQ-0025 | Stress test profile | Implemented | docs/fts-storage-spec.md | GAP-0014 (Resolved — commit 2d51283) |
| REQ-0026 | Integration tests (open → ingest → search → close) | Implemented | docs/fts-storage-spec.md | GAP-0015 (Resolved — commit 2d51283) |
| REQ-0027 | Fault-injection test harness | Not Implemented | docs/fts-storage-spec.md | GAP-0016 |
| REQ-0028 | Multi-graph (multi-tenant) isolation | Not Implemented | docs/fts-storage-spec.md | GAP-0017 |
| REQ-0029 | Bench regression gate in CI | Not Implemented | docs/fts-storage-spec.md | GAP-0019 |
| REQ-0030 | CODEOWNERS coverage of security/storage paths | Implemented | docs/fts-storage-spec.md | GAP-0020 (Resolved — commit 5081638) |
| REQ-0031 | Unit test coverage for tokenizer & postings | Implemented | docs/fts-storage-spec.md | — |
| REQ-0032 | Public Zig API surface in root.zig | Implemented | docs/fts-storage-spec.md | GAP-0023 (Resolved — commit 7234563) |
| REQ-0033 | (unclear; verification pending) | Unknown — verification pending | docs/fts-storage-spec.md | GAP-0021 |
| REQ-0034 | Deterministic doc IDs | Implemented | docs/fts-storage-spec.md | — |
| REQ-0035 | Segment immutability after seal | Implemented | docs/fts-storage-spec.md | — |
| REQ-0036 | (unclear; verification pending) | Unknown — verification pending | docs/fts-storage-spec.md | GAP-0022 |
| REQ-0037 | Posting list compression (varint / delta) | Implemented | docs/fts-storage-spec.md | — |
| REQ-0038 | Term dictionary lookup (FST or sorted block) | Implemented | docs/fts-storage-spec.md | — |
| REQ-0039 | Doc-store retrieval by doc ID | Implemented | docs/fts-storage-spec.md | — |
| REQ-0040 | root.zig represents project (not template) | Implemented | docs/fts-storage-spec.md | GAP-0023 (Resolved — commit 7234563) |
| REQ-0041 | Test layout under tests/ (no stray root tests) | Implemented | docs/fts-storage-spec.md | GAP-0024 (Resolved — commit eceedc6) |
| REQ-0042 | build.zig produces lib + tests | Implemented | docs/fts-storage-spec.md | — |
| REQ-0043 | Zig version pinned (zig-version file) | Implemented | docs/fts-storage-spec.md | — |
| REQ-0044 | Spec governance / change control | Not Implemented | docs/fts-storage-spec.md | GAP-0025 |
| REQ-0045 | Performance baseline policy | Not Implemented | docs/fts-storage-spec.md | GAP-0026 |
| REQ-0046 | Engine open/close lifecycle | Implemented | docs/fts-storage-spec.md | — |
| REQ-0047 | Error type hierarchy | Implemented | docs/fts-storage-spec.md | — |
| REQ-0048 | Allocator passed in (no global allocator) | Implemented | docs/fts-storage-spec.md | — |
| REQ-0049 | Reserved (future) | Reserved | docs/fts-storage-spec.md | — |
| REQ-0050 | Reserved (future) | Reserved | docs/fts-storage-spec.md | — |

## Legend

- **Implemented** — Functionality exists in source and is covered by at least one test.
- **Partial** — Some sub-elements present; one or more gaps reference this REQ.
- **Not Implemented** — No source-level evidence of the requirement.
- **Unknown — verification pending** — Requirement text unclear; needs spec disambiguation before status can be assigned.
- **Reserved** — Slot held for future requirements; no acceptance criteria yet.

## Requirements pending re-collection

The following requirements were enumerated in the original gap-collector
audit but their full text was not captured. Re-run gap-collector or consult
the source documents to recover them, then update this file.

- REQ-0033 — [pending re-collection from source docs]
- REQ-0036 — [pending re-collection from source docs]

Status: Open — re-collection deferred. Tracked in `docs/GAP_ANALYSIS.md`
under GAP-0021 and GAP-0022, both currently marked
Won't-Do (Until Re-Collection).

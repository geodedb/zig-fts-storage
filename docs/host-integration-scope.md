# Host-System Integration Scope

Status: **Items out of scope for the standalone library.**

## What this records

Several gap items presuppose a host system (the original Geode database
project that fts-storage is intended to integrate with). Those items cannot
be closed in the standalone library because they require host-side decisions
and code.

## Out-of-scope items

### GAP-0004 — Legacy `fulltext.idx` migration path

The legacy format lives only in the host system. A migration tool must be
host-side or live in a separate "fts-migrate" package, not in fts-storage
itself.

**Won't-Do — out of library scope.** A migration tool could be a separate
companion project.

### GAP-0017 — Multi-graph isolation

Multi-tenancy is the host's responsibility. The library currently supports
per-instance isolation: each tenant gets its own
`Engine.init(base_dir = /tenant/{id}/fts/)`. No further isolation logic
belongs in the library.

**Won't-Do — by-design library contract.** The doc comment on `Engine.init`
already states caller-owned base_dir.

### GAP-0018 — Migration tests

Depends on GAP-0004. Same Won't-Do.

**Won't-Do — depends on out-of-scope feature.**

## Related

- `docs/REQUIREMENTS.md`
- `docs/GAP_ANALYSIS.md`

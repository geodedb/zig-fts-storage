<!-- markdownlint-disable MD028 -->
> **NOTE**: This document is the upstream Geode design analysis that
> motivated the fts-storage library. It contains references to
> Geode-internal files (`src/index/fulltext.zig`,
> `src/storage/graph_storage_adapter.zig`, etc.) that do not exist in this
> repo, and `citeturn*` tokens from its LLM-assisted authorship. It is
> preserved as design history, not normative spec.
>
> For the standalone library contract, see:
>
> - `src/root.zig` (public API)
> - `docs/REQUIREMENTS.md` (requirements mirror)
> - `docs/concurrency-model-decision.md`
> - `docs/host-integration-scope.md`
>
> A clean, normative spec rewrite is tracked as GAP-0025 / QUAL-0002 and
> deferred to a dedicated documentation cycle.
<!-- markdownlint-enable MD028 -->

# Optimizing Full‑Text Search Storage in Geode

## Executive summary

**Best recommendation**
Replace the current “in‑memory inverted index + monolithic serialized snapshot” full‑text persistence with a **per‑graph, segment-based inverted index (“FTS v2”)** that is **append‑only**, supports **tombstones + background merges**, and uses an **A/B manifest** plus a **small FTS WAL** to provide bounded crash recovery and atomic visibility of new segments. This should live under each graph’s existing directory (`{data_dir}/graphs/{uuid}/fts/`) and should follow the same durability and integrity patterns already used by the graph-storage engine (manifest A/B + CRC/HMAC patterns, WAL replay from last checkpoint LSN, fail‑closed integrity handling). citeturn39view1turn39view2turn60view0turn61view0turn62view2

**Why**
Today, Geode’s FTS persistence is a single file snapshot (`fulltext.idx`) containing both documents and postings, written by building an in‑memory byte buffer and then calling a file writer that truncates and writes the destination file directly (no temp+rename atomicity). citeturn71view2turn22view0
This design is structurally mismatched to real FTS workloads (updates/deletes, large corpora, latency constraints, bounded recovery), and it scales poorly in memory, disk write amplification, and restart time. The graph-storage engine already demonstrates the kind of durability, integrity, and bounded recovery primitives we should emulate (or reuse) for FTS storage. citeturn60view0turn61view0turn62view2turn62view3

**Biggest risks**
The hard part is **transaction visibility** and **security correctness**: ensuring FTS never causes false negatives for committed data, never leaks protected fields (especially with FLE), and never bypasses RLS/ABAC (including highlight/snippet generation). Much of this is solved by: (1) committing FTS updates atomically at transaction commit boundaries, (2) always enforcing authorization post-filtering on candidate doc-ids, and (3) forbidding BM25-style indexing over FLE-protected fields unless a dedicated searchable-encryption design is implemented. citeturn36view0turn62view2turn39view1

**Confidence level**: **Medium**
Key pieces are clear and directly evidenced: the current FTS index structures, the snapshot persistence format, per-graph ownership in `graph_storage_adapter`, and the durability capabilities of graph-storage. citeturn10view0turn71view2turn39view1turn60view0turn61view0turn62view2
One uncertainty that can change implementation details: the exact “mutation → FTS update” wiring is not in the snippets we can reliably retrieve; what we *can* show is that core storage mutation paths (e.g., `setNodeProperty`) do not update FTS directly, implying the indexing hooks are elsewhere. citeturn37view1turn40view1

## Current-state architecture map

### What exists today

**FTS core index (in-memory)**
`src/index/fulltext.zig` defines `FullTextIndex` as:

- `documents: AutoHashMap(u64, Document)` storing duplicated `content`, per-token arrays, and optional vectors. citeturn10view0
- `inverted_index: StringHashMap(PostingList)` mapping term → postings with per-document positions, tf, and tf-idf. citeturn10view0
- Tokenization is ASCII-ish (alphanumeric + underscore) and includes positions/offsets in the original content buffer. citeturn10view0
- Normalization calls a Unicode module for NFC normalize + case folding (`unicode.nfcNormalize`, `unicode.foldCase`). citeturn10view0turn9view1
- Ranking is “BM25-like” (k1, b, k3 query tf factor), computed against per-document token lengths and per-term doc freq derived from posting list length. citeturn10view0turn9view0
- The index supports `indexDocument(doc_id, content)` and `removeDocument(doc_id)`; “update” is not a first-class operation here (expected to be remove+add). citeturn10view0

**FTS persistence (snapshot file)**
`src/index/fulltext_persist.zig` saves the entire index to `{dir_path}/fulltext.idx`:

- Header: `MAGIC="GFTS"`, `VERSION=1`, then doc_count, documents, term_count, posting lists. citeturn71view0turn71view2turn71view4
- It serializes documents including the full content bytes and serialized token text, and serializes postings including all positions. citeturn71view2turn71view4
- On load, it reconstructs token slices by skipping token text bytes and re-slicing into `content` using `offset/length`, and applies sanity caps to avoid huge allocations. citeturn71view1turn71view4
- Persistence is **snapshot-style** (not append/WAL/segment): the entire index is rewritten in one buffer and then written to disk. citeturn71view2

**Encryption-at-rest primitive used by FTS persistence**
`src/storage/tde_file_encryption.zig` implements AES‑256‑GCM with a magic header; if the env var key is not set, it returns a copy of plaintext (passthrough). citeturn22view0
Crucially, `writeEncryptedFile()` opens with `createFile(path, .{})` and `writeAll(encrypted)`, i.e., it writes the destination file directly without an A/B manifest or temp+fsync+rename sequence. citeturn22view0turn71view2

### Where FTS “lives” relative to the new graph-storage architecture

**Per-graph ownership and on-disk location**
`src/storage/graph_storage_adapter.zig` manages one `ManagedGraph` per graph UUID directory and includes:

- `fts_index: ?*FullTextIndex` and `fts_dir: ?[]const u8` stored per graph. citeturn40view0
- `initFtsForGraph()` builds `{graph_dir}/fts`, creates the directory, and loads `FullTextIndex.loadFromDisk(fts_dir)` when opening an existing graph; on load failure it logs and falls back to a fresh in-memory index. citeturn39view0turn39view1
- `createGraphLocked()` initializes a fresh FTS index for new graphs; `openGraphLocked()` loads it for existing graphs. citeturn38view2turn39view1

So today, the FTS persistent format is **per-graph**, in a **sidecar directory** under the graph-storage directory tree (`graphs/{uuid}/fts/fulltext.idx`). citeturn39view0turn39view1turn71view2

**Durability boundary**
Geode’s top-level WAL wrapper (`src/wal.zig`) explicitly states that **physical crash recovery is handled by the graph-storage engine’s WAL** and that this WAL is a **logical change feed** for CDC/audit, not required for durability. citeturn35view0
This implies FTS durability should be treated as either:

- a *derived* index rebuilt from graph data, or
- a *durable* sub-system with its own atomic commit + recovery, aligned with the graph-storage engine’s durability model (preferred for performance and bounded recovery). citeturn35view0turn61view0turn62view3

### What the code indicates about indexing hooks and planner integration

**Storage adapter mutation paths do not update FTS directly**
For example, `setNodeProperty()` converts values and calls `engine.putProperty()` and then `engine.putNode()`, with no `fts_index` update in that path. citeturn37view1turn40view1
Therefore, any “graph mutation → FTS update” path must be implemented elsewhere (e.g., a higher-level mutation layer), or FTS is currently incomplete/experimental.

**Planner/optimizer knows about FTS query types**
`src/server/index_optimizer.zig` has `optimizeFtsQuery()` which considers a `.fulltext` index and models query types including `.simple`, `.phrase`, and `.proximity`, and produces explain text referencing BM25 scoring. citeturn49view0
This is a strong signal that the intended semantics include phrase/proximity query forms even if implementations are partial today.

**“Advanced FTS” appears stubbed**
`src/fts/advanced.zig` implements analyzers and phrase/proximity/highlight logic, but its `phraseQuery` uses a synthetic corpus string and is gated by a feature-flag style `enabled()`/test override. citeturn9view1turn69view0
So phrase/proximity/highlight semantics are not presently backed by the persistent index format in `fulltext.idx`.

### Backup/restore boundary relevant to FTS artifacts

`src/storage/backup.zig` backs up the **entire `graphs/` directory tree** under `data_dir`, plus `graph_registry.dat`, meaning it will include `{uuid}/fts/...` artifacts as they exist today. citeturn63view2
The restore path re-materializes each archived file entry into `restore_dir` without FTS-specific logic. citeturn63view2turn63view3

## Alternatives analysis

### Evaluation criteria and weighting

Because Geode is a transactional graph system that is aiming for enterprise guarantees, I overweight: (a) latency/throughput, (b) crash safety + bounded recovery, and (c) security/integrity isolation.

Weights (sum = 1.00):

- Indexing throughput 0.08
- Update/delete churn cost 0.08
- Search latency 0.12
- Phrase/proximity/highlight cost 0.08
- Startup/load time 0.10
- Memory footprint 0.08
- Index size on disk 0.06
- Merge/checkpoint cost 0.08
- Recovery cost 0.10
- Backup/restore efficiency 0.06
- Corruption blast radius 0.06
- Metadata leakage risk 0.06
- Implementation complexity/refactor risk 0.06
- Migration difficulty 0.03
- Fit with future distributed replication/sharding 0.05

Rationale: current snapshot persistence directly threatens restart time, recovery boundedness, corruption isolation, and write amplification. citeturn71view2turn22view0turn39view0turn60view0turn62view2

### Decision matrix (0–5 score, higher is better)

| Option | Summary | Weighted score | Keep / eliminate |
|---|---|---:|---|
| A | Keep current design as-is | 1.9 | Eliminate |
| B | Snapshot design + tuning (faster serialization, safer writes) | 2.6 | Eliminate (stopgap only) |
| C | Global segment-based inverted index | 2.8 | Eliminate (multi-tenant blast radius) |
| D | Per-graph/per-index segment-based inverted index + manifest | 4.1 | Serious contender |
| E | Page-based FTS storage reusing graph-storage primitives | 4.0 | Serious contender |
| F | Hybrid RAM dictionary + disk postings/doc-values/norms | 4.3 | Serious contender (pairs well with D/E) |
| G | LSM-like segments + tombstones + merge policy | 4.4 | Best fit |
| H | Alternative (external search engine) | 2.7 | Eliminate (violates deploy/consistency goals) |

Why A/B lose:

- The snapshot write path serializes *everything* and writes via a non-atomic file replace (direct create+write), so crash during save can corrupt or truncate the only index file. citeturn71view2turn22view0
- The on-disk structure duplicates full document contents and token text, inflating disk and memory pressure as corpora grow. citeturn10view0turn71view2turn71view4
- FTS initialization in `graph_storage_adapter` treats load failure as a soft error and can fall back to a fresh index, creating an availability/correctness cliff unless there is an automatic rebuild pipeline. citeturn39view0turn39view1

Why C loses:

- A global (cross-graph) index defeats the explicit per-graph directory model existing in `graph_storage_adapter` and increases corruption and leakage blast radius for multi-tenant deployments. citeturn39view0turn40view0

Why D/E/F/G win:

- Segment + merge designs are the standard way to control write amplification, support deletes/updates, and keep query latency stable across churn.
- Geode already has per-graph directory scoping and a storage engine that demonstrates atomic manifest switching and WAL-based bounded recovery; those patterns map well to a per-graph FTS manifest + WAL. citeturn39view0turn61view0turn62view2turn62view3

## Recommended design

This combines **D + F + G**, optionally leveraging **E’s** durability primitives.

### On-disk layout (per graph)

Under each graph directory (`{data_dir}/graphs/{uuid_hex}`), create:

- `fts/manifest.a`
- `fts/manifest.b`
  - A/B pair, monotonic `counter`, CRC32C over fields; optional HMAC when encryption is enabled (match the graph-storage style of authenticated backup/integrity). citeturn62view2turn62view3
- `fts/wal/fts.wal` + `fts/wal/fts.uuid`
  - Small redo log for recently committed FTS mutations not yet merged into segments (BEGIN/COMMIT markers). Mirror the graph-storage WAL record/begin/commit model conceptually. citeturn62view3turn60view0turn61view0
- `fts/segments/`
  - `seg_{gen}_{lsn}_{docbase}/` directories (or flat files with generation suffixes).
  - Each segment is **immutable once published** in the manifest.

Per segment files (minimal set):

- `terms.fst` (or `terms.hash`)
  Term → {df, postings_offset[field], postings_len[field]}
- `postings.{field}.bin`
  Block-compressed docids + tf + positions
- `norms.{field}.bin`
  Per-doc field length used by BM25/BM25F
- `docmap.bin`
  ExternalDocID (node/edge id + field id) → (seg_id, local_docid, version)
- `deletes.bitset` or `tombstones.bin`
  Marks deleted local docids; applied at query time; cleared/compacted on merge.

#### Segment file envelope (v2, GSP-9)

As implemented in `src/segment.zig`, every segment file (`terms.hash`,
`postings.bin`, `tombstones.bin`, `norms.bin`) is wrapped in a uniform,
versioned, checksummed envelope:

```
magic(4)="FSG2" | version(4, u32 LE = 2) | payload | crc32c(4, over magic..payload)
```

- The envelope is applied **inside** the AEAD envelope when at-rest
  encryption (WRK-038) is enabled — i.e. the plaintext that gets AEAD-sealed
  is itself the v2-enveloped payload, so `nonce || AEAD(magic|version|payload|crc32c) || tag`
  is what lands on disk.
- **Downgrade-safe by construction:** the magic's four bytes (`'F','S','G','2'`)
  deliberately decode, as the little-endian `u32` `count` field every legacy
  parser reads first, to `0x32475346` = 843,600,710 — far above every
  `MAX_*_PER_SEGMENT` cap (2^24). An old (pre-v2) binary that opens a v2
  `terms.hash` therefore fails loudly at its existing count guard
  (`error.TermCountTooLarge`) instead of misparsing the file as valid data.
  This mirrors graph-storage's slab-marker trick for cross-layout misroutes.
- **Read-both, forever:** format is detected exactly once per segment, on
  `terms.hash` (the only file whose magic-sniff is unambiguous). Files
  without the magic parse as legacy (v1, naked) exactly as before v2 shipped
  — there is no sunset date for this fallback. Once `terms.hash` establishes
  the segment's format, `postings.bin`, `tombstones.bin`, and `norms.bin`
  must match it: `.enveloped` segments require and strip the envelope from
  every file; `.legacy` segments read every file verbatim. In particular,
  `postings.bin` is never independently magic-sniffed on a legacy segment —
  a legacy postings.bin's varint stream could coincidentally start with the
  same four bytes as valid delta-coded posting data, so the format decision
  is made once, on the unambiguous file, and trusted thereafter.
- **Plaintext `postings.bin` CRC exemption (documented, intentional):** the
  positional-read path used for plaintext (non-AEAD) postings.bin verifies
  only the 8-byte magic+version header at segment open (`postings_base = 8`,
  payload size = `stat.size - 12`) — it does *not* checksum the whole file,
  since that would force an O(file) read on every open purely to validate a
  file whose postings are read positionally anyway. Integrity for this path
  rests on three other layers: the checked varint decode in `PostingIterator`
  (GSP-4, rejects overflow/out-of-range instead of misparsing), the
  dictionary extent validation against the postings file size at load
  (GSP-5), and the full CRC32C check when AEAD encryption is enabled (the
  encrypted path always materializes and CRC-validates the whole postings
  buffer at open, since AEAD ciphertext isn't random-accessible).
- Version mismatches (`version != 2` inside a recognized-magic file) surface
  as `error.UnsupportedSegmentVersion` — a deployment condition (binary too
  old for the on-disk format), never silently misparsed and never confused
  with `error.ChecksumMismatch` (payload corruption under a version this
  binary *does* understand).

Constraints from current semantics:

- Current `FullTextIndex` tokenization stores per-token offsets and positions, so the recommended postings format must support **positions** (at minimum) to enable phrase/proximity/highlight correctly. citeturn10view0turn49view0
- Current persistence also stores the entire content; **FTS v2 should *not* store full plaintext content** unless strictly necessary. Highlight/snippet can be generated by fetching the property value from the graph store after auth filtering. This avoids doubling sensitive content at rest. citeturn71view2turn37view1turn36view0

### Dictionary, postings, norms, and scoring stats

**Dictionary**

- Use a memory-mappable structure:
  - either an FST (ideal) or a compact open-addressed hash table of fixed-size metadata records.
- Store per-term `df` (document frequency) in the dictionary so BM25 IDF can be computed without scanning postings. This aligns with how current code derives `doc_freq` from posting list length, but makes it O(lookup) per term rather than O(load postings). citeturn10view0turn9view0

**Postings encoding**

- For each term, encode docids as delta-coded increasing integers.
- Use a block codec (e.g., varint-block or SIMD-BP128 eventually). The “first implementable” version in Zig should be:
  - delta docids with LEB128 varints
  - tf as u16/u32 varint
  - positions as delta varints
- Add skip pointers at the block level once correctness is stable.

**Norms**

- Persist field length per doc (u16/u32) and optionally precomputed BM25 normalization factors.

**Global stats**

- Maintain `total_docs` per graph and per-field `avg_doc_len` and store in manifest or a `stats.bin` referenced by manifest.
- On segment publish, incrementally update these counters.
- This preserves current BM25 behavior which uses avg doc length and total docs. citeturn10view0turn9view0

### Update/delete/merge model

**RAM staging (“memtable”)**

- During a commit, apply text mutations into an in-memory structure:
  - term → postings for newly added docs within this memtable
  - docmap updates for external doc ids
  - tombstones for deletes/updates

**Flush**

- When memtable crosses a threshold (tokens, bytes, or time), build a new immutable segment directory and fsync it.
- Write new `manifest.*` using A/B switching:
  - write to temp, fsync, rename (graph-storage explicitly documents this manifest atomicity requirement). citeturn61view0turn62view2

**Deletes & updates**

- Updates are “delete old version + add new version”.
- tombstones are applied at query time by consulting `deletes.bitset` and docmap versioning.
- Background merges rewrite segments to discard deleted docs and coalesce postings.

**Merge policy**

- Start with a size-tiered LSM policy (e.g., 4× fanout):
  - level 0: many small segments (recent writes)
  - periodic merge into larger segments
- Merge is per-graph to preserve isolation and avoid cross-tenant leakage. citeturn39view0turn40view0

### Crash-recovery model

**Goal:** committed FTS updates are never lost; recovery work is bounded.

Minimal robust design:

- Record per-transaction FTS mutations in `fts.wal` with BEGIN/COMMIT markers.
- On startup:
  1. Read the latest valid manifest (A/B, CRC-validated).
  2. Load segment list from manifest.
  3. Replay committed FTS WAL entries after the manifest’s `last_checkpoint_lsn` (or equivalent) into a new memtable, then flush as a new segment and publish a new manifest.
This mirrors the graph-storage engine’s stated approach: replay committed WAL records since last checkpoint and write a fresh checkpoint baseline. citeturn61view0turn62view3turn60view0

If you choose to **reuse graph-storage primitives (Option E)**:

- Store FTS postings and dictionaries as page files managed by a FileManager/Pager and use the same per-page CRC + WAL page_update mechanism, at the cost of more integration work. The graph-storage format-spec already defines page headers (CRC32C, LSN) and WAL record structure including file_id and page_id. citeturn62view0turn62view3turn61view0
This can yield better streaming encryption and avoids “whole-file decrypt” overhead.

### Backup/restore model

Short-term (works today):

- Because Geode backup includes the entire `graphs/` directory tree, FTS v2 artifacts will be captured automatically if they reside inside `{uuid}/fts/`. citeturn63view2turn39view0

Medium-term (recommended):

- Introduce a backup mode that understands the FTS manifest and includes only live segments referenced by the chosen manifest + the FTS WAL (if retention requires).
This reduces backup bloat and ensures restore does not resurrect unreferenced/garbage segments.

### Security model

**Encryption-at-rest**

- Current FTS persistence uses TDE file-level encryption; but the implementation encrypts whole buffers and writes via a direct file overwrite. citeturn71view2turn22view0
For large FTS segments, this will become a bottleneck (encrypting/decrypting multi-GB files per open). FTS v2 should either:

1. Implement streaming encryption for segment files, or
2. Reuse the graph-storage per-page encryption model (AES‑256‑GCM per page) already described in graph-storage docs. citeturn61view0turn60view0turn62view2

**Integrity and fail-closed**

- Today, `writeEncryptedFile` provides AEAD integrity *only if encryption is enabled*; if disabled, file corruption can produce arbitrary behavior unless explicit checksums are added. citeturn22view0turn71view4
FTS v2 must add: per-file CRC32C (and optional HMAC with the TDE key) and must fail-closed on corruption: mark index “needs rebuild” rather than silently treating it as empty.

**RLS/ABAC + highlighting**

- FTS must be treated as a **candidate generator**; final result sets must always be filtered through the same authorization logic that applies to graph reads.
- Highlight/snippet should be generated from the base property values *after* authorization checks, not from stored fields inside the FTS index (to prevent leakage of unseen content). This is consistent with the fact that core storage fetches occur via the graph engine and authorization layers, and avoids extra plaintext duplication. citeturn37view1turn36view0

**FLE (Field-Level Encryption) interaction**

- If a field is FLE-protected, full-text indexing with BM25 is generally unsafe because tokenization and term frequencies are the sensitive data. The safe default is:
  - **Do not index FLE-protected fields** for full-text search.
  - Allow only exact-match searchable encryption (blind indices / deterministic tokens) in a separate mechanism, and keep it out of BM25 ranking.
Geode already integrates FLE at the storage/value layer (GraphStore includes explicit FLE integration and envelope detection). citeturn36view0

### Migration model

A safe incremental plan:

1. **Introduce a new module** `src/index/fts2/` implementing:
   - Segment writer/reader
   - FTS manifest A/B
   - FTS WAL
   - Query executor producing doc-id candidates + score vectors

2. **Dual-read, single-write phase**
   - Keep reading from old `FullTextIndex` if `fts2/manifest.*` does not exist.
   - Write new updates only to old index initially (no behavior change).

3. **Backfill builder**
   - Add an online “rebuild FTS v2 for graph” command that:
     - scans all nodes/edges/properties and feeds FTS v2
     - runs in a controlled background job
   - Once complete, publish `fts2/manifest.*`.

4. **Dual-write phase**
   - For a period, apply new mutations to both old and new indexes; compare query results in tests and optionally in production shadow-mode.

5. **Cutover + cleanup**
   - Switch query execution to FTS v2 as the source of truth.
   - Retain old `fulltext.idx` for rollback window; then delete or archive.

## Why the current design needs replacement

This is the “tell it like it is” assessment based on direct code evidence.

**Snapshot persistence is structurally wrong for FTS at scale**
`fulltext_persist.save()` serializes the entire in-memory index (documents + inverted index) into a single buffer and writes it to `{dir}/fulltext.idx`. citeturn71view2
That means:

- write amplification is proportional to *total index size*, not change size
- no incremental durability for recent updates
- save time grows without bound as corpus grows

**The write path is not crash-atomic**
The underlying writer (`tde.writeEncryptedFile`) creates and writes the destination file directly. There is no evidence of a temp file + fsync + rename atomic swap in this path. citeturn22view0turn71view2
Graph-storage explicitly calls out A/B manifest switching with atomic write-to-tmp + fsync + rename as a required durability pattern; FTS currently does not follow that bar. citeturn61view0turn62view2

**The persistence format duplicates sensitive and large data**
The snapshot contains the full document contents plus per-token data and even serializes token text (even though load skips it and reconstructs slices into content). citeturn71view2turn71view4turn10view0
For large corpora, this becomes a disk bloat and backup bloat problem and increases the plaintext surface area if encryption is not enabled. citeturn22view0turn63view2

**FTS init/load is fail-open today**
`initFtsForGraph` logs and falls back to a fresh index on load failure. citeturn39view0turn39view1
Even if FTS is “derived state”, silently returning an empty index is operationally dangerous: it can cause massive performance regressions and inconsistent user experience unless there is an explicit, audited rebuild process.

**“Advanced FTS” semantics are not backed by persistent index structures**
The advanced module’s phrase/proximity/highlight behavior is stubbed/synthetic and not wired to the persisted `FullTextIndex` format. citeturn9view1turn69view0
Yet the optimizer models phrase/proximity as query types. citeturn49view0
A segment-based postings+positions format is the appropriate foundation to make those semantics real.

## Security review

### Confidentiality

**What can leak today**

- If TDE is not enabled, `encrypt()` returns plaintext bytes; `fulltext.idx` will contain literal term bytes and content. citeturn22view0turn71view2
- Even when TDE is enabled, current FTS stores document content in the index snapshot, increasing the number of encrypted blobs containing sensitive text (more targets, more blast radius). citeturn71view2turn71view4
- Backup captures the entire graph directory tree (including `fts/`), so plaintext FTS artifacts (if encryption disabled) propagate into backups. citeturn63view2turn22view0

**FTS v2 fix**

- Avoid storing full text in the index; store only postings, positions, and doc-id mappings.
- Ensure encryption is streaming/page-based so large indexes are not decrypted wholesale at startup.

### Integrity and tamper resistance

**What exists today**

- AES-GCM provides integrity when encryption is enabled, but when not enabled, there is no checksum for `fulltext.idx` beyond basic parsing constraints. citeturn22view0turn71view4
- The write path is not atomic. A crash mid-write can yield truncated or partially written files. citeturn22view0turn71view2

**FTS v2 fix**

- A/B manifest with CRC32C and optional HMAC, segment file CRCs, and fail-closed behavior on corruption (reject index, trigger rebuild, do not silently treat as empty).

### Metadata leakage

Even with encryption, file sizes, segment counts, and dictionary sizes leak approximate corpus size and churn. That’s unavoidable unless you pad aggressively, but you *can* minimize leakage by:

- keeping segment filenames non-semantic (IDs only)
- ensuring manifests do not store plaintext field/property names unless encrypted (or only store hashed identifiers)
- ensuring logs/metrics never emit raw query terms (today, several modules include structured logging; avoid placing terms in structured attributes). citeturn22view0turn35view0turn72view0

### FLE interaction (explicit callout)

Geode’s storage layer has explicit FLE integration hooks and envelope detection. citeturn36view0
Given that, FTS v2 must enforce:

- **Default: exclude FLE-protected fields** from BM25 indexing.
- If “search over encrypted fields” is required, it must be a separate feature (deterministic keyword search / blind indices) with explicit leakage tradeoff documentation, not quietly implemented inside BM25.

## Implementation, testing, benchmarking, and rollout

This section contains deliverables 7–11 (code impact map, testing plan, benchmark plan, risk register, final recommendation) in a decision-ready form.

### Code impact map

**Files that must change immediately (minimum viable FTS v2 integration)**

- `src/storage/graph_storage_adapter.zig`
  - Replace `fts_index: ?*FullTextIndex` with `fts_index: ?*FtsIndex` interface
  - Keep per-graph directory ownership (`{graph_dir}/fts`) citeturn40view0turn39view0
- `src/index/fulltext.zig` / `src/index/fulltext_persist.zig`
  - Freeze as legacy (`fts1`) for migration
  - Add `src/index/fts2/*` modules for segments/manifest/WAL

**Interfaces to introduce**

- `pub const FtsIndex = struct { ... }` (or a Zig interface pattern) with:
  - `indexDoc(external_id, fields...)`
  - `deleteDoc(external_id)`
  - `search(query_ast, options) -> iterator of (external_id, score, positions…)`
  - `checkpoint()` / `flush()` / `close()`

**Compatibility shims**

- A shim that implements the new interface by delegating to `FullTextIndex` for graphs that have not been migrated yet.

### Testing plan

**Unit tests (fast, deterministic)**

- Segment codec tests:
  - postings encode/decode round-trip (docids, tf, positions)
  - dictionary lookups and df correctness
  - norms encode/decode
- Manifest A/B correctness:
  - select newest valid manifest, reject corrupted one (mirror graph-storage manifest selection concepts). citeturn62view2turn61view0
- WAL replay:
  - committed transactions replayed; aborted not applied (mirror graph-storage WAL semantics). citeturn62view3turn61view0
- Security invariants:
  - ensure query terms are not written to logs/metrics
  - ensure manifests don’t store plaintext field/property names when encryption is enabled (store hashed identifiers)

**Integration tests (geode + graph-storage adapter)**

- Create graph → index documents via mutation path → restart → verify search returns expected matches.
- Multi-graph isolation: ensure graph A queries never see graph B docs (consistent with per-graph directory scoping). citeturn39view1turn36view0
- Backup/restore:
  - backup captures FTS v2 files (directory tree capture already does) and restore yields consistent search results. citeturn63view2

**Fault-injection tests**

- Crash during:
  - segment write before publish
  - manifest publish (simulate partial write)
  - WAL append between BEGIN and COMMIT
- Corrupt:
  - truncate postings file
  - corrupt manifest CRC
  - corrupt dictionary offsets
Expected behavior: fail-closed, mark graph FTS “needs rebuild”, do not silently return empty index.

**Migration tests**

- Start with legacy `fulltext.idx` present → rebuild v2 → dual-write → cutover → verify stable results.

### Benchmark plan

Implement a benchmark harness that operates at the `FtsIndex` interface layer and can run both FTS1 and FTS2 for A/B comparison.

**Corpora**

- Hot corpus (large): 10–50M tokens, 1–5M docs, realistic text distribution
- Many small graphs: 10k graphs × 100–1k docs each (multi-tenant stress)
- Unicode-heavy: multilingual text with NFC/Case folding and mixed scripts (validate analyzer + normalization paths). citeturn10view0turn9view1

**Scenarios (each defines workload, success metrics, failure conditions, instrumentation, expected trade-offs)**

1. **Read-heavy search with moderate updates**
   - Workload: 95% queries, 5% updates; term and multi-term queries; top‑k = 20
   - Metrics: p50/p95/p99 latency, CPU/op, cache misses, heap allocations/op
   - Failure: p99 regressions > 20% vs baseline

2. **Write-heavy ingest**
   - Workload: 100% indexing, batching sizes 1 / 100 / 1k
   - Metrics: docs/sec, tokens/sec, bytes written per doc/token, flush frequency
   - Expectation: FTS2 > FTS1 because no full snapshot rewrites.

3. **Delete/update churn**
   - Workload: 30% deletes, 30% updates, 40% queries
   - Metrics: segment count growth, merge wall time, query latency under high tombstone ratios

4. **Phrase/proximity heavy**
   - Workload: explicit phrase queries and proximity windows (as modeled by optimizer) citeturn49view0turn9view1
   - Metrics: latency, postings/positions decode costs, skip effectiveness

5. **Highlight-heavy**
   - Workload: highlight/snippet generation for top‑k results
   - Metrics: extra graph property reads, total query time, memory overhead
   - Security requirement: snippet only produced post-authorization

6. **Cold start / reopen**
   - Workload: open graph with large FTS index after process restart
   - Metrics: open time, RSS growth, segment metadata load time
   - Expectation: FTS2 uses mmap and avoids full-file decrypt; FTS1 requires full decrypt+parse of snapshot. citeturn22view0turn71view4

7. **Crash + recovery**
   - Workload: crash at randomized points during flush/merge
   - Metrics: recovery time, correctness of committed visibility, no silent loss
   - Expected: bounded replay via WAL/manifest design

8. **TDE enabled vs disabled**
   - Compare performance of encryption mode; ensure no plaintext artifacts when enabled. citeturn22view0turn71view2

9. **FLE-protected fields included vs excluded**
   - Ensure excluded fields do not contribute tokens; verify no leakage.

**Instrumentation (minimum)**

- indexing throughput, p50/p95/p99 latency, index size, bytes written per doc/token, merge time, startup/load time, recovery time, RSS, backup size & delta size, restore time, corruption isolation success.
(These align directly with the user-required metrics.)

### Risk register

**Technical risks**

- Segment merge correctness bugs (lost postings, bad docmap) → mitigated by heavy round-trip and differential testing against FTS1 in dual-write phase.
- Query-time cost regressions for small corpora → mitigate with hybrid in-memory L0 segment and adaptive merge thresholds.

**Security risks**

- Indexing FLE fields accidentally → mitigate with schema-level “field eligibility” checks enforced at ingestion (hard fail).
- Highlight leakage (snippets from unauthorized docs) → mitigate by designing highlight to require post-auth graph reads only.

**Operational risks**

- Index rebuild time for huge graphs → mitigate with incremental rebuild + throttling + background jobs.
- Disk bloat if merge lags → mitigate with explicit merge scheduling and admin introspection.

**Migration risks**

- Dual-write divergence (FTS1 vs FTS2 scoring differences) → mitigate by freezing scoring model and adding “score parity tests” for sampled queries.

**Unknowns that need PoC validation**

- Best integration point for transaction commit hooks (the exact mutation layer wasn’t fully traceable from retrieved snippets). The smallest PoC: wire a single “node property updated → indexDoc” hook at the highest-level mutation handler that has transaction context, measure overhead, and verify visibility semantics.

### Final recommendation

**Go / no-go**: **Go**, with a phased rollout.

**Phased rollout plan**

1. Build FTS2 core (segments + manifest + WAL) behind a feature flag per graph.
2. Add rebuild tooling and dual-read capability (fallback to legacy snapshot).
3. Enable for internal benchmark suites; verify crash recovery and corruption fail-closed.
4. Dual-write in staging; require parity gates.
5. Gradual production rollout by tenant/graph.

**Rollback plan**

- Keep legacy `fulltext.idx` untouched during the rollout window.
- If FTS2 misbehaves, switch reads back to legacy and continue dual-writing fixes until stable.

**What to prototype first**

1. Segment writer/reader with postings+positions and docmap.
2. Manifest A/B with CRC and atomic publish (temp+fsync+rename).
3. WAL replay of committed updates since last checkpoint.
4. Integration into `graph_storage_adapter` per-graph ownership model (same directory layout) with explicit “needs rebuild” state instead of silent empty fallback. citeturn39view0turn39view1turn62view2turn62view3

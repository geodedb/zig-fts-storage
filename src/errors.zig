// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Aggregated named error sets per module — re-exported by each module so
//! downstream consumers can `switch` exhaustively.

pub const WalError = error{
    InvalidData,
    InvalidMagic,
    ChecksumMismatch,
    Incomplete,
    PayloadTooLarge,
    Overflow,
};

pub const ManifestError = error{
    InvalidData,
    InvalidMagic,
    ChecksumMismatch,
    ManifestTooLarge,
    SegmentCountTooLarge,
    NoManifest,
    /// Manifest carries a format_version this binary does not implement.
    /// Fail-loud downgrade/upgrade gate (GSP-6): a version mismatch is a
    /// deployment condition, not corruption — it must never be masked by
    /// the A/B corrupt-slot fallback or misparsed at a guessed layout.
    UnsupportedManifestVersion,
};

pub const SegmentError = error{
    InvalidData,
    InvalidMagic,
    ChecksumMismatch,
    TermCountTooLarge,
    TombstoneCountTooLarge,
    NormCountTooLarge,
    PostingsTooLarge,
    PositionCountTooLarge,
    PositionOutOfRange,
};

pub const EngineError = error{
    EmptyTerm,
    TermTooLong,
    PositionCountTooLarge,
    PositionsNotMonotonic,
    ManifestCorrupt,
    ManifestTooLarge,
    /// Trailing HMAC-SHA256 envelope did not match the recomputed tag.
    /// Surfaced by WAL replay and manifest load when `EngineConfig.hmac_key`
    /// is set (SEC-02, SEC-EXT-0401, GAP-0027).
    HmacMismatch,
    /// AES-256-GCM key must be exactly 32 bytes; SEC-EXT-0402.
    InvalidKey,
    /// AES-256-GCM segment ciphertext was shorter than the minimum
    /// `nonce(12) || ciphertext(0) || tag(16)` envelope (SEC-EXT-0402).
    CiphertextTooShort,
    /// Caller-supplied `excluded_fields` blocked an indexDocument batch
    /// because one of its TermPostings carries a matching `field` tag
    /// (GAP-0010).
    FieldExcluded,
    /// WAL replay accumulated more aggregate payload bytes than the
    /// configured cap (SEC-EXT-0203). Each individual record is already
    /// bounded by `MAX_WAL_PAYLOAD_BYTES`, but a sufficiently long WAL can
    /// still exhaust memory across many records — this aggregate bound is
    /// the second line of defense.
    WalTooLarge,
    /// Manifest carries a format_version this binary does not implement.
    /// Fail-loud downgrade/upgrade gate (GSP-6): a version mismatch is a
    /// deployment condition, not corruption — it must never be masked by
    /// the A/B corrupt-slot fallback or misparsed at a guessed layout.
    UnsupportedManifestVersion,
};

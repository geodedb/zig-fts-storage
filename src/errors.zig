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
};

pub const SegmentError = error{
    InvalidData,
    InvalidMagic,
    ChecksumMismatch,
    TermCountTooLarge,
    TombstoneCountTooLarge,
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
};

# Cross-platform session contracts

The canonical cross-platform recording-session contract lives at
[`../../contracts/recording-session.schema.json`](../../contracts/recording-session.schema.json).
`recording-info.schema.json` is only a compatibility reference for Windows
tooling; it must not diverge from that root contract.

Compatibility rules:

1. A missing `schemaVersion` means the legacy macOS v1 shape.
2. New Windows files write `schemaVersion: 1`, `source`, and `participants`.
3. Readers ignore unknown fields so a newer producer does not make a session
   disappear from the library.
4. Dates use ISO 8601 strings, matching the Swift encoder.
5. Metadata is written atomically beside the media file.
6. Session media remains named `recording.m4a` or `recording.mp4`; an
   interrupted writer must not publish a partial file under either final name.

The schemas describe the interchange format. The fixtures exercise both a
legacy macOS file with no version field and a versioned file.

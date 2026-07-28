# Cross-platform session contracts

These contracts preserve the existing macOS session folder format while
allowing Windows writers to add a schema version.

Compatibility rules:

1. A missing `schemaVersion` means the legacy macOS v1 shape.
2. New Windows files write `schemaVersion: 1`.
3. Readers ignore unknown fields so a newer producer does not make a session
   disappear from the library.
4. Dates use ISO 8601 strings, matching the Swift encoder.
5. Metadata is written atomically beside the media file.
6. Session media remains named `recording.m4a` or `recording.mp4`; an
   interrupted writer must not publish a partial file under either final name.

The schemas describe the interchange format. The fixtures exercise both a
legacy macOS file with no version field and a versioned file.

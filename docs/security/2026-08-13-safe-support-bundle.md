# Safe Support Bundle Field Inventory

`SafeSupportBundleStore` is an internal export API for a narrowly scoped,
owner-only support artifact. It is not a session export, a diagnostics upload
mechanism, or a retention feature. There is deliberately no UI action or
automatic generation path in this baseline.

## Storage boundary

The caller supplies an app-owned root directory. On export, the store creates
that directory with mode `0700`; if it already exists, it must be owned by the
current UID, be a real directory (not a link), and have no group/world bits.
Otherwise the export fails closed. Each JSON artifact is written atomically at
mode `0600` with a random, content-free filename.

## Exact JSON inventory

The bundle contains only these fields:

| Field | Type / bound |
|---|---|
| `schemaVersion` | fixed integer (`1`) |
| `generatedAt` | ISO-8601 timestamp |
| `build.channel` | fixed enum: `development`, `staging`, `production` |
| `build.versionMajor`, `versionMinor`, `versionPatch`, `buildNumber` | integers clamped to `0...9,999,999` |
| `diagnostics` | at most 100 `SafeRecordingDiagnostic` values |

Each diagnostic is the existing typed redacted schema only: its fixed enums,
validated HTTP status, bounded counts/byte count, schema version, and
timestamp. No per-session identifier is included.

The exported bundle types are encode-only. Their sole construction paths accept
typed `Date`/enum/integer inputs and apply the schema/version/count bounds
before encoding; they do not accept decoded or arbitrary string payloads.

## Explicitly excluded

The bundle cannot contain paths, URLs, device names or UIDs, recording media,
transcripts, prompts, provider responses, credentials/tokens, Keychain data,
bookmark bytes, raw errors/status text, or arbitrary user strings. Adding any
new field requires updating this inventory and a focused allowlist test before
it can be exported.

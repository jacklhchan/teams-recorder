# OpenAI-Compatible Provider and Product Hardening Design

**Date:** 2026-07-28
**Status:** Approved direction; written specification pending user review
**Base commit:** `c201cc11235dc43e9bdce9e0abe028a5fa007583`

## Goal

Close the five current configuration, credential, dependency, and release gaps
without coupling Local Meeting Recorder to oMLX, Qwen, or any single hosted
provider.

The recorder will use a user-configured OpenAI-compatible provider for
post-call transcription. Users can enter their own API base URL, ASR model,
future meeting-intelligence LLM model, language, and optional API key.

The implementation must preserve the validated long-recording behavior:

- silence-aware chunk planning;
- bounded 120-180 second chunks with overlap;
- rolling context;
- retry with shorter chunks;
- repetition and prompt-echo validation;
- atomic publication only after all chunks pass validation.

## Verified Starting Point

The review claim that the active app bypasses the long-form helper is stale.
The current app launches `transcribe-qwen-asr.sh`, which delegates to
`qwen_asr_longform.py`. The bundled helper and its focused 24-test suite are
already present.

The remaining live gaps are:

1. Runtime model configuration is duplicated and hard-coded.
2. A 4-bit model publishes filenames containing `8bit`.
3. Teams and ASR credentials are not stored behind a secure credential
   boundary.
4. The release manifest still models BlackHole even though native
   ScreenCaptureKit capture does not use it.
5. Packaging is a debug, ad-hoc-signed staging build with fixed version data.

The main checkout also contains unrelated uncommitted release-manifest drafts.
They remain untouched while this work is developed in the isolated
`codex/openai-provider-hardening` worktree. Their exact-source validation
intent is retained in the new provider validation tests, even though the dead
installer manifest is removed.

## Chosen Approach

Use incremental provider hardening rather than replacing the validated
long-form engine.

Rejected alternatives:

- A full native Swift rewrite of chunking and transcription now would combine
  provider migration with a high-risk audio-processing rewrite.
- A documentation-only correction would leave credentials exposed and runtime
  behavior split across hard-coded defaults.
- Provider-specific adapters for oMLX, OpenAI, and every local server would
  duplicate an API contract they already share.

## Provider Contract

### Stored Profile

Versioned non-secret settings are stored in `UserDefaults`:

```swift
struct OpenAICompatibleProviderProfile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var baseURL: URL
    var asrModel: String
    var llmModel: String
    var language: String
    var prompt: String
}
```

Version one supports one active profile. The model fields are arbitrary
non-empty provider model identifiers; the app does not validate them against
a Qwen or OpenAI allowlist.

`llmModel` is persisted now so the same provider profile can serve the planned
meeting-intelligence pipeline. This change does not add summary generation or
make chat-completion requests.

### URL Rules

The saved URL represents the API base ending in `/v1`. The client derives:

```text
GET  <baseURL>/models
POST <baseURL>/audio/transcriptions
```

Validation rules:

- `https` is accepted for all hosts;
- `http` is accepted only for loopback hosts such as `localhost`, `127.0.0.1`,
  and `::1`;
- user information, fragments, and query strings are rejected;
- trailing slash and one missing `/v1` suffix are normalized;
- model identifiers and language are trimmed before saving.

### Authentication

Bearer authentication is optional. An empty API key supports local servers
configured without authentication. A non-empty key is stored only in Keychain
and attached as:

```http
Authorization: Bearer <key>
```

The key must never appear in:

- `UserDefaults`;
- process arguments;
- process environment;
- status text;
- transcription logs;
- diagnostics;
- persisted provider JSON.

### Model Discovery

`GET /v1/models` is an optional convenience, not a transcription prerequisite.
The settings UI offers a connection test and model menu when the endpoint
supports discovery. A failed or unsupported model-list request still allows a
manually entered model.

The connection test verifies transport and authentication. It does not claim
that an arbitrary listed model supports audio transcription.

### Transcription Request

Each accepted chunk uses the OpenAI-compatible multipart contract:

```text
file=<audio chunk>
model=<user ASR model>
language=<user language, when non-empty>
prompt=<base prompt plus bounded rolling context, when non-empty>
response_format=json
```

The required response shape is a JSON object containing a string `text`
member. Provider-specific timestamp fields may be retained in raw diagnostics
but are not required in this milestone.

The provider snapshot is captured when a job starts. Editing settings during a
running transcription affects only the next job.

## Provider Settings UI

Add one compact `AI Provider` settings section using existing application
layout conventions:

- API Base URL text field;
- API Key secure field;
- ASR Model editable field with optional discovered-model menu;
- LLM Model editable field with optional discovered-model menu;
- Language field;
- Prompt editor;
- Save command;
- Test Connection command;
- Remove API Key command;
- inline validation or connection status.

Saving a blank API-key field preserves an existing key. Removing a key requires
the explicit Remove API Key command.

No oMLX launch button or provider-specific copy remains in the normal path.
The app never starts another provider application automatically.

## Legacy Migration

### Existing ASR Setup

On the first launch without a saved provider profile:

1. Detect the existing local `~/.omlx/settings.json` configuration.
2. Import its base URL and API key into a generic local provider profile.
3. Use the prior 4-bit ASR model only as a one-time legacy migration default.
4. Verify the Keychain value can be read back.
5. Tighten `~/.omlx` to `0700` and its settings file to `0600` when possible.
6. Leave the oMLX settings key in place because the external server owns and
   still needs that file.

After migration, transcription code no longer reads oMLX settings. A mismatch
between an existing Keychain key and the legacy settings key is reported
without silently rotating either credential.

New installations start with empty provider settings instead of an oMLX
default.

### Existing Transcripts

New output names are provider-independent:

```text
transcript.txt
transcript.raw.txt
transcription.json
transcription.log
```

`transcript.txt` contains the final display/edit version. Existing
model-specific transcript files remain readable as legacy fallbacks. A rerun
backs up an existing canonical transcript before atomic replacement.

## Credential Architecture

### Keychain Primitive

Introduce a small Security-framework wrapper around generic-password items:

```swift
protocol SecureValueStoring {
    func load(service: String, account: String) throws -> Data?
    func save(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}
```

It handles `errSecSuccess`, `errSecItemNotFound`, duplicate-item update, corrupt
UTF-8 data, and typed redacted errors.

Accounts:

```text
service local.meeting.recorder.teams-third-party-api
account pairing-token.v1

service local.meeting.recorder.openai-compatible-provider
account active-profile-api-key.v1
```

No Keychain access group or sharing entitlement is added.

### Teams Migration

Change `TeamsPairingTokenStoring` to throwing load/save/clear operations.

Migration rules:

1. Keychain wins when it contains a valid token.
2. Otherwise read the legacy UserDefaults token.
3. Save and read back the token from Keychain.
4. Delete the legacy value only after successful read-back.
5. A Keychain failure preserves the legacy value but fails closed: no socket is
   opened and the UI does not claim pairing succeeded.
6. Invalid-token cleanup clears both stores. Cleanup failure stops automatic
   reconnect and presents a redacted actionable error.

### Child Process Secret Transport

Rename the provider-neutral entry points:

```text
scripts/transcribe-openai-compatible.sh
scripts/openai_asr_longform.py
scripts/check-openai-compatible-provider.py
```

The app writes a small secret payload to the child's private stdin pipe and
then closes it. The key is not passed through arguments or environment.

The Python HTTP boundary uses a native HTTP client or stdin-fed request
configuration so an Authorization header never appears in a `curl` process
argument list.

Compatibility wrappers may retain the old script names for one release, but
they contain no model, endpoint, or provider defaults.

## Dependency and Manifest Cleanup

The abandoned self-service installer manifest is not a runtime source of truth
and is removed:

- remove BlackHole from release metadata;
- remove the unused `ReleaseManifest` runtime type and tests;
- remove `release-manifest.json` from SwiftPM resources and app packaging;
- remove stale self-service dependency claims from README;
- retain historical design documents as history, clearly marked superseded
  where needed.

Provider model and endpoint selection belongs to the user profile, not release
metadata. The app does not download BlackHole, oMLX, provider binaries, or
models in this milestone, so it must not present nullable checksums as artifact
verification.

## Build and Release

### Staging Build

Keep `scripts/build-app.sh` for local QA, but:

- make configuration, version, build number, bundle identifier, and output path
  explicit inputs;
- continue to default to a staging bundle and ad-hoc signature;
- package every required helper and license resource;
- verify the final bundle with strict code-sign checks;
- add a smoke test that moves the app outside the checkout and confirms bundled
  resources resolve.

### Release Build

Add a separate release command that:

1. requires explicit version and build number;
2. performs a Swift release build for Apple Silicon;
3. uses stable bundle identifier `local.meeting.recorder`;
4. signs inside-out with a supplied Developer ID Application identity;
5. enables hardened runtime and secure timestamp;
6. produces a ZIP release artifact and SHA-256 file;
7. optionally submits through `xcrun notarytool`;
8. staples and validates the ticket;
9. runs `codesign --strict` and `spctl --assess`.

The command fails clearly when signing identity or notarization credentials are
absent. It never silently labels an ad-hoc build as production.

The current machine has no valid code-signing identity, so this milestone can
test the release script's unsigned/ad-hoc dry-run and missing-credential
failure paths, but cannot claim a notarized production artifact.

### CI

Add a macOS GitHub Actions workflow for:

- Swift full suite;
- focused Python script suite;
- release compilation;
- staging bundle smoke checks;
- secret-pattern scan of generated logs and process invocations;
- license and third-party notice presence.

Signing and notarization remain a protected manual release job until secrets
and certificates are configured.

## Licensing

The repository is licensed under Apache License 2.0, as approved by the owner.

Add:

- root `LICENSE` containing Apache-2.0;
- `THIRD_PARTY_NOTICES.md`;
- bundled copies or references required by included third-party code;
- the existing Apple sample license for the virtual microphone driver;
- notices for external systems without implying they are bundled.

## Error Handling

User-facing failures are typed and redacted:

- invalid or insecure endpoint;
- missing ASR model;
- Keychain unavailable;
- migration mismatch;
- authentication rejected;
- model not found;
- transcription endpoint unsupported;
- timeout or network failure;
- malformed transcription response;
- validation/retry exhaustion;
- missing signing identity or notarization profile.

A provider or transcription failure never blocks, stops, or corrupts recording.
Partial long-form candidates remain unpublished.

## Test Strategy

### Provider Configuration

- URL normalization and loopback HTTP rules;
- arbitrary ASR and LLM model identifiers;
- profile persistence without API key;
- provider snapshot isolation during a running job;
- optional model discovery and manual-entry fallback.

### Credentials

- generic-password add/update/load/delete;
- Keychain not-found, permission, and corrupt-data paths;
- Teams migration success and read-back;
- failed migration preserves legacy token and fails closed;
- invalid-token cleanup across both stores;
- ASR API key never enters defaults, arguments, environment, logs, or status.

### OpenAI-Compatible ASR

- multipart fields match the documented contract;
- optional Bearer authentication;
- no-auth local provider;
- JSON `text` response;
- 401, 404/model, timeout, malformed JSON, and cancellation;
- long-form planning, context, retries, validation, and atomic publication;
- canonical output and legacy transcript discovery.

### Packaging and Release

- provider helpers are executable and bundled;
- app works after moving outside the checkout;
- staging and release metadata are distinct;
- missing Developer ID fails closed;
- strict code-sign verification;
- CI workflow syntax and required gates;
- Apache-2.0 and third-party notices are packaged.

### Regression

- focused Swift provider, Keychain, Teams, transcription, and manifest-removal
  suites;
- focused Python entrypoint and long-form suites;
- complete Swift suite;
- independent code review;
- installed-app migration test before replacing the user's running app.

## Acceptance Criteria

1. A user can save any conforming OpenAI-compatible base URL and arbitrary ASR
   model without code changes.
2. Local no-auth and Bearer-auth providers are both supported.
3. oMLX is no longer named or launched by the production provider path.
4. Long recordings retain current chunking and validation guarantees.
5. New transcripts use canonical provider-independent filenames and old
   recordings remain readable.
6. Teams token and provider API key are Keychain-backed with tested migration.
7. No secret appears in process metadata or persisted logs.
8. BlackHole and the abandoned installer manifest are absent from active
   runtime and release metadata.
9. Apache-2.0 and third-party notices are present.
10. Staging remains runnable while production release scripts fail closed
    without Developer ID credentials.

## Out of Scope

- meeting-summary generation;
- chat-completion calls;
- multiple saved provider profiles;
- Azure-specific `api-key` headers or deployment URL conventions;
- arbitrary custom HTTP headers;
- realtime transcription;
- speaker diarization;
- automatic provider application installation or launch;
- automatic oMLX 0.5.1 to 0.5.3 upgrade;
- claiming notarization before a real Developer ID identity is installed.

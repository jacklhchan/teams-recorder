# Reliable Recording Storage and OneDrive Publication Design

## Status

Approved on 2026-08-13. Amended the same day to use adaptive bookmarks after
the current non-sandboxed build was verified to reject security-scoped bookmark
creation.

## Context

Local Meeting Recorder currently records directly into `AppModel.outputFolder`.
The selected folder is not restored after relaunch, and a cloud-backed folder
can become unavailable or slow while a recording is active. This couples media
finalization to OneDrive availability and can leave the user uncertain whether
a stopped recording is locally safe, published, or damaged.

The existing code already provides useful safety boundaries that this design
must retain:

- `RecordingEngine` finalizes one session folder and returns a
  `RecordingResult`.
- `IncompleteSessionRecovery` promotes a valid audio backup without replacing
  an existing final recording.
- `RecordingStoragePolicy` warns, disables video, or safely stops based on free
  space.
- the Library feature uses a workspace publication fence and one mutation gate
  to reject stale publication and artifact mutations.

This design adds a durable storage boundary around those components. It does
not create a second recording engine or a second recordings library.

## Goals

1. Persist the user-selected recording destination across application launches.
2. Finalize every new recording on local storage before publishing it to a
   cloud-backed destination.
3. Preserve the local recording until the destination copy is fully verified.
4. Resume interrupted publication after relaunch without overwriting existing
   destination data.
5. Clearly distinguish a locally safe recording from a recording published to
   its selected destination.
6. Reject empty, unreadable, escaped, or tampered publication inputs.

## Non-goals

- Keeping two permanent copies of every successfully published recording.
- Building the full Recovery Center UI; that is a later, independently
  deliverable project.
- Replacing `RecordingEngine`, `IncompleteSessionRecovery`, the Library feature,
  or its mutation gate.
- Implementing a general-purpose cloud synchronization engine.
- Adding a OneDrive API, account credential, or Microsoft Graph integration.
- Changing Developer ID signing, Hardened Runtime, notarization, or the current
  ad-hoc development release flow.

## Considered Approaches

### 1. Local staging plus a durable publication queue — selected

Record and finalize locally, then publish the complete session folder to the
selected destination. A durable queue survives relaunch and retains local data
until the destination is verified. This isolates capture reliability from a
cloud filesystem while keeping OneDrive as the canonical recordings library.

### 2. Continue recording directly to OneDrive and retain a backup

This is a smaller change, but the primary writer remains exposed to cloud
latency, offline placeholders, sync interruption, and volume availability. It
does not address the central failure boundary.

### 3. Keep a permanent local library and mirror it to OneDrive

This provides strong redundancy but permanently doubles storage and introduces
two canonical workspaces. It is unnecessary for the requested behavior.

## Architecture

### Recording destination persistence

A `RecordingDestinationStore` owns the selected destination. It stores a
versioned bookmark catalog in `UserDefaults`; it never stores a OneDrive
credential. Each catalog entry has a stable destination identity, intended
path, bookmark kind, and bookmark data. The current destination identity is
stored separately. Older entries remain available while a pending queue item
still references them, so changing the output folder never silently retargets
an already finalized recording.

Bookmark creation is adaptive. The store first requests a security-scoped
bookmark. The current non-sandboxed build can reject that operation through
`ScopedBookmarksAgent`, so the store falls back to a standard bookmark and
records that kind. A future sandboxed build can create and resolve
security-scoped entries without changing the catalog schema. Plain path-only
persistence is not used.

The store exposes a resolved destination and an explicit access state:

- `ready`
- `needsFolderAccess`
- `unavailable`

On launch, a valid bookmark restores the exact selected directory. A stale or
unresolvable bookmark does not silently fall back to Downloads. The application
keeps the intended destination label and asks the user to select the folder
again. An explicitly injected `initialOutputFolder` remains authoritative in
tests and previews and is not replaced by persisted state.

For a security-scoped entry, the app holds scoped access only for the duration
required to inspect or publish files and balances every successful
`startAccessingSecurityScopedResource` call with
`stopAccessingSecurityScopedResource`. A standard bookmark in the current
non-sandboxed build uses a no-op access lease after resolution.

### Local pending root

Every new recording is written beneath:

`Application Support/Local Meeting Recorder/Pending Recordings`

The root and newly created session content use owner-only permissions. A
`RecordingPendingStore` owns this root and accepts only direct, regular session
directories whose canonical paths remain below the canonical pending root.
Symbolic links, aliases that resolve outside the root, unexpected file types,
and path traversal are rejected.

`AppModel` continues to expose the selected destination as `outputFolder` for
the workspace and UI, but passes the pending root to `RecordingEngine.start`.
The selected destination is captured together with the existing workspace
publication fence when recording starts. Changing the selected destination
during a recording affects the next recording and invalidates stale UI
publication; it does not retarget an already finalized session.

### Durable publication queue

A `RecordingPublicationCoordinator` owns one serial publication task and a
versioned, atomically written JSON manifest in the pending root. Each item has:

- a stable session identifier;
- the local session directory name;
- the intended destination bookmark identity;
- the workspace publication fence captured at recording start;
- creation and last-attempt timestamps;
- attempt count;
- state and a non-sensitive failure reason.
- the finalized recording health and metadata-warning context required to
  recreate a complete Library finalization after relaunch.

Queue states are:

- `pending`
- `publishing`
- `waitingForDestination`
- `needsAttention`

`publishing` is reset to `pending` after a process interruption. A corrupt or
missing manifest never causes file deletion. The coordinator reconstructs
entries by scanning valid direct children of the pending root and places
ambiguous or invalid sessions in `needsAttention`.

The coordinator retries when the app starts, when the destination becomes
available, and when the user selects **Retry Now**. Automatic retries use a
bounded backoff and one task; they do not create concurrent copies of the same
session.

### Publication protocol

The publisher performs these operations away from capture callbacks and the
main actor:

1. Validate that the source is a direct, non-symbolic child of the pending root.
2. Run existing incomplete-session recovery within that session.
3. Validate that the finalized recording is a regular non-empty file and can
   be opened as media with a finite duration greater than zero.
4. Resolve and temporarily access the selected destination bookmark.
5. Before copying, look for an exact publication marker for this queue item. If
   a previously published folder has the matching marker and verified source
   inventory digest, treat it as the idempotent result rather than publishing a
   duplicate.
6. Create an owner-only hidden staging directory under the destination using a
   unique session identifier.
7. Copy the complete session contents without following symbolic links and add
   a versioned publication marker containing the queue item identity and source
   inventory digest.
8. Compare the source and destination content inventory, byte sizes, and
   SHA-256 digests for every regular session file; exclude only the exact owned
   publication marker from this equality check.
9. Atomically rename the staging directory to its published session name using
   no-replace semantics.
10. Confirm that the published recording still passes media validation.
11. Publish the destination session through the existing Library workspace
    fence and mutation boundary.
12. Remove the local pending session only after all previous steps succeed.

An existing destination name is never overwritten. A collision receives a new
unique session name. A destination entry introduced during publication causes
the no-replace rename to fail safely and the local source remains intact.
The publication marker makes the operation idempotent if the process exits
after the destination rename but before manifest or local-source cleanup.

Hash calculation occurs only after local finalization and runs in background
work. It never executes on capture callbacks.

### Stop semantics and finalization

Stopping completes when the local media writer and metadata have finalized
safely. OneDrive publication begins afterward and never makes Stop wait for an
unbounded cloud operation.

`RecordingResult` continues to represent a locally finalized result. AppModel
then enqueues it for publication and reports one of:

- locally saved and publishing;
- locally saved and waiting for OneDrive;
- locally saved but requiring attention;
- published to the selected destination.

The Library treats the destination copy as canonical. A pending local session
is not advertised as if it were already available in OneDrive, but remains
reachable through the pending-recordings UI.

## User Interface

### Settings → Storage & Shortcuts

The storage section shows:

- the intended recording destination;
- destination access status;
- the local pending cache location;
- pending and needs-attention counts;
- **Choose Output Folder** or **Restore Folder Access**;
- **Retry Now** when work is pending;
- **Open Local Copies** when a retained local session exists.

The user-facing states are limited to:

- `Ready`
- `Recording locally`
- `Publishing`
- `Waiting for OneDrive`
- `Needs folder access`
- `Publish failed`

### Record workspace

A non-blocking banner appears when unpublished local sessions exist. It shows
the count and offers **Retry Now** and **Open Local Copies**. OneDrive being
offline does not prevent a recording when the local pending volume has enough
space.

Zero-byte or unreadable media is labelled **Needs attention** and is not
automatically retried. The UI never claims that it was published or deletes it.

## Error Handling

- A stale bookmark yields `needsFolderAccess`; Downloads is not selected as an
  implicit fallback.
- An unavailable destination yields `waitingForDestination`; the local session
  remains safe and automatic retry is bounded.
- An invalid or zero-byte source yields `needsAttention`; it is not published.
- A copy, inventory, size, digest, or media-validation mismatch removes only
  the owned destination staging directory and preserves the local source.
- A destination collision is resolved with a unique name and no overwrite.
- A corrupt queue manifest preserves all session data and triggers a safe scan.
- A crash during recording uses existing backup recovery before publication.
- A crash during copy leaves an owned hidden staging directory that can be
  safely reconciled on launch; it is never treated as a published session.
- A destination change or stale workspace fence prevents obsolete UI/library
  publication while leaving the completed destination data intact.

## Security Boundaries

- Adaptive bookmark catalog data is versioned non-secret configuration. No
  account credential or provider key is stored with it. Old destination entries
  are pruned only after neither the current selection nor any manifest item
  references their identity.
- Pending files, manifests, and destination staging directories are owner-only.
- All recursive operations validate canonical containment and reject symlinks.
- Publication never follows an attacker-controlled link or overwrites an
  existing destination.
- Queue errors and logs contain session identifiers and failure categories, not
  captured audio, transcripts, API keys, prompts, or bookmark bytes.
- The publisher operates only on a finalized session selected by the pending
  store; arbitrary filesystem paths are not accepted.

## Testing and Acceptance

Testing is deliberately focused on the storage boundary rather than a broad
cloud or device matrix.

### Unit and focused integration tests

1. A security-scoped bookmark is preferred; a non-sandboxed creation failure
   falls back to a standard bookmark. Both restore the selected folder, while a
   stale bookmark requests folder access and never falls back to Downloads.
2. A recording is finalized under the local pending root, then enqueued.
3. An unavailable destination retains the local session and later retry
   publishes it.
4. A queue interrupted in `publishing` resumes after relaunch.
5. Empty or unreadable media becomes `needsAttention` and is not copied.
6. A pre-existing or late-created destination is never overwritten.
7. A symlink or canonical-path escape is rejected.
8. An inventory, size, or SHA-256 mismatch retains the local source.
9. Successful verified publication removes the local pending copy exactly once.
10. A relaunch after destination rename but before cleanup recognizes the
    matching publication marker and does not create a duplicate destination.
11. A destination change retains access to the old identity until its pending
    item publishes, and does not retarget that item.
12. A stale workspace fence does not publish obsolete Library state.
13. Existing incomplete-session recovery, low-storage behavior, and Library
    mutation-gate tests remain green.

### Manual staging acceptance

1. Select a OneDrive folder, relaunch the app, and confirm the exact folder is
   restored.
2. Record while OneDrive is available; Stop returns after local finalization,
   publication completes, and the session appears in the destination library.
3. Make the destination unavailable, record and stop, and confirm the local
   retained banner and recording remain accessible.
4. Restore access and select **Retry Now**; confirm the session publishes and
   the pending copy is removed only after verification.
5. Relaunch with a pending item and confirm automatic resume.
6. Inject a zero-byte test artifact and confirm **Needs attention** without a
   false success message or deletion.

Verification consists of one focused test pass, one relevant integration-suite
pass, and this bounded staging UAT.

## Delivery Sequence

1. Destination bookmark persistence and access presentation.
2. Owner-only pending root and locally finalized recording flow.
3. Durable queue, validation, verified no-replace publication, and retry.
4. Pending-status presentation and Library finalization integration.
5. Focused automated verification and bounded OneDrive staging UAT.

Each step is independently testable and preserves a recoverable local recording
if later publication work is incomplete.

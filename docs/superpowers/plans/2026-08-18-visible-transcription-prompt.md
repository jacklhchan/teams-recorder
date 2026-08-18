# Visible Transcription Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the optional transcription prompt visibly identifiable as a labeled, bordered multi-line input.

**Architecture:** Keep `TranscriptionRequestDraft` and submission unchanged. Compose the existing `TextEditor` inside a small SwiftUI prompt field with a visible label, empty-state placeholder, text-background fill, and rounded border; verify it through the existing mounted workspace host.

**Tech Stack:** Swift 6, SwiftUI/AppKit on macOS, XCTest.

## Global Constraints

- The visible label is exactly `Prompt (optional):`.
- The empty placeholder is exactly `Names, terminology, or transcription guidance…`.
- Prompt submission remains optional and continues through `TranscriptionRequestDraft.options`.
- The existing `RecorderActionID.transcriptionPrompt` identifier and `Prompt` accessibility label remain unchanged.
- Do not change language selection, draft identity, cancel/submit behavior, provider requests, persistence, recording, storage, or floating panels.

---

### Task 1: Render a discoverable optional prompt field

**Files:**
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- Modify: `Sources/RecorderApp/Views/TranscriptionRequestSheet.swift`

**Interfaces:**
- Consumes: `TranscriptionRequestDraft.prompt: String`, `RecorderActionID.transcriptionPrompt`, and the existing `WorkspaceHost` text-editor helpers.
- Produces: the same `TranscriptionRequestOptions` submission, with only the prompt field presentation changed.

- [ ] **Step 1: Write the failing mounted-render test**

Add this focused test beside the existing transcription-sheet render tests:

```swift
func testTranscriptionSheetShowsVisibleOptionalPromptField() throws {
    let fixture = makeFixtureWithOneSession()
    let host = try makeWorkspaceHost(
        model: fixture.model,
        size: .init(width: 1_280, height: 800)
    )
    defer { host.close() }
    host.select(.recordings)

    fixture.model.requestTranscriptionOptions(sessionID: fixture.session.id)
    try waitUntil(timeout: 1, message: "transcription prompt field") {
        host.containsAccessibilityIdentifier(RecorderActionID.transcriptionSheet)
    }

    XCTAssertTrue(host.containsText("Prompt (optional):"))
    XCTAssertTrue(host.containsText("Names, terminology, or transcription guidance…"))
    XCTAssertNotNil(
        host.frame(forAccessibilityIdentifier: RecorderActionID.transcriptionPrompt)
    )
    XCTAssertTrue(host.replaceTextEditor(
        RecorderActionID.transcriptionPrompt,
        with: "Names: Ada and Grace"
    ))
    XCTAssertFalse(host.containsText("Names, terminology, or transcription guidance…"))
    XCTAssertEqual(
        host.transcriptionPromptValue(for: RecorderActionID.transcriptionPrompt),
        "Names: Ada and Grace"
    )
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
swift test --disable-sandbox --filter RecorderWorkspaceRenderTests/testTranscriptionSheetShowsVisibleOptionalPromptField
```

Expected: the test fails because `Prompt (optional):` and the empty placeholder are not rendered by the current borderless `TextEditor`.

- [ ] **Step 3: Implement the minimal prompt field**

Replace only the current `TextEditor` block with:

```swift
VStack(alignment: .leading, spacing: 6) {
    Text("Prompt (optional):")
        .font(.subheadline.weight(.medium))

    ZStack(alignment: .topLeading) {
        Color(nsColor: .textBackgroundColor)

        TextEditor(text: $draft.prompt)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(4)
            .accessibilityLabel("Prompt")
            .accessibilityIdentifier(RecorderActionID.transcriptionPrompt)
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: RecorderActionID.transcriptionPrompt,
                    label: "Prompt"
                )
            )

        if draft.prompt.isEmpty {
            Text("Names, terminology, or transcription guidance…")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
    .frame(minHeight: 96)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
}
```

Do not change the surrounding sheet buttons, language picker, sizing, draft state, or submit closure.

- [ ] **Step 4: Run focused GREEN verification**

Run:

```bash
swift test --disable-sandbox --filter 'RecorderWorkspaceRenderTests/testTranscriptionSheet'
```

Expected: all matched transcription-sheet render tests pass with zero failures.

- [ ] **Step 5: Run the directly affected render group and release compile**

Run:

```bash
swift test --disable-sandbox --filter 'RecorderWorkspaceRenderTests/testTranscrib|RecorderWorkspaceRenderTests/testUploadAudioIsDisabledWhileTranscriptionDraftIsPending'
swift build --disable-sandbox -c release
git diff --check
```

Expected: matched tests pass, the release build exits 0, and `git diff --check` prints no errors.

- [ ] **Step 6: Commit only the prompt UI and test**

```bash
git add -- Sources/RecorderApp/Views/TranscriptionRequestSheet.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git commit -m "fix: make transcription prompt field visible"
```

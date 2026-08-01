# Direction A Visual Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the production macOS 26 SwiftUI workspace visibly match the
approved PR #7 Direction A prototype while preserving every PR B owner,
command, presenter lifetime, and product behavior.

**Architecture:** The UI observes the four existing PR B feature boundaries
directly and adds only view-local presentation routing. Shared semantic surface
tokens drive a branded sidebar, dark Recordings/Provider canvases, and
system-adaptive Transcript/Meeting Intelligence canvases. `ContentView` keeps
sole ownership of the playback and Teams-countdown presenters, and canonical
Library snapshots remain the only session source.

**Tech Stack:** Swift 6, SwiftUI and AppKit on macOS 26.0, XCTest/AppKit-hosted
render tests, existing `RecorderGlass` and `RecorderMotionPolicy` primitives.

**Approved design:**
`docs/superpowers/specs/2026-08-01-direction-a-visual-alignment-design.md` at
`05ca6bb1181dbb80e79ae2dcbd693431ffd7a2e9` (Status: Approved).

## Global Constraints

- Implementation base is exactly
  `2313be2e40fbf6108c294d248596a6a0fcdaa053` from Draft PR #8.
- Work only in
  `/Users/apple/Documents/recorder/.worktrees/pr7-direction-a-visual-alignment`
  on `codex/pr7-direction-a-visual-alignment`.
- Keep this a stacked, presentation-only branch. Do not merge or mark PR #8
  Ready and do not start PR C.
- Do not modify `AppModel` ownership/composition, PR B features/bridges,
  repositories, publication, provider transport, Keychain, media, capture,
  Teams behavior, virtual microphone behavior, scripts, or Windows paths.
- Capture one Library snapshot, ASR presentation, and Meeting Intelligence
  snapshot per body evaluation. Never mirror their mutable state.
- Use the canonical Library session for every detail action and MI lookup.
- `ContentView` alone retains playback and Teams-countdown presenters.
- Never embed `AVPlayerView`, `VideoPlayer`, or `RecordingPlaybackView` in the
  workspace.
- Recordings and Provider are intentionally dark; Transcript/MI follow the
  macOS `colorScheme`. Do not add an application theme preference.
- Render only real product data. No fake waveform, speaker, timestamp, ASR
  percentage, storage capacity, provider success, transcript, or summary.
- Preserve every existing `RecorderActionID`, destination marker, floating
  panel marker, VoiceOver name, keyboard path, and Reduce Motion/Transparency
  behavior.
- Keep the recording panel 390×112 and Teams countdown 360×94 without changing
  their AppKit lifetime, position, focus, drag, close, or action semantics.

---

## File and responsibility map

| File | Responsibility in this plan |
| --- | --- |
| `Sources/RecorderApp/UI/RecorderVisualStyle.swift` | Direction A semantic palettes and surface identifiers only |
| `Sources/RecorderApp/ContentView.swift` | Pass canonical sidebar presentation; preserve presenter lifetimes and destination routing |
| `Sources/RecorderApp/UI/RecorderSidebar.swift` | Branded gradient, native navigation rows, real folder/warning storage card |
| `Sources/RecorderApp/UI/RecorderSettingsNavigation.swift` | New view-local Settings section enum and secondary rail |
| `Sources/RecorderApp/UI/RecorderSettingsView.swift` | Compose existing permission/capture/Teams/virtual-mic/provider controls into the secondary sections |
| `Sources/RecorderApp/Views/AIProviderSettingsView.swift` | Dark opaque provider form using the one injected model |
| `Sources/RecorderApp/UI/RecordingsPresentationRoute.swift` | Pure list/detail route resolution and fail-closed invalidation by canonical session ID |
| `Sources/RecorderApp/UI/RecordingSessionCardView.swift` | Dark expandable session card and existing session actions |
| `Sources/RecorderApp/UI/RecordingsLibraryView.swift` | One-snapshot filtering, toolbar, list/detail composition, metadata/trash sheets |
| `Sources/RecorderApp/UI/TranscriptDetailView.swift` | Extracted adaptive transcript header/playback/MI/editor/footer composition |
| `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift` | Approved opaque MI card styling over existing immutable presentation |
| Existing render/test files named below | RED/GREEN contracts; no second harness |

## Moved UI responsibility map

| Responsibility | Current source | Destination after this plan |
| --- | --- | --- |
| Workspace destination selection and presenter lifetime | `ContentView.swift` / `RecorderWorkspaceContent` | Remains in `ContentView.swift`; only sidebar inputs and destination surfaces change |
| Sidebar destination rows | `RecorderSidebar.swift` / `RecorderSidebar` | Same type/file, recomposed with brand and real workspace status card |
| Permission, capture, Teams, mute-sync, virtual-mic, provider, and workspace controls | One continuous `RecorderSettingsView.swift` form | Existing bindings/closures moved into section builders in the same file; `RecorderSettingsNavigation.swift` owns only the local section enum/rail |
| Provider profile form and draft bindings | `AIProviderSettingsView.swift` | Same type/file, dark opaque presentation only; same injected model instance |
| Session summary row and row actions | `RecordingsLibraryView.swift` / private `SessionListView` row body | `RecordingSessionCardView.swift` / `RecordingSessionCardView`; closures still originate in `RecordingsLibraryView` |
| Transcript sheet item routing | `RecordingsLibraryView.swift` / `transcriptSession` sheet state | `RecordingsLibraryView.swift` stores `RecordingsPresentationRoute`; `RecordingsPresentationRoute.swift` resolves only canonical IDs |
| Transcript detail wrapper, editor draft, action projection, save footer | `RecordingsLibraryView.swift` / `TranscriptDetailSheetView`, `TranscriptEditorDraft`, `TranscriptDetailActionProjection`, `TranscriptEditorView` | `TranscriptDetailView.swift`; names retained where tests depend on them, production wrapper renamed to `TranscriptDetailView` |
| Metadata editor and Trash confirmation | `RecordingsLibraryView.swift` | Remain in `RecordingsLibraryView.swift` as native sheet/dialog presentation |
| MI phase/actions/revision-driven feedback | `MeetingIntelligenceSectionView.swift` | Same type/file, token and layout changes only |
| Playback window presenter and Teams countdown presenter | `ContentView.swift` | Remain constructed and retained exactly once by `ContentView`; never moved into a destination |
| Floating recording/countdown panels | `RecordingControllerPanel.swift`, `TeamsAutoMeetingCountdownPanel.swift` | No source move or production edit; existing render suites are regression gates |

## Exact command parity

| UI action | Existing command that must remain exact |
| --- | --- |
| Record/Recordings/Settings navigation | `RecorderNavigationState.select(_:hasUnsavedChanges:)` |
| Upload Audio | `AppModel.chooseAudioFileForTranscription()` |
| Refresh Recordings | `AppModel.refreshSessions()` |
| Play session / transcript playback strip | `AppModel.play(session:)` through the retained external presenter |
| Open session folder | `AppModel.open(session:)` |
| Transcribe | `AppModel.transcribe(session:)` |
| Cancel ASR | `AppModel.cancelTranscription()` |
| View/Edit transcript detail | View-local `route = .transcript(session.id)`; re-resolve that ID from the canonical Library snapshot |
| Open transcript/log as files | `AppModel.openTranscript(for:)` / `openTranscriptLog(for:)` when those existing file-opening controls are exposed |
| Save transcript | `AppModel.saveTranscript(_:for:)` async outcome |
| Copy/export transcript | `AppModel.copyTranscript(for:)` / `exportTranscript(for:)` |
| Save metadata | `AppModel.saveMetadata(title:tags:isFavorite:for:)` async outcome |
| Trash | `AppModel.moveSessionToTrash(_:)` after existing confirmation |
| MI Check/Generate/Regenerate/Retry/Cancel/Apply | Existing `AppModel` `checkMeetingIntelligenceAvailability(for:)`, `generateMeetingIntelligence(for:)`, `regenerateMeetingIntelligence(for:)`, `retryMeetingIntelligenceGeneration(for:)`, `cancelMeetingIntelligence(for:)`, and `applyMeetingIntelligenceSuggestedTitle(for:)` façades with the canonical session |
| Permission grant/settings | `requestSystemAudioPermission()`, `requestMicrophonePermission()`, `openScreenCaptureSettings()`, `openMicrophoneSettings()` |
| Capture mode/app/mic | `selectCaptureMode(_:)`, `selectCaptureApplication(bundleIdentifier:)`, `refreshCaptureApplications()`, `reconnectSelectedApplication()`, `selectMicrophone(_:)` |
| Teams screen | `setTeamsScreenCaptureRequested(_:)` and `selectTeamsScreenCaptureWindow(_:)` |
| Auto Recording | `setTeamsAutoMeetingEnabled(_:)` and `cancelTeamsAutoMeetingCountdown()` |
| Mute Sync | `setTeamsMuteSyncEnabled(_:)`, `retryTeamsMuteSync()`, `requestTeamsPairing()` |
| Workspace folder | `chooseOutputFolder()` and existing `setOutputFolder(_:)` path |
| Provider kind/drafts | Existing bindings on `AppModel.aiProviderSettingsModel` |
| Provider Save/Test/Remove | `AIProviderSettingsModel.save()`, `testConnection()`, `removeAPIKey()` |

### Task 1: Semantic Direction A Surface Contract

**Files:**

- Modify: `Sources/RecorderApp/UI/RecorderVisualStyle.swift`
- Create: `Tests/RecorderAppTests/RecorderVisualStyleTests.swift`

**Interfaces:**

- Consumes: SwiftUI `ColorScheme`.
- Produces: `RecorderSurfaceAppearance`,
  `RecorderVisualStyle.transcriptAppearance(for:)`, semantic colors, and
  stable `accessibilityIdentifier` values used by every later render slice.

**Rollback commit:** `feat: define direction a surface tokens`

- [ ] **Step 1: Write the failing pure appearance tests**

```swift
import SwiftUI
import XCTest
@testable import RecorderApp

final class RecorderVisualStyleTests: XCTestCase {
    func testTranscriptAppearanceIsDistinctAcrossSystemSchemes() {
        XCTAssertEqual(
            RecorderVisualStyle.transcriptAppearance(for: .light),
            .transcriptLight
        )
        XCTAssertEqual(
            RecorderVisualStyle.transcriptAppearance(for: .dark),
            .transcriptDark
        )
        XCTAssertNotEqual(
            RecorderSurfaceAppearance.transcriptLight.accessibilityIdentifier,
            RecorderSurfaceAppearance.transcriptDark.accessibilityIdentifier
        )
    }

    func testFixedDarkSurfacesHaveStableIdentifiers() {
        XCTAssertEqual(
            RecorderSurfaceAppearance.recordingsDark.accessibilityIdentifier,
            "recorder.surface.recordings.dark"
        )
        XCTAssertEqual(
            RecorderSurfaceAppearance.providerDark.accessibilityIdentifier,
            "recorder.surface.provider.dark"
        )
    }

    func testContrastAppearanceAndHairlineStrengthAreSemantic() {
        XCTAssertEqual(
            RecorderVisualStyle.contrastAppearance(for: .standard),
            .standardContrast
        )
        XCTAssertEqual(
            RecorderVisualStyle.contrastAppearance(for: .increased),
            .increasedContrast
        )
        XCTAssertGreaterThan(
            RecorderVisualStyle.hairlineOpacity(for: .increased),
            RecorderVisualStyle.hairlineOpacity(for: .standard)
        )
    }
}
```

- [ ] **Step 2: Run the RED test**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderVisualStyleTests
```

Expected: FAIL because `RecorderSurfaceAppearance` and the appearance function
do not exist.

- [ ] **Step 3: Add the minimal semantic implementation**

```swift
import SwiftUI

enum RecorderSurfaceAppearance: String, Equatable, Sendable {
    case recordingsDark = "recordings.dark"
    case providerDark = "provider.dark"
    case transcriptLight = "transcript.light"
    case transcriptDark = "transcript.dark"
    case standardContrast = "contrast.standard"
    case increasedContrast = "contrast.increased"

    var accessibilityIdentifier: String {
        "recorder.surface.\(rawValue)"
    }
}

enum RecorderVisualStyle {
    static let systemAudio = Color.cyan
    static let microphone = Color.green
    static let recording = Color.red
    // Retain the existing neutral surface used by Record and any untouched
    // compatibility presentation during this stacked UI refactor.
    static let cardSurface = Color.secondary.opacity(0.08)
    static let accentCyan = Color(red: 0.098, green: 0.765, blue: 0.863)
    static let actionBlue = Color(red: 0.086, green: 0.471, blue: 0.933)
    static let success = Color(red: 0.145, green: 0.718, blue: 0.451)
    static let warning = Color(red: 0.941, green: 0.416, blue: 0.106)
    static let destructive = Color(red: 0.984, green: 0.376, blue: 0.353)
    static let recordingsCanvas = Color(red: 0.039, green: 0.078, blue: 0.173)
    static let recordingsCard = Color(red: 0.071, green: 0.114, blue: 0.235)
    static let providerCanvas = Color(red: 0.051, green: 0.086, blue: 0.125)
    static let transcriptLightCanvas = Color(red: 0.984, green: 0.984, blue: 0.992)
    static let transcriptLightCard = Color.white
    static let transcriptLightEditor = Color.white
    static let transcriptLightText = Color(red: 0.063, green: 0.082, blue: 0.153)
    static let transcriptLightSecondary = Color(red: 0.337, green: 0.373, blue: 0.471)
    static let transcriptLightHairline = Color(red: 0.875, green: 0.890, blue: 0.918)
    static let transcriptDarkCanvas = Color(red: 0.071, green: 0.094, blue: 0.141)
    static let transcriptDarkCard = Color(red: 0.094, green: 0.122, blue: 0.173)
    static let transcriptDarkEditor = Color(red: 0.078, green: 0.106, blue: 0.153)
    static let transcriptDarkText = Color(red: 0.949, green: 0.961, blue: 0.984)
    static let transcriptDarkSecondary = Color(red: 0.678, green: 0.714, blue: 0.780)
    static let transcriptDarkHairline = Color(red: 0.204, green: 0.239, blue: 0.306)

    static func transcriptAppearance(
        for colorScheme: ColorScheme
    ) -> RecorderSurfaceAppearance {
        colorScheme == .dark ? .transcriptDark : .transcriptLight
    }

    static func contrastAppearance(
        for contrast: ColorSchemeContrast
    ) -> RecorderSurfaceAppearance {
        contrast == .increased ? .increasedContrast : .standardContrast
    }

    static func hairlineOpacity(
        for contrast: ColorSchemeContrast
    ) -> Double {
        contrast == .increased ? 0.72 : 0.42
    }
}
```

Do not expose hex parsing or a persisted appearance preference.

- [ ] **Step 4: Run GREEN and diff checks**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderVisualStyleTests
git diff --check
```

Expected: all `RecorderVisualStyleTests` pass and no whitespace errors.

- [ ] **Step 5: Commit only this slice**

```bash
git add Sources/RecorderApp/UI/RecorderVisualStyle.swift \
  Tests/RecorderAppTests/RecorderVisualStyleTests.swift
git commit -m "feat: define direction a surface tokens"
```

### Task 2: Branded Workspace Sidebar

**Files:**

- Modify: `Sources/RecorderApp/ContentView.swift`
- Modify: `Sources/RecorderApp/UI/RecorderSidebar.swift`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- Verify without modification:
  `Tests/RecorderAppTests/RecorderWorkspaceStabilityTests.swift`

**Interfaces:**

- Consumes: existing `Binding<RecorderDestination>`, `AppModel.outputFolder`,
  and `AppModel.storageWarningMessage`.
- Produces: a branded sidebar with the existing navigation bindings and new
  passive markers `recorder.sidebar.brand` and `recorder.sidebar.storage`.

**Rollback commit:** `feat: add direction a workspace shell`

- [ ] **Step 1: Add failing 860×680 and wide shell tests**

Add to `RecorderWorkspaceRenderTests`:

```swift
func testDirectionASidebarRendersAtSupportedSizes() throws {
    for size in [
        CGSize(width: 860, height: 680),
        CGSize(width: 1_280, height: 800)
    ] {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(model: fixture.model, size: size)
        defer { host.close() }

        for identifier in [
            "recorder.workspace.sidebar",
            "recorder.sidebar.brand",
            "recorder.sidebar.storage",
            "recorder.navigation.record",
            "recorder.navigation.recordings",
            "recorder.navigation.settings"
        ] {
            let frame = try XCTUnwrap(
                host.frame(forAccessibilityIdentifier: identifier)
            )
            XCTAssertTrue(host.windowContentRect.contains(frame))
        }
    }
}
```

Add a semantic accessibility-appearance matrix:

```swift
func testDirectionASidebarUsesNativeGlassFallbackAndContrastMarkers() throws {
    let variants: [(Bool, ColorSchemeContrast, String, String)] = [
        (false, .standard,
         "recorder.glass.native", "recorder.surface.contrast.standard"),
        (true, .increased,
         "recorder.glass.material-separator",
         "recorder.surface.contrast.increased")
    ]
    for (reduceTransparency, contrast, glassID, contrastID) in variants {
        let fixture = makeStartupDisabledFixture()
        let host = try WorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680),
            reduceTransparencyOverride: reduceTransparency,
            contrast: contrast
        )
        defer { host.close() }
        XCTAssertTrue(host.containsAccessibilityIdentifier(glassID))
        XCTAssertTrue(host.containsAccessibilityIdentifier(contrastID))
    }
}
```

Add `reduceTransparencyOverride: Bool? = nil` and
`contrast: ColorSchemeContrast = .standard` to `WorkspaceHost.init`, store
them on `WorkspaceHostRoot`, and apply exactly:

```swift
RecorderWorkspaceContent(/* existing bindings */)
    .environment(
        \.recorderReduceTransparencyOverride,
        reduceTransparencyOverride
    )
    .environment(\.colorSchemeContrast, contrast)
```

Extend the existing repeated-navigation test to assert the brand and storage
markers still appear exactly once after every destination cycle. Keep the
presenter-pair assertions in `RecorderWorkspaceStabilityTests` unchanged.

- [ ] **Step 2: Run the RED shell suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceStabilityTests
```

Expected: the new marker assertions fail; existing navigation and presenter
lifetime tests remain green.

- [ ] **Step 3: Implement the branded sidebar without moving ownership**

Change the call site only to:

```swift
RecorderSidebar(
    selection: selection,
    outputFolder: model.outputFolder,
    storageWarning: model.storageWarningMessage
)
.navigationSplitViewColumnWidth(min: 185, ideal: 232, max: 278)
```

Implement `RecorderSidebar` as a native selection list inside a branded
container:

```swift
struct RecorderSidebar: View {
    @Binding var selection: RecorderDestination
    let outputFolder: URL
    let storageWarning: String?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
                .background(RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.sidebar.brand"
                ))
            List(RecorderDestination.allCases, selection: $selection) {
                destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
                    .accessibilityIdentifier(
                        "recorder.navigation.\(destination.rawValue)"
                    )
            }
            .listStyle(.sidebar)
            storageCard
                .background(RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.sidebar.storage"
                ))
        }
        .background(sidebarGradient)
        .background(RecorderDestinationAccessibilityMarker(
            identifier: RecorderVisualStyle
                .contrastAppearance(for: contrast)
                .accessibilityIdentifier
        ))
        .accessibilityIdentifier("recorder.workspace.sidebar")
    }
}
```

The brand uses Bundle version when available. The storage card renders the
real folder name and warning/ready copy only; do not query capacity or draw a
fake percentage. Apply `.recorderGlassSurface(.navigation)` only to the
storage card and use `RecorderVisualStyle.hairlineOpacity(for: contrast)` for
its semantic border. Leave `ContentView`'s presenter construction and
`onChange` lifecycle byte-for-byte unchanged.

- [ ] **Step 4: Run GREEN shell/stability tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceStabilityTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelPlaybackTests
```

Expected: all pass; playback remains outside the workspace and one presenter
pair remains retained.

- [ ] **Step 5: Commit the shell slice**

```bash
git add Sources/RecorderApp/ContentView.swift \
  Sources/RecorderApp/UI/RecorderSidebar.swift \
  Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git commit -m "feat: add direction a workspace shell"
```

### Task 3: Secondary Settings Navigation and Dark Provider Surface

**Files:**

- Create: `Sources/RecorderApp/UI/RecorderSettingsNavigation.swift`
- Modify: `Sources/RecorderApp/UI/RecorderSettingsView.swift`
- Modify: `Sources/RecorderApp/Views/AIProviderSettingsView.swift`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- Modify: `Tests/RecorderAppTests/AIProviderSettingsRenderTests.swift`

**Interfaces:**

- Consumes: one existing `AppModel` and its exact
  `aiProviderSettingsModel` instance.
- Produces: `RecorderSettingsSection` and stable navigation identifiers;
  every existing control remains backed by its current command.

**Rollback commit:** `feat: compose direction a settings`

- [ ] **Step 1: Write failing navigation/action-parity render tests**

Add a section matrix to `RecorderWorkspaceRenderTests`:

```swift
func testDirectionASettingsKeepsEveryExistingControlReachable() throws {
    let fixture = makeStartupDisabledFixture(
        systemPermission: .granted,
        microphonePermission: .granted
    )
    fixture.model.captureSelection = .init(
        mode: .selectedApplication,
        selectedBundleIdentifier: "com.example.capture"
    )
    let host = try makeWorkspaceHost(
        model: fixture.model,
        size: .init(width: 1_280, height: 800)
    )
    defer { host.close() }
    host.select(.settings)

    let expectedControls: [(String, [String])] = [
        ("audio", [
            "recorder.settings.capture-section",
            "recorder.settings.microphone-picker",
            "recorder.settings.audio-integration-section"
        ]),
        ("recording", [
            "capture-mode-picker",
            "recorder.settings.capture-application-picker",
            "recorder.settings.capture-refresh",
            "teams-auto-recording-toggle",
            "teams-auto-recording-status",
            "teams-mute-sync-status"
        ]),
        ("transcription", [
            "recorder.settings.transcription-profile-status"
        ]),
        ("ai-provider", [RecorderActionID.providerKind]),
        ("storage-shortcuts", [RecorderActionID.chooseOutputFolder])
    ]
    for (section, identifiers) in expectedControls {
        XCTAssertTrue(host.click(
            atAccessibilityFrame: "recorder.settings.navigation.\(section)"
        ))
        XCTAssertTrue(host.revealSettingsControl(
            "recorder.settings.section.\(section)"
        ))
        for identifier in identifiers {
            XCTAssertTrue(
                host.revealSettingsControl(identifier),
                "Unreachable \(section) control: \(identifier)"
            )
        }
    }
}
```

Add this exact helper to the existing `WorkspaceHost`; every identifier above
has an `NSView` marker in production:

```swift
func revealSettingsControl(_ identifier: String) -> Bool {
    guard let marker = view(forAccessibilityIdentifier: identifier)
        ?? view(forAccessibilityIdentifier: identifier + ".marker") else {
        return false
    }
    marker.scrollToVisible(marker.bounds)
    render()
    return windowContentRect.contains(marker.accessibilityFrame())
}
```

Update the existing Settings render tests in this file to select the matching
secondary section before checking their old identifiers. Keep the existing
conditional Teams-screen tests and assert their
`teams-screen-capture-toggle`, `teams-screen-capture-status`, and
`teams-screen-window-menu` identifiers under `.recording`; do not fabricate
those controls for a non-Teams capture selection.

Extend `AIProviderSettingsRenderTests` to render HKT and OpenAI-compatible
profiles at 860×680 and 1280×800 and assert:

```swift
host.selectSettingsSection("ai-provider")
XCTAssertTrue(host.reveal(RecorderActionID.providerKind))
XCTAssertTrue(host.reveal(
    RecorderSurfaceAppearance.providerDark.accessibilityIdentifier
))
```

Add this helper to the existing `ProviderSettingsProductionHost`; it uses the
same rendered-event path as `WorkspaceHost.click(atAccessibilityFrame:)`:

```swift
func selectSettingsSection(_ section: String) {
    let identifier = "recorder.settings.navigation.\(section)"
    guard let marker = marker(for: identifier) else {
        XCTFail("Missing settings navigation marker: \(identifier)")
        return
    }
    let location = marker.convert(
        NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
        to: nil
    )
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else {
            XCTFail("Could not create settings navigation event")
            return
        }
        window.sendEvent(event)
    }
    render()
}
```

For HKT, require Group ID and resolved URL and reject base URL. For generic,
require base URL and reject HKT-only fields. Keep every existing provider
Save/Test/Remove/ASR/LLM/language/prompt identifier reachable.

- [ ] **Step 2: Run the RED Settings suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AIProviderSettingsRenderTests
```

Expected: new secondary-navigation and provider-surface markers are missing.

- [ ] **Step 3: Add the view-local section contract**

```swift
enum RecorderSettingsSection: String, CaseIterable, Identifiable {
    case audio
    case recording
    case transcription
    case aiProvider = "ai-provider"
    case storageShortcuts = "storage-shortcuts"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Audio"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .aiProvider: "AI Provider"
        case .storageShortcuts: "Storage & Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: "speaker.wave.2"
        case .recording: "record.circle"
        case .transcription: "text.bubble"
        case .aiProvider: "sparkles"
        case .storageShortcuts: "internaldrive"
        }
    }
}
```

These projections own no persisted state and import no repositories.

- [ ] **Step 4: Recompose existing controls without duplicating them**

`RecorderSettingsView` retains exactly one `@ObservedObject var model` and one
view-local selection:

```swift
@State private var selectedSection: RecorderSettingsSection = .audio

var body: some View {
    HStack(spacing: 0) {
        settingsRail
        Divider()
        selectedSectionContent
    }
    .background(RecorderDestinationAccessibilityMarker(
        identifier: "recorder.destination.settings"
    ))
}
```

The rail is a native selection list with stable markers:

```swift
private var settingsRail: some View {
    List(RecorderSettingsSection.allCases, selection: $selectedSection) {
        section in
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
            .accessibilityIdentifier(
                "recorder.settings.navigation.\(section.rawValue)"
            )
            .background(RecorderDestinationAccessibilityMarker(
                identifier:
                    "recorder.settings.navigation.\(section.rawValue).marker"
            ))
    }
    .listStyle(.sidebar)
    .frame(minWidth: 176, idealWidth: 210, maxWidth: 240)
}

@ViewBuilder
private var selectedSectionContent: some View {
    switch selectedSection {
    case .audio:
        sectionSurface(.audio) { audioSectionContent }
    case .recording:
        sectionSurface(.recording) { recordingSectionContent }
    case .transcription:
        sectionSurface(.transcription) { transcriptionSectionContent }
    case .aiProvider:
        sectionSurface(.aiProvider) {
            AIProviderSettingsView(model: model.aiProviderSettingsModel)
        }
    case .storageShortcuts:
        sectionSurface(.storageShortcuts) {
            storageAndShortcutsSectionContent
        }
    }
}

private func sectionSurface<Content: View>(
    _ section: RecorderSettingsSection,
    @ViewBuilder content: () -> Content
) -> some View {
    ScrollView {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
    }
    .background(RecorderDestinationAccessibilityMarker(
        identifier: "recorder.settings.section.\(section.rawValue)"
    ))
    .accessibilityIdentifier(
        "recorder.settings.section.\(section.rawValue)"
    )
}
```

Extract the current source blocks without changing their bindings or action
closures, using this exact ownership mapping:

- Audio: permission rows, microphone picker, Virtual Mic;
- Recording: capture mode/app, Teams screen, Auto Recording, Mute Sync;
- Transcription: explanatory status that points to the selected provider and
  contains no second editable profile; attach
  `recorder.settings.transcription-profile-status`;
- AI Provider: exactly
  `AIProviderSettingsView(model: model.aiProviderSettingsModel)`;
- Storage & Shortcuts: real `model.outputFolder` and
  `model.chooseOutputFolder` using `RecorderActionID.chooseOutputFolder`.

Attach the existing section identifiers to their moved content so old tests
and VoiceOver automation remain valid.

- [ ] **Step 5: Apply the dark Provider presentation**

Use opaque Direction A form cards and attach:

```swift
.providerAccessibility(
    RecorderSurfaceAppearance.providerDark.accessibilityIdentifier
)
.preferredColorScheme(.dark)
```

The provider picker and every binding/action remain unchanged. Do not create a
new `AIProviderSettingsModel`, repository, credential draft, or connection
status. The fixed dark appearance is presentation-only.

- [ ] **Step 6: Run GREEN Settings and composition suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AIProviderSettingsRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelPRBFeatureBoundaryTests
```

Expected: all pass; provider composition identity tests prove the UI did not
replace the shared repository/model.

- [ ] **Step 7: Commit the Settings slice**

```bash
git add Sources/RecorderApp/UI/RecorderSettingsNavigation.swift \
  Sources/RecorderApp/UI/RecorderSettingsView.swift \
  Sources/RecorderApp/Views/AIProviderSettingsView.swift \
  Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift \
  Tests/RecorderAppTests/AIProviderSettingsRenderTests.swift
git commit -m "feat: compose direction a settings"
```

### Task 4: Deep-Navy Recording Cards and Fail-Closed Detail Route

**Files:**

- Create: `Sources/RecorderApp/UI/RecordingsPresentationRoute.swift`
- Create: `Sources/RecorderApp/UI/RecordingSessionCardView.swift`
- Create: `Sources/RecorderApp/UI/TranscriptDetailView.swift`
- Modify: `Sources/RecorderApp/UI/RecordingsLibraryView.swift`
- Create: `Tests/RecorderAppTests/RecordingsPresentationRouteTests.swift`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- Modify: `Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift`

**Interfaces:**

- Consumes: one captured `LibraryFeatureSnapshot`, one ASR presentation, and
  one MI snapshot per body.
- Produces: `RecordingsPresentationRoute.list` or
  `.transcript(RecordingSession.ID)` and a card view that routes only existing
  closures.

**Rollback commit:** `feat: align recordings library cards`

- [ ] **Step 1: Write RED pure route tests**

```swift
import XCTest
@testable import RecorderApp

@MainActor
final class RecordingsPresentationRouteTests: XCTestCase {
    func testTranscriptRouteResolvesOnlyExactCanonicalSessionID() {
        let session = makeSession(title: "Canonical")
        let route = RecordingsPresentationRoute.transcript(session.id)
        XCTAssertEqual(route.resolvedSession(in: [session])?.id, session.id)
        XCTAssertNil(route.resolvedSession(in: []))
    }

    func testInvalidationClearsMissingSessionAndRejectsSameNameReplacement() {
        let original = makeSession(title: "Shared title")
        let replacement = makeSession(title: "Shared title")
        var route = RecordingsPresentationRoute.transcript(original.id)
        route.invalidateIfMissing(from: [replacement])
        XCTAssertEqual(route, .list)
    }

    func testCapturedActionRevalidatesCanonicalSessionAtInvocationTime() {
        let original = makeSession(title: "Original")
        var currentSessions = [original]
        var invokedIDs: [RecordingSession.ID] = []
        let admission = RecordingsCanonicalActionAdmission {
            currentSessions
        }
        let capturedAction = {
            admission.perform(sessionID: original.id) {
                invokedIDs.append($0.id)
            }
        }

        XCTAssertTrue(capturedAction())
        currentSessions = []
        XCTAssertFalse(capturedAction())
        XCTAssertEqual(invokedIDs, [original.id])
    }

    func testCapturedActionRejectsSameNameReplacementWithDifferentID() {
        let original = makeSession(title: "Shared title")
        let replacement = makeSession(title: "Shared title")
        var currentSessions = [original]
        var writes = 0
        let admission = RecordingsCanonicalActionAdmission {
            currentSessions
        }
        let capturedAction = {
            admission.perform(sessionID: original.id) { _ in writes += 1 }
        }

        currentSessions = [replacement]
        XCTAssertFalse(capturedAction())
        XCTAssertEqual(writes, 0)
    }

    private func makeSession(title: String) -> RecordingSession {
        let folder = URL(
            fileURLWithPath: "/tmp/recordings-route-\(UUID().uuidString)"
        )
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 60,
            fileSize: 1_024,
            metadata: .init(title: title)
        )
    }
}
```

The helper creates URL values only and writes no filesystem artifact.

- [ ] **Step 2: Run the RED route test**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingsPresentationRouteTests
```

Expected: FAIL because the route type does not exist.

- [ ] **Step 3: Implement the pure fail-closed route**

```swift
enum RecordingsPresentationRoute: Equatable {
    case list
    case transcript(RecordingSession.ID)

    func resolvedSession(
        in sessions: [RecordingSession]
    ) -> RecordingSession? {
        guard case let .transcript(id) = self else { return nil }
        return sessions.first { $0.id == id }
    }

    mutating func invalidateIfMissing(from sessions: [RecordingSession]) {
        guard case .transcript = self,
              resolvedSession(in: sessions) == nil else { return }
        self = .list
    }
}

@MainActor
struct RecordingsCanonicalActionAdmission {
    let currentSessions: () -> [RecordingSession]

    init(currentSessions: @escaping () -> [RecordingSession]) {
        self.currentSessions = currentSessions
    }

    func canonicalSession(
        for sessionID: RecordingSession.ID
    ) -> RecordingSession? {
        currentSessions().first { $0.id == sessionID }
    }

    @discardableResult
    func perform(
        sessionID: RecordingSession.ID,
        action: (RecordingSession) -> Void
    ) -> Bool {
        guard let session = canonicalSession(for: sessionID) else {
            return false
        }
        action(session)
        return true
    }

    func save(
        sessionID: RecordingSession.ID,
        artifact: LibraryEditableArtifact,
        action: (RecordingSession) async -> LibrarySaveOutcome
    ) async -> LibrarySaveOutcome {
        guard let session = canonicalSession(for: sessionID) else {
            return .failed(
                sessionID: sessionID,
                artifact,
                "The recording is no longer available."
            )
        }
        return await action(session)
    }

    @discardableResult
    func performAsync(
        sessionID: RecordingSession.ID,
        action: (RecordingSession) async -> Void
    ) async -> Bool {
        guard let session = canonicalSession(for: sessionID) else {
            return false
        }
        await action(session)
        return true
    }
}
```

The production view creates the admission boundary with
`{ libraryFeature.snapshot.sessions }`. Every Play, Open Folder, Edit,
Transcribe, Transcript route, Trash, log, transcript Save, and MI command
captures only the session ID and resolves through this boundary at invocation
time. This is a read-only command fence over the canonical owner, not a
mirrored session array.

- [ ] **Step 4: Add the failing production render test**

Add this flow to `RecorderWorkspaceRenderTests` using the existing
`RecordingsMeetingIntelligenceRenderFixture` (it owns a real temporary
transcript and removes it in `remove()`) and `WorkspaceHost`:

```swift
func testDirectionARecordingsOpensCanonicalDetailAndFailsClosedWhenRemoved()
throws {
    let fixture = try RecordingsMeetingIntelligenceRenderFixture()
    defer { fixture.remove() }
    let host = try makeWorkspaceHost(
        model: fixture.model,
        size: .init(width: 860, height: 680)
    )
    defer { host.close() }
    host.select(.recordings)

    XCTAssertTrue(host.containsAccessibilityIdentifier(
        RecorderSurfaceAppearance.recordingsDark.accessibilityIdentifier
    ))
    let rowID = fixture.session.id.lastPathComponent
    XCTAssertTrue(host.click(
        atAccessibilityFrame: "recorder.row.transcript.\(rowID)"
    ))
    XCTAssertTrue(host.containsAccessibilityIdentifier(
        "recorder.transcript.detail.root"
    ))
    XCTAssertFalse(host.containsView(named: "AVPlayerView"))
    XCTAssertTrue(host.replaceTranscriptEditorText(with: "Unsaved route draft"))
    XCTAssertEqual(host.transcriptEditorText, "Unsaved route draft")

    fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
        [], workspace: fixture.model.outputFolder, fence: .initial
    )
    host.render()
    XCTAssertTrue(host.containsAccessibilityIdentifier(
        "recorder.recordings.list"
    ))
    XCTAssertFalse(host.containsAccessibilityIdentifier(
        RecorderActionID.saveTranscript
    ))
    XCTAssertFalse(host.containsAccessibilityIdentifier(
        RecorderActionID.meetingIntelligenceCard
    ))
    XCTAssertFalse(host.click(
        atAccessibilityFrame: "recorder.row.transcript.\(rowID)"
    ))

    fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
        [fixture.session], workspace: fixture.workspace, fence: .initial
    )
    host.render()
    XCTAssertTrue(host.click(
        atAccessibilityFrame: "recorder.row.transcript.\(rowID)"
    ))
    try waitUntil(timeout: 1) {
        host.transcriptEditorText == "Production recordings transcript"
    }
}
```

Before publishing the empty snapshot, set the editor to `"Unsaved route
draft"` through the production `TextEditor`. Re-adding and reopening the same
canonical session must load `"Production recordings transcript"`, as above,
which proves the removed detail destroyed its view-local draft. Add these
helpers to `WorkspaceHost`:

```swift
@discardableResult
func replaceTranscriptEditorText(with text: String) -> Bool {
    guard let root = view(
        forAccessibilityIdentifier: "recorder.transcript.editor"
    ), let editor = allViews(startingAt: root)
        .compactMap({ $0 as? NSTextView }).first else {
        return false
    }
    editor.string = text
    editor.didChangeText()
    render()
    return true
}

var transcriptEditorText: String? {
    guard let root = view(
        forAccessibilityIdentifier: "recorder.transcript.editor"
    ) else { return nil }
    return allViews(startingAt: root)
        .compactMap { $0 as? NSTextView }.first?.string
}
```

Extend `RecordingsMeetingIntelligenceRenderFixture.init` with
`mutationGate: RecordingSessionMutationGate? = nil`. When supplied, construct
and inject this exact Library boundary so the AppModel-created ASR and MI
boundaries receive the same gate through the existing individual-injection
compatibility path:

```swift
let injectedLibraryFeature = mutationGate.map { gate in
    LibraryFeatureModel(
        sessionLoader: { _ in [] },
        sessionReloader: { $0 },
        searchDocumentLoader: { session in
            RecordingLibrarySearchDocument.load(
                folderURL: session.folderURL,
                displayName: session.displayName,
                createdAt: session.createdAt,
                metadata: session.metadata
            )
        },
        recovery: { _ in },
        trashHandler: { _ in true },
        mutationGate: gate
    )
}

model = AppModel(
    defaults: defaults,
    providerRepository: providerRepository,
    inputDevices: { [] },
    defaultInputDeviceID: { nil },
    performStartupWork: false,
    initialOutputFolder: workspace,
    libraryFeature: injectedLibraryFeature,
    meetingIntelligenceFeatureFactory: { repository, sourceID, gate in
        let coordinator = MeetingIntelligenceJobCoordinator(
            providerRepository: repository,
            expectedPublicationSourceID: sourceID,
            mutationGate: gate,
            transcriptReader:
                RenderMeetingIntelligenceTranscriptReader(snapshot: transcript),
            availabilityChecker: RenderMeetingIntelligenceAvailability(),
            generator: generator,
            publisher:
                RenderMeetingIntelligencePublisher(published: published),
            artifactStore: RenderMeetingIntelligenceArtifactStore(),
            stateStore: RenderMeetingIntelligenceStateStore()
        )
        let feature = MeetingIntelligenceFeatureModel(
            coordinator: coordinator
        )
        retainedCoordinator = coordinator
        retainedFeature = feature
        return feature
    }
)
```

Add the real inline-route late-save integration. It blocks the shared mutation
gate only after the save has been admitted, removes the canonical session,
then proves the eventual completion cannot recreate the detail:

```swift
func testInFlightSaveCannotReopenInvalidatedRecordingsDetail() async throws {
    let mutationAttempt = DispatchSemaphore(value: 0)
    let releaseMutation = DispatchSemaphore(value: 0)
    let holderEntered = DispatchSemaphore(value: 0)
    let gate = RecordingSessionMutationGate {
        mutationAttempt.signal()
    }
    let fixture = try RecordingsMeetingIntelligenceRenderFixture(
        mutationGate: gate
    )
    defer {
        releaseMutation.signal()
        fixture.remove()
    }
    let folder = fixture.session.folderURL
    let holder = Task.detached {
        gate.withMutation(for: folder) {
            holderEntered.signal()
            releaseMutation.wait()
        }
    }
    XCTAssertEqual(holderEntered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(mutationAttempt.wait(timeout: .now() + 1), .success)

    let host = try makeWorkspaceHost(
        model: fixture.model,
        size: .init(width: 860, height: 680)
    )
    defer { host.close() }
    host.select(.recordings)
    let rowID = fixture.session.id.lastPathComponent
    XCTAssertTrue(host.click(
        atAccessibilityFrame: "recorder.row.transcript.\(rowID)"
    ))
    XCTAssertTrue(host.replaceTranscriptEditorText(
        with: "Durable in-flight transcript"
    ))
    XCTAssertTrue(host.click(
        atAccessibilityFrame: RecorderActionID.saveTranscript
    ))
    try waitUntil(timeout: 1) {
        host.containsAccessibilityIdentifier(
            RecorderActionID.transcriptSaveInFlight
        )
    }
    try waitUntil(timeout: 1) {
        mutationAttempt.wait(timeout: .now()) == .success
    }

    fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
        [], workspace: fixture.workspace, fence: .initial
    )
    try waitUntil(timeout: 1) {
        host.containsAccessibilityIdentifier("recorder.recordings.list")
            && !host.containsAccessibilityIdentifier(
                "recorder.transcript.detail.root"
            )
    }

    releaseMutation.signal()
    await holder.value
    try waitUntil(timeout: 2) {
        (try? TranscriptDocumentStore.read(in: folder))
            == "Durable in-flight transcript"
    }
    XCTAssertTrue(host.containsAccessibilityIdentifier(
        "recorder.recordings.list"
    ))
    XCTAssertFalse(host.containsAccessibilityIdentifier(
        "recorder.transcript.detail.root"
    ))

    fixture.model.libraryFeature.seedCanonicalSessionsForTesting(
        [fixture.session], workspace: fixture.workspace, fence: .initial
    )
    host.render()
    XCTAssertTrue(host.click(
        atAccessibilityFrame: "recorder.row.transcript.\(rowID)"
    ))
    try waitUntil(timeout: 1) {
        host.transcriptEditorText
            == (try? TranscriptDocumentStore.read(in: folder))
    }
}
```

The reopened text is read from the canonical durable transcript, whatever the
Library save path admitted before removal; no stale SwiftUI draft or late
completion can restore the old detail route.

Also add a two-session card test. Seed a second in-memory `RecordingSession`
under `fixture.workspace`, click `recorder.row.card.<firstID>`, then
`recorder.row.card.<secondID>`, and assert this exact sequence:

```swift
XCTAssertFalse(host.containsAccessibilityIdentifier(
    "recorder.row.expanded.\(firstID)"
))
XCTAssertTrue(host.click(
    atAccessibilityFrame: "recorder.row.card.\(firstID)"
))
XCTAssertTrue(host.containsAccessibilityIdentifier(
    "recorder.row.expanded.\(firstID)"
))
XCTAssertFalse(host.containsAccessibilityIdentifier(
    "recorder.row.expanded.\(secondID)"
))
XCTAssertTrue(host.click(
    atAccessibilityFrame: "recorder.row.card.\(secondID)"
))
XCTAssertFalse(host.containsAccessibilityIdentifier(
    "recorder.row.expanded.\(firstID)"
))
XCTAssertTrue(host.containsAccessibilityIdentifier(
    "recorder.row.expanded.\(secondID)"
))
```

The pure admission tests prove a closure captured before invalidation cannot
invoke a playback, metadata, save, or MI command afterward; the integration
test proves the stale detail and its draft disappear.

- [ ] **Step 5: Render one filtered array and expandable cards**

Change the outer body to capture exact immutable projections:

```swift
let librarySnapshot = libraryFeature.snapshot
let transcription = transcriptionFeature.presentation
let meetingIntelligenceSnapshot = meetingIntelligenceFeature.snapshot
let visibleSessions = RecordingLibraryQuery(
    text: searchText,
    favoritesOnly: favoritesOnly
).filter(librarySnapshot.sessions)
```

Do not use `libraryFeature.sessions` again during the body. Replace the inset
row with `ScrollView` + `LazyVStack` cards. `RecordingSessionCardView` accepts
one session and the existing action closures. It exposes an `Expanded` or
`Collapsed` accessibility value and preserves every session-specific row
marker. Use `ViewThatFits(in: .horizontal)` for labeled versus icon-only action
strips so 860×680 never clips an action.

The parent owns exactly one expansion identity:

```swift
@State private var expandedSessionID: RecordingSession.ID?

private func expansionBinding(
    for sessionID: RecordingSession.ID
) -> Binding<Bool> {
    Binding(
        get: { expandedSessionID == sessionID },
        set: { expandedSessionID = $0 ? sessionID : nil }
    )
}
```

Pass that binding to every card. The card header exposes
`recorder.row.card.<id>` and the action strip exists only while expanded with
`recorder.row.expanded.<id>`. When a canonical publication removes the
expanded session, set `expandedSessionID = nil` in the same invalidation pass.

- [ ] **Step 6: Compose list/detail with a session-ID route**

First move `TranscriptDetailSheetView`, `TranscriptEditorDraft`,
`TranscriptDetailActionProjection`, and `TranscriptEditorView` from
`RecordingsLibraryView.swift` into `TranscriptDetailView.swift`. Rename the
production wrapper to `TranscriptDetailView`; update the one production and
one `MeetingIntelligenceSheetRenderTests` direct construction. Add an explicit
`close` closure to the production wrapper and an optional `close` parameter to
`TranscriptEditorView` so its existing direct test initializers remain source
compatible. Back, Cancel, and a successful expected-session Save use the
explicit close when present and otherwise fall back to `dismiss()`.

Use:

```swift
@State private var route: RecordingsPresentationRoute = .list
@State private var expandedSessionID: RecordingSession.ID?
@State private var metadataSession: RecordingSession?
@State private var sessionPendingTrash: RecordingSession?

private var actionAdmission: RecordingsCanonicalActionAdmission {
    RecordingsCanonicalActionAdmission {
        libraryFeature.snapshot.sessions
    }
}

@ViewBuilder
private func content(allSessions: [RecordingSession]) -> some View {
    switch route {
    case .list:
        recordingsList
    case .transcript:
        if let session = route.resolvedSession(in: allSessions) {
            TranscriptDetailView(
                openedSession: session,
                allSessions: allSessions,
                close: { route = .list },
                load: { transcriptText(session) },
                save: { text in
                    await actionAdmission.save(
                        sessionID: session.id,
                        artifact: .transcript
                    ) { await saveTranscript(text, $0) }
                },
                openFolder: {
                    _ = actionAdmission.perform(
                        sessionID: session.id, action: open
                    )
                },
                play: {
                    _ = actionAdmission.perform(
                        sessionID: session.id, action: play
                    )
                },
                export: {
                    _ = actionAdmission.perform(
                        sessionID: session.id, action: exportTranscript
                    )
                },
                copy: {
                    _ = actionAdmission.perform(
                        sessionID: session.id, action: copyTranscript
                    )
                },
                editDetails: { requested in
                    _ = actionAdmission.perform(sessionID: requested.id) {
                        metadataSession = $0
                    }
                },
                meetingIntelligencePresentation:
                    meetingIntelligencePresentation,
                meetingIntelligenceObservedSnapshot:
                    meetingIntelligenceObservedSnapshot,
                checkMeetingIntelligenceAvailability: { requested in
                    _ = actionAdmission.perform(sessionID: requested.id,
                        action: checkMeetingIntelligenceAvailability)
                },
                generateMeetingIntelligence: { requested in
                    _ = actionAdmission.perform(sessionID: requested.id,
                        action: generateMeetingIntelligence)
                },
                regenerateMeetingIntelligence: { requested in
                    _ = actionAdmission.perform(sessionID: requested.id,
                        action: regenerateMeetingIntelligence)
                },
                retryMeetingIntelligenceGeneration: { requested in
                    _ = actionAdmission.perform(sessionID: requested.id,
                        action: retryMeetingIntelligenceGeneration)
                },
                cancelMeetingIntelligence: { requested in
                    _ = actionAdmission.perform(sessionID: requested.id,
                        action: cancelMeetingIntelligence)
                },
                applyMeetingIntelligenceSuggestedTitle: { requested in
                    _ = actionAdmission.perform(sessionID: requested.id,
                        action: applyMeetingIntelligenceSuggestedTitle)
                }
            )
        }
    }
}
```

These four presentation states move from the current private
`SessionListView` into `RecordingsLibraryView`; delete `transcriptSession` and
replace it with `route`. Keep any extracted list/card child stateless except
for bindings supplied by this parent. This is presentation composition only
and does not mirror a feature snapshot.

Wrap card actions through the same `actionAdmission`; for Trash use
`performAsync`, and for metadata Save use `save(... artifact: .metadata)`.
The Transcript button first admits the row ID, then sets
`route = .transcript(canonical.id)`.

On `librarySnapshot.revision` changes run one MainActor invalidation function:

```swift
private func invalidatePresentation(
    using sessions: [RecordingSession]
) {
    route.invalidateIfMissing(from: sessions)
    if let expandedSessionID,
       !sessions.contains(where: { $0.id == expandedSessionID }) {
        self.expandedSessionID = nil
    }
    if let metadataSession,
       !sessions.contains(where: { $0.id == metadataSession.id }) {
        self.metadataSession = nil
    }
    if let sessionPendingTrash,
       !sessions.contains(where: { $0.id == sessionPendingTrash.id }) {
        self.sessionPendingTrash = nil
    }
}
```

Destroying the detail view clears its draft/save state. Metadata editing and
Trash confirmation remain native sheets/dialogs. Search and Favorites apply
only to the list; a filter never invalidates a canonical detail that still
exists in the unfiltered snapshot.

- [ ] **Step 7: Run GREEN Library/route/render suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingsPresentationRouteTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingLibraryQueryTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter LibraryFeatureModelTests
```

Expected: one-snapshot filtering, snippets, Favorites, route invalidation, and
all existing actions pass.

- [ ] **Step 8: Commit the Recordings slice**

```bash
git add Sources/RecorderApp/UI/RecordingsPresentationRoute.swift \
  Sources/RecorderApp/UI/RecordingSessionCardView.swift \
  Sources/RecorderApp/UI/TranscriptDetailView.swift \
  Sources/RecorderApp/UI/RecordingsLibraryView.swift \
  Tests/RecorderAppTests/RecordingsPresentationRouteTests.swift \
  Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift \
  Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift
git commit -m "feat: align recordings library cards"
```

### Task 5: Adaptive Transcript and Meeting Intelligence Detail

**Files:**

- Modify: `Sources/RecorderApp/UI/TranscriptDetailView.swift`
- Modify: `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift`
- Modify: `Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift`
- Modify: `Tests/RecorderAppTests/MeetingIntelligenceSectionRenderTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelPlaybackTests.swift`

**Interfaces:**

- Consumes: canonical session, async save closure, existing external-playback
  command, one MI presentation and one observed snapshot.
- Produces: `TranscriptDetailView` with explicit `close` command and system
  appearance marker; no new player, feature model, or durable state.

**Rollback commit:** `feat: align transcript intelligence detail`

- [ ] **Step 1: Add failing light/dark and layout render tests**

For each size and color scheme:

```swift
for size in [
    CGSize(width: 860, height: 680),
    CGSize(width: 1_280, height: 800)
] {
    for scheme in [ColorScheme.light, .dark] {
        let openedSession = session()
        let readyPresentation = MeetingIntelligencePresentation(
            phase: .ready,
            summary: "A concise meeting summary.",
            suggestedTitle: "Atlas planning",
            statusMessage: "Ready.",
            model: "test-model",
            titleIsProtected: false,
            unavailableReason: nil
        )
        let root = TranscriptDetailView(
            openedSession: openedSession,
            allSessions: [openedSession],
            close: {},
            load: { "Draft transcript" },
            save: { _ in
                .saved(sessionID: openedSession.id, .transcript)
            },
            openFolder: {},
            play: {},
            export: {},
            copy: {},
            editDetails: { _ in },
            meetingIntelligencePresentation: { _ in readyPresentation },
            meetingIntelligenceObservedSnapshot: { _ in nil },
            checkMeetingIntelligenceAvailability: { _ in },
            generateMeetingIntelligence: { _ in },
            regenerateMeetingIntelligence: { _ in },
            retryMeetingIntelligenceGeneration: { _ in },
            cancelMeetingIntelligence: { _ in },
            applyMeetingIntelligenceSuggestedTitle: { _ in }
        )
        .environment(\.colorScheme, scheme)
        let host = try SheetRenderHost(size: size, root: root)
        defer { host.close() }
        let appearance = RecorderVisualStyle.transcriptAppearance(for: scheme)
        XCTAssertTrue(host.contains(appearance.accessibilityIdentifier))
        XCTAssertTrue(host.contains(RecorderActionID.saveTranscript))
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceCard))
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
    }
}
```

Update `testTranscriptDetailSourceDoesNotDeclareEmbeddedPlaybackViews` to read
both `RecordingsLibraryView.swift` and the new `TranscriptDetailView.swift`,
then reject `AVPlayerView`, `VideoPlayer`, and `RecordingPlaybackView` from
each source string.

Extend the phase matrix to keep Generate/Check Again, working/Cancel,
ready/Regenerate, recovery/Retry, and manual/Apply mutually exclusive. Preserve
the existing non-ready→ready and Reduce Motion feedback tests.

- [ ] **Step 2: Run the RED Transcript/MI suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceSheetRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceSectionRenderTests
```

Expected: adaptive surface identifiers and the new inline close contract are
missing; existing MI behavior remains green.

- [ ] **Step 3: Preserve the extracted editor lifetime contract**

Task 4 already extracted the production wrapper and editor types. Confirm
`rg -n "TranscriptDetailSheetView" Sources Tests` returns no match. Keep the
direct `TranscriptEditorView` test initializers source-compatible with the
optional fallback to the SwiftUI dismiss environment:

```swift
let close: (() -> Void)?
@Environment(\.dismiss) private var dismiss

private func closeDetail() {
    if let close { close() } else { dismiss() }
}
```

Back, Cancel, and successful expected-session Save call `closeDetail()`.
Failure and stale outcomes retain the draft and do not close. Keep
`LibraryEditorSaveState` generation/admission logic unchanged.

- [ ] **Step 4: Apply approved adaptive, opaque hierarchy**

Read `@Environment(\.colorScheme)` once at the detail boundary and attach the
matching passive marker:

```swift
let appearance = RecorderVisualStyle.transcriptAppearance(for: colorScheme)

VStack(spacing: 0) {
    header
    ScrollView {
        playbackControls
        MeetingIntelligenceSectionView(...)
        transcriptEditor
    }
    footer
}
.background(transcriptCanvas)
.background(RecorderDestinationAccessibilityMarker(
    identifier: appearance.accessibilityIdentifier
))
```

Use fixed header/footer and a scrollable middle. The playback strip retains
only `play()` and the exact copy “Play in separate window.” Style the MI card
with opaque card/hairline tokens while preserving `RecorderObservedSnapshot`
feedback and every action ID.

- [ ] **Step 5: Run GREEN editor, MI, playback, and save suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceSheetRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceSectionRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter LibraryEditorSaveStateTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelMeetingIntelligenceIntegrationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelPlaybackTests
```

Expected: all pass; light/dark markers differ; save failure/in-flight behavior
and canonical title ownership remain unchanged; no player view is embedded.

- [ ] **Step 6: Commit the Transcript/MI slice**

```bash
git add Sources/RecorderApp/UI/TranscriptDetailView.swift \
  Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift \
  Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift \
  Tests/RecorderAppTests/MeetingIntelligenceSectionRenderTests.swift \
  Tests/RecorderAppTests/AppModelPlaybackTests.swift
git commit -m "feat: align transcript intelligence detail"
```

### Task 6: Floating-Window Non-Regression, Full Gate, and Staging Evidence

**Files:**

- Verify without modification:
  `Tests/RecorderAppTests/RecordingControllerRenderTests.swift`
- Verify without modification:
  `Tests/RecorderAppTests/TeamsAutoMeetingCountdownRenderTests.swift`
- Modify: `docs/superpowers/plans/2026-08-01-direction-a-visual-alignment.md`

**Interfaces:**

- Consumes: final UI head.
- Produces: automated evidence, path-scope proof, manual visual checklist, and
  a clean branch. No new product code is expected in this task.

**Rollback commit:** `test: complete direction a visual regression gate`

- [ ] **Step 1: Run all focused presentation suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderVisualStyleTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecorderWorkspaceStabilityTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AIProviderSettingsRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingsPresentationRouteTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceSectionRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceSheetRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelPlaybackTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingControllerRenderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TeamsAutoMeetingCountdownRenderTests
```

Expected: every suite passes with zero failures.

- [ ] **Step 2: Prove floating presentation behavior stayed unchanged**

Run the existing fixed-size, action-admission, Reduce Motion, Reduce
Transparency, and exact-once presenter suites. Do not modify floating source
files to fix a workspace-only visual test. If a test genuinely exposes a
presentation regression, first add the smallest RED case and preserve:

- 390×112 recording bounds;
- 360×94 countdown bounds;
- non-activating/cross-Space/drag behavior;
- Stop, screen toggle, countdown Cancel exact routing;
- finalizing controls disabled;
- ContentView-only countdown presenter ownership.

- [ ] **Step 3: Run the complete macOS 26 repository gate**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py' -v
Tests/PackagingTests/run-tests.sh
Tests/VirtualMicDriverTests/run-tests.sh
Tests/VirtualMicDriverTests/run-bundle-tests.sh
Tests/VirtualMicDriverTests/run-script-tests.sh
git diff --check 2313be2e40fbf6108c294d248596a6a0fcdaa053...HEAD
```

Expected: all commands pass. The VirtualMic gate requires no installed staging
app or stray XCTest process to hold its exclusive resources.

- [ ] **Step 4: Enforce the presentation-only path allowlist**

```bash
set -o pipefail
git diff --name-only \
  2313be2e40fbf6108c294d248596a6a0fcdaa053...HEAD |
awk '
/^Sources\/RecorderApp\/ContentView\.swift$/ { next }
/^Sources\/RecorderApp\/UI\// { next }
/^Sources\/RecorderApp\/Views\/AIProviderSettingsView\.swift$/ { next }
/^Tests\/RecorderAppTests\/[^\/]*RenderTests\.swift$/ { next }
/^Tests\/RecorderAppTests\/(RecorderVisualStyleTests|RecordingsPresentationRouteTests|AppModelPlaybackTests)\.swift$/ { next }
/^docs\/superpowers\/specs\/2026-08-01-direction-a-visual-alignment-design\.md$/ { next }
/^docs\/superpowers\/plans\/2026-08-01-direction-a-visual-alignment\.md$/ { next }
{
    print "Disallowed presentation-only path: " $0 > "/dev/stderr"
    bad = 1
}
END { exit bad }
'
```

Every path must be under:

```text
Sources/RecorderApp/ContentView.swift
Sources/RecorderApp/UI/
Sources/RecorderApp/Views/AIProviderSettingsView.swift
Tests/RecorderAppTests/*RenderTests.swift
Tests/RecorderAppTests/RecorderVisualStyleTests.swift
Tests/RecorderAppTests/RecordingsPresentationRouteTests.swift
Tests/RecorderAppTests/AppModelPlaybackTests.swift
docs/superpowers/specs/2026-08-01-direction-a-visual-alignment-design.md
docs/superpowers/plans/2026-08-01-direction-a-visual-alignment.md
```

Fail if `AppModel.swift`, a PR B feature/bridge/repository, scripts/Python,
capture/Teams/media/virtual-mic production source, Windows, packaging, workflow,
or user-owned root file appears.

- [ ] **Step 5: Build and inspect a staging candidate without overwriting first**

Build to a unique temporary output, verify the bundle, signature, and clean
runtime-helper contract, and retain the printed temporary path for inspection:

```bash
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lmr-direction-a.XXXXXX")"
scripts/build-app.sh \
  --configuration release \
  --version 0.2.0 \
  --build-number 3 \
  --bundle-id local.meeting.recorder.staging \
  --bundle-name "Local Meeting Recorder Staging" \
  --output "$STAGING_ROOT/Local Meeting Recorder Staging.app" \
  --sign ad-hoc
scripts/verify-app-bundle.sh \
  "$STAGING_ROOT/Local Meeting Recorder Staging.app" \
  local.meeting.recorder.staging 0.2.0 3 ad-hoc
codesign --verify --deep --strict --verbose=2 \
  "$STAGING_ROOT/Local Meeting Recorder Staging.app"
if find "$STAGING_ROOT/Local Meeting Recorder Staging.app/Contents/Resources" \
  \( -iname '*.py' -o -iname '*.pyc' -o -iname '__pycache__' \
     -o -iname 'python*' -o -iname '*ffmpeg*' -o -iname '*ffprobe*' \) \
  -print -quit | rg -q .; then
  echo "Forbidden runtime helper found in staging bundle" >&2
  exit 1
fi
printf '%s\n' "$STAGING_ROOT/Local Meeting Recorder Staging.app"
```

Launching that temporary app for visual inspection is a GUI action and must
be requested explicitly at that point. Inspect 860×680 and 1280×800 before
replacing `/Applications/Local Meeting Recorder Staging.app`; installation
requires separate explicit authorization.

Manual evidence must cover:

- Recordings, HKT Provider, OpenAI Provider;
- MI unavailable/generating/ready/manual-title states;
- Light/Dark Transcript, Reduce Motion/Transparency, increased contrast;
- repeated list/detail Back, Cancel, Save failure, successful Save;
- keyboard and VoiceOver;
- external playback only;
- recording/finalizing/countdown floating windows on multiple Spaces.

Record real-provider, Teams, TCC, AirPods, media, notarized-artifact, and
hardware acceptance as outstanding unless separately executed.

- [ ] **Step 6: Request independent final review and commit evidence**

Ask an independent reviewer to compare the final diff to the approved spec and
report Critical/Important/Minor findings. Resolve all Critical/Important,
rerun affected focused and full gates, update this plan with exact SHA/test
evidence, then commit only the plan/test evidence:

```bash
git diff --quiet -- \
  Tests/RecorderAppTests/RecordingControllerRenderTests.swift \
  Tests/RecorderAppTests/TeamsAutoMeetingCountdownRenderTests.swift
git add docs/superpowers/plans/2026-08-01-direction-a-visual-alignment.md
git commit -m "test: complete direction a visual regression gate"
```

The `git diff --quiet` command must exit 0; these two suites are verification
inputs, not evidence-commit content. Keep the branch unmerged until the user
approves the staging visuals and explicitly requests integration.

## Execution evidence — 2026-08-02

Status: automated Direction A code and repository validation is complete on
implementation head `1afc00d01a162c4811aeed5a0de1a5630422cc8d`.
Actual-runtime GUI acceptance remains pending because the Mac was locked during
the bounded Computer Use attempt. This status does not claim production,
provider, permission, media, Teams, AirPods, notarized-artifact, or hardware
acceptance.

### Implementation commits

- `3139cf0` — `feat: define direction a surface tokens`
- `57acdc6` — `feat: add direction a workspace shell`
- `6a6b361` — `feat: compose direction a settings`
- `8248f27` — `fix: preserve native settings selection`
- `fad7a98` — `feat: align recordings library cards`
- `14eb0a5` — `fix: complete recordings route lifecycle`
- `21d0a789` — `feat: align transcript intelligence detail`
- `a778453` — `fix: apply branded sidebar gradient`
- `1afc00d` — `fix: preserve native sidebar selection contrast`

The final two commits resolve the independent review finding that the production
sidebar did not use the approved fixed brand gradient. The final implementation
uses exact sRGB stops `#132452 → #244F9E → #112B63`, exposes the gradient through
the native List background, and retains system-owned selected-row, keyboard,
VoiceOver, and increased-contrast foreground semantics.

### Automated validation

- Focused final-head suites: `RecorderVisualStyleTests` 6/6,
  `RecorderWorkspaceRenderTests` 24/24,
  `RECORDER_STABILITY=1 RecorderWorkspaceStabilityTests` 4/4,
  `AppModelPlaybackTests` 10/10, `RecordingControllerRenderTests` 3/3, and
  `TeamsAutoMeetingCountdownRenderTests` 2/2; zero failures.
- Complete Swift suite: 1,269 tests executed, 5 skipped, zero failures in
  37.669 seconds. The prior transcription-cancellation hang did not reproduce.
- Python/script suites: 105/105 and policy/packaging-workflow 29/29; zero
  failures. Localhost fixtures required the normal sandbox exception for loopback
  binding.
- Packaging tests, strict ad-hoc codesign, bundle verification, Mach-O inspection,
  and bundle-content scans passed. The candidate is macOS 26.0 minimum, SDK 26.5,
  system-dependency-only, and contains no Python, FFmpeg/FFprobe, oMLX/Qwen, or
  provider runtime helper.
- Virtual microphone gates: native contract, bundle contract, and install-script
  contract passed. The native binary reproducibly failed only inside the workspace
  sandbox because the fixed POSIX shared-memory namespace was denied; the identical
  binary and complete native script passed outside that sandbox with no resource
  holder. No product or driver source was changed for this environmental gate.
- `git diff --check` passed. The corrected Step 4 command admitted exactly 18
  presentation-only paths and no AppModel, feature/bridge/repository, media,
  capture, Teams, virtual-mic production, scripts, workflows, packaging, or Windows
  path. The recording-controller and Teams-countdown render test files are
  unchanged from the PR B base.
- Independent review after the sidebar repair: 0 Critical, 0 Important, 0 Minor.

### Staging candidate and remaining manual gate

The verified, uninstalled candidate is:

```text
/private/var/folders/8v/mldvjq_j2mz2tqbt5kvxwgtr0000gp/T/lmr-direction-a-final.S8XlUF/Local Meeting Recorder Staging.app
```

It is `local.meeting.recorder.staging` version `0.2.0 (3)`, ad-hoc signed, and
was neither launched nor copied over `/Applications/Local Meeting Recorder
Staging.app`. After the Mac is unlocked, manual acceptance must still inspect
860×680 and 1280×800, Recordings, HKT/OpenAI Provider, all MI states, adaptive
Transcript light/dark, Reduce Motion/Transparency, increased contrast, repeated
navigation, editor success/failure, keyboard/VoiceOver, external playback, and
both floating windows across Spaces. Keep the branch unmerged and unpushed until
that visual acceptance and an explicit integration request.

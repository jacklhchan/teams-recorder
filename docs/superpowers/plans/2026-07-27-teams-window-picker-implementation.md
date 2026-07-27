# Teams Window Picker Filtering and Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the viability probe's raw Teams window list with a default list of understandable meeting candidates plus an explicit all-windows recovery mode.

**Architecture:** Put all filtering, ranking, naming, fallback, and selection decisions in a pure Swift model that accepts value descriptors and returns a picker result. Adapt `SCWindow` instances into those descriptors at the existing ScreenCaptureKit discovery boundary, then map the result back to the retained `SCWindow` objects used by the probe. SwiftUI only binds the mode toggle and renders the model-provided labels.

**Tech Stack:** Swift 5.9, SwiftUI, ScreenCaptureKit, XCTest, macOS 15

## Global Constraints

- Continue enumerating only windows owned by `com.microsoft.teams2`.
- Recommended mode hides exact normalized title `Teams NRC`, nonzero window layers, off-screen windows, widths below 320 points, and heights below 180 points.
- A substantial normal-layer on-screen untitled window remains selectable.
- Recommended labels omit `CGWindowID`; all-windows and automatic-fallback labels include `Window ID <id>`.
- Labels use ASCII source text and whole-point dimensions.
- `Microsoft Teams` ranks first, then other titled windows, then untitled windows; area descends within each role and window ID is the final tie-breaker.
- Preserve the selected window ID when it remains visible; otherwise select the first ranked candidate.
- `Show all Teams windows` is disabled during capture, but the existing picker remains enabled for filter-dwell testing.
- Refreshing or selecting a picker item never changes the active capture filter; only the existing explicit filter buttons do that.
- Do not change `SCStream`, content-filter transitions, audio capture, evidence generation, or viability evaluation.
- Add no dependencies and keep the deployment target at macOS 15.

## File Structure

- Create `Sources/RecorderApp/Capture/TeamsCaptureWindowPickerModel.swift`
  - Pure descriptors, classification, naming, ordering, fallback, status, and selection.
- Create `Tests/RecorderAppTests/TeamsCaptureWindowPickerModelTests.swift`
  - Unit coverage for every classifier and presentation rule without constructing `SCWindow`.
- Modify `Sources/RecorderApp/Capture/TeamsCaptureViabilityProbe.swift`
  - Adapt discovered `SCWindow` values to descriptors and retain the matching capture objects.
- Modify `Sources/RecorderApp/Views/TeamsCaptureViabilityProbeView.swift`
  - Render the all-windows toggle and model-provided labels.

---

### Task 1: Add the Picker Model and Wire It Into the Probe

**Files:**
- Create: `Sources/RecorderApp/Capture/TeamsCaptureWindowPickerModel.swift`
- Create: `Tests/RecorderAppTests/TeamsCaptureWindowPickerModelTests.swift`
- Modify: `Sources/RecorderApp/Capture/TeamsCaptureViabilityProbe.swift:515-615`
- Modify: `Sources/RecorderApp/Views/TeamsCaptureViabilityProbeView.swift:7-18`

**Interfaces:**
- Consumes: `SCWindow.windowID`, `SCWindow.title`, `SCWindow.frame`, `SCWindow.isOnScreen`, and `SCWindow.windowLayer`.
- Produces: `TeamsCaptureWindowDescriptor`, `TeamsCaptureWindowPickerResult`, `TeamsCaptureWindowPickerModel.makeResult(descriptors:showAll:selectedWindowID:)`, and `TeamsCaptureWindowPickerModel.displayName(for:includesWindowID:)`.

- [ ] **Step 1: Write the failing model tests**

Create `Tests/RecorderAppTests/TeamsCaptureWindowPickerModelTests.swift`:

```swift
import XCTest
@testable import RecorderApp

final class TeamsCaptureWindowPickerModelTests: XCTestCase {
    func testRecommendedModeHidesInternalInactiveAndSmallWindows() {
        let descriptors = [
            descriptor(id: 1, title: "Teams NRC"),
            descriptor(id: 2, title: "Microsoft Teams"),
            descriptor(id: 3, title: ""),
            descriptor(id: 4, title: "Small", width: 319),
            descriptor(id: 5, title: "Offscreen", isOnScreen: false),
            descriptor(id: 6, title: "Overlay", windowLayer: 1)
        ]

        let result = TeamsCaptureWindowPickerModel.makeResult(
            descriptors: descriptors,
            showAll: false,
            selectedWindowID: nil
        )

        XCTAssertEqual(result.windowIDs, [2, 3])
        XCTAssertEqual(result.selectedWindowID, 2)
        XCTAssertEqual(
            result.status,
            "2 likely Teams windows; 4 internal or inactive windows hidden."
        )
        XCTAssertFalse(result.isUsingAllWindowsFallback)
    }

    func testRecommendedModeKeepsMinimumSizedUntitledWindow() {
        let result = TeamsCaptureWindowPickerModel.makeResult(
            descriptors: [
                descriptor(id: 7, title: "", width: 320, height: 180)
            ],
            showAll: false,
            selectedWindowID: nil
        )

        XCTAssertEqual(result.windowIDs, [7])
    }

    func testRecommendedLabelsExplainMainAndUntitledWindowsWithoutIDs() {
        XCTAssertEqual(
            TeamsCaptureWindowPickerModel.displayName(
                for: descriptor(
                    id: 10,
                    title: "Microsoft Teams",
                    width: 1512,
                    height: 982
                ),
                includesWindowID: false
            ),
            "Main Teams window - 1512x982"
        )
        XCTAssertEqual(
            TeamsCaptureWindowPickerModel.displayName(
                for: descriptor(
                    id: 11,
                    title: "",
                    width: 1280,
                    height: 720
                ),
                includesWindowID: false
            ),
            "Possible meeting or shared-content window - 1280x720"
        )
    }

    func testAllWindowsLabelExplainsNRCAndIncludesWindowID() {
        XCTAssertEqual(
            TeamsCaptureWindowPickerModel.displayName(
                for: descriptor(
                    id: 12,
                    title: "Teams NRC",
                    width: 900,
                    height: 600
                ),
                includesWindowID: true
            ),
            "Teams internal window (NRC) - 900x600 - Window ID 12"
        )
    }

    func testOtherTitledWindowKeepsItsTitleAndDimensions() {
        XCTAssertEqual(
            TeamsCaptureWindowPickerModel.displayName(
                for: descriptor(
                    id: 13,
                    title: "Presenter view",
                    width: 1024,
                    height: 768
                ),
                includesWindowID: false
            ),
            "Presenter view - 1024x768"
        )
    }

    func testOrderingUsesRoleThenAreaThenWindowID() {
        let result = TeamsCaptureWindowPickerModel.makeResult(
            descriptors: [
                descriptor(id: 4, title: "Second", width: 800, height: 600),
                descriptor(id: 2, title: "", width: 1600, height: 900),
                descriptor(id: 9, title: "Microsoft Teams", width: 640, height: 480),
                descriptor(id: 3, title: "First", width: 1200, height: 800)
            ],
            showAll: true,
            selectedWindowID: nil
        )

        XCTAssertEqual(result.windowIDs, [9, 3, 4, 2])
    }

    func testVisibleSelectionIsPreserved() {
        let result = TeamsCaptureWindowPickerModel.makeResult(
            descriptors: [
                descriptor(id: 20, title: "Microsoft Teams"),
                descriptor(id: 21, title: "Meeting")
            ],
            showAll: false,
            selectedWindowID: 21
        )

        XCTAssertEqual(result.selectedWindowID, 21)
    }

    func testNoRecommendedCandidatesFallsBackToAllWindows() {
        let result = TeamsCaptureWindowPickerModel.makeResult(
            descriptors: [
                descriptor(id: 30, title: "Teams NRC"),
                descriptor(id: 31, title: "", width: 200, height: 100)
            ],
            showAll: false,
            selectedWindowID: nil
        )

        XCTAssertEqual(result.windowIDs, [30, 31])
        XCTAssertEqual(result.selectedWindowID, 30)
        XCTAssertEqual(
            result.status,
            "No likely meeting windows found; showing all 2 Teams windows."
        )
        XCTAssertTrue(result.isUsingAllWindowsFallback)
    }

    func testAllWindowsModeIncludesEveryDescriptor() {
        let result = TeamsCaptureWindowPickerModel.makeResult(
            descriptors: [
                descriptor(id: 40, title: "Teams NRC"),
                descriptor(id: 41, title: "Tiny", width: 100, height: 100),
                descriptor(id: 42, title: "Microsoft Teams")
            ],
            showAll: true,
            selectedWindowID: 41
        )

        XCTAssertEqual(Set(result.windowIDs), Set([40, 41, 42]))
        XCTAssertEqual(result.selectedWindowID, 41)
        XCTAssertEqual(result.status, "Showing all 3 Teams windows.")
        XCTAssertFalse(result.isUsingAllWindowsFallback)
    }

    private func descriptor(
        id: UInt32,
        title: String,
        width: Int = 1280,
        height: Int = 720,
        isOnScreen: Bool = true,
        windowLayer: Int = 0
    ) -> TeamsCaptureWindowDescriptor {
        TeamsCaptureWindowDescriptor(
            windowID: id,
            title: title,
            width: width,
            height: height,
            isOnScreen: isOnScreen,
            windowLayer: windowLayer
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsCaptureWindowPickerModelTests
```

Expected: compilation fails because `TeamsCaptureWindowDescriptor` and
`TeamsCaptureWindowPickerModel` do not exist.

- [ ] **Step 3: Implement the pure picker model**

Create `Sources/RecorderApp/Capture/TeamsCaptureWindowPickerModel.swift`:

```swift
import Foundation

struct TeamsCaptureWindowDescriptor: Equatable, Hashable, Identifiable {
    let windowID: UInt32
    let title: String
    let width: Int
    let height: Int
    let isOnScreen: Bool
    let windowLayer: Int

    var id: UInt32 { windowID }

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var area: Int {
        max(0, width) * max(0, height)
    }
}

struct TeamsCaptureWindowPickerResult: Equatable {
    let windowIDs: [UInt32]
    let selectedWindowID: UInt32?
    let status: String
    let isUsingAllWindowsFallback: Bool
}

enum TeamsCaptureWindowPickerModel {
    private static let minimumWidth = 320
    private static let minimumHeight = 180

    static func makeResult(
        descriptors: [TeamsCaptureWindowDescriptor],
        showAll: Bool,
        selectedWindowID: UInt32?
    ) -> TeamsCaptureWindowPickerResult {
        let rankedAll = descriptors.sorted(by: ranksBefore)
        let recommended = rankedAll.filter(isRecommended)
        let usesFallback = !showAll && recommended.isEmpty && !rankedAll.isEmpty
        let visible = showAll || usesFallback ? rankedAll : recommended
        let windowIDs = visible.map(\.windowID)
        let selected = selectedWindowID.flatMap {
            windowIDs.contains($0) ? $0 : nil
        } ?? windowIDs.first

        let status: String
        if rankedAll.isEmpty {
            status = "No windows owned by com.microsoft.teams2 were found."
        } else if showAll {
            status = "Showing all \(rankedAll.count) Teams \(windowNoun(rankedAll.count))."
        } else if usesFallback {
            status = "No likely meeting windows found; showing all \(rankedAll.count) Teams \(windowNoun(rankedAll.count))."
        } else {
            let hiddenCount = rankedAll.count - recommended.count
            status = "\(recommended.count) likely Teams \(windowNoun(recommended.count)); \(hiddenCount) internal or inactive \(windowNoun(hiddenCount)) hidden."
        }

        return TeamsCaptureWindowPickerResult(
            windowIDs: windowIDs,
            selectedWindowID: selected,
            status: status,
            isUsingAllWindowsFallback: usesFallback
        )
    }

    static func displayName(
        for descriptor: TeamsCaptureWindowDescriptor,
        includesWindowID: Bool
    ) -> String {
        let title = descriptor.normalizedTitle
        let role: String
        if title.caseInsensitiveCompare("Microsoft Teams") == .orderedSame {
            role = "Main Teams window"
        } else if title.caseInsensitiveCompare("Teams NRC") == .orderedSame {
            role = "Teams internal window (NRC)"
        } else if title.isEmpty {
            role = "Possible meeting or shared-content window"
        } else {
            role = title
        }

        let dimensions = "\(descriptor.width)x\(descriptor.height)"
        let base = "\(role) - \(dimensions)"
        return includesWindowID
            ? "\(base) - Window ID \(descriptor.windowID)"
            : base
    }

    private static func isRecommended(
        _ descriptor: TeamsCaptureWindowDescriptor
    ) -> Bool {
        descriptor.normalizedTitle.caseInsensitiveCompare("Teams NRC")
            != .orderedSame
            && descriptor.windowLayer == 0
            && descriptor.isOnScreen
            && descriptor.width >= minimumWidth
            && descriptor.height >= minimumHeight
    }

    private static func ranksBefore(
        _ lhs: TeamsCaptureWindowDescriptor,
        _ rhs: TeamsCaptureWindowDescriptor
    ) -> Bool {
        let lhsRole = roleRank(lhs)
        let rhsRole = roleRank(rhs)
        if lhsRole != rhsRole {
            return lhsRole < rhsRole
        }
        if lhs.area != rhs.area {
            return lhs.area > rhs.area
        }
        return lhs.windowID < rhs.windowID
    }

    private static func roleRank(
        _ descriptor: TeamsCaptureWindowDescriptor
    ) -> Int {
        let title = descriptor.normalizedTitle
        if title.caseInsensitiveCompare("Microsoft Teams") == .orderedSame {
            return 0
        }
        return title.isEmpty ? 2 : 1
    }

    private static func windowNoun(_ count: Int) -> String {
        count == 1 ? "window" : "windows"
    }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsCaptureWindowPickerModelTests
```

Expected: 9 tests pass with 0 failures.

- [ ] **Step 5: Adapt ScreenCaptureKit discovery and publish the visible list**

Replace `TeamsCaptureViabilityWindow` in
`Sources/RecorderApp/Capture/TeamsCaptureViabilityProbe.swift` with:

```swift
struct TeamsCaptureViabilityWindow: Identifiable, Hashable {
    let descriptor: TeamsCaptureWindowDescriptor
    let includesWindowID: Bool
    fileprivate let window: SCWindow

    var id: UInt32 { descriptor.windowID }

    var displayName: String {
        TeamsCaptureWindowPickerModel.displayName(
            for: descriptor,
            includesWindowID: includesWindowID
        )
    }

    func presented(includesWindowID: Bool) -> Self {
        Self(
            descriptor: descriptor,
            includesWindowID: includesWindowID,
            window: window
        )
    }
}
```

Add the published mode and retained discovery list beside the current picker
properties:

```swift
@Published var showsAllTeamsWindows = false {
    didSet {
        guard oldValue != showsAllTeamsWindows else { return }
        rebuildWindowPicker()
    }
}

private var discoveredWindows: [TeamsCaptureViabilityWindow] = []
```

Adapt each Teams-owned `SCWindow` inside `refreshWindows()`:

```swift
let descriptor = TeamsCaptureWindowDescriptor(
    windowID: window.windowID,
    title: window.title ?? "",
    width: Int(window.frame.width.rounded()),
    height: Int(window.frame.height.rounded()),
    isOnScreen: window.isOnScreen,
    windowLayer: window.windowLayer
)
return TeamsCaptureViabilityWindow(
    descriptor: descriptor,
    includesWindowID: false,
    window: window
)
```

Replace the current alphabetical sort and direct publication with:

```swift
publish {
    self.discoveredWindows = teamsWindows
    self.rebuildWindowPicker()
}
```

Add this helper to the probe:

```swift
private func rebuildWindowPicker() {
    let result = TeamsCaptureWindowPickerModel.makeResult(
        descriptors: discoveredWindows.map(\.descriptor),
        showAll: showsAllTeamsWindows,
        selectedWindowID: selectedWindowID
    )
    let byID = Dictionary(
        uniqueKeysWithValues: discoveredWindows.map { ($0.id, $0) }
    )
    let includesWindowID =
        showsAllTeamsWindows || result.isUsingAllWindowsFallback

    windows = result.windowIDs.compactMap {
        byID[$0]?.presented(includesWindowID: includesWindowID)
    }
    selectedWindowID = result.selectedWindowID
    status = result.status
}
```

Do not change `start()`, `switchToSelectedWindow()`,
`switchToApplication()`, `stop()`, or the report/evaluator code.

- [ ] **Step 6: Add the native all-windows toggle**

In `Sources/RecorderApp/Views/TeamsCaptureViabilityProbeView.swift`, place this
toggle immediately after the Picker:

```swift
Toggle(
    "Show all Teams windows",
    isOn: $probe.showsAllTeamsWindows
)
.disabled(probe.isCapturing)
```

Leave the Picker enabled during capture and retain all existing action-button
conditions.

- [ ] **Step 7: Re-run focused tests and compile the integration**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsCaptureWindowPickerModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build
```

Expected: 9 focused tests pass, then the app builds successfully.

- [ ] **Step 8: Run the complete regression suite**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: all tests pass with 0 failures, including the existing Teams
same-stream gate tests.

- [ ] **Step 9: Inspect the scoped diff and commit**

Run:

```bash
git diff --check
git status --short
git diff --stat
git add \
  Sources/RecorderApp/Capture/TeamsCaptureWindowPickerModel.swift \
  Sources/RecorderApp/Capture/TeamsCaptureViabilityProbe.swift \
  Sources/RecorderApp/Views/TeamsCaptureViabilityProbeView.swift \
  Tests/RecorderAppTests/TeamsCaptureWindowPickerModelTests.swift
git commit -m "Clarify Teams window selection"
```

Expected: only the four planned files are included in the implementation
commit.

---

### Task 2: Reinstall and Validate the Native Picker

**Files:**
- Verify only: `/Applications/Local Meeting Recorder.app`
- Verify only: `~/Downloads/TeamsCaptureViability/`

**Interfaces:**
- Consumes: the committed executable from Task 1 and the existing stable bundle ID `local.meeting.recorder`.
- Produces: installed-app UI evidence that recommended mode is clean and all-windows mode remains available.

- [ ] **Step 1: Reinstall the committed app**

Run with user-approved `/Applications` access:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  scripts/install-app.sh
```

Expected: `Installed: /Applications/Local Meeting Recorder.app`; the bundle ID
remains `local.meeting.recorder`.

- [ ] **Step 2: Launch the installed viability probe**

Run:

```bash
open -n -a "/Applications/Local Meeting Recorder.app" \
  --args --teams-screen-viability-probe
```

Expected: the probe opens under the existing Screen & System Audio Recording
permission.

- [ ] **Step 3: Validate recommended mode**

Use the live Teams process and inspect the native picker.

Expected:

- `Teams NRC` is absent;
- small, off-screen, and non-normal-layer entries are absent;
- `Main Teams window - <width>x<height>` appears when the main Teams window is
  available;
- substantial untitled entries read
  `Possible meeting or shared-content window - <width>x<height>`;
- no recommended label contains `Window ID`.

- [ ] **Step 4: Validate all-windows recovery**

Enable `Show all Teams windows` and inspect the picker.

Expected:

- every enumerated Teams-owned window appears;
- `Teams internal window (NRC)` appears when Teams exposes it;
- every label ends with `Window ID <id>`;
- disabling the toggle restores the recommended list and preserves a still
  visible selection.

- [ ] **Step 5: Confirm capture controls retain their contract**

Start the probe and inspect the controls without saving new viability evidence.

Expected:

- `Show all Teams windows` is disabled;
- the Teams window Picker remains enabled;
- Start is disabled;
- both filter buttons and Stop and Save follow their existing capture state;
- no content-filter change occurs until an explicit filter button is pressed.

Stop the probe after this UI check. The separate same-stream live audio/video
gate remains pending and must not be marked passed by this picker validation.

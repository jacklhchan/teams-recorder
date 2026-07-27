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

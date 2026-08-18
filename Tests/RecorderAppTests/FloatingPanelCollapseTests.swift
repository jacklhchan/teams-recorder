import AppKit
import XCTest
@testable import RecorderApp

final class FloatingPanelCollapseTests: XCTestCase {
    func testCollapsedFrameIs132By40AndPreservesTopRightAnchor() {
        let current = NSRect(x: 500, y: 400, width: 390, height: 180)
        let collapsed = FloatingPanelLayout.frame(
            preservingTopRightOf: current,
            targetSize: FloatingPanelLayout.collapsedSize
        )

        XCTAssertEqual(collapsed.size, .init(width: 132, height: 40))
        XCTAssertEqual(collapsed.maxX, current.maxX)
        XCTAssertEqual(collapsed.maxY, current.maxY)
    }

    func testCollapseAccessibilityCopyIsStateSpecific() {
        XCTAssertEqual(
            FloatingPanelPresentationState.expanded.toggleLabel,
            "Collapse floating window"
        )
        XCTAssertEqual(
            FloatingPanelPresentationState.expanded.accessibilityValue,
            "Expanded"
        )
        XCTAssertEqual(
            FloatingPanelPresentationState.collapsed.toggleLabel,
            "Expand floating window"
        )
        XCTAssertEqual(
            FloatingPanelPresentationState.collapsed.accessibilityValue,
            "Collapsed"
        )
    }
}

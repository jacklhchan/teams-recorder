import XCTest
@testable import RecorderApp

final class RecorderNavigationTests: XCTestCase {
    func testCleanNavigationSelectsDestinationAndClearsPending() {
        var state = RecorderNavigationState(selection: .record)
        state.select(.recordings, hasUnsavedChanges: false)
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertNil(state.pendingDestination)
    }

    func testDirtyNavigationRequestsConfirmationWithoutChangingSelection() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.settings, hasUnsavedChanges: true)
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertEqual(state.pendingDestination, .settings)
    }

    func testKeepEditingClearsPendingAndRetainsCurrentDestination() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.settings, hasUnsavedChanges: true)
        state.keepEditing()
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertNil(state.pendingDestination)
    }

    func testDiscardSelectsPendingDestinationExactlyOnce() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.settings, hasUnsavedChanges: true)
        state.discardAndNavigate()
        XCTAssertEqual(state.selection, .settings)
        XCTAssertNil(state.pendingDestination)
        state.discardAndNavigate()
        XCTAssertEqual(state.selection, .settings)
    }

    func testOneHundredCleanCyclesDoNotLeakPendingRoute() {
        var state = RecorderNavigationState(selection: .record)
        for _ in 0..<100 {
            state.select(.recordings, hasUnsavedChanges: false)
            state.select(.settings, hasUnsavedChanges: false)
            state.select(.record, hasUnsavedChanges: false)
            XCTAssertNil(state.pendingDestination)
        }
    }
}

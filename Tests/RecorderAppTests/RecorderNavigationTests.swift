import XCTest
@testable import RecorderApp

final class RecorderNavigationTests: XCTestCase {
    func testCleanNavigationSelectsDestinationAndClearsPending() {
        var state = RecorderNavigationState(selection: .record)
        state.select(.recordings, hasUnsavedChanges: false)
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertNil(state.pendingDestination)
    }

    func testCleanNavigationSelectsHealthAndClearsPending() {
        var state = RecorderNavigationState(selection: .record)
        state.select(.health, hasUnsavedChanges: false)
        XCTAssertEqual(state.selection, .health)
        XCTAssertNil(state.pendingDestination)
    }

    func testCleanNavigationSelectsRecoveryAndClearsPending() {
        var state = RecorderNavigationState(selection: .record)
        state.select(.recovery, hasUnsavedChanges: false)
        XCTAssertEqual(state.selection, .recovery)
        XCTAssertNil(state.pendingDestination)
    }

    func testDirtyNavigationRequestsConfirmationWithoutChangingSelection() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.settings, hasUnsavedChanges: true)
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertEqual(state.pendingDestination, .settings)
    }

    func testDirtyNavigationDefersRecoveryUntilDiscard() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.recovery, hasUnsavedChanges: true)
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertEqual(state.pendingDestination, .recovery)
        state.discardAndNavigate()
        XCTAssertEqual(state.selection, .recovery)
        XCTAssertNil(state.pendingDestination)
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
}

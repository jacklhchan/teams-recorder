import XCTest
@testable import RecorderApp

final class RecorderGlassTests: XCTestCase {
    func testVersionBoundary() {
        XCTAssertEqual(RecorderGlassStyle.resolve(majorVersion: 25), .material)
        XCTAssertEqual(RecorderGlassStyle.resolve(majorVersion: 26), .glass)
    }
}

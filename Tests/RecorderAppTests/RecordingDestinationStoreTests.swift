import Foundation
import XCTest
@testable import RecorderApp

final class RecordingDestinationStoreTests: XCTestCase {
    func testNoSavedSelectionUsesDefaultWithoutPersistingIt() throws {
        let defaults = UserDefaults(suiteName: #function + UUID().uuidString)!
        let codec = DestinationBookmarkCodecSpy()
        let store = RecordingDestinationStore(defaults: defaults, codec: codec.codec)
        let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)

        XCTAssertEqual(store.restore(defaultURL: downloads).state, .ready)
        XCTAssertEqual(store.restore(defaultURL: downloads).url, downloads)
        XCTAssertNil(defaults.data(forKey: RecordingDestinationStore.bookmarkKey))
    }

    func testValidBookmarkRestoresExactSelectedFolder() throws {
        let fixture = DestinationStoreFixture()
        let selected = URL(fileURLWithPath: "/Volumes/OneDrive/Meeting Recording", isDirectory: true)
        try fixture.store.save(selected)
        fixture.codec.resolvedURL = selected

        let restored = fixture.store.restore(defaultURL: fixture.downloads)

        XCTAssertEqual(restored.url, selected)
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.identity, fixture.store.currentIdentity)
    }

    func testNonSandboxedScopedFailureFallsBackToStandardBookmark() throws {
        let fixture = DestinationStoreFixture()
        fixture.codec.scopedEncodeError = DestinationBookmarkTestError.scopedUnavailable
        try fixture.store.save(fixture.destination)

        XCTAssertEqual(fixture.store.savedBookmarkKind, .standard)
        XCTAssertEqual(fixture.codec.standardEncodeCount, 1)
        XCTAssertEqual(
            fixture.store.restore(defaultURL: fixture.downloads).url,
            fixture.destination
        )
    }

    func testNonSandboxedCodecSkipsSecurityScopedBookmarkEncoding() throws {
        let defaults = UserDefaults(suiteName: #function + UUID().uuidString)!
        let codec = DestinationBookmarkCodecSpy()
        let store = RecordingDestinationStore(
            defaults: defaults,
            codec: codec.makeCodec(prefersSecurityScope: false)
        )

        try store.save(URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true))

        XCTAssertEqual(codec.scopedEncodeCount, 0)
        XCTAssertEqual(codec.standardEncodeCount, 1)
        XCTAssertEqual(store.savedBookmarkKind, .standard)
    }

    func testStaleBookmarkNeedsFolderAccessAndDoesNotFallBackToDownloads() throws {
        let fixture = DestinationStoreFixture()
        let selected = URL(fileURLWithPath: "/Volumes/OneDrive/Meeting Recording", isDirectory: true)
        try fixture.store.save(selected)
        fixture.codec.resolvedURL = selected
        fixture.codec.isStale = true

        let restored = fixture.store.restore(defaultURL: fixture.downloads)

        XCTAssertEqual(restored.url, selected)
        XCTAssertEqual(restored.state, .needsFolderAccess)
        XCTAssertNotEqual(restored.url, fixture.downloads)
    }

    func testCorruptCurrentIdentityNeedsFolderAccessForOnlyCatalogDestination() throws {
        let fixture = DestinationStoreFixture()
        try fixture.store.save(fixture.destination)
        fixture.defaults.set(Data("corrupt identity".utf8), forKey: "recordingDestinationCurrentIdentityV1")

        let restored = fixture.store.restore(defaultURL: fixture.downloads)

        XCTAssertEqual(restored.url, fixture.destination)
        XCTAssertEqual(restored.state, .needsFolderAccess)
        XCTAssertNotEqual(restored.url, fixture.downloads)
    }

    func testAccessBalancesSuccessfulSecurityScope() throws {
        let fixture = DestinationStoreFixture()
        try fixture.store.save(fixture.destination)
        fixture.codec.resolvedURL = fixture.destination

        let access = try fixture.store.access(identity: fixture.store.currentIdentity!)
        XCTAssertEqual(access.url, fixture.destination)
        access.close()

        XCTAssertEqual(fixture.codec.startCount, 1)
        XCTAssertEqual(fixture.codec.stopCount, 1)
    }

    func testDestinationHistoryRemainsUntilNoQueueIdentityReferencesIt() throws {
        let fixture = DestinationStoreFixture()
        try fixture.store.save(fixture.destination)
        let oldIdentity = try XCTUnwrap(fixture.store.currentIdentity)
        try fixture.store.save(fixture.otherDestination)
        let currentIdentity = try XCTUnwrap(fixture.store.currentIdentity)

        fixture.store.prune(keeping: [oldIdentity, currentIdentity])
        XCTAssertNoThrow(try fixture.store.access(identity: oldIdentity))
        fixture.store.prune(keeping: [currentIdentity])
        XCTAssertThrowsError(try fixture.store.access(identity: oldIdentity))
    }
}

private final class DestinationStoreFixture {
    let defaults: UserDefaults
    private let defaultsSuiteName: String
    let codec = DestinationBookmarkCodecSpy()
    let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
    let destination = URL(fileURLWithPath: "/Volumes/OneDrive/Meeting Recording", isDirectory: true)
    let otherDestination = URL(fileURLWithPath: "/Volumes/OneDrive/Other Recording", isDirectory: true)
    lazy var store = RecordingDestinationStore(defaults: defaults, codec: codec.codec)

    init() {
        defaultsSuiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

private enum DestinationBookmarkTestError: Error {
    case scopedUnavailable
}

private final class DestinationBookmarkCodecSpy {
    var scopedEncodeError: Error?
    var resolvedURL: URL?
    var isStale = false
    private(set) var scopedEncodeCount = 0
    private(set) var standardEncodeCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var codec: RecordingDestinationBookmarkCodec {
        makeCodec(prefersSecurityScope: true)
    }

    func makeCodec(prefersSecurityScope: Bool) -> RecordingDestinationBookmarkCodec {
        RecordingDestinationBookmarkCodec(
            prefersSecurityScope: prefersSecurityScope,
            encodeScoped: { [weak self] url in
                self?.scopedEncodeCount += 1
                if let error = self?.scopedEncodeError {
                    throw error
                }
                return self?.encoded(url, kind: .securityScoped) ?? Data()
            },
            encodeStandard: { [weak self] url in
                self?.standardEncodeCount += 1
                return self?.encoded(url, kind: .standard) ?? Data()
            },
            resolve: { [weak self] data, _ in
                let url = self?.resolvedURL ?? self?.decodedURL(from: data)
                guard let url else { throw CocoaError(.fileNoSuchFile) }
                return (url, self?.isStale ?? false)
            },
            startAccessing: { [weak self] _ in
                self?.startCount += 1
                return true
            },
            stopAccessing: { [weak self] _ in self?.stopCount += 1 }
        )
    }

    private func encoded(_ url: URL, kind: RecordingDestinationBookmarkKind) -> Data {
        let value = "\(kind.rawValue)|\(url.path)"
        return Data(value.utf8)
    }

    private func decodedURL(from data: Data) -> URL? {
        guard let value = String(data: data, encoding: .utf8),
              let separator = value.firstIndex(of: "|") else { return nil }
        return URL(fileURLWithPath: String(value[value.index(after: separator)...]), isDirectory: true)
    }
}

import Foundation
import XCTest
@testable import RecorderApp

final class LegacyTeamsIntegrationCleanerTests: XCTestCase {
    private var suiteName: String!

    override func tearDown() {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(
                forName: suiteName
            )
        }
        super.tearDown()
    }

    func testCleanDeletesRetiredDefaultsAndPairingCredential() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "teamsMuteSyncEnabled")
        defaults.set("legacy-token", forKey: "teamsThirdPartyAPIPairingToken")
        let secureStore = CleanerSecureValueStore()

        try LegacyTeamsIntegrationCleaner(
            secureStore: secureStore,
            defaults: defaults
        ).clean()

        XCTAssertNil(defaults.object(forKey: "teamsMuteSyncEnabled"))
        XCTAssertNil(defaults.object(forKey: "teamsThirdPartyAPIPairingToken"))
        XCTAssertEqual(
            secureStore.deleted,
            [
                .init(
                    service: "local.meeting.recorder.teams-third-party-api",
                    account: "pairing-token.v1"
                )
            ]
        )
    }

    func testCleanStillDeletesDefaultsWhenKeychainDeleteFails() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "teamsMuteSyncEnabled")
        defaults.set("legacy-token", forKey: "teamsThirdPartyAPIPairingToken")
        let secureStore = CleanerSecureValueStore(deleteError: CleanerError.failed)

        XCTAssertThrowsError(
            try LegacyTeamsIntegrationCleaner(
                secureStore: secureStore,
                defaults: defaults
            ).clean()
        )

        XCTAssertNil(defaults.object(forKey: "teamsMuteSyncEnabled"))
        XCTAssertNil(defaults.object(forKey: "teamsThirdPartyAPIPairingToken"))
    }

    private func makeDefaults() -> UserDefaults {
        suiteName = "LegacyTeamsIntegrationCleanerTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}

private enum CleanerError: Error {
    case failed
}

private final class CleanerSecureValueStore: SecureValueStoring, @unchecked Sendable {
    struct DeletedValue: Equatable {
        let service: String
        let account: String
    }

    private let deleteError: Error?
    private(set) var deleted: [DeletedValue] = []

    init(deleteError: Error? = nil) {
        self.deleteError = deleteError
    }

    func load(service _: String, account _: String) throws -> Data? { nil }

    func save(
        _: Data,
        service _: String,
        account _: String
    ) throws {}

    func delete(service: String, account: String) throws {
        deleted.append(.init(service: service, account: account))
        if let deleteError {
            throw deleteError
        }
    }
}

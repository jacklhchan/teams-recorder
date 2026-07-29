import Foundation
import XCTest
@testable import RecorderApp

final class TeamsPairingTokenStoreTests: XCTestCase {
    private static let legacyKey = TeamsPairingCredential.legacyDefaultsKey
    private var suiteName: String!

    override func tearDown() {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(
                forName: suiteName
            )
        }
        super.tearDown()
    }

    func testKeychainWinsAndDeletesDifferentLegacyToken() throws {
        let secure = InMemorySecureValueStore(
            stored: Data("keychain-token".utf8)
        )
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)
        let store = makeStore(secure: secure, defaults: defaults)

        XCTAssertEqual(try store.load(), "keychain-token")
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }

    func testLegacyTokenIsDeletedOnlyAfterVerifiedMigration() throws {
        let secure = InMemorySecureValueStore()
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)
        let store = makeStore(secure: secure, defaults: defaults)

        XCTAssertEqual(try store.load(), "legacy-token")
        XCTAssertEqual(secure.stored, Data("legacy-token".utf8))
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }

    func testFailedSavePreservesLegacyToken() {
        let secure = InMemorySecureValueStore(saveError: TestError.failed)
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).load()
        )
        XCTAssertEqual(defaults.string(forKey: Self.legacyKey), "legacy-token")
    }

    func testReadBackMismatchPreservesLegacyToken() {
        let secure = InMemorySecureValueStore(
            readBackOverride: Data("different-token".utf8)
        )
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).load()
        )
        XCTAssertEqual(defaults.string(forKey: Self.legacyKey), "legacy-token")
    }

    func testInvalidUTF8InKeychainFailsWithoutDeletingLegacyToken() {
        let secure = InMemorySecureValueStore(stored: Data([0xFF]))
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).load()
        ) { error in
            XCTAssertEqual(error as? TeamsPairingTokenStoreError, .invalidEncoding)
        }
        XCTAssertEqual(defaults.string(forKey: Self.legacyKey), "legacy-token")
    }

    func testEmptyKeychainValueFailsWithoutDeletingLegacyToken() {
        let secure = InMemorySecureValueStore(stored: Data())
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).load()
        ) { error in
            XCTAssertEqual(error as? TeamsPairingTokenStoreError, .invalidEncoding)
        }
        XCTAssertEqual(defaults.string(forKey: Self.legacyKey), "legacy-token")
    }

    func testSavingEmptyTokenFailsWithoutCallingSecureStore() {
        let secure = InMemorySecureValueStore()

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: makeDefaults()).save("")
        ) { error in
            XCTAssertEqual(error as? TeamsPairingTokenStoreError, .emptyToken)
        }
        XCTAssertTrue(secure.operations.isEmpty)
    }

    func testUsesRequiredKeychainServiceAndAccountForLoadSaveAndDelete() throws {
        let secure = InMemorySecureValueStore()
        let store = makeStore(secure: secure, defaults: makeDefaults())

        XCTAssertNil(try store.load())
        try store.save("pairing-token")
        try store.clear()

        XCTAssertEqual(
            secure.operations,
            [
                .load(
                    service: TeamsPairingCredential.service,
                    account: TeamsPairingCredential.account
                ),
                .save(
                    service: TeamsPairingCredential.service,
                    account: TeamsPairingCredential.account
                ),
                .delete(
                    service: TeamsPairingCredential.service,
                    account: TeamsPairingCredential.account
                )
            ]
        )
    }

    func testClearRemovesLegacyValueEvenWhenKeychainDeleteFails() {
        let secure = InMemorySecureValueStore(deleteError: TestError.failed)
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).clear()
        )
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }

    private func makeDefaults() -> UserDefaults {
        suiteName = "TeamsPairingTokenStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeStore(
        secure: InMemorySecureValueStore,
        defaults: UserDefaults
    ) -> KeychainTeamsPairingTokenStore {
        KeychainTeamsPairingTokenStore(
            secureStore: secure,
            defaults: defaults
        )
    }
}

private enum TestError: Error {
    case failed
}

private final class InMemorySecureValueStore: SecureValueStoring, @unchecked Sendable {
    enum Operation: Equatable {
        case load(service: String, account: String)
        case save(service: String, account: String)
        case delete(service: String, account: String)
    }

    private let lock = NSLock()
    private var value: Data?
    private var recordedOperations: [Operation] = []
    private let readBackOverride: Data?
    private let saveError: Error?
    private let deleteError: Error?

    init(
        stored: Data? = nil,
        readBackOverride: Data? = nil,
        saveError: Error? = nil,
        deleteError: Error? = nil
    ) {
        value = stored
        self.readBackOverride = readBackOverride
        self.saveError = saveError
        self.deleteError = deleteError
    }

    var stored: Data? {
        lock.withLock { value }
    }

    var operations: [Operation] {
        lock.withLock { recordedOperations }
    }

    func load(service: String, account: String) throws -> Data? {
        lock.withLock {
            recordedOperations.append(.load(service: service, account: account))
            guard value != nil else { return nil }
            return readBackOverride ?? value
        }
    }

    func save(_ data: Data, service: String, account: String) throws {
        lock.withLock {
            recordedOperations.append(.save(service: service, account: account))
        }
        if let saveError { throw saveError }
        lock.withLock { value = data }
    }

    func delete(service: String, account: String) throws {
        lock.withLock {
            recordedOperations.append(.delete(service: service, account: account))
        }
        if let deleteError { throw deleteError }
        lock.withLock { value = nil }
    }
}

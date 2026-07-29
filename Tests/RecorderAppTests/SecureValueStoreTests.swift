import Foundation
import Security
import XCTest
@testable import RecorderApp

final class SecureValueStoreTests: XCTestCase {
    func testLoadReturnsNilForItemNotFound() throws {
        let backend = FakeKeychainBackend(readResult: .init(
            status: errSecItemNotFound,
            data: nil
        ))
        let store = KeychainSecureValueStore(backend: backend)

        XCTAssertNil(
            try store.load(
                service: "read-service",
                account: "read-account"
            )
        )
        XCTAssertEqual(
            backend.readIdentity,
            .init(service: "read-service", account: "read-account")
        )
    }

    func testSaveAddsNewValue() throws {
        let backend = FakeKeychainBackend(addStatus: errSecSuccess)
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("do-not-log".utf8)

        try store.save(
            secret,
            service: "add-service",
            account: "add-account"
        )

        XCTAssertEqual(backend.addedData, secret)
        XCTAssertEqual(
            backend.addIdentity,
            .init(service: "add-service", account: "add-account")
        )
        XCTAssertEqual(backend.updateCount, 0)
    }

    func testDuplicateAddUpdatesExistingValue() throws {
        let backend = FakeKeychainBackend(
            addStatus: errSecDuplicateItem,
            updateStatus: errSecSuccess
        )
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("replacement".utf8)

        try store.save(
            secret,
            service: "update-service",
            account: "update-account"
        )

        XCTAssertEqual(backend.updatedData, secret)
        XCTAssertEqual(
            backend.updateIdentity,
            .init(service: "update-service", account: "update-account")
        )
        XCTAssertEqual(backend.updateCount, 1)
    }

    func testDeleteTreatsMissingItemAsSuccess() {
        let backend = FakeKeychainBackend(deleteStatus: errSecItemNotFound)
        let store = KeychainSecureValueStore(backend: backend)

        XCTAssertNoThrow(
            try store.delete(
                service: "delete-service",
                account: "delete-account"
            )
        )
        XCTAssertEqual(
            backend.deleteIdentity,
            .init(service: "delete-service", account: "delete-account")
        )
    }

    func testUnexpectedStatusIsRedacted() {
        let backend = FakeKeychainBackend(addStatus: errSecAuthFailed)
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("never-appear".utf8)

        XCTAssertThrowsError(
            try store.save(secret, service: "service", account: "account")
        ) { error in
            XCTAssertEqual(
                error as? SecureValueStoreError,
                .operationFailed(
                    operation: "add",
                    status: errSecAuthFailed
                )
            )
            XCTAssertFalse(error.localizedDescription.contains("never-appear"))
            XCTAssertTrue(error.localizedDescription.contains("\(errSecAuthFailed)"))
        }
    }

    func testSuccessWithoutDataIsRejected() {
        let backend = FakeKeychainBackend(readResult: .init(
            status: errSecSuccess,
            data: nil
        ))

        XCTAssertThrowsError(
            try KeychainSecureValueStore(backend: backend)
                .load(service: "service", account: "account")
        ) { error in
            XCTAssertEqual(
                error as? SecureValueStoreError,
                .missingResultData
            )
        }
    }
}

private struct KeychainIdentity: Equatable {
    let service: String
    let account: String
}

private final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let readResult: KeychainReadResult
    private let addStatus: OSStatus
    private let updateStatus: OSStatus
    private let deleteStatus: OSStatus
    private var storedReadIdentity: KeychainIdentity?
    private var storedAddIdentity: KeychainIdentity?
    private var storedUpdateIdentity: KeychainIdentity?
    private var storedDeleteIdentity: KeychainIdentity?
    private var storedAddedData: Data?
    private var storedUpdatedData: Data?
    private var storedUpdateCount = 0

    init(
        readResult: KeychainReadResult = .init(
            status: errSecItemNotFound,
            data: nil
        ),
        addStatus: OSStatus = errSecSuccess,
        updateStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.readResult = readResult
        self.addStatus = addStatus
        self.updateStatus = updateStatus
        self.deleteStatus = deleteStatus
    }

    var readIdentity: KeychainIdentity? {
        lock.withLock { storedReadIdentity }
    }

    var addIdentity: KeychainIdentity? {
        lock.withLock { storedAddIdentity }
    }

    var updateIdentity: KeychainIdentity? {
        lock.withLock { storedUpdateIdentity }
    }

    var deleteIdentity: KeychainIdentity? {
        lock.withLock { storedDeleteIdentity }
    }

    var addedData: Data? {
        lock.withLock { storedAddedData }
    }

    var updatedData: Data? {
        lock.withLock { storedUpdatedData }
    }

    var updateCount: Int {
        lock.withLock { storedUpdateCount }
    }

    func read(service: String, account: String) -> KeychainReadResult {
        lock.withLock {
            storedReadIdentity = .init(service: service, account: account)
            return readResult
        }
    }

    func add(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus {
        lock.withLock {
            storedAddIdentity = .init(service: service, account: account)
            storedAddedData = data
            return addStatus
        }
    }

    func update(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus {
        lock.withLock {
            storedUpdateIdentity = .init(service: service, account: account)
            storedUpdatedData = data
            storedUpdateCount += 1
            return updateStatus
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            storedDeleteIdentity = .init(service: service, account: account)
            return deleteStatus
        }
    }
}

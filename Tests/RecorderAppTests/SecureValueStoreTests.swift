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

        XCTAssertNil(try store.load(service: "service", account: "account"))
    }

    func testSaveAddsNewValue() throws {
        let backend = FakeKeychainBackend(addStatus: errSecSuccess)
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("do-not-log".utf8)

        try store.save(secret, service: "service", account: "account")

        XCTAssertEqual(backend.addedData, secret)
        XCTAssertEqual(backend.updateCount, 0)
    }

    func testDuplicateAddUpdatesExistingValue() throws {
        let backend = FakeKeychainBackend(
            addStatus: errSecDuplicateItem,
            updateStatus: errSecSuccess
        )
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("replacement".utf8)

        try store.save(secret, service: "service", account: "account")

        XCTAssertEqual(backend.updatedData, secret)
        XCTAssertEqual(backend.updateCount, 1)
    }

    func testDeleteTreatsMissingItemAsSuccess() {
        let backend = FakeKeychainBackend(deleteStatus: errSecItemNotFound)
        let store = KeychainSecureValueStore(backend: backend)

        XCTAssertNoThrow(
            try store.delete(service: "service", account: "account")
        )
    }

    func testUnexpectedStatusIsRedacted() {
        let backend = FakeKeychainBackend(addStatus: errSecAuthFailed)
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("never-appear".utf8)

        XCTAssertThrowsError(
            try store.save(secret, service: "service", account: "account")
        ) { error in
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
        )
    }
}

private final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let readResult: KeychainReadResult
    private let addStatus: OSStatus
    private let updateStatus: OSStatus
    private let deleteStatus: OSStatus
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
        lock.withLock { readResult }
    }

    func add(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus {
        lock.withLock {
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
            storedUpdatedData = data
            storedUpdateCount += 1
            return updateStatus
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock { deleteStatus }
    }
}

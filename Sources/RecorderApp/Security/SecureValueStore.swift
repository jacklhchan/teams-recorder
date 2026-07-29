import Foundation
import Security

protocol SecureValueStoring: Sendable {
    func load(service: String, account: String) throws -> Data?
    func save(
        _ data: Data,
        service: String,
        account: String
    ) throws
    func delete(service: String, account: String) throws
}

struct KeychainReadResult: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol KeychainBackend: Sendable {
    func read(service: String, account: String) -> KeychainReadResult
    func add(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus
    func update(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

enum SecureValueStoreError: LocalizedError, Equatable {
    case operationFailed(operation: String, status: OSStatus)
    case missingResultData

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let status):
            "Keychain \(operation) failed with status \(status)."
        case .missingResultData:
            "Keychain returned success without credential data."
        }
    }
}

struct SystemKeychainBackend: KeychainBackend {
    func read(service: String, account: String) -> KeychainReadResult {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        return KeychainReadResult(status: status, data: result as? Data)
    }

    func add(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus {
        SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(
            baseQuery(service: service, account: account) as CFDictionary
        )
    }

    private func baseQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class KeychainSecureValueStore:
    SecureValueStoring,
    @unchecked Sendable
{
    private let backend: any KeychainBackend

    init(backend: any KeychainBackend = SystemKeychainBackend()) {
        self.backend = backend
    }

    func load(service: String, account: String) throws -> Data? {
        let result = backend.read(service: service, account: account)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else {
                throw SecureValueStoreError.missingResultData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SecureValueStoreError.operationFailed(
                operation: "read",
                status: result.status
            )
        }
    }

    func save(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        let addStatus = backend.add(
            data,
            service: service,
            account: account
        )
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw SecureValueStoreError.operationFailed(
                operation: "add",
                status: addStatus
            )
        }
        let updateStatus = backend.update(
            data,
            service: service,
            account: account
        )
        guard updateStatus == errSecSuccess else {
            throw SecureValueStoreError.operationFailed(
                operation: "update",
                status: updateStatus
            )
        }
    }

    func delete(service: String, account: String) throws {
        let status = backend.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureValueStoreError.operationFailed(
                operation: "delete",
                status: status
            )
        }
    }
}

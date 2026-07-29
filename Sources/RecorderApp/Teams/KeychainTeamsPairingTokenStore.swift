import Foundation

enum TeamsPairingCredential {
    static let service = "local.meeting.recorder.teams-third-party-api"
    static let account = "pairing-token.v1"
    static let legacyDefaultsKey = "teamsThirdPartyAPIPairingToken"
}

enum TeamsPairingTokenStoreError: LocalizedError, Equatable {
    case invalidEncoding
    case migrationVerificationFailed
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "The saved Teams pairing credential is invalid."
        case .migrationVerificationFailed:
            "Teams pairing credential migration could not be verified."
        case .emptyToken:
            "Teams returned an empty pairing credential."
        }
    }
}

final class KeychainTeamsPairingTokenStore:
    TeamsPairingTokenStoring,
    @unchecked Sendable
{
    private let secureStore: any SecureValueStoring
    private let defaults: UserDefaults
    private let legacyKey: String
    private let lock = NSLock()

    init(
        secureStore: any SecureValueStoring = KeychainSecureValueStore(),
        defaults: UserDefaults = .standard,
        legacyKey: String = TeamsPairingCredential.legacyDefaultsKey
    ) {
        self.secureStore = secureStore
        self.defaults = defaults
        self.legacyKey = legacyKey
    }

    func load() throws -> String? {
        try lock.withLock {
            if let data = try secureStore.load(
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            ) {
                let value = try decode(data)
                defaults.removeObject(forKey: legacyKey)
                return value
            }
            guard let legacy = defaults.string(forKey: legacyKey),
                  !legacy.isEmpty else {
                return nil
            }
            let data = Data(legacy.utf8)
            try secureStore.save(
                data,
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            )
            guard try secureStore.load(
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            ) == data else {
                throw TeamsPairingTokenStoreError.migrationVerificationFailed
            }
            defaults.removeObject(forKey: legacyKey)
            return legacy
        }
    }

    func save(_ token: String) throws {
        guard !token.isEmpty else {
            throw TeamsPairingTokenStoreError.emptyToken
        }
        try lock.withLock {
            try secureStore.save(
                Data(token.utf8),
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            )
        }
    }

    func clear() throws {
        try lock.withLock {
            var deletionError: Error?
            do {
                try secureStore.delete(
                    service: TeamsPairingCredential.service,
                    account: TeamsPairingCredential.account
                )
            } catch {
                deletionError = error
            }
            defaults.removeObject(forKey: legacyKey)
            if let deletionError {
                throw deletionError
            }
        }
    }

    private func decode(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw TeamsPairingTokenStoreError.invalidEncoding
        }
        return value
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

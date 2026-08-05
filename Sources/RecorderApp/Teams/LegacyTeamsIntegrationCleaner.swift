import Foundation

struct LegacyTeamsIntegrationCleaner {
    static let keychainService =
        "local.meeting.recorder.teams-third-party-api"
    static let keychainAccount = "pairing-token.v1"
    static let defaultsKeys = [
        "teamsMuteSyncEnabled",
        "teamsThirdPartyAPIPairingToken"
    ]

    let secureStore: any SecureValueStoring
    let defaults: UserDefaults

    func clean() throws {
        for key in Self.defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        try secureStore.delete(
            service: Self.keychainService,
            account: Self.keychainAccount
        )
    }
}

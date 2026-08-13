import Foundation
import XCTest
@testable import RecorderApp

final class RecordingDataLifecyclePolicyTests: XCTestCase {
    func testMissingPreferenceLoadsSafeDefault() {
        let defaults = makeDefaults()
        defer { clear(defaults) }

        XCTAssertEqual(
            RecordingDataLifecyclePolicyStore(defaults: defaults).load(),
            .safeDefault
        )
    }

    func testCorruptPreferenceLoadsSafeDefault() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(Data("not json".utf8), forKey: RecordingDataLifecyclePolicyStore.defaultsKey)

        XCTAssertEqual(
            RecordingDataLifecyclePolicyStore(defaults: defaults).load(),
            .safeDefault
        )
    }

    func testUnknownSchemaLoadsSafeDefault() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(
            Data(#"{"schemaVersion":99,"ownerOnlyForNewLocalArtifacts":false,"redactGeneratedDiagnostics":false,"retention":{"kind":"enabled","eligibleClasses":["transcriptionLog"],"olderThanDays":30}}"#.utf8),
            forKey: RecordingDataLifecyclePolicyStore.defaultsKey
        )

        XCTAssertEqual(
            RecordingDataLifecyclePolicyStore(defaults: defaults).load(),
            .safeDefault
        )
    }

    func testSaveAndLoadPreservesEnabledRetentionPolicy() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let expected = RecordingDataLifecyclePolicy(
            ownerOnlyForNewLocalArtifacts: false,
            redactGeneratedDiagnostics: false,
            retention: .enabled(
                eligibleClasses: [.transcriptionLog, .legacyRun],
                olderThanDays: 30
            )
        )
        let store = RecordingDataLifecyclePolicyStore(defaults: defaults)

        try store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testSaveRejectsInvalidEnabledRetentionWithoutPersistingIt() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let store = RecordingDataLifecyclePolicyStore(defaults: defaults)
        XCTAssertNoThrow(try store.save(.safeDefault))
        let persistedBefore = defaults.data(forKey: RecordingDataLifecyclePolicyStore.defaultsKey)
        let invalid = RecordingDataLifecyclePolicy(
            retention: .enabled(eligibleClasses: [], olderThanDays: 0)
        )

        XCTAssertThrowsError(try store.save(invalid)) { error in
            XCTAssertEqual(error as? RecordingDataLifecyclePolicyStoreError, .unsupportedPolicy)
        }
        XCTAssertEqual(
            defaults.data(forKey: RecordingDataLifecyclePolicyStore.defaultsKey),
            persistedBefore
        )
        XCTAssertEqual(store.load(), .safeDefault)
    }

    func testRetentionAggregateStorePersistsOnlySafeCounts() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let expected = RecordingRetentionAggregate(
            eligible: 2,
            skipped: 3,
            deleted: 1,
            errors: 0
        )
        let store = RecordingRetentionAggregateStore(defaults: defaults)

        store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "RecordingDataLifecyclePolicyTests.\(UUID().uuidString)")!
    }

    private func clear(_ defaults: UserDefaults) {
        guard let suiteName = defaults.volatileDomainNames.first(where: { $0.hasPrefix("RecordingDataLifecyclePolicyTests.") }) else {
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
    }
}

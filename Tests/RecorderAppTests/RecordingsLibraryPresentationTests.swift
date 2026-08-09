import Foundation
import XCTest
@testable import RecorderApp

final class RecordingsLibraryPresentationTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testNewestProjectionGroupsTodayYesterdayAndPriorMonth() throws {
        let fixture = try makeFixture()

        let presentation = makePresentation(fixture: fixture)

        XCTAssertEqual(presentation.itemCountText, "4 recordings")
        XCTAssertEqual(presentation.totalDurationText, "7 min total")
        XCTAssertEqual(presentation.sections.map(\.title), ["Today", "Yesterday", "July 2026"])
        XCTAssertEqual(
            presentation.sections.flatMap(\.sessions).map(\.id),
            [fixture.todayNew.id, fixture.todayOld.id, fixture.yesterday.id, fixture.july.id]
        )
    }

    func testFiltersComposeWithSearchAndInjectedTranscriptState() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(
            makePresentation(fixture: fixture, filter: .favorites)
                .sections.flatMap(\.sessions).map(\.id),
            [fixture.todayOld.id]
        )
        XCTAssertEqual(
            makePresentation(fixture: fixture, filter: .hasTranscript)
                .sections.flatMap(\.sessions).map(\.id),
            [fixture.todayNew.id, fixture.july.id]
        )
        XCTAssertEqual(
            makePresentation(fixture: fixture, filter: .needsAttention)
                .sections.flatMap(\.sessions).map(\.id),
            [fixture.yesterday.id, fixture.july.id]
        )
        XCTAssertEqual(
            makePresentation(
                fixture: fixture,
                query: RecordingLibraryQuery(text: "customer"),
                filter: .hasTranscript
            ).sections.flatMap(\.sessions).map(\.id),
            [fixture.july.id]
        )
    }

    func testOldestFirstReversesSectionsAndRowsDeterministically() throws {
        let fixture = try makeFixture()

        let presentation = makePresentation(fixture: fixture, sort: .oldestFirst)

        XCTAssertEqual(presentation.sections.map(\.title), ["July 2026", "Yesterday", "Today"])
        XCTAssertEqual(
            presentation.sections.flatMap(\.sessions).map(\.id),
            [fixture.july.id, fixture.yesterday.id, fixture.todayOld.id, fixture.todayNew.id]
        )
    }

    func testEmptyResultsHaveStableSummaryAndSections() throws {
        let fixture = try makeFixture()

        let presentation = makePresentation(
            fixture: fixture,
            query: RecordingLibraryQuery(text: "no match")
        )

        XCTAssertEqual(presentation.sections, [])
        XCTAssertEqual(presentation.itemCountText, "0 recordings")
        XCTAssertEqual(presentation.totalDurationText, "0 min total")
    }

    private func makePresentation(
        fixture: Fixture,
        query: RecordingLibraryQuery = .init(text: ""),
        filter: RecordingLibraryFilter = .all,
        sort: RecordingLibrarySort = .newestFirst
    ) -> RecordingsLibraryPresentation {
        RecordingsLibraryPresentation.make(
            sessions: fixture.sessions,
            query: query,
            filter: filter,
            sort: sort,
            now: fixture.now,
            calendar: calendar,
            hasTranscript: { fixture.transcriptIDs.contains($0.id) },
            transcriptionPhase: { fixture.phases[$0.id] }
        )
    }

    private func makeFixture() throws -> Fixture {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 8, hour: 15
        )))
        let todayNew = makeSession(
            name: "today-new", date: date(2026, 8, 8, 14), duration: 60,
            searchText: "engineering"
        )
        let todayOld = makeSession(
            name: "today-old", date: date(2026, 8, 8, 9), duration: 90,
            favorite: true, searchText: "planning"
        )
        let yesterday = makeSession(
            name: "yesterday", date: date(2026, 8, 7, 12), duration: 120,
            recovery: .recoveredAfterInterruption, searchText: "operations"
        )
        let july = makeSession(
            name: "july", date: date(2026, 7, 20, 8), duration: 150,
            searchText: "customer"
        )
        return Fixture(
            now: now,
            sessions: [july, todayOld, yesterday, todayNew],
            todayNew: todayNew,
            todayOld: todayOld,
            yesterday: yesterday,
            july: july,
            transcriptIDs: [todayNew.id, july.id],
            phases: [july.id: .failed]
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    private func makeSession(
        name: String,
        date: Date,
        duration: TimeInterval,
        favorite: Bool = false,
        recovery: RecordingRecoveryState = .none,
        searchText: String
    ) -> RecordingSession {
        let folder = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: date,
            duration: duration,
            fileSize: 1,
            metadata: .init(
                title: name,
                isFavorite: favorite,
                recoveryState: recovery
            ),
            searchDocument: .init(metadataText: searchText, transcriptText: "")
        )
    }

    private struct Fixture {
        let now: Date
        let sessions: [RecordingSession]
        let todayNew: RecordingSession
        let todayOld: RecordingSession
        let yesterday: RecordingSession
        let july: RecordingSession
        let transcriptIDs: Set<RecordingSession.ID>
        let phases: [RecordingSession.ID: TranscriptionState.Phase]
    }
}

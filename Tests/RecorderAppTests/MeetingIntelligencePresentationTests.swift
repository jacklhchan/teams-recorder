import XCTest
@testable import RecorderApp

final class MeetingIntelligencePresentationTests: XCTestCase {
    func testUnconfirmedAvailabilitySeparatesCheckFromExplicitGeneration() {
        let section = MeetingIntelligenceSectionPresentation.make(
            presentation: .init(
                phase: .notGenerated,
                summary: nil,
                suggestedTitle: nil,
                statusMessage: "Could not verify model discovery.",
                model: nil,
                titleIsProtected: false,
                unavailableReason: .discoveryUnsupported
            )
        )

        XCTAssertTrue(section.showsCheckAgain)
        XCTAssertTrue(section.showsGenerate)
        XCTAssertFalse(section.showsRetryGeneration)
    }

    func testReadyStateOffersRegenerationAndProtectedSuggestionCanBeApplied() {
        let section = MeetingIntelligenceSectionPresentation.make(
            presentation: .init(
                phase: .ready,
                summary: "Summary",
                suggestedTitle: "Project Atlas",
                statusMessage: "Ready.",
                model: "gpt-test",
                titleIsProtected: true,
                unavailableReason: nil
            )
        )

        XCTAssertTrue(section.showsRegenerate)
        XCTAssertTrue(section.showsApplySuggestedTitle)
        XCTAssertTrue(section.showsManualTitleProtection)
    }

    func testDraftTextSurvivesAnUnrelatedPresentationRerenderInSameOpenSheet() {
        XCTAssertEqual(
            TranscriptEditorDraft.loadedText(existing: "Edited draft", hasLoaded: true, load: { "Stored transcript" }),
            "Edited draft"
        )
        XCTAssertEqual(
            TranscriptEditorDraft.loadedText(existing: "", hasLoaded: false, load: { "Stored transcript" }),
            "Stored transcript"
        )
        XCTAssertEqual(
            TranscriptEditorDraft.loadedText(existing: "", hasLoaded: true, load: { "Stored transcript" }),
            ""
        )
    }
}

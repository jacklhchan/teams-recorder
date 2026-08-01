import XCTest
@testable import RecorderApp

final class MeetingIntelligencePresentationTests: XCTestCase {
    func testPhaseMatrixProjectsOneExclusiveActionGroupAndStatusTone() {
        let unconfirmed = section(.init(phase: .notGenerated, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: false, unavailableReason: .discoveryUnsupported))
        let checking = section(.init(phase: .checkingAvailability, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: false, unavailableReason: nil))
        let generating = section(.init(phase: .generating(.init(stage: .generatingFinal, current: 1, total: 1)), summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: false, unavailableReason: nil))
        let ready = section(.init(phase: .ready, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: false, unavailableReason: nil))
        let staleProtected = section(.init(phase: .stale, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: true, unavailableReason: nil))
        let failed = section(.init(phase: .failed, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: false, unavailableReason: nil))
        let cancelled = section(.init(phase: .cancelled, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: false, unavailableReason: nil))
        let interrupted = section(.init(phase: .interrupted, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: false, unavailableReason: nil))

        XCTAssertEqual(unconfirmed.actionGroup, .availability(checkAgain: true))
        XCTAssertEqual(checking.actionGroup, .working)
        XCTAssertEqual(generating.actionGroup, .working)
        XCTAssertEqual(ready.actionGroup, .ready(checkAgain: false, applySuggestedTitle: false))
        XCTAssertEqual(staleProtected.actionGroup, .ready(checkAgain: false, applySuggestedTitle: true))
        XCTAssertEqual(failed.actionGroup, .recovery(checkAgain: false, applySuggestedTitle: false))
        XCTAssertEqual(cancelled.actionGroup, .recovery(checkAgain: false, applySuggestedTitle: false))
        XCTAssertEqual(interrupted.actionGroup, .recovery(checkAgain: false, applySuggestedTitle: false))

        XCTAssertEqual(unconfirmed.statusTone, .neutral)
        XCTAssertEqual(generating.statusTone, .working)
        XCTAssertEqual(ready.statusTone, .success)
        XCTAssertEqual(failed.statusTone, .warning)
    }

    func testProtectedTitlePreservesExactVisibleCopyAndVoiceOverLabel() {
        let protected = section(.init(phase: .ready, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Status", model: "gpt-test", titleIsProtected: true, unavailableReason: nil))

        XCTAssertEqual(
            protected.manualTitleProtectionCopy,
            "The current title was edited manually. Apply the suggestion only if you want to replace it."
        )
        XCTAssertEqual(protected.manualTitleProtectionAccessibilityLabel, "Manual title protected")
    }

    func testReadyAvailabilityFeedbackKeepsDurableOutputAndAddsCheckAgain() {
        let readyUnavailable = section(.init(phase: .ready, summary: "Summary", suggestedTitle: "Suggested title", statusMessage: "Availability changed.", model: "gpt-test", titleIsProtected: false, unavailableReason: .discoveryUnsupported))

        XCTAssertEqual(readyUnavailable.actionGroup, .ready(checkAgain: true, applySuggestedTitle: false))
        XCTAssertEqual(readyUnavailable.summary, "Summary")
        XCTAssertEqual(readyUnavailable.suggestedTitle, "Suggested title")
    }

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

    private func section(_ presentation: MeetingIntelligencePresentation) -> MeetingIntelligenceSectionPresentation {
        .make(presentation: presentation)
    }
}

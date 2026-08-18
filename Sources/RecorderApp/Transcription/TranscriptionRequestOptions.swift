import Foundation

enum MeetingLanguage: String, CaseIterable, Sendable {
    case cantonese = "yue"
    case english = "en"
    case mandarin = "zh"

    var displayName: String {
        switch self {
        case .cantonese: "Cantonese"
        case .english: "English"
        case .mandarin: "Mandarin"
        }
    }
}

struct TranscriptionRequestOptions: Equatable, Sendable {
    let language: MeetingLanguage
    let prompt: String

    init(language: MeetingLanguage = .cantonese, prompt: String = "") {
        self.language = language
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

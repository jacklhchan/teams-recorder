import Foundation

enum RecordingLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case hasTranscript
    case needsAttention

    var id: Self { self }
}

enum RecordingLibrarySort: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: Self { self }
}

struct RecordingLibrarySection: Identifiable, Equatable {
    let id: String
    let title: String
    let sessions: [RecordingSession]
}

struct RecordingsLibraryPresentation: Equatable {
    let sections: [RecordingLibrarySection]
    let itemCountText: String
    let totalDurationText: String

    static func make(
        sessions: [RecordingSession],
        query: RecordingLibraryQuery,
        filter: RecordingLibraryFilter,
        sort: RecordingLibrarySort,
        now: Date,
        calendar: Calendar,
        hasTranscript: (RecordingSession) -> Bool,
        transcriptionPhase: (RecordingSession) -> TranscriptionState.Phase?
    ) -> Self {
        let visibleSessions = query.filter(sessions).filter { session in
            switch filter {
            case .all:
                true
            case .favorites:
                session.isFavorite
            case .hasTranscript:
                hasTranscript(session)
            case .needsAttention:
                session.recoveryState != .none
                    || [.failed, .cancelled, .interrupted]
                        .contains(transcriptionPhase(session))
            }
        }
        let orderedSessions = visibleSessions.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return sort == .newestFirst
                    ? lhs.id.absoluteString < rhs.id.absoluteString
                    : lhs.id.absoluteString > rhs.id.absoluteString
            }
            return sort == .newestFirst
                ? lhs.createdAt > rhs.createdAt
                : lhs.createdAt < rhs.createdAt
        }

        var sectionOrder: [String] = []
        var sectionTitles: [String: String] = [:]
        var groupedSessions: [String: [RecordingSession]] = [:]
        for session in orderedSessions {
            let section = sectionIdentity(
                for: session.createdAt,
                now: now,
                calendar: calendar
            )
            if groupedSessions[section.id] == nil {
                sectionOrder.append(section.id)
                sectionTitles[section.id] = section.title
            }
            groupedSessions[section.id, default: []].append(session)
        }

        let count = visibleSessions.count
        let duration = visibleSessions.reduce(0) {
            $0 + max(0, Int($1.duration.rounded()))
        }
        return Self(
            sections: sectionOrder.map { id in
                RecordingLibrarySection(
                    id: id,
                    title: sectionTitles[id] ?? id,
                    sessions: groupedSessions[id] ?? []
                )
            },
            itemCountText: "\(count) \(count == 1 ? "recording" : "recordings")",
            totalDurationText: durationText(seconds: duration)
        )
    }

    private static func sectionIdentity(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> (id: String, title: String) {
        if calendar.isDate(date, inSameDayAs: now) {
            return ("today", "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return ("yesterday", "Yesterday")
        }

        let components = calendar.dateComponents([.year, .month], from: date)
        let id = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM yyyy"
        return (id, formatter.string(from: date))
    }

    private static func durationText(seconds: Int) -> String {
        guard seconds > 0 else { return "0 min total" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        var components: [String] = []
        if hours > 0 { components.append("\(hours) hr") }
        if minutes > 0 { components.append("\(minutes) min") }
        if remainingSeconds > 0 { components.append("\(remainingSeconds) sec") }
        return components.joined(separator: " ") + " total"
    }
}

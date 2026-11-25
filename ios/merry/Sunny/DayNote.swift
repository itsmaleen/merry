import Foundation

/// An end-of-day note in the Planner (`day_notes`, wrinkles-planner): what
/// Marlin said about work that never became a task, and context other tasks
/// should have. Sunny reads the unread ones on its 04:30 run and records
/// what it did with each thing said.
struct DayNote: Identifiable, Equatable {
    struct Line: Equatable, Identifiable {
        /// logged, finished, context, todo or kept (see `label`).
        let kind: String
        let text: String
        let title: String?
        let index: Int
        var id: Int { index }

        var label: String {
            switch kind {
            case "logged": return "Logged as done"
            case "finished": return "Marked for you to confirm"
            case "context": return "Added to"
            case "todo": return "New task"
            default: return "Kept in the note"
            }
        }

        var icon: String {
            switch kind {
            case "logged": return "checkmark.circle"
            case "finished": return "questionmark.circle"
            case "context": return "text.append"
            case "todo": return "plus.circle"
            default: return "tray"
            }
        }
    }

    let id: String
    let date: String
    let text: String
    let createdAt: Date?
    let processedAt: Date?
    let lines: [Line]

    var isRead: Bool { processedAt != nil }

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let date = json["date"] as? String, let text = json["text"] as? String else { return nil }
        self.id = id
        self.date = date
        self.text = text
        createdAt = (json["createdAt"] as? String).flatMap(SunnyDates.parse)
        processedAt = (json["processedAt"] as? String).flatMap(SunnyDates.parse)
        lines = ((json["outcome"] as? [[String: Any]]) ?? []).enumerated().compactMap { i, l in
            guard let kind = l["kind"] as? String, let text = l["text"] as? String else { return nil }
            return Line(kind: kind, text: text, title: l["title"] as? String, index: i)
        }
    }

    /// The day a note made at `now` is about: today, or yesterday before
    /// 04:00, so a note spoken after midnight belongs to the day that just
    /// ended. Same rule as `noteDate` in the Planner API.
    static func date(for now: Date, calendar: Calendar = .current) -> String {
        let shifted = now.addingTimeInterval(-4 * 3600)
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Builds one transcript out of what the speech recogniser reports. The
/// recogniser sends the whole current phrase again on every partial result,
/// ends a phrase on its own after a pause or about a minute, and on iOS 18
/// sometimes starts its text over mid-task. Finished phrases are kept and
/// the live one is replaced, so a long note is never cut back to its tail.
struct TranscriptAccumulator: Equatable {
    private(set) var committed = ""
    private(set) var current = ""

    var text: String { Self.join(committed, current) }

    /// A new partial result for the live phrase.
    mutating func update(_ partial: String) {
        if Self.startedOver(from: current, to: partial) { commit() }
        current = partial
    }

    /// The live phrase is final; the next partial starts a new one.
    mutating func commit() {
        committed = text
        current = ""
    }

    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// A revision keeps most of the phrase; a restart is much shorter and
    /// does not begin the way the old text did.
    static func startedOver(from old: String, to new: String) -> Bool {
        guard old.count >= 12, new.count * 2 < old.count else { return false }
        return !old.lowercased().hasPrefix(new.lowercased().prefix(6))
    }
}

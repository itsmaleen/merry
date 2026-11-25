import Foundation

/// The morning digest Sunny (the Planner's overnight steward, wrinkles-planner
/// apps/sunny) writes to the Wrinkles hub as `sunny/latest.json`. Mirrors
/// `Digest` in apps/sunny/digest.ts; every field the app does not need to act
/// on is optional so an older or newer digest still decodes.
struct SunnyDigest: Decodable, Equatable {
    struct Question: Decodable, Equatable { let taskId: String; let title: String; let needs: [String] }
    struct Review: Decodable, Equatable { let taskId: String; let title: String; let verdict: String; let line: String }
    struct Stale: Decodable, Equatable { let taskId: String; let title: String; let verdict: String; let reason: String }
    struct Unblocked: Decodable, Equatable { let taskId: String; let title: String }
    struct Find: Decodable, Equatable {
        let title: String; let url: String; let kind: String; let interest: String
        let why: String; let leverage: String; let ideaId: String?
    }
    struct Proposed: Decodable, Equatable {
        let title: String; let why: String; let created: Bool; let skipped: String?; let taskId: String?
    }

    /// One thing from a day note and what Sunny did with it.
    struct NoteLine: Decodable, Equatable {
        let noteId: String; let date: String; let kind: String; let text: String; let taskId: String?; let title: String?
    }

    let date: String
    let generatedAt: String?
    let url: String?
    let counts: [String: Int]?
    let questions: [Question]
    let unblocked: [Unblocked]?
    let review: [Review]
    let stale: [Stale]?
    let finds: [Find]?
    let proposed: [Proposed]?
    let dayNotes: [NoteLine]?
    let costUsd: Double?
    let errors: [String]?
    let dry: Bool?

    /// Same wording as `headline()` in digest.ts.
    var headline: String {
        var parts: [String] = []
        if !questions.isEmpty { parts.append("\(questions.count) question\(questions.count > 1 ? "s" : "") for you") }
        if !review.isEmpty { parts.append("\(review.count) to review") }
        let said = (dayNotes ?? []).filter { $0.kind == "finished" }.count
        if said > 0 { parts.append("\(said) to confirm done") }
        if let u = unblocked, !u.isEmpty { parts.append("\(u.count) unblocked") }
        if let f = finds, !f.isEmpty { parts.append("\(f.count) research finds") }
        return parts.isEmpty ? "Nothing needs you this morning" : parts.joined(separator: ", ")
    }

    /// Everything that asks for a decision, in the order to make them:
    /// questions first (they unblock agents), then open tasks a day note
    /// said are finished, then the review pile worst first, then Sunny's kill and merge suggestions, proposals and finds.
    /// Stale tasks Sunny would keep are left out: there is nothing to decide.
    var items: [SunnyItem] {
        var out: [SunnyItem] = []
        out += questions.map { SunnyItem(kind: .question, key: $0.taskId, title: $0.title, lines: $0.needs, taskId: $0.taskId) }
        var saidDone: Set<String> = []
        for n in dayNotes ?? [] where n.kind == "finished" {
            guard let id = n.taskId, saidDone.insert(id).inserted else { continue }
            out.append(SunnyItem(kind: .done, key: id, title: n.title ?? n.text, detail: n.text, taskId: id, caption: "From your day note, \(n.date)"))
        }
        let order = ["redo": 0, "look": 1, "approve": 2]
        out += review.sorted { (order[$0.verdict] ?? 3) < (order[$1.verdict] ?? 3) }
            .map { SunnyItem(kind: .review, key: $0.taskId, title: $0.title, verdict: $0.verdict, detail: $0.line, taskId: $0.taskId) }
        out += (stale ?? []).filter { $0.verdict != "keep" }
            .map { SunnyItem(kind: .stale, key: $0.taskId, title: $0.title, verdict: $0.verdict, detail: $0.reason, taskId: $0.taskId) }
        out += (proposed ?? []).compactMap { p in
            guard let id = p.taskId else { return nil }
            return SunnyItem(kind: .proposal, key: id, title: p.title, detail: p.why, taskId: id)
        }
        out += (finds ?? []).map {
            SunnyItem(kind: .find, key: $0.url, title: $0.title, verdict: $0.kind,
                      detail: $0.why, lines: ["Use it: " + $0.leverage], link: URL(string: $0.url), rawLink: $0.url,
                      ideaId: $0.ideaId, caption: $0.interest)
        }
        return out
    }
}

struct SunnyItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case question, done, review, stale, proposal, find
        var id: String { rawValue }
        var label: String {
            switch self {
            case .question: return "Questions"
            case .done: return "Said done"
            case .review: return "Review"
            case .stale: return "Stale"
            case .proposal: return "Proposals"
            case .find: return "Finds"
            }
        }
        var singular: String {
            switch self {
            case .question: return "Question"
            case .done: return "You said it's done"
            case .review: return "Review"
            case .stale: return "Stale task"
            case .proposal: return "Proposed task"
            case .find: return "Research find"
            }
        }
        var icon: String {
            switch self {
            case .question: return "questionmark.bubble"
            case .done: return "mic"
            case .review: return "checkmark.seal"
            case .stale: return "hourglass"
            case .proposal: return "lightbulb"
            case .find: return "sparkle.magnifyingglass"
            }
        }
    }

    let kind: Kind
    let key: String
    let title: String
    var verdict: String? = nil
    var detail: String? = nil
    var lines: [String] = []
    var link: URL? = nil
    /// The find's address as Sunny wrote it, for the agent's brief.
    var rawLink: String? = nil
    var taskId: String? = nil
    var ideaId: String? = nil
    var caption: String? = nil

    var id: String { "\(kind.rawValue):\(key)" }
}

/// What a decision does. Each case names the Planner write it makes, so the
/// store's switch is the whole contract.
enum SunnyAction: Equatable {
    /// Append the answer to the task's brief and clear its needs, which makes
    /// agent work ready.
    case answer(String)
    /// Complete the task.
    case approve
    /// Complete an open task a day note said was finished.
    case complete
    /// Append the note to the brief and set the task back to ready.
    case redo(String)
    /// The work stands; ask for one more thing. Appends it to the brief and
    /// starts the agent again on the desktop.
    case followUp(String)
    /// Complete a stale task Sunny suggested killing.
    case kill
    /// A find worth keeping: an agent files it in the Wrinkles wiki.
    case file
    /// A find becomes Marlin's own Planner task (the note is optional), and
    /// an agent files it in the wiki.
    case makeTask(String)
    /// Leave it as it is.
    case keep
    /// Delete one of Sunny's own proposals or finds.
    case drop
    /// Not now: move it to the back of the deck. Nothing is written.
    case later

    /// The text typed with the decision, if any.
    var note: String? {
        switch self {
        case .answer(let text), .redo(let text), .followUp(let text): return text
        case .makeTask(let text): return text.isEmpty ? nil : text
        default: return nil
        }
    }

    var outcome: String {
        switch self {
        case .answer: return "answered"
        case .approve: return "approved"
        case .complete: return "completed"
        case .redo: return "sent back"
        case .followUp: return "follow-up sent"
        case .kill: return "killed"
        case .keep: return "kept"
        case .file: return "filing in the wiki"
        case .makeTask: return "made a task"
        case .drop: return "dropped"
        case .later: return "later"
        }
    }
}

/// A card that has been decided, for the "Decided" list.
struct SunnyDecision: Identifiable, Equatable {
    let item: SunnyItem
    let outcome: String
    let note: String?
    var id: String { item.id }
}

/// The Planner task behind a card: what "Show more" adds to Sunny's one line.
struct SunnyTaskContext: Equatable {
    var brief: String?
    var notes: String?
    var needs: [String] = []
    var mode: String?
    var priority: String?
    var scheduledDate: String?
    var agentStatus: String?
    var agentActivity: String?
    var agentSession: String?
    var completed = false
    var createdAt: Date?
    /// The Planner's dated log for the task, oldest first.
    var events: [SunnyEvent] = []

    /// When the agent last asked for something.
    var askedAt: Date? { events.last { $0.kind == "asked" }?.at }
    /// When an agent session last started.
    var startedAt: Date? { events.last { $0.kind == "started" }?.at }
    /// The agent's latest sign of life: a start, a progress line or a hand-back.
    var agentAt: Date? { events.last { ["started", "activity", "review"].contains($0.kind) && !$0.isMine }?.at }

    /// "Created 9 Nov · Asked today · Agent update 30 Oct", with whatever is known.
    var dateLine: String {
        var parts: [String] = []
        if let d = createdAt { parts.append("Created " + SunnyDates.day(d)) }
        if let d = askedAt { parts.append("Asked " + SunnyDates.day(d)) }
        if let d = agentAt { parts.append("Agent update " + SunnyDates.day(d)) }
        return parts.joined(separator: " · ")
    }

    /// The log to show: "created" comes from the task when the log began later.
    var timeline: [SunnyEvent] {
        var out = events
        if let d = createdAt, !out.contains(where: { $0.kind == "created" }) {
            out.insert(SunnyEvent(kind: "created", text: nil, at: d), at: 0)
        }
        out.sort { $0.at < $1.at }
        // An answer from Merry is logged twice (needs cleared, and its line);
        // keep the one that says who did it.
        return out.enumerated().filter { i, e in
            guard e.kind == "answered", i + 1 < out.count else { return true }
            return !(out[i + 1].isMine && out[i + 1].at.timeIntervalSince(e.at) < 5)
        }.map(\.element)
    }

    init(_ task: [String: Any]) {
        func text(_ key: String) -> String? {
            (task[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        brief = text("brief")
        notes = text("notes")
        needs = task["agentNeeds"] as? [String] ?? []
        mode = text("mode")
        priority = text("priority")
        scheduledDate = text("scheduledDate")
        agentStatus = text("agentStatus")
        agentActivity = text("agentActivity")
        agentSession = text("agentSession")
        completed = text("completedAt") != nil
        createdAt = text("createdAt").flatMap(SunnyDates.parse)
        events = (task["events"] as? [[String: Any]] ?? []).compactMap { e in
            guard let kind = e["kind"] as? String, let at = (e["at"] as? String).flatMap(SunnyDates.parse) else { return nil }
            return SunnyEvent(kind: kind, text: (e["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }, at: at)
        }
        // A Planner without the log still has the latest agent date.
        if events.isEmpty, let at = text("agentActivityAt").flatMap(SunnyDates.parse) {
            events = [SunnyEvent(kind: "activity", text: agentActivity, at: at)]
        }
    }

    /// One line of facts: "P1 · pair · needs brief · 2026-11-11".
    var facts: String {
        [priority, mode, agentStatus?.replacingOccurrences(of: "_", with: " "),
         completed ? "completed" : nil, scheduledDate]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// One dated line of a task's log in the Planner.
struct SunnyEvent: Equatable {
    let kind: String
    let text: String?
    let at: Date

    /// Merry writes Marlin's own answer or redo as the task's activity line.
    var isMine: Bool {
        kind == "activity" && ["Answered from Merry", "Sent back from Merry", "Follow-up from Merry", "Kept from Merry"].contains { text?.hasPrefix($0) == true }
    }

    var label: String {
        if isMine {
            if text?.hasPrefix("Answered") == true { return "You answered" }
            if text?.hasPrefix("Kept") == true { return "You kept it" }
            return text?.hasPrefix("Follow-up") == true ? "You asked for a follow-up" : "You sent it back"
        }
        switch kind {
        case "created": return "Created"
        case "asked": return "Agent asked for"
        case "answered": return "Answered"
        case "started": return "Session started"
        case "activity": return "Agent update"
        case "review": return "Session finished, back for review"
        case "completed": return "Completed"
        case "reopened": return "Reopened"
        default: return kind.capitalized
        }
    }
}

enum SunnyDates {
    static func parse(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// "today", "yesterday", "9 Nov", or "9 Nov 2025" for another year.
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }

    /// Day and time for the timeline: "9 Nov, 14:55".
    static func stamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return day(date, now: now, calendar: calendar) + ", " + f.string(from: date)
    }
}

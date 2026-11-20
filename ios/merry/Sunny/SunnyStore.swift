import Foundation
import SwiftUI

/// Loads Sunny's digest from the Wrinkles hub and writes decisions to the
/// Planner API. The Planner trusts the owner's tailnet devices, so the phone
/// gets a session from `/auth/trusted-session` with no key or password.
@MainActor
final class SunnyStore: ObservableObject {
    static let digestURLKey = "sunnyDigestURL"
    static let plannerURLKey = "sunnyPlannerURL"
    static let defaultDigestURL = "https://ms-mac-mini.tail901772.ts.net/wrinkles/sunny/latest.json"
    static let defaultPlannerURL = "http://ms-mac-mini.tail901772.ts.net:3579"

    @Published private(set) var digest: SunnyDigest?
    @Published private(set) var isLoading = false
    @Published var error: String?
    /// Decisions made on this digest, by item id. Kept per digest date so a
    /// relaunch doesn't show finished cards again.
    @Published private(set) var handled: [String: String] = [:]
    /// Cards put off with "later" this session; they go to the back.
    @Published private(set) var deferred: [String] = []
    @Published private(set) var busy: Set<String> = []
    /// What Marlin typed with a decision (an answer, a redo note), by item id.
    @Published private(set) var notes: [String: String] = [:]
    /// The Planner task behind a card, by task id, once "Show more" asked.
    @Published private(set) var contexts: [String: SunnyTaskContext] = [:]
    @Published private(set) var contextErrors: [String: String] = [:]

    private var token: String?

    var digestURL: String {
        UserDefaults.standard.string(forKey: Self.digestURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultDigestURL
    }
    var plannerURL: String {
        UserDefaults.standard.string(forKey: Self.plannerURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultPlannerURL
    }
    /// The digest page on the hub, for "open the full page".
    var pageURL: URL? {
        if let u = digest?.url, let url = URL(string: u) { return url }
        return URL(string: digestURL.replacingOccurrences(of: "latest.json", with: ""))
    }

    /// Undecided cards, put-off ones last.
    var pending: [SunnyItem] {
        let open = (digest?.items ?? []).filter { handled[$0.id] == nil }
        let later = Set(deferred)
        return open.filter { !later.contains($0.id) } + deferred.compactMap { id in open.first { $0.id == id } }
    }

    func pending(_ kind: SunnyItem.Kind?) -> [SunnyItem] {
        guard let kind else { return pending }
        return pending.filter { $0.kind == kind }
    }

    var total: Int { digest?.items.count ?? 0 }

    /// Cards already decided on this digest, in digest order.
    var decided: [SunnyDecision] {
        (digest?.items ?? []).compactMap { item in
            handled[item.id].map { SunnyDecision(item: item, outcome: $0, note: notes[item.id]) }
        }
    }

    // MARK: - Loading

    func load() async {
        guard !isLoading else { return }
        if let fixture = Self.fixtureDigest() { apply(fixture); return }
        guard let url = URL(string: digestURL) else { error = "The digest URL is not valid."; return }
        isLoading = true
        defer { isLoading = false }
        do {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 404 {
                error = "No digest yet. Sunny publishes one after its 04:30 run."
                return
            }
            apply(try JSONDecoder().decode(SunnyDigest.self, from: data))
            error = nil
        } catch {
            self.error = "Couldn't load the digest: \(error.localizedDescription)"
        }
    }

    private func apply(_ d: SunnyDigest) {
        if d.date != digest?.date { deferred = [] }
        digest = d
        handled = UserDefaults.standard.dictionary(forKey: handledKey(d.date)) as? [String: String] ?? [:]
        notes = UserDefaults.standard.dictionary(forKey: notesKey(d.date)) as? [String: String] ?? [:]
    }

    private func handledKey(_ date: String) -> String { "sunnyHandled.\(date)" }
    private func notesKey(_ date: String) -> String { "sunnyNotes.\(date)" }

    // MARK: - Context

    /// Loads the task's brief, notes and agent state for the detail sheet.
    /// Read-only, so it also runs against a fixture digest.
    func loadContext(for item: SunnyItem, force: Bool = false) async {
        guard let id = item.taskId, force || contexts[id] == nil else { return }
        do {
            let data = try await planner("GET", "tasks/\(id)", nil)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let task = obj?["data"] as? [String: Any] else { throw SunnyError("the Planner sent no task") }
            contexts[id] = SunnyTaskContext(task)
            contextErrors[id] = nil
        } catch {
            contextErrors[id] = "Couldn't load the task: \(error.localizedDescription)"
        }
    }

    /// `-SunnyFixture <path>` in the launch arguments loads a digest file
    /// instead of the hub, for the simulator and screenshots.
    private static func fixtureDigest() -> SunnyDigest? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SunnyFixture"), i + 1 < args.count,
              let data = FileManager.default.contents(atPath: args[i + 1]) else { return nil }
        return try? JSONDecoder().decode(SunnyDigest.self, from: data)
    }

    private var isFixture: Bool { ProcessInfo.processInfo.arguments.contains("-SunnyFixture") }

    // MARK: - Decisions

    func perform(_ action: SunnyAction, on item: SunnyItem) async -> Bool {
        if action == .later {
            deferred.removeAll { $0 == item.id }
            deferred.append(item.id)
            return true
        }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        do {
            if !isFixture { try await write(action, item) }
            mark(item, action.outcome, note: action.note)
            if let id = item.taskId { contexts[id] = nil }
            return true
        } catch {
            self.error = "\(action.outcome.capitalized) didn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Takes back the last local mark (the Planner write stays as it is).
    func unmark(_ item: SunnyItem) {
        guard let date = digest?.date else { return }
        handled[item.id] = nil
        UserDefaults.standard.set(handled, forKey: handledKey(date))
    }

    private func mark(_ item: SunnyItem, _ outcome: String, note: String?) {
        guard let date = digest?.date else { return }
        handled[item.id] = outcome
        notes[item.id] = note
        deferred.removeAll { $0 == item.id }
        UserDefaults.standard.set(handled, forKey: handledKey(date))
        UserDefaults.standard.set(notes, forKey: notesKey(date))
    }

    private func write(_ action: SunnyAction, _ item: SunnyItem) async throws {
        let stamp = Self.day.string(from: Date())
        switch action {
        case .answer(let text):
            let id = try need(item.taskId)
            let brief = try await currentBrief(id)
            let added = "Marlin's answer (\(stamp), from Merry): \(text)"
            try await planner("PATCH", "tasks/\(id)", [
                "brief": [brief, added].compactMap { $0 }.joined(separator: "\n\n"),
                "agentNeeds": [String](),
                "agentActivity": "Answered from Merry",
            ])
        case .approve, .kill:
            try await planner("PATCH", "tasks/\(try need(item.taskId))", ["completedAt": ISO8601DateFormatter().string(from: Date())])
        case .redo(let note):
            let id = try need(item.taskId)
            let brief = try await currentBrief(id)
            try await planner("PATCH", "tasks/\(id)", [
                "brief": [brief, "Redo (\(stamp)): \(note)"].compactMap { $0 }.joined(separator: "\n\n"),
                "agentStatus": "ready",
                "agentActivity": "Sent back from Merry: \(note.prefix(80))",
            ])
        case .file:
            try await fileFind(item, then: nil)
        case .followUp(let note) where item.kind == .find:
            try await fileFind(item, then: note)
        case .makeTask(let note):
            // The idea becomes Marlin's own task; filing it is a second,
            // agent task so his stays his.
            let id = try await taskForFind(item)
            if !note.isEmpty {
                let data = try await planner("GET", "tasks/\(id)", nil)
                let task = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
                let notes = (task?["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                try await planner("PATCH", "tasks/\(id)", ["notes": [notes, "Marlin (\(stamp), from Merry): \(note)"].compactMap { $0 }.joined(separator: "\n\n")])
            }
            let filing = try await planner("POST", "tasks", [
                "title": String("File in the wiki: \(item.title)".prefix(480)),
                "notes": findNotes(item),
                "mode": "agent",
                "brief": filingBrief(item, then: nil),
                "agentNeeds": [String](),
            ])
            if let fid = ((try JSONSerialization.jsonObject(with: filing) as? [String: Any])?["data"] as? [String: Any])?["id"] as? String {
                await startAgent(fid)
            }
        case .followUp(let note):
            let id = try need(item.taskId)
            let brief = try await currentBrief(id)
            try await planner("PATCH", "tasks/\(id)", [
                "brief": [brief, "Follow-up (\(stamp), from Merry): \(note)"].compactMap { $0 }.joined(separator: "\n\n"),
                "agentStatus": "ready",
                "agentActivity": "Follow-up from Merry: \(note.prefix(260))",
            ])
            await startAgent(id)
        case .drop:
            if item.kind == .find, let idea = item.ideaId {
                try await planner("DELETE", "ideas/\(idea)", nil)
            } else if item.kind == .proposal {
                try await planner("DELETE", "tasks/\(try need(item.taskId))", nil)
            }
        case .keep, .later:
            break
        }
    }

    /// Starts the task's agent on the desktop. What was written is saved
    /// either way; when the desktop is full or off the task stays ready.
    private func startAgent(_ id: String) async {
        do {
            try await planner("POST", "tasks/\(id)/agent/start", nil)
        } catch {
            self.error = "Saved, but the agent didn't start: \(error.localizedDescription) It stays ready in the Planner."
        }
    }

    /// The Planner task for a find: its idea promoted (the same task every
    /// time), or a new task when the find never reached the Ideas board.
    private func taskForFind(_ item: SunnyItem) async throws -> String {
        let data: Data
        let path: [String]
        if let idea = item.ideaId {
            data = try await planner("POST", "ideas/\(idea)/promote", [String: Any]())
            path = ["data", "task", "id"]
        } else {
            data = try await planner("POST", "tasks", ["title": String(item.title.prefix(480)), "notes": findNotes(item)])
            path = ["data", "id"]
        }
        var node: Any? = try JSONSerialization.jsonObject(with: data)
        for key in path { node = (node as? [String: Any])?[key] }
        guard let id = node as? String else { throw SunnyError("the Planner sent no task for this find") }
        return id
    }

    /// Keep or follow up on a find: its task becomes agent work that files
    /// the source in the wiki (and then does `then`), and starts.
    private func fileFind(_ item: SunnyItem, then: String?) async throws {
        let id = try await taskForFind(item)
        try await planner("PATCH", "tasks/\(id)", [
            "mode": "agent",
            "brief": filingBrief(item, then: then),
            "agentNeeds": [String](),
            "agentStatus": "ready",
            "agentActivity": String((then.map { "Follow-up from Merry: \($0)" } ?? "Kept from Merry: file it in the wiki").prefix(290)),
        ])
        await startAgent(id)
    }

    private func findNotes(_ item: SunnyItem) -> String {
        [item.rawLink, item.caption, item.detail.map { "Why: \($0)" }, item.lines.first].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func filingBrief(_ item: SunnyItem, then: String?) -> String {
        var parts = [
            "File this source in the Wrinkles wiki, following the ingest workflow in the wiki's CLAUDE.md: fetch \(item.rawLink ?? item.title), save a copy under raw/, write its source summary in wiki/articles/, update the pages it touches, and add it to INDEX.md and log.md.",
            "Sunny found it overnight\(item.caption.map { " for the interest \"\($0)\"" } ?? ""). \(item.detail.map { "Why it matters: \($0)" } ?? "") \(item.lines.first ?? "")",
            "Done means the article exists and is linked from INDEX.md. Put the article's slug in the task notes. Don't publish anything publicly.",
        ]
        if let then {
            parts.append("Follow-up (\(Self.day.string(from: Date())), from Merry): after filing it, \(then)")
        }
        return String(parts.joined(separator: "\n\n").prefix(4800))
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func need(_ id: String?) throws -> String {
        guard let id else { throw SunnyError("this card has no Planner task") }
        return id
    }

    private func currentBrief(_ id: String) async throws -> String? {
        let data = try await planner("GET", "tasks/\(id)", nil)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let task = obj?["data"] as? [String: Any]
        return (task?["brief"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Planner API

    @discardableResult
    private func planner(_ method: String, _ path: String, _ body: [String: Any]?, retry: Bool = true) async throws -> Data {
        guard let base = URL(string: plannerURL) else { throw SunnyError("the Planner URL is not valid") }
        if token == nil { token = try await trustedSession(base) }
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {
            token = nil
            return try await planner(method, path, body, retry: false)
        }
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["message"] as? String }
            throw SunnyError(msg ?? "the Planner answered \(status)")
        }
        return data
    }

    private func trustedSession(_ base: URL) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("auth/trusted-session"), timeoutInterval: 15)
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (obj["data"] as? [String: Any])?["token"] as? String
        else { throw SunnyError("the Planner didn't trust this phone (is Tailscale on?)") }
        return token
    }
}

struct SunnyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

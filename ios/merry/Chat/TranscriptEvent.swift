import Foundation

/// One item of an agent conversation as the bridge sends it with
/// `claude.transcript` `format: "events"` (see plans/session-ui.md).
///
/// Decoded from JSONSerialization dictionaries, not Codable: the reply is
/// already parsed into `[String: Any]` by BridgeClient, and every field but
/// `id`/`kind` is optional, so a missing or oddly typed field degrades to an
/// empty value instead of dropping the whole transcript.
///
/// UIKit-free on purpose: exercised by `ios/scripts/test-chat-grouping.swift`.
struct TranscriptEvent: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case user, text, tool, question
    }

    enum ToolStatus: String, Sendable {
        case running, ok, error
    }

    struct Option: Equatable, Sendable {
        let label: String
        let description: String
    }

    struct Question: Equatable, Sendable {
        let question: String
        let header: String
        let multi: Bool
        let options: [Option]
    }

    let id: String
    let kind: Kind
    /// Unix seconds, when the bridge knows them.
    let ts: Double?
    /// `user` and `text`: the message. Empty for the other kinds.
    var text: String = ""
    // `tool` fields.
    var tool: String = ""
    var arg: String = ""
    var status: ToolStatus = .ok
    var output: String?
    var added: Int?
    var removed: Int?
    // `question` fields.
    var questions: [Question] = []
    var answered: Bool = false
    var answer: String?
    // `user` slash-command fields (contract "Slash commands and scheduled
    // runs"). An older bridge sends "/name args" as plain `text` with no
    // `command`; that stays an ordinary user turn.
    /// The command with its slash ("/loop"); `text` then holds only the args.
    var command: String?
    /// The harness injected a skill prompt for the command.
    var skillLoaded: Bool = false
    /// The harness fired this line, not the human.
    var scheduled: Bool = false
    /// 1-based count of a scheduled task's fires so far.
    var run: Int?
    /// What a local command printed (`/model` → "Set model to …"), shown as
    /// a quiet line under its chip. nil when it printed nothing.
    var commandOutput: String?
    /// `commandOutput` came from stderr.
    var commandError: Bool = false
    /// Sent while the agent was working and not delivered yet (contract
    /// "Queued messages"): always after every other event, never part of
    /// the conversation proper.
    var queued: Bool = false
    /// The harness compacted the conversation here. The summary it wrote is
    /// not sent; the row is a quiet divider, never a bubble from the human.
    var compacted: Bool = false

    init(id: String, kind: Kind, ts: Double? = nil, text: String = "", tool: String = "", arg: String = "",
         status: ToolStatus = .ok, output: String? = nil, added: Int? = nil, removed: Int? = nil,
         questions: [Question] = [], answered: Bool = false, answer: String? = nil,
         command: String? = nil, skillLoaded: Bool = false, scheduled: Bool = false, run: Int? = nil,
         queued: Bool = false, commandOutput: String? = nil, commandError: Bool = false) {
        self.id = id
        self.kind = kind
        self.ts = ts
        self.text = text
        self.tool = tool
        self.arg = arg
        self.status = status
        self.output = output
        self.added = added
        self.removed = removed
        self.questions = questions
        self.answered = answered
        self.answer = answer
        self.command = command
        self.skillLoaded = skillLoaded
        self.scheduled = scheduled
        self.run = run
        self.queued = queued
        self.commandOutput = commandOutput
        self.commandError = commandError
    }

    /// nil for an entry with no id or a kind this build doesn't know, so a
    /// newer bridge can add kinds without breaking older phones.
    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty,
              let kindRaw = dict["kind"] as? String,
              let kind = Kind(rawValue: kindRaw) else { return nil }
        self.id = id
        self.kind = kind
        self.ts = Self.number(dict["ts"])
        self.text = dict["text"] as? String ?? ""
        self.tool = dict["tool"] as? String ?? ""
        self.arg = dict["arg"] as? String ?? ""
        // An unknown status reads as still running: the safe assumption for a
        // call whose result we can't interpret.
        self.status = (dict["status"] as? String).flatMap(ToolStatus.init(rawValue:)) ?? .running
        if kind != .tool { self.status = .ok }
        let output = dict["output"] as? String
        self.output = (output?.isEmpty == false) ? output : nil
        self.added = Self.number(dict["added"]).map { Int($0) }
        self.removed = Self.number(dict["removed"]).map { Int($0) }
        self.answered = dict["answered"] as? Bool ?? false
        self.answer = dict["answer"] as? String
        if kind == .user {
            let command = (dict["command"] as? String)?.trimmingCharacters(in: .whitespaces)
            self.command = (command?.isEmpty == false) ? command : nil
            self.skillLoaded = dict["skill_loaded"] as? Bool ?? false
            self.scheduled = dict["scheduled"] as? Bool ?? false
            self.run = Self.number(dict["run"]).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            self.queued = dict["queued"] as? Bool ?? false
            self.compacted = dict["compacted"] as? Bool ?? false
            let output = (dict["command_output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.commandOutput = (output?.isEmpty == false) ? output : nil
            self.commandError = self.commandOutput != nil && (dict["command_error"] as? Bool ?? false)
        }
        self.questions = (dict["questions"] as? [[String: Any]] ?? []).map { q in
            Question(
                question: q["question"] as? String ?? "",
                header: q["header"] as? String ?? "",
                multi: q["multi"] as? Bool ?? false,
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                }
            )
        }
    }

    /// What the human typed, as they typed it: "/loop 5m check the deploy"
    /// for a command, the text otherwise.
    var typedText: String {
        guard let command else { return text }
        return text.isEmpty ? command : command + " " + text
    }

    /// Decodes a reply's `events` array, skipping entries it can't read.
    /// Ids are made unique (the later entry wins, at the earlier position):
    /// every list on screen is keyed by id, and a repeated id in a SwiftUI
    /// ForEach draws the wrong rows or traps.
    static func decodeList(_ raw: Any?) -> [TranscriptEvent] {
        uniqued((raw as? [[String: Any]] ?? []).compactMap(TranscriptEvent.init))
    }

    /// `events` with each id once: a repeat replaces the first occurrence's
    /// content and is dropped from its own position. Returns the input
    /// untouched (no copy) in the normal case of no repeats.
    static func uniqued(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        var index: [String: Int] = [:]
        index.reserveCapacity(events.count)
        var out: [TranscriptEvent]?
        for (i, e) in events.enumerated() {
            if let first = index[e.id] {
                if out == nil { out = Array(events[..<i]) }
                out?[first] = e
            } else {
                index[e.id] = out?.count ?? i
                out?.append(e)
            }
        }
        return out ?? events
    }

    /// JSON numbers arrive as NSNumber (Int or Double); accept either, and a
    /// numeric string from a loose encoder.
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// What a session is waiting on from the human, from the reply's `pending`.
struct PendingState: Equatable, Sendable {
    enum Kind: String, Sendable {
        case approval, question, unknown
    }

    let kind: Kind
    let eventID: String?
    let tool: String?
    let arg: String?

    init(kind: Kind, eventID: String? = nil, tool: String? = nil, arg: String? = nil) {
        self.kind = kind
        self.eventID = eventID
        self.tool = tool
        self.arg = arg
    }

    /// nil for JSON null, a missing field, or something unreadable. An
    /// unrecognised kind is treated as `unknown`: the session is still waiting,
    /// and the live-screen peek is the honest way to show a block we can't parse.
    init?(_ raw: Any?) {
        guard let dict = raw as? [String: Any] else { return nil }
        let kindRaw = dict["kind"] as? String ?? "unknown"
        self.kind = Kind(rawValue: kindRaw) ?? .unknown
        self.eventID = dict["event_id"] as? String
        self.tool = dict["tool"] as? String
        self.arg = dict["arg"] as? String
    }
}

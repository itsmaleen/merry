import Foundation

/// A message the phone just sent from the composer, shown at once ("Sending")
/// until the transcript carries it (contract "Queued messages").
///
/// UIKit-free on purpose: exercised by `ios/scripts/test-chat-paging.swift`.
struct LocalEcho: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case sending
        /// A plain message with no matching event after
        /// `ChatOutbox.confirmWindow`, while the agent never started working:
        /// "Not delivered?" for one more poll, then removed. Never resent.
        case unconfirmed
    }

    let id: String
    /// What was typed, as typed ("/loop 5m check the deploy" for a command).
    let text: String
    /// Unix seconds.
    let sentAt: Double
    var state: State = .sending
    /// A dialog opened on the live screen after this was sent (a picker the
    /// command opened). When it closes the command is done, whatever the
    /// transcript says: a cancelled picker writes nothing.
    var sawDialog = false
    /// The agent went to working after this was sent: it was received.
    var sawWorking = false

    init(id: String, text: String, sentAt: Double, state: State = .sending) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
        self.state = state
    }

    /// A slash command ("/model"): drawn as a chip with no status label.
    var isCommand: Bool { ChatOutbox.splitCommand(text).command != nil }
}

/// A row at the very bottom of the chat that isn't conversation yet: a queued
/// event from the bridge, or a local echo.
struct OutboxItem: Equatable, Identifiable {
    enum Label: Equatable {
        case queued, sending, unconfirmed

        var text: String {
            switch self {
            case .queued: return "Queued"
            case .sending: return "Sending"
            case .unconfirmed: return "Not delivered?"
            }
        }
    }

    let id: String
    /// The typed text, split like a user event: `command` set for a slash
    /// command, with `text` holding only its args.
    let command: String?
    let text: String
    /// nil for a just-sent slash command: a picker it opens can take as long
    /// as the human likes, so there is nothing to say about it.
    let label: Label?

    init(event: TranscriptEvent) {
        id = event.id
        command = event.command
        text = event.text
        label = .queued
    }

    init(echo: LocalEcho) {
        id = "local:" + echo.id
        let split = ChatOutbox.splitCommand(echo.text)
        command = split.command
        text = split.args
        if split.command != nil {
            label = nil
        } else {
            label = echo.state == .sending ? .sending : .unconfirmed
        }
    }

    var typedText: String {
        guard let command else { return text }
        return text.isEmpty ? command : command + " " + text
    }
}

enum ChatOutbox {
    /// How long a local echo waits for its event.
    static let confirmWindow: Double = 60
    /// How long "Not confirmed" stays up: about one poll cycle.
    static let unconfirmedLinger: Double = 5
    /// Clock slack between the phone and the machine stamping events.
    static let clockSlack: Double = 5

    /// "/loop 5m check" → ("/loop", "5m check"); plain text has no command.
    static func splitCommand(_ typed: String) -> (command: String?, args: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return (nil, trimmed) }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let name = String(parts[0])
        let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (name, args)
    }

    static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The echoes still to show after `events` landed at `now`: each echo
    /// whose text a user event (queued or not) carries, stamped at or after
    /// the send (less `clockSlack`), is dropped; one event answers one echo.
    /// Unmatched after `confirmWindow`: a command is dropped silently (a
    /// picker it opened may have been cancelled, which writes nothing), as is
    /// a message the agent evidently received (`sawWorking`); any other
    /// message turns `.unconfirmed` and is removed `unconfirmedLinger` later.
    static func resolve(_ echoes: [LocalEcho], events: [TranscriptEvent], now: Double) -> [LocalEcho] {
        guard !echoes.isEmpty else { return echoes }
        // Only the newest user events can answer a just-sent message; walking
        // back from the end keeps this cheap on a 3000-event list.
        var candidates: [TranscriptEvent] = []
        for e in events.reversed() where e.kind == .user && !e.scheduled && !e.compacted {
            candidates.append(e)
            if candidates.count >= 20 { break }
        }
        var used = Set<String>()
        var out: [LocalEcho] = []
        for echo in echoes {
            let want = normalized(echo.text)
            let match = candidates.first { e in
                !used.contains(e.id) && normalized(e.typedText) == want
                    && (e.ts.map { $0 >= echo.sentAt - clockSlack } ?? true)
            }
            if let match {
                used.insert(match.id)
                continue
            }
            let age = now - echo.sentAt
            if age >= confirmWindow && (echo.isCommand || echo.sawWorking) { continue }
            if age >= confirmWindow + unconfirmedLinger { continue }
            var kept = echo
            if age >= confirmWindow { kept.state = .unconfirmed }
            out.append(kept)
        }
        return out
    }

    /// A dialog appeared on the live screen at `now`: the commands sent
    /// before it are the ones that opened it.
    static func dialogOpened(_ echoes: [LocalEcho], now: Double) -> [LocalEcho] {
        echoes.map { e in
            guard e.isCommand, !e.sawDialog, e.sentAt <= now + clockSlack else { return e }
            var e = e
            e.sawDialog = true
            return e
        }
    }

    /// The dialog closed: the commands that opened it are done (picked or
    /// cancelled), so their echoes go. A pick that printed something comes
    /// back as the command's own event with `command_output`.
    static func dialogClosed(_ echoes: [LocalEcho]) -> [LocalEcho] {
        echoes.filter { !($0.isCommand && $0.sawDialog) }
    }

    /// The agent went to working at `now`: every message sent before then
    /// was received.
    static func agentWorking(_ echoes: [LocalEcho], now: Double) -> [LocalEcho] {
        echoes.map { e in
            guard !e.sawWorking, e.sentAt <= now else { return e }
            var e = e
            e.sawWorking = true
            return e
        }
    }
}

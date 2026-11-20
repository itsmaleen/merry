import Foundation

/// Slash-command suggestions for the chat composer: offered while the draft
/// is a bare "/name" (no space yet), filtered by prefix.
///
/// UIKit-free on purpose: exercised by `ios/scripts/test-chat-grouping.swift`.
enum SlashCommands {
    /// Common Claude Code commands, offered on every agent surface.
    static let builtIn: [String] = [
        "/loop", "/clear", "/compact", "/model", "/resume", "/review", "/code-review",
        "/init", "/memory", "/context", "/cost", "/help", "/fast", "/config",
        "/agents", "/mcp", "/permissions", "/status",
    ]

    /// The commands this surface's transcript has run, most recent first,
    /// each once.
    static func seen(in events: [TranscriptEvent]) -> [String] {
        var out: [String] = []
        for e in events.reversed() {
            guard let c = e.command, !out.contains(c) else { continue }
            out.append(c)
        }
        return out
    }

    /// Suggestions for `draft`, or none when it isn't a bare "/name".
    /// `seen` (most recent first) comes before the built-in list; a command
    /// appears once. Matching ignores case.
    static func suggestions(draft: String, seen: [String], builtIn: [String] = builtIn) -> [String] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let query = draft.lowercased()
        var out: [String] = []
        var keys = Set<String>()
        for c in seen + builtIn {
            let key = c.lowercased()
            guard key.hasPrefix("/"), key.hasPrefix(query), !keys.contains(key) else { continue }
            keys.insert(key)
            out.append(c)
        }
        // The draft already is the only match: nothing left to offer.
        if out.count == 1, out[0].lowercased() == query { return [] }
        return out
    }
}

import Foundation

/// One row of the chat body: what the transcript's events become on screen.
enum ChatItem: Equatable, Identifiable {
    case user(TranscriptEvent)
    case assistant(TranscriptEvent)
    /// Every tool call between two pieces of prose, folded into one row.
    case work(WorkGroup)
    case question(TranscriptEvent)
    /// A slash command the human ran ("/loop 5m …"), shown as a chip.
    case command(TranscriptEvent)
    /// A line the harness fired on a schedule, shown as a quiet divider.
    case scheduled(TranscriptEvent)
    case compacted(TranscriptEvent)
    /// Not conversation yet: a queued message or one the phone just sent.
    /// Always after every other row.
    case outbox(OutboxItem)

    var id: String {
        switch self {
        case .user(let e), .assistant(let e), .question(let e), .command(let e), .scheduled(let e), .compacted(let e): return e.id
        case .work(let g): return g.id
        case .outbox(let o): return o.id
        }
    }

    var isOutbox: Bool {
        if case .outbox = self { return true }
        return false
    }
}

/// A run of tool calls shown as "Worked 2m · read 4 files, ran 2 commands".
struct WorkGroup: Equatable {
    /// The first tool's id, so the row keeps its identity (and its expanded
    /// state) while later calls join the run.
    let id: String
    let tools: [TranscriptEvent]
    /// Seconds, when the events carry timestamps; nil otherwise.
    let duration: Double?
    var isRunning: Bool { tools.contains { $0.status == .running } }
    var failedCount: Int { tools.filter { $0.status == .error }.count }

    /// "Worked 2m", "Working 40s", or just "Worked" with no timestamps.
    var title: String {
        let verb = isRunning ? "Working" : "Worked"
        guard let duration, let text = ChatGrouping.formatDuration(duration) else { return verb }
        return "\(verb) \(text)"
    }

    /// "read 4 files, ran 2 commands".
    var summary: String { ChatGrouping.summary(of: tools) }

    var label: String {
        let s = summary
        return s.isEmpty ? title : "\(title) · \(s)"
    }
}

/// How one tool call reads as a single line in an expanded work row.
struct ToolLine: Equatable {
    enum Category: Equatable {
        case read, edit, command, search, web, agent, todo, other
    }

    let category: Category
    /// "Read", "Edited", "Ran", "Searched".
    let verb: String
    /// The file's name, the command, or the quoted pattern.
    let subject: String
    /// Right-hand detail: "failed", "running", "+9 −2", or empty.
    let detail: String
}

/// The one-sentence state of a session, for small cards and switcher tiles.
struct Glance: Equatable {
    enum Status: Equatable {
        /// A question is waiting for an answer.
        case asks
        /// A tool call is waiting for permission.
        case approve
        /// Blocked on something the chat couldn't parse (the live-screen peek).
        case waiting
        case working
        case done
    }

    let status: Status
    let sentence: String
    let added: Int
    let removed: Int

    var needsYou: Bool { status == .asks || status == .approve || status == .waiting }
}

/// Pure transforms from transcript events to what the chat body draws.
/// UIKit-free on purpose: exercised by `ios/scripts/test-chat-grouping.swift`.
enum ChatGrouping {

    // MARK: - Items

    /// The conversation proper: everything but queued messages.
    static func conversation(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        events.contains(where: \.queued) ? events.filter { !$0.queued } : events
    }

    /// Groups events into chat items. Every run of consecutive tool events
    /// becomes one work row; user, assistant and question events stand alone.
    /// Queued events and local echoes follow as outbox rows, real queued
    /// events first; they never join or end a work row.
    static func items(from all: [TranscriptEvent], local: [LocalEcho] = []) -> [ChatItem] {
        let events = conversation(all)
        var items: [ChatItem] = []
        var run: [TranscriptEvent] = []

        func flush(nextIndex: Int) {
            guard !run.isEmpty else { return }
            // The run's work ended when whatever follows it was written; the
            // last call's own stamp is when it STARTED, so using it would
            // under-count a long command.
            // A run still going has no end yet; the view can't tick a clock
            // from here, so it shows "Working" without a span.
            let stillRunning = nextIndex >= events.count && run.contains { $0.status == .running }
            let end = nextIndex < events.count ? events[nextIndex].ts : (stillRunning ? nil : run.last?.ts)
            items.append(.work(WorkGroup(id: run[0].id, tools: run, duration: duration(from: run.first?.ts, to: end))))
            run = []
        }

        for (index, event) in events.enumerated() {
            switch event.kind {
            case .tool:
                run.append(event)
            case .user:
                flush(nextIndex: index)
                if event.compacted {
                    items.append(.compacted(event))
                } else if event.scheduled {
                    items.append(.scheduled(event))
                } else if event.command != nil {
                    items.append(.command(event))
                } else {
                    items.append(.user(event))
                }
            case .text:
                // Blank prose (a turn that was only tool calls) would otherwise
                // split one run into two rows with nothing between them.
                if event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                flush(nextIndex: index)
                items.append(.assistant(event))
            case .question:
                flush(nextIndex: index)
                items.append(.question(event))
            }
        }
        flush(nextIndex: events.count)
        for e in all where e.queued && e.kind == .user { items.append(.outbox(OutboxItem(event: e))) }
        for echo in local { items.append(.outbox(OutboxItem(echo: echo))) }
        return items
    }

    static func duration(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return end - start
    }

    /// "40s", "2m", "1h 5m". nil for a negative span.
    static func formatDuration(_ seconds: Double) -> String? {
        guard seconds >= 0 else { return nil }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(1, s))s" }
        if s < 3600 { return "\(s / 60)m" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
    }

    // MARK: - Commands and scheduled runs

    /// "Loop" for "/loop": the command without its slash, capitalised.
    static func commandTitle(_ command: String) -> String {
        let name = command.hasPrefix("/") ? String(command.dropFirst()) : command
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "Loop run 4", "Loop run", "Scheduled run 4", "Scheduled run".
    static func scheduledTitle(_ event: TranscriptEvent) -> String {
        let name = event.command.map(commandTitle) ?? "Scheduled"
        return event.run.map { "\(name) run \($0)" } ?? "\(name) run"
    }

    /// The divider's text: "Loop run 4 · 2:15 PM"; the time is left off
    /// when the event has none.
    static func scheduledLabel(_ event: TranscriptEvent, time: String?) -> String {
        guard let time, !time.isEmpty else { return scheduledTitle(event) }
        return "\(scheduledTitle(event)) · \(time)"
    }

    // MARK: - Tool lines

    static func category(of tool: String) -> ToolLine.Category {
        // opencode names its tools in lowercase; Claude in PascalCase.
        switch tool.lowercased() {
        case "read", "notebookread", "view": return .read
        case "edit", "write", "multiedit", "notebookedit", "patch", "apply_patch": return .edit
        case "bash", "bashoutput", "killshell", "killbash", "shell": return .command
        case "grep", "glob", "list", "ls", "search", "codesearch": return .search
        case "webfetch", "websearch", "fetch": return .web
        case "task", "agent": return .agent
        case "todowrite", "todoread", "todo": return .todo
        default: return .other
        }
    }

    static func line(for event: TranscriptEvent) -> ToolLine {
        let cat = category(of: event.tool)
        let firstLine = event.arg.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let verb: String
        let subject: String
        switch cat {
        case .read: verb = "Read"; subject = basename(firstLine)
        case .edit: verb = "Edited"; subject = basename(firstLine)
        case .command: verb = "Ran"; subject = firstLine
        case .search: verb = "Searched"; subject = firstLine.isEmpty ? "" : "“\(firstLine)”"
        case .web: verb = "Fetched"; subject = firstLine
        case .agent: verb = "Agent"; subject = firstLine
        case .todo: verb = "Updated todos"; subject = ""
        case .other: verb = event.tool.isEmpty ? "Tool" : event.tool; subject = firstLine
        }
        let detail: String
        switch event.status {
        case .error: detail = "failed"
        case .running: detail = "running"
        case .ok:
            if let a = event.added, let r = event.removed { detail = "+\(a) −\(r)" }
            else if let a = event.added { detail = "+\(a)" }
            else { detail = "" }
        }
        return ToolLine(category: cat, verb: verb, subject: subject, detail: detail)
    }

    /// The last path component of a file argument; anything that isn't a
    /// path (no slash) comes back unchanged.
    static func basename(_ path: String) -> String {
        guard path.contains("/") else { return path }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    /// "read 4 files, ran 2 commands". Files count once however often they
    /// were touched; commands and searches count every call.
    static func summary(of tools: [TranscriptEvent]) -> String {
        var read = Set<String>(), edited = Set<String>()
        var commands = 0, searches = 0, web = 0, agents = 0, todos = 0, other = 0
        for t in tools {
            switch category(of: t.tool) {
            case .read: read.insert(t.arg)
            case .edit: edited.insert(t.arg)
            case .command: commands += 1
            case .search: searches += 1
            case .web: web += 1
            case .agent: agents += 1
            case .todo: todos += 1
            case .other: other += 1
            }
        }
        var parts: [String] = []
        if !read.isEmpty { parts.append("read \(plural(read.count, "file"))") }
        if !edited.isEmpty { parts.append("edited \(plural(edited.count, "file"))") }
        if commands > 0 { parts.append("ran \(plural(commands, "command"))") }
        if searches > 0 { parts.append(plural(searches, "search", "searches")) }
        if web > 0 { parts.append(plural(web, "web lookup")) }
        if agents > 0 { parts.append(plural(agents, "agent")) }
        if other > 0 { parts.append("used \(plural(other, "tool"))") }
        if todos > 0 && parts.isEmpty { parts.append("updated todos") }
        return parts.joined(separator: ", ")
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (many ?? one + "s"))"
    }

    // MARK: - Glance

    /// Status plus one sentence for a small card: the pending call or question
    /// if there is one, else the first sentence of the last assistant text.
    static func glance(events all: [TranscriptEvent], pending: PendingState?, agentStatus: String?, isWorking: Bool) -> Glance {
        let events = conversation(all)
        let tools = events.filter { $0.kind == .tool }
        let added = tools.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = tools.reduce(0) { $0 + ($1.removed ?? 0) }

        let status: Glance.Status
        var sentence: String?
        switch pending?.kind {
        case .question:
            status = .asks
            let q = events.last(where: { $0.id == pending?.eventID }) ?? events.last(where: { $0.kind == .question })
            sentence = q?.questions.first?.question
        case .approval:
            status = .approve
            let event = events.last(where: { $0.id == pending?.eventID })
            let tool = pending?.tool ?? event?.tool ?? ""
            let arg = pending?.arg ?? event?.arg ?? ""
            sentence = approvalSentence(tool: tool, arg: arg)
        case .unknown:
            status = .waiting
            sentence = "Waiting on you in the terminal."
        case nil:
            if agentStatus == "blocked" {
                status = .waiting
                sentence = "Waiting on you in the terminal."
            } else if agentIsWorking(agentStatus: agentStatus, screenActive: isWorking) {
                status = .working
            } else {
                status = .done
            }
        }
        if sentence?.isEmpty ?? true {
            let lastText = events.last(where: { $0.kind == .text && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            // One sentence, or two when the first is too short to say much
            // ("Found it.").
            sentence = lastText.map { leadSentences(of: $0.text) } ?? "No reply yet."
        }
        return Glance(status: status, sentence: sentence ?? "", added: added, removed: removed)
    }

    /// The one rule for "the agent is working". A backend that reports agent
    /// status (herdr) is the only word: working means `"working"`. Without
    /// one (cmux), the screen-activity heuristic stands in. A trailing tool
    /// call with no result never means working on its own: an interrupted
    /// turn or a background agent call leaves one behind for good.
    static func agentIsWorking(agentStatus: String?, screenActive: Bool) -> Bool {
        if let agentStatus { return agentStatus == "working" }
        return screenActive
    }

    /// "Wants to run `gh pr create`", "Wants to edit ssh.go".
    static func approvalSentence(tool: String, arg: String) -> String {
        let firstLine = arg.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        switch category(of: tool) {
        case .command: return firstLine.isEmpty ? "Wants to run a command." : "Wants to run `\(firstLine)`"
        case .edit: return "Wants to edit \(basename(firstLine))"
        case .read: return "Wants to read \(basename(firstLine))"
        case .web: return "Wants to fetch \(firstLine)"
        default: return firstLine.isEmpty ? "Wants to use \(tool)" : "Wants to use \(tool): \(firstLine)"
        }
    }

    /// The first sentence of some markdown prose, as plain-ish text: heading
    /// and list markers dropped, kept to one line, capped at `limit`.
    static func firstSentence(of text: String, limit: Int = 180) -> String {
        cap(sentences(inLeadLineOf: text).first ?? "", limit)
    }

    /// Sentences from the start of some prose until they reach `minLength`
    /// characters, capped at `limit`: enough to fill a glance tile's lines
    /// when the first sentence alone says little ("Found it.").
    static func leadSentences(of text: String, minLength: Int = 60, limit: Int = 180) -> String {
        var out = ""
        for sentence in sentences(inLeadLineOf: text) {
            out = out.isEmpty ? sentence : out + " " + sentence
            if out.count >= minLength { break }
        }
        return cap(out, limit)
    }

    private static func cap(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }

    /// The first non-empty line of prose (block markdown and bold markers
    /// dropped), split into sentences. A sentence ends at . ! or ? followed
    /// by a space, but not inside inline code, where "a.b c" is a path.
    static func sentences(inLeadLineOf text: String) -> [String] {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("```") }) ?? ""
        var s = Substring(line)
        while let f = s.first, "#>-*".contains(f) { s = s.dropFirst() }
        let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
        var result: [String] = []
        var current = ""
        var inCode = false
        var i = clean.startIndex
        while i < clean.endIndex {
            let c = clean[i]
            current.append(c)
            if c == "`" { inCode.toggle() }
            let next = clean.index(after: i)
            if !inCode, ".!?".contains(c), next < clean.endIndex, clean[next] == " " {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            i = next
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    // MARK: - Questions

    /// Whether a question can be answered by one number key: a single,
    /// single-select question with at most nine options. Claude's question
    /// dialog numbers its options and takes the digit as the choice; several
    /// questions or multi-select need its tab and space navigation, which the
    /// live-screen peek is for.
    static func canAnswerByKey(_ event: TranscriptEvent) -> Bool {
        guard event.kind == .question, !event.answered, event.questions.count == 1,
              let q = event.questions.first else { return false }
        return !q.multi && (1...9).contains(q.options.count)
    }

    // MARK: - Plain text

    /// The conversation as plain text, in the bridge's old text-mode style,
    /// for the places that still render text: the Terminal toggle, find in
    /// surface, and the history fallback.
    static func plainText(_ events: [TranscriptEvent]) -> String {
        var out: [String] = []
        var lastSpeaker: TranscriptEvent.Kind?
        for e in events {
            switch e.kind {
            case .user where e.queued:
                out.append("")
                out.append("› You (queued)")
                out.append(e.typedText)
                lastSpeaker = .user
            case .user where e.compacted:
                out.append("")
                out.append("— Earlier conversation summarized —")
                lastSpeaker = .user
            case .user where e.scheduled:
                out.append("")
                out.append("— \(scheduledTitle(e)) —")
                lastSpeaker = .user
            case .user:
                out.append("")
                out.append("› You")
                out.append(e.typedText)
                if let output = e.commandOutput {
                    out.append(contentsOf: output.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "  ⎿ " + $0 })
                }
                lastSpeaker = .user
            case .text:
                if lastSpeaker != .text {
                    out.append("")
                    out.append("⏺ Claude")
                }
                out.append(e.text)
                lastSpeaker = .text
            case .tool:
                let suffix = e.status == .error ? " (failed)" : ""
                out.append("⚙ \(e.tool): \(e.arg)\(suffix)")
                if e.status == .error, let output = e.output { out.append(output) }
            case .question:
                for q in e.questions {
                    out.append("? \(q.question)")
                    for (i, o) in q.options.enumerated() { out.append("  \(i + 1). \(o.label)") }
                }
                if let answer = e.answer { out.append("→ \(answer)") }
            }
        }
        while out.first == "" { out.removeFirst() }
        return out.joined(separator: "\n")
    }

    // MARK: - Find

    /// The text find matches in one chat row: what the row shows, plus a
    /// work row's calls (which open when a match is in them).
    static func searchText(_ item: ChatItem) -> String {
        switch item {
        case .user(let e), .assistant(let e): return e.text
        case .command(let e): return e.typedText + (e.commandOutput.map { "\n" + $0 } ?? "")
        case .scheduled(let e): return scheduledTitle(e) + "\n" + e.text
        case .compacted: return "Earlier conversation summarized"
        case .question(let e):
            return (e.questions.flatMap { [$0.question] + $0.options.map(\.label) } + [e.answer ?? ""])
                .joined(separator: "\n")
        case .work(let g):
            return g.tools.map { t in
                let l = line(for: t)
                return [l.verb, t.arg, t.output ?? ""].joined(separator: " ")
            }.joined(separator: "\n")
        case .outbox(let o): return o.typedText
        }
    }

    /// One entry per match, in order: the id of the row it is in. Capped at
    /// `TextSearch.maxMatches` by the caller's matcher.
    static func matchRows(_ items: [ChatItem], query: String, matcher: (String, String) -> Int, cap: Int) -> [String] {
        guard !query.isEmpty else { return [] }
        var out: [String] = []
        for item in items {
            let n = matcher(query, searchText(item))
            if n > 0 { out.append(contentsOf: repeatElement(item.id, count: min(n, cap - out.count))) }
            if out.count >= cap { break }
        }
        return out
    }
}

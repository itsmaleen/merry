import SwiftUI

/// Colours for the chat and glance bodies, from the session-UI mockups
/// (wiki merry_session_ui_nov2026): a dark-only palette like the rest of Merry.
enum ChatStyle {
    static let fg = Color(white: 0.96)
    static let prose = Color(white: 0.925)
    static let sub = Color(white: 0.54)
    static let dim = Color(white: 0.40)
    static let line = Color.white.opacity(0.08)
    static let bubble = Color(white: 0.135)
    static let panel = Color(red: 0.10, green: 0.106, blue: 0.106)
    static let accent = Color(red: 0.204, green: 0.42, blue: 0.945)
    static let ok = Color(red: 0.204, green: 0.827, blue: 0.6)
    static let warn = Color(red: 1.0, green: 0.69, blue: 0.125)
    static let bad = Color(red: 1.0, green: 0.39, blue: 0.40)
}

/// The conversation as chat rows: user turns in a bubble, assistant prose
/// without one, tool runs folded into work rows that open on tap. Shared by
/// the focused surface and the full-screen history (terminal-mode agents).
///
/// System type with Dynamic Type styles throughout; monospace only for code.
/// Text is selectable: a long-press starts a selection, so the surface
/// claims no long-press of its own.
///
/// Hosted in a UIScrollView, so not lazy: every row it is given is built.
/// ChatCardBody hands it a bounded window of rows. Rows are Equatable and
/// keyed by id, so a tail poll that changes only the last event re-renders
/// only that row.
struct ChatTranscriptView: View, Equatable {
    /// What sits above the first row. Every case but `none` is one row of
    /// the same height, so the spinner coming and going never moves the
    /// conversation; only a landed page does (and that is compensated).
    enum Top: Equatable {
        case none
        /// Older events exist; the row waits empty for the spinner.
        case more
        /// A page of older events is on its way.
        case loading
        /// Nothing older exists.
        case start
        /// Older events exist but this phone keeps no more (ChatPaging.maxKept).
        case capped
    }

    let items: [ChatItem]
    let expanded: Set<String>
    let onToggle: (String) -> Void
    /// Long-press copies a whole table cell, tool line or chip; prose, code
    /// and bubbles select by range (SelectableProse).
    var selectable = true
    /// A trailing "Working…" line when the session is busy but its last row
    /// doesn't already say so.
    var showsWorking = false
    /// A question the pinned sheet is already showing, left out here so it
    /// doesn't appear twice.
    var hiddenQuestionID: String? = nil
    var top: Top = .none
    /// "New since you were here" goes above the row with this id.
    var markerBeforeID: String? = nil
    var markerLabel: String = ""
    /// The current find match's row: lightly highlighted.
    var highlightID: String? = nil
    /// Rows whose top (in this view's coordinates) is reported, for opening
    /// on the marker and scrolling to a find match. Only these rows pay for
    /// a geometry read.
    var trackedID: String? = nil
    var onMarkerY: ((CGFloat) -> Void)? = nil
    var onTrackedY: ((String, CGFloat) -> Void)? = nil

    static let space = "chatContent"

    /// What it draws; the closures are left out. Lets the hosting scroll
    /// view skip an update that changes nothing (a poll that only touched
    /// the plain text, a frame on another surface).
    static func == (a: ChatTranscriptView, b: ChatTranscriptView) -> Bool {
        a.items == b.items && a.expanded == b.expanded && a.selectable == b.selectable
            && a.showsWorking == b.showsWorking && a.hiddenQuestionID == b.hiddenQuestionID && a.top == b.top
            && a.markerBeforeID == b.markerBeforeID && a.markerLabel == b.markerLabel
            && a.highlightID == b.highlightID && a.trackedID == b.trackedID
    }

    var body: some View {
        // Top-aligned, like a document: a short conversation starts at the
        // top instead of floating above the composer with a gap on top.
        VStack(alignment: .leading, spacing: 16) {
            topRow
            if items.isEmpty {
                Text("No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(items.filter { $0.id != hiddenQuestionID }) { item in
                if item.id == markerBeforeID {
                    NewSinceDivider(label: markerLabel)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { y in
                            onMarkerY?(y)
                        }
                }
                ChatRow(item: item, isExpanded: expanded.contains(item.id), isHighlighted: item.id == highlightID,
                        tracksY: item.id == trackedID, onToggle: onToggle, onY: onTrackedY)
                    .equatable()
            }
            if showsWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Working…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        // Links read as underlined text in the text's colour, not blue.
        .tint(.primary)
        .modifier(SelectableText(enabled: selectable))
    }

    @ViewBuilder
    private var topRow: some View {
        switch top {
        case .none:
            EmptyView()
        case .more:
            Color.clear.frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                .accessibilityLabel("Loading earlier messages")
        case .start:
            Text("Start of conversation")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        case .capped:
            Text("Earlier messages aren't kept on this phone")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        }
    }
}

/// One chat row. Equatable on what it draws (the closures are left out), so
/// SwiftUI skips the body of every row a poll didn't change.
struct ChatRow: View, Equatable {
    let item: ChatItem
    let isExpanded: Bool
    let isHighlighted: Bool
    let tracksY: Bool
    let onToggle: (String) -> Void
    let onY: ((String, CGFloat) -> Void)?

    static func == (a: ChatRow, b: ChatRow) -> Bool {
        a.item == b.item && a.isExpanded == b.isExpanded && a.isHighlighted == b.isHighlighted && a.tracksY == b.tracksY
    }

    var body: some View {
        let row = content
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                        .padding(.horizontal, -10)
                        .padding(.vertical, -6)
                }
            }
        if tracksY {
            row.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ChatTranscriptView.space)).minY } action: { y in
                onY?(item.id, y)
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .user(let e):
            UserBubble(text: e.text, isExpanded: isExpanded) { onToggle(e.id) }
        case .assistant(let e):
            MarkdownBlocks(text: e.text)
        case .work(let g):
            WorkRowView(group: g, isExpanded: isExpanded) { onToggle(g.id) }
        case .question(let e):
            QuestionRecordView(event: e)
        case .command(let e):
            CommandChipView(event: e, isExpanded: isExpanded) { onToggle(e.id) }
        case .scheduled(let e):
            ScheduledRunDivider(event: e, isExpanded: isExpanded) { onToggle(e.id) }
        case .compacted(let e):
            NewSinceDivider(label: e.ts.map { "Earlier conversation summarized · " + Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? "Earlier conversation summarized")
        case .outbox(let o):
            OutboxRowView(item: o)
        }
    }
}

/// The human's turn: a bubble on the right, about 80% of the width at most.
/// A long one (a pasted summary, a log) shows its first lines and "Show
/// all" (LongText): drawn whole it would cost ~100 MB of layer memory.
struct UserBubble: View {
    let text: String
    var isExpanded = false
    var onToggle: () -> Void = {}

    var body: some View {
        let preview = LongText.preview(text)
        HStack {
            Spacer(minLength: 64)
            VStack(alignment: .leading, spacing: 6) {
                if let preview, !isExpanded {
                    SelectableProse(text: ChatMarkdown.inline(preview), hugsWidth: true)
                } else {
                    ForEach(Array(LongText.chunks(text).enumerated()), id: \.offset) { _, piece in
                        SelectableProse(text: ChatMarkdown.inline(piece), hugsWidth: true)
                    }
                }
                if preview != nil {
                    Button(isExpanded ? "Show less" : "Show all") { onToggle() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.c.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// A message not in the conversation yet: queued behind the agent's turn,
/// or just sent from this phone. The bubble (or command chip) it will become,
/// dimmed, with "Queued" / "Sending" / "Not delivered?" under it (a
/// just-sent slash command has no label).
struct OutboxRowView: View {
    let item: OutboxItem

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Group {
                if let command = item.command {
                    HStack {
                        Spacer(minLength: 64)
                        HStack(spacing: 6) {
                            Text(command)
                                .font(.subheadline.monospaced().weight(.semibold))
                                .foregroundStyle(.primary)
                                .layoutPriority(1)
                            if !item.text.isEmpty {
                                Text(item.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.c.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                } else {
                    UserBubble(text: item.text)
                }
            }
            .opacity(0.7)
            if let label = item.label {
                Text(label.text)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

/// "New since you were here · 3h ago": where the last visit ended, in the
/// same quiet divider style as a scheduled run.
struct NewSinceDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            rule
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            rule
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Commands and scheduled runs

/// A slash command the human ran, where their bubble would be: the name in
/// monospace and the first line of its args, one line. Tap opens the full
/// args (selectable in history) and notes a loaded skill prompt. What a
/// local command printed sits under it as a quiet line, three lines at most
/// until the chip is opened; red only when it came from stderr.
struct CommandChipView: View {
    let event: TranscriptEvent
    let isExpanded: Bool
    let onToggle: () -> Void

    private var firstLine: String {
        event.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
    private var hasMore: Bool { !event.text.isEmpty || event.skillLoaded || event.commandOutput != nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            chip
            if let output = event.commandOutput {
                Text(ChatMarkdown.inline(output))
                    .font(.footnote)
                    .foregroundStyle(event.commandError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 64)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
                    .accessibilityLabel(event.commandError ? "Error: \(output)" : output)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var chip: some View {
        HStack {
            Spacer(minLength: 64)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Text(event.command ?? "")
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                            .layoutPriority(1)
                        if !isExpanded && !firstLine.isEmpty {
                            Text(firstLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasMore)
                .accessibilityLabel(event.typedText)
                .accessibilityHint(hasMore ? (isExpanded ? "Hides the details" : "Shows the full command") : "")

                if isExpanded {
                    if !event.text.isEmpty {
                        Text(event.text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if event.skillLoaded {
                        Text("Loaded skill prompt")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.c.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// A line the harness fired on a schedule: a centred quiet divider,
/// "Loop run 4 · 2:15 PM", never a bubble from the human. Tap shows what it
/// sent.
struct ScheduledRunDivider: View {
    let event: TranscriptEvent
    let isExpanded: Bool
    let onToggle: () -> Void

    private var label: String {
        let time = event.ts.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) }
        return ChatGrouping.scheduledLabel(event, time: time)
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    rule
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    rule
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(event.text.isEmpty)
            .accessibilityLabel(label)
            .accessibilityHint(event.text.isEmpty ? "" : (isExpanded ? "Hides what it sent" : "Shows what it sent"))

            if isExpanded && !event.text.isEmpty {
                Text(event.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}

private struct SelectableText: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content }
    }
}

// MARK: - Work row

/// "Worked 2m · 6 steps" and a chevron; tap for the per-type breakdown and
/// one line per call. "· 1 failed" in red text only when something did.
struct WorkRowView: View {
    let group: WorkGroup
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    (Text(group.title + " · " + ChatGrouping.plural(group.tools.count, "step"))
                     + Text(group.failedCount > 0 ? " · \(group.failedCount) failed" : "").foregroundColor(.red))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.label)
            .accessibilityHint(isExpanded ? "Hides the tool calls" : "Shows each tool call")

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if !group.summary.isEmpty {
                        Text(group.summary.prefix(1).uppercased() + group.summary.dropFirst())
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 2)
                    }
                    ForEach(group.tools) { tool in
                        ToolLineView(event: tool)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

struct ToolLineView: View {
    let event: TranscriptEvent

    var body: some View {
        let line = ChatGrouping.line(for: event)
        let failed = event.status == .error
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: failed ? "xmark.circle" : icon(line.category))
                    .font(.footnote)
                    .foregroundStyle(failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                    .frame(width: 20)
                (Text(line.verb).foregroundColor(failed ? .red : nil)
                 + Text(ChatMarkdown.linked(line.subject.isEmpty ? "" : " " + line.subject)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                detail(line)
            }
            .frame(minHeight: 26)
            if failed, let output = event.output {
                Text(ChatMarkdown.linked(output))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    // Its full height: the row's HStack sibling otherwise
                    // squeezes a multi-line tail down to one truncated line.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func detail(_ line: ToolLine) -> some View {
        if let a = event.added, event.status == .ok {
            Text("+\(a)" + (event.removed.map { " −\($0)" } ?? ""))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
        } else if !line.detail.isEmpty, event.status != .error {
            Text(line.detail)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func icon(_ c: ToolLine.Category) -> String {
        switch c {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .command: return "terminal"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .agent: return "person.2"
        case .todo: return "checklist"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// A question in the transcript. While unanswered the pinned sheet carries
/// the choices; here it only marks where it was asked.
struct QuestionRecordView: View {
    let event: TranscriptEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(event.questions.enumerated()), id: \.offset) { _, q in
                Label(q.question, systemImage: "questionmark.bubble")
                    .font(.subheadline)
                    .foregroundStyle(event.answered ? .secondary : .primary)
            }
            if event.answered {
                Text("→ " + (event.answer ?? "answered"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
    }
}

// MARK: - Markdown

/// Lightweight markdown: inline styling through AttributedString, fenced code
/// blocks in monospace, headings bold, list markers as bullets. Enough for an
/// agent's prose; pipe tables become a grid (or one card per row when they
/// are too wide for a phone). Nested lists read as plain text.
enum ChatMarkdown {
    enum Block: Equatable {
        case prose(String)
        case heading(String)
        case code(String)
        case table(MarkdownTable)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var prose: [String] = []
        var code: [String]?
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty {
                // Blank lines split paragraphs so each gets its own spacing.
                for para in joined.components(separatedBy: "\n\n") where !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(.prose(para))
                }
            }
            prose = []
        }
        let lines = text.components(separatedBy: "\n")
        var skip = 0
        for (index, raw) in lines.enumerated() {
            if skip > 0 { skip -= 1; continue }
            if code == nil, raw.contains("|"), let found = MarkdownTable.parse(lines, from: index) {
                flushProse()
                out.append(.table(found.table))
                skip = found.count - 1
                continue
            }
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code {
                    out.append(.code(c.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flushProse()
                out.append(.heading(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(raw.prefix(while: { $0 == " " }))
                prose.append(indent + "• " + trimmed.dropFirst(2))
            } else {
                prose.append(raw)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushProse()
        return out
    }

    static func inline(_ text: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return linked(parsed)
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Plain text with its bare URLs made links.
    static func linked(_ text: String) -> AttributedString { linked(AttributedString(text)) }

    /// Bare URLs become links (markdown links already are), skipping inline
    /// code; every link is underlined. Its colour is the text's own (the chat
    /// tints links primary): blue is kept for the one primary action.
    static func linked(_ input: AttributedString) -> AttributedString {
        var attr = input
        let plain = String(attr.characters)
        if let detector = linkDetector, plain.contains("://") || plain.contains("www.") {
            let ns = plain as NSString
            for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
                guard let url = match.url, let range = Range(match.range, in: attr) else { continue }
                let slice = attr[range]
                let isCode = slice.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }
                let isLinked = slice.runs.contains { $0.link != nil }
                guard !isCode, !isLinked else { continue }
                attr[range].link = url
            }
        }
        for run in attr.runs where run.link != nil {
            attr[run.range].underlineStyle = .single
        }
        return attr
    }
}

/// Parsed markdown per message text, so a row mounted again (the window
/// growing, a surface reopened) doesn't re-parse. Bounded; dropped on a
/// memory warning.
enum ChatMarkdownCache {
    final class Entry {
        let blocks: [ChatMarkdown.Block]
        let inline: [Int: AttributedString]
        /// Per table block: its header cells, then each row's cells.
        let tables: [Int: [[AttributedString]]]
        init(blocks: [ChatMarkdown.Block], inline: [Int: AttributedString], tables: [Int: [[AttributedString]]]) {
            self.blocks = blocks
            self.inline = inline
            self.tables = tables
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 400
        return c
    }()

    static func entry(_ text: String) -> Entry {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let blocks = ChatMarkdown.blocks(text)
        var inline: [Int: AttributedString] = [:]
        var tables: [Int: [[AttributedString]]] = [:]
        for (i, b) in blocks.enumerated() {
            switch b {
            case .prose(let p), .heading(let p): inline[i] = ChatMarkdown.inline(p)
            case .code: break
            case .table(let t):
                tables[i] = ([t.header] + t.rows).map { $0.map(ChatMarkdown.inline) }
            }
        }
        let entry = Entry(blocks: blocks, inline: inline, tables: tables)
        cache.setObject(entry, forKey: key)
        return entry
    }

    static func removeAll() { cache.removeAllObjects() }
}

struct MarkdownBlocks: View {
    let text: String

    var body: some View {
        let parsed = ChatMarkdownCache.entry(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parsed.blocks.enumerated()), id: \.offset) { i, block in
                switch block {
                case .prose(let p) where p.count > 1500:
                    // One layer per piece, not one unbounded layer.
                    ForEach(Array(LongText.chunks(p).enumerated()), id: \.offset) { _, piece in
                        SelectableProse(text: ChatMarkdown.inline(piece))
                    }
                case .prose(let p):
                    SelectableProse(text: parsed.inline[i] ?? AttributedString(p))
                case .heading(let h):
                    SelectableProse(text: parsed.inline[i] ?? AttributedString(h), style: .heading)
                case .code(let c):
                    // Wrapped, not scrolled: readable without a sideways
                    // drag on a phone. Long code is drawn in pieces.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(LongText.chunks(c).enumerated()), id: \.offset) { _, piece in
                            SelectableProse(text: AttributedString(piece), style: .code)
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .table(let t):
                    MarkdownTableView(table: t, cells: parsed.tables[i] ?? [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A table sized for a phone: up to three columns as a grid whose cells
/// wrap; wider ones as one card per row, the first column as its title and
/// the rest as "Header  value" lines, so nothing needs a sideways scroll.
struct MarkdownTableView: View {
    let table: MarkdownTable
    /// Styled cells: the header row, then each data row.
    let cells: [[AttributedString]]

    private var header: [AttributedString] { cells.first ?? table.header.map { AttributedString($0) } }
    private var rows: [[AttributedString]] { cells.count > 1 ? Array(cells.dropFirst()) : [] }

    var body: some View {
        Group {
            if table.columnCount <= 3 { grid } else { cards }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(cell)
                            .font(.subheadline)
                            .fontWeight(column == 0 ? .medium : .regular)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 5) {
                    if let title = row.first {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(row.enumerated().dropFirst()), id: \.offset) { column, cell in
                        if !cell.characters.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(column < header.count ? header[column] : AttributedString(""))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 96, alignment: .leading)
                                Text(cell)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                if index < rows.count - 1 { Divider().padding(.leading, 12) }
            }
        }
    }
}

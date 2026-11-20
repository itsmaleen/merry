import SwiftUI

/// Panels pinned above the composer while the session waits on you. Every
/// answer goes out as the TUI's own keys through `surface.send_key`, so the
/// terminal stays the source of truth: if a panel guessed wrong, the screen
/// shows what actually happened.
///
/// Approval, question and peek share one container (`PendingPanel`): the same
/// shape, material, padding and caption, so "waiting on you" always looks the
/// same whatever it is waiting for.

// MARK: - Approval

/// "Edit ssh.go", the exact argument, then Deny / Allow side by side and the
/// session-wide option as a text button under them. Keys stay the dialog's
/// own: Deny 3, Allow 1, the second option 2.
struct ApprovalSheet: View {
    let tool: String
    let arg: String
    let since: Double?
    let onKey: (String) -> Void
    @State private var argExpanded = false

    var body: some View {
        let category = ChatGrouping.category(of: tool)
        PendingPanel(caption: "Approval needed", since: since) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title(category))
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !arg.isEmpty {
                    Text(arg)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(argExpanded ? nil : 3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { argExpanded.toggle() }
                        .accessibilityHint(argExpanded ? "Collapses the full argument" : "Shows the full argument")
                }
            }
            HStack(spacing: 10) {
                Button { onKey("3") } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Button { onKey("1") } label: {
                    Text("Allow").foregroundStyle(Theme.c.onAccent).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.c.accent)
            }
            .controlSize(.large)
            .fontWeight(.semibold)
            // Claude's option 2 is "allow all edits" for file edits and
            // "don't ask again for this command" for everything else.
            Button { onKey("2") } label: {
                Text(category == .edit ? "Always allow edits" : "Don't ask again for this")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Or type below to tell it what to do instead.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func title(_ c: ToolLine.Category) -> String {
        let first = arg.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        switch c {
        case .edit: return "Edit \(ChatGrouping.basename(first))"
        case .read: return "Read \(ChatGrouping.basename(first))"
        case .command: return "Run a command"
        case .web: return "Fetch a page"
        default: return tool.isEmpty ? "Use a tool" : "Use \(tool)"
        }
    }
}

// MARK: - Question

/// An AskUserQuestion with one single-select question: tap a row, then Send
/// types its number. Two steps so a stray tap while scrolling can't answer
/// for you.
struct QuestionSheet: View {
    let event: TranscriptEvent
    let onKey: (String) -> Void
    @State private var selected: Int?

    var body: some View {
        let q = event.questions.first
        let options = q?.options ?? []
        PendingPanel(caption: q?.header.isEmpty == false ? q!.header : "Question", since: event.ts) {
            Text(q?.question ?? "")
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button { selected = index } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if !option.description.isEmpty {
                                    Text(option.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .opacity(selected == index ? 1 : 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == index ? .isSelected : [])
                    if index < options.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            Group {
                if let selected {
                    Button { onKey("\(selected + 1)") } label: {
                        Text("Send").foregroundStyle(Theme.c.onAccent).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.c.accent)
                } else {
                    // A disabled system button draws as a black slab on the
                    // material; a quiet pill reads as "not yet".
                    Text("Send")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Send, choose an option first")
                }
            }
            .controlSize(.large)
            .fontWeight(.semibold)
        }
    }
}

// MARK: - Terminal dialog

/// A picker open in the terminal that the transcript knows nothing about
/// (`/model`, a trust check), read off the live screen (ScreenDialog). One
/// tap picks a row: its number in a numbered dialog, otherwise arrows from
/// the TUI's cursor row and Return. The checkmark is where the TUI's cursor
/// is, so it moves as the screen does.
struct ScreenDialogSheet: View {
    let dialog: ScreenDialog
    let onKey: (String) -> Void
    let onShowTerminal: () -> Void
    /// The row just tapped: it shows a spinner and the list stops taking
    /// taps until the terminal's screen changes, so one tap is one answer.
    @State private var chosen: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text(dialog.title ?? "Choose in terminal")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button { onKey("Escape") } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.1), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .accessibilityHint("Sends Escape")
            }
            .padding(.trailing, -7)
            .padding(.vertical, -7)

            Group {
                if dialog.options.count > 5 {
                    ScrollView { rows }
                        .frame(maxHeight: 330)
                        .scrollIndicators(.visible)
                } else {
                    rows
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button(action: onShowTerminal) {
                Text("Open terminal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.c.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: dialog) { _, _ in chosen = nil }
        .task(id: chosen) {
            // The screen never changed (the key was lost): let them try again.
            guard chosen != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { chosen = nil }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if dialog.hiddenAbove > 0 {
                moreRow("\(dialog.hiddenAbove) more above", icon: "chevron.up", key: "Up", presses: dialog.scrollUpPresses)
                Divider().padding(.leading, 16)
            }
            ForEach(Array(dialog.options.enumerated()), id: \.offset) { index, option in
                Button { choose(index) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = option.detail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if chosen == index {
                            ProgressView().controlSize(.small)
                        } else if option.selected {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.c.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DialogRowStyle())
                .disabled(chosen != nil)
                .accessibilityAddTraits(option.selected ? .isSelected : [])
                .accessibilityHint("Chooses this in the terminal")
                if index < dialog.options.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
            if dialog.hiddenBelow > 0 {
                Divider().padding(.leading, 16)
                moreRow("\(dialog.hiddenBelow) more below", icon: "chevron.down", key: "Down", presses: dialog.scrollDownPresses)
            }
        }
    }

    /// The terminal is too short to show the whole list: scrolls its window
    /// so the hidden choices come into view (and stay listed here).
    private func moreRow(_ label: String, icon: String, key: String, presses: Int) -> some View {
        Button {
            for _ in 0..<max(1, presses) { onKey(key) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.footnote.weight(.semibold))
                Text(label).font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DialogRowStyle())
        .disabled(chosen != nil)
        .accessibilityHint("Scrolls the list in the terminal")
    }

    private func choose(_ index: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        chosen = index
        for key in dialog.keys(toChoose: index) { onKey(key) }
    }
}

/// A list row that lights up while pressed, like a system list.
struct DialogRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0))
            .animation(.easeOut(duration: configuration.isPressed ? 0 : 0.25), value: configuration.isPressed)
    }
}

// MARK: - Live-screen peek

/// A block the chat couldn't parse: the bottom rows of the real terminal at
/// a readable size, the keys that answer most TUI dialogs, and a way to flip
/// the whole surface to the terminal. Chat is a lossy view; this is where it
/// admits it.
struct PeekPanel: View {
    let caption: String
    let screen: ScreenModel?
    let fallbackText: String
    let onKey: (String) -> Void
    let onShowTerminal: () -> Void

    private let keys: [(label: String, key: String)] = [
        ("1", "1"), ("2", "2"), ("3", "3"), ("esc", "Escape"), ("↑", "Up"), ("↓", "Down"), ("⏎", "enter"),
    ]

    var body: some View {
        PendingPanel(caption: caption, since: nil) {
            Group {
                if let screen {
                    PeekScreenRows(screen: screen)
                } else {
                    PeekRows(lines: PeekRows.bottomRows(of: fallbackText))
                }
            }
            HStack(spacing: 6) {
                ForEach(keys, id: \.label) { k in
                    Button { onKey(k.key) } label: {
                        Text(k.label)
                            .font(.subheadline.monospaced().weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .tint(.white)
                    .accessibilityLabel(k.key == "Escape" ? "Escape" : k.key == "enter" ? "Return" : k.label)
                }
            }
            Button(action: onShowTerminal) {
                Text("Open terminal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The live screen's bottom rows, re-read whenever a frame lands.
private struct PeekScreenRows: View {
    @ObservedObject var screen: ScreenModel

    var body: some View {
        let used = screen.lines.prefix(screen.usedRows).map { $0.map(\.t).joined() }
        PeekRows(lines: PeekRows.bottomRows(of: used.joined(separator: "\n")))
    }
}

private struct PeekRows: View {
    let lines: [String]

    /// The last `count` rows of a screen, trailing blank rows dropped.
    static func bottomRows(of text: String, count: Int = 8) -> [String] {
        var rows = text.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        return Array(rows.suffix(count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.caption.monospaced())
                    // The TUI's selection marker reads brighter, so you can
                    // see which option return would pick.
                    .foregroundStyle(line.contains("❯") ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared container

/// The one shape every pending prompt uses: a caption, then content, on a
/// rounded material panel pinned above the composer.
struct PendingPanel<Content: View>: View {
    let caption: String
    let since: Double?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(caption)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.c.attention)
                Spacer()
                if let since, let ago = ChatTime.ago(since) {
                    Text(ago == "now" ? "now" : "\(ago) ago")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.c.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

enum ChatTime {
    /// "now", "4m", "3h", "2d" since a unix timestamp; nil for a future one.
    static func ago(_ ts: Double, now: Date = Date()) -> String? {
        let s = now.timeIntervalSince1970 - ts
        guard s >= 0 else { return nil }
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

import SwiftUI

/// An always-available "remote keyboard" docked under the focused terminal.
///
/// The terminal pane already renders cmux/Claude's own input line, so this bar
/// is deliberately styled as distinct keyboard chrome (not glass-terminal) to
/// read as *your* input bridge rather than a second prompt. It stays collapsed
/// to a slim field until tapped, then reveals command autocomplete and a
/// control-key row. It clears on send — the terminal's output remains the one
/// source of truth for what was typed.
struct TerminalInputBar: View {
    let surfaceTitle: String
    /// Reflects keyboard/compose focus up to the parent so it can give the
    /// focused terminal the whole screen while typing.
    @Binding var isActive: Bool
    var onSendText: (String) -> Void   // send text only (no newline)
    var onSendEnter: (String) -> Void  // send text + Enter (run it)
    var onSendKey: (String) -> Void    // send a control/navigation key

    @State private var draft = ""
    @FocusState private var focused: Bool
    @StateObject private var commandDict = CommandDictionary()
    // Landscape on iPhone reports a compact vertical size class. There the
    // keyboard eats most of the height, so the bar shrinks to a single chip
    // row + inline dismiss to leave room for the terminal.
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isCompact: Bool { vSizeClass == .compact }

    // Label, key-name sent to the bridge (matches SendTextView conventions).
    private let controlKeys: [(String, String)] = [
        ("esc", "Escape"), ("⌃C", "ctrl+c"), ("⌃D", "ctrl+d"),
        ("⇥", "Tab"), ("↑", "Up"), ("↓", "Down"), ("←", "Left"), ("→", "Right"),
    ]

    var body: some View {
        VStack(spacing: isCompact ? 4 : 6) {
            if focused {
                if isCompact {
                    // One merged, scrollable row keeps the footprint minimal.
                    compactChipsRow
                } else {
                    header
                    suggestionsRow
                    controlKeyRow
                }
            }
            composeRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isCompact ? 6 : 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.18), value: focused)
        .onChange(of: focused) { _, active in isActive = active }
    }

    // MARK: - Header (only while composing)

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
            Text(surfaceTitle.isEmpty ? "terminal" : surfaceTitle)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Dismiss lives top-right — where iOS keyboard "Done" belongs.
            Button {
                focused = false
            } label: {
                HStack(spacing: 4) {
                    Text("Done")
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    // MARK: - Compose row

    private var composeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.4))

            TextField("", text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...4)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white)
                .tint(.green)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .overlay(alignment: .leading) {
                    if draft.isEmpty {
                        Text("Send to \(surfaceTitle.isEmpty ? "terminal" : surfaceTitle)…")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                            .allowsHitTesting(false)
                    }
                }

            if !draft.isEmpty {
                Button {
                    send(withEnter: false)
                } label: {
                    Image(systemName: "paperplane")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Button {
                    send(withEnter: true)
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            // Compact mode has no header, so the dismiss lives inline here.
            if isCompact && focused {
                Button {
                    focused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.leading, 2)
            }
        }
    }

    // MARK: - Command suggestions

    private var currentWord: String {
        let trimmed = draft.replacingOccurrences(of: "\n", with: " ")
        return trimmed.split(separator: " ").last.map(String.init) ?? ""
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commandDict.suggestions(for: currentWord), id: \.self) { cmd in
                    suggestionChip(cmd)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 30)
    }

    // MARK: - Control keys

    private var controlKeyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(controlKeys, id: \.1) { label, key in
                    controlChip(label: label, key: key)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 32)
    }

    // MARK: - Compact chips (landscape)

    // Suggestions + control keys merged into a single scrollable row so the
    // whole bar is just this row + the compose row when the keyboard is up.
    private var compactChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(commandDict.suggestions(for: currentWord), id: \.self) { cmd in
                    suggestionChip(cmd)
                }
                ForEach(controlKeys, id: \.1) { label, key in
                    controlChip(label: label, key: key)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 30)
    }

    private func suggestionChip(_ cmd: String) -> some View {
        Button {
            insertSuggestion(cmd)
        } label: {
            Text(cmd)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.1)))
        }
    }

    private func controlChip(label: String, key: String) -> some View {
        Button {
            onSendKey(key)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 34)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
        }
    }

    // MARK: - Actions

    private func send(withEnter: Bool) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        learnCommand(text)
        if withEnter {
            onSendEnter(text)
        } else {
            onSendText(text)
        }
        draft = ""
        // Keep the keyboard up so the user can fire off several commands.
    }

    private func insertSuggestion(_ command: String) {
        let parts = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty {
            draft = command + " "
        } else {
            var updated = parts
            updated[updated.count - 1] = command
            draft = updated.joined(separator: " ") + " "
        }
    }

    private func learnCommand(_ input: String) {
        let firstWord = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        if !firstWord.isEmpty { commandDict.add(firstWord) }
    }
}

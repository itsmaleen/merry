import SwiftUI
import UIKit

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
    var onSend: (String, Bool) -> Void // send the composed message (text, withEnter); pending image, if any, goes first
    var onSendText: (String) -> Void   // type literal text into the terminal (control chips)
    var onSendKey: (String) -> Void    // send a control/navigation key
    // Image attachment, owned by AppState so the quick action and this bar share
    // one pending slot. When set, a preview chip shows and Send is enabled even
    // with an empty draft.
    var hasPendingImage: Bool = false
    var pendingThumbnail: Data? = nil
    var onAttachImage: () -> Void = {}
    var onRemoveImage: () -> Void = {}

    @State private var draft = ""
    // Whether the system clipboard holds an image right now, so the attach
    // button can highlight. `hasImages` does not trigger iOS's paste prompt
    // (only reading the image does), so it is safe to check eagerly.
    @State private var clipboardHasImage = false
    @FocusState private var focused: Bool
    @StateObject private var commandDict = CommandDictionary()
    // Landscape on iPhone reports a compact vertical size class. There the
    // keyboard eats most of the height, so the bar shrinks to a single chip
    // row + inline dismiss to leave room for the terminal.
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isCompact: Bool { vSizeClass == .compact }

    // A control chip either fires a named key via the bridge (`surface.send_key`,
    // matching SendTextView conventions) or injects literal text. cmux has no
    // key-name for the spacebar, so Space is sent as a literal " ".
    private enum KeyAction {
        case key(String)
        case text(String)
    }

    private struct ControlKey: Identifiable {
        let label: String
        let action: KeyAction
        // Lowercase aliases the compose field can filter on as you type.
        let terms: [String]
        // Space gets a wider chip so it reads as a spacebar.
        var isWide: Bool = false
        var id: String { label }
    }

    // Merged from the quick-actions "Input" section so the remote keyboard is a
    // superset of the popup — plus a spacebar the popup never had.
    private let controlKeys: [ControlKey] = [
        ControlKey(label: "esc", action: .key("Escape"), terms: ["esc", "escape"]),
        ControlKey(label: "⏎",   action: .key("enter"),  terms: ["enter", "return", "cr"]),
        ControlKey(label: "␣",   action: .text(" "),     terms: ["space", "spacebar", "spc"], isWide: true),
        ControlKey(label: "⇥",   action: .key("Tab"),    terms: ["tab"]),
        ControlKey(label: "⌃C",  action: .key("ctrl+c"), terms: ["ctrl+c", "ctrlc", "^c", "interrupt"]),
        ControlKey(label: "⌃D",  action: .key("ctrl+d"), terms: ["ctrl+d", "ctrld", "^d", "eof"]),
        ControlKey(label: "⌃Z",  action: .key("ctrl+z"), terms: ["ctrl+z", "ctrlz", "^z", "suspend"]),
        ControlKey(label: "⌃L",  action: .key("ctrl+l"), terms: ["ctrl+l", "ctrll", "^l", "clear"]),
        ControlKey(label: "↑",   action: .key("Up"),     terms: ["up", "arrow"]),
        ControlKey(label: "↓",   action: .key("Down"),   terms: ["down", "arrow"]),
        ControlKey(label: "←",   action: .key("Left"),   terms: ["left", "arrow"]),
        ControlKey(label: "→",   action: .key("Right"),  terms: ["right", "arrow"]),
    ]

    // The word being typed in the compose field doubles as a live filter for the
    // control chips (mirrors how command suggestions filter). If the word matches
    // no key it isn't a key query — a normal command — so we fall back to the full
    // row and keep navigation keys reachable while composing.
    private var filteredControlKeys: [ControlKey] {
        let q = currentWord.lowercased()
        guard !q.isEmpty else { return controlKeys }
        let matches = controlKeys.filter { ck in
            ck.label.lowercased().hasPrefix(q) || ck.terms.contains { $0.hasPrefix(q) }
        }
        return matches.isEmpty ? controlKeys : matches
    }

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
            attachmentChip
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
        .onChange(of: focused) { _, active in
            isActive = active
            if active { clipboardHasImage = UIPasteboard.general.hasImages }
        }
        .onAppear { clipboardHasImage = UIPasteboard.general.hasImages }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardHasImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Copying happens in another app, so re-check when we return.
            clipboardHasImage = UIPasteboard.general.hasImages
        }
        // If the bar is torn down while focused (quick actions open, the focused
        // surface closes or becomes a browser, tab switch), `.onChange(of:focused)`
        // won't fire — so reset here, or the parent leaves the workspace bar and
        // secondaries hidden forever.
        .onDisappear { isActive = false }
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

    private var canSend: Bool {
        hasPendingImage || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // A preview of the attached image with a remove button, shown above the
    // compose field while an image is pending. The message the user types is
    // sent together with it.
    @ViewBuilder
    private var attachmentChip: some View {
        if hasPendingImage {
            HStack(spacing: 8) {
                if let data = pendingThumbnail, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
                }
                Text("Image attached")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    onRemoveImage()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var composeRow: some View {
        HStack(spacing: 8) {
            // Attach/paste an image. Highlights when the clipboard holds one so
            // it reads as "paste this image" rather than a blind picker.
            Button {
                onAttachImage()
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 15))
                    .foregroundStyle(clipboardHasImage ? .green : .white.opacity(0.4))
            }

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

            if canSend {
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

            // Tab stays one tap away while the bar is collapsed — completions
            // and agent-mode toggles shouldn't require raising the keyboard
            // first. While composing, the control-key row already offers ⇥.
            if !focused {
                Button {
                    onSendKey("Tab")
                } label: {
                    Text("⇥")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(minWidth: 30)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
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
                ForEach(filteredControlKeys) { ck in
                    controlChip(ck)
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
                ForEach(filteredControlKeys) { ck in
                    controlChip(ck)
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

    private func controlChip(_ ck: ControlKey) -> some View {
        Button {
            fire(ck)
        } label: {
            Text(ck.label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: ck.isWide ? 72 : 34)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
        }
    }

    private func fire(_ ck: ControlKey) {
        switch ck.action {
        case .key(let key):   onSendKey(key)
        case .text(let text): onSendText(text)
        }
    }

    // MARK: - Actions

    private func send(withEnter: Bool) {
        let text = draft
        let textEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // With an image attached, an empty message is fine — the image is the
        // message. Otherwise there's nothing to send.
        guard !textEmpty || hasPendingImage else { return }
        if !textEmpty { learnCommand(text) }
        // AppState composes: the pending image's path is typed first, then this
        // text, then Enter when requested.
        onSend(text, withEnter)
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

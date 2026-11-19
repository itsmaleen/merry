import SwiftUI
import UIKit

/// The one composer under the open surface, the same component for an agent
/// chat and a plain shell: a "+" menu, a rounded field, and a trailing
/// circular button: Send with text, Stop on an empty field while the agent
/// works, otherwise a mic that toggles dictation (as volume-up does).
///
/// The terminal keys (esc, tab, ^C, arrows…) sit in a row above the field
/// when "Show keys" is on: on by default for a terminal view, off for chat.
/// It clears on send; the surface's output stays the one source of truth for
/// what was typed.
struct TerminalInputBar: View {
    let surfaceID: String
    let surfaceTitle: String
    /// The open surface shows chat (an agent session in its chat view).
    var chatMode: Bool = false
    /// The surface runs an agent (claude/opencode), whether shown as chat or
    /// terminal: offers slash commands, file mentions and mode in "+".
    var isAgent: Bool = false
    /// The agent is working (AppState.isAgentWorking): an empty field's
    /// trailing button stops it.
    var isWorking: Bool = false
    /// Speech input is recording; the mic shows as stop.
    var isRecording: Bool = false
    /// The volume-up speech toggle: start dictation, or stop and send.
    var onToggleDictation: () -> Void = {}
    /// Reflects keyboard focus up to the parent, which keeps a stray swipe
    /// from switching surfaces mid-command.
    @Binding var isActive: Bool
    var onSend: (String, Bool) -> Void // send the composed message (text, withEnter); pending image, if any, goes first
    var onSendText: (String) -> Void   // type literal text into the terminal (control keys)
    var onSendKey: (String) -> Void    // send a control/navigation key
    // Attachment (image or file), owned by AppState so the quick action and this
    // bar share one pending slot. When set, a preview chip shows and Send is
    // enabled even with an empty draft.
    var hasPendingAttachment: Bool = false
    var pendingThumbnail: Data? = nil   // an image preview; nil for a non-image file
    var pendingLabel: String = ""       // "Image" or a filename
    var onAddFile: () -> Void = {}      // opens the Photo / File / Paste menu
    var onRemoveAttachment: () -> Void = {}
    /// Swipe up on the composer (keyboard down) opens the surface switcher.
    var onSwipeUp: () -> Void = {}
    /// Slash commands this surface's transcript has run, most recent first;
    /// offered ahead of the built-in list while a chat draft is "/name".
    var seenCommands: [String] = []
    /// Screenshot fixture: a draft to start with.
    var initialDraft: String = ""

    @State private var draft = ""
    @State private var showKeys = false
    @FocusState private var focused: Bool
    @StateObject private var commandDict = CommandDictionary()
    // Landscape on iPhone reports a compact vertical size class. There the
    // keyboard eats most of the height, so suggestions and keys share a row.
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isCompact: Bool { vSizeClass == .compact }

    // A control key either fires a named key via the bridge (`surface.send_key`,
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
        // Space gets a wider key so it reads as a spacebar.
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

    // The word being typed doubles as a live filter for the control keys
    // (mirrors how command suggestions filter). If the word matches no key it
    // isn't a key query, so the full row stays.
    private var filteredControlKeys: [ControlKey] {
        let q = currentWord.lowercased()
        guard !q.isEmpty else { return controlKeys }
        let matches = controlKeys.filter { ck in
            ck.label.lowercased().hasPrefix(q) || ck.terms.contains { $0.hasPrefix(q) }
        }
        return matches.isEmpty ? controlKeys : matches
    }

    /// Command suggestions: shell commands while typing at a terminal; in
    /// chat, slash commands while the draft is a bare "/name".
    private var suggestions: [String] {
        if chatMode { return SlashCommands.suggestions(draft: draft, seen: seenCommands) }
        guard focused else { return [] }
        return commandDict.suggestions(for: currentWord)
    }

    var body: some View {
        VStack(spacing: 8) {
            if isCompact {
                if showKeys || !suggestions.isEmpty { compactChipsRow }
            } else {
                if !suggestions.isEmpty { suggestionsRow }
                if showKeys { controlKeyRow }
            }
            attachmentChip
            composeRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, isCompact ? 4 : 6)
        .contentShape(Rectangle())
        // Swipe up on the composer opens the switcher, like the iOS app
        // switcher. Only with the keyboard down, where a vertical drag on the
        // field means nothing else.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard !focused else { return }
                    if value.translation.height < -30,
                       abs(value.translation.height) > abs(value.translation.width) * 1.5 {
                        onSwipeUp()
                    }
                }
        )
        .animation(.easeInOut(duration: 0.18), value: showKeys)
        .animation(.easeInOut(duration: 0.18), value: suggestions)
        .onChange(of: focused) { _, active in isActive = active }
        // The layout lowered the keyboard (Keyboard.dismiss): follow it.
        .onChange(of: isActive) { _, active in if !active && focused { focused = false } }
        .onAppear {
            showKeys = !chatMode
            if draft.isEmpty && !initialDraft.isEmpty { draft = initialDraft }
        }
        // A terminal view starts with the keys out, chat without; switching
        // surface or view resets to that default.
        .onChange(of: surfaceID) { _, _ in showKeys = !chatMode }
        .onChange(of: chatMode) { _, chat in showKeys = !chat }
        // If the bar is torn down while focused (quick actions open, the focused
        // surface closes or becomes a browser, tab switch), `.onChange(of:focused)`
        // won't fire — so reset here, or the parent keeps vetoing swipes.
        .onDisappear { isActive = false }
    }

    // MARK: - Compose row

    private var canSend: Bool {
        hasPendingAttachment || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // A preview of the attached image or file with a remove button, shown above
    // the field. The message the user types is sent together with it.
    @ViewBuilder
    private var attachmentChip: some View {
        if hasPendingAttachment {
            HStack(spacing: 10) {
                if let data = pendingThumbnail, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(pendingLabel.isEmpty ? "Attached" : pendingLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: onRemoveAttachment) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Remove attachment")
            }
            .padding(.horizontal, 4)
        }
    }

    private var composeRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            plusMenu

            HStack(alignment: .bottom, spacing: 6) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.leading, 14)
                    .padding(.vertical, 8)
                trailingButton
                    .padding(.trailing, 3)
                    .padding(.bottom, 3)
            }
            .frame(minHeight: 38)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        }
    }

    private var placeholder: String {
        if chatMode { return "Reply" }
        return surfaceTitle.isEmpty ? "Send to terminal" : "Send to \(surfaceTitle)"
    }

    private var plusMenu: some View {
        Menu {
            Button("Attach Image", systemImage: "paperclip") { onAddFile() }
            if isAgent {
                Button("Slash Command", systemImage: "slash.circle") { startDraft("/") }
                Button("Mention File", systemImage: "at") { startDraft("@") }
                Button("Change Mode", systemImage: "shift") { onSendKey("shift+tab") }
            }
            Divider()
            Button(showKeys ? "Hide Keys" : "Show Keys", systemImage: "keyboard") { showKeys.toggle() }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .tint(Color(white: 0.6))
        .accessibilityLabel("More input")
    }

    /// Send (arrow up) with text; Stop (square) on an empty field while the
    /// agent works; otherwise a neutral mic for dictation, red stop while
    /// recording. Long-press send to type the text without pressing return.
    @ViewBuilder
    private var trailingButton: some View {
        if canSend {
            Button { send(withEnter: true) } label: {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.c.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Theme.c.accent, in: Circle())
            }
            .accessibilityLabel("Send")
            .contextMenu {
                Button("Type Without Return", systemImage: "text.cursor") { send(withEnter: false) }
            }
        } else if isRecording {
            Button(action: onToggleDictation) {
                Image(systemName: "stop.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop dictation")
        } else if isAgent && isWorking {
            Button { onSendKey("Escape") } label: {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.9), in: Circle())
            }
            .accessibilityLabel("Stop the agent")
        } else {
            Button(action: onToggleDictation) {
                Image(systemName: "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dictate")
        }
    }

    // MARK: - Command suggestions

    private var currentWord: String {
        let trimmed = draft.replacingOccurrences(of: "\n", with: " ")
        return trimmed.split(separator: " ").last.map(String.init) ?? ""
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { cmd in
                    suggestionChip(cmd)
                }
            }
        }
        .frame(height: 32)
    }

    // MARK: - Control keys

    private var controlKeyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filteredControlKeys) { ck in
                    controlChip(ck)
                }
                keyRowTrailing
            }
        }
        .frame(height: 34)
    }

    /// Lower the keyboard while it is up; otherwise, on a chat, put the keys
    /// away again (a terminal keeps them out).
    @ViewBuilder
    private var keyRowTrailing: some View {
        if focused {
            keyButton(systemImage: "keyboard.chevron.compact.down", label: "Hide keyboard") { focused = false }
        } else if chatMode {
            keyButton(systemImage: "chevron.down", label: "Hide keys") { showKeys = false }
        }
    }

    // MARK: - Compact chips (landscape)

    // Suggestions + control keys merged into a single scrollable row.
    private var compactChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { cmd in
                    suggestionChip(cmd)
                }
                if showKeys {
                    ForEach(filteredControlKeys) { ck in
                        controlChip(ck)
                    }
                }
                keyRowTrailing
            }
        }
        .frame(height: 32)
    }

    private func suggestionChip(_ cmd: String) -> some View {
        Button {
            insertSuggestion(cmd)
        } label: {
            Text(cmd)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func controlChip(_ ck: ControlKey) -> some View {
        Button {
            fire(ck)
        } label: {
            Text(ck.label)
                .font(.subheadline.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .frame(minWidth: ck.isWide ? 64 : 36, minHeight: 32)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func keyButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func fire(_ ck: ControlKey) {
        switch ck.action {
        case .key(let key):   onSendKey(key)
        case .text(let text): onSendText(text)
        }
    }

    // MARK: - Actions

    private func startDraft(_ prefix: String) {
        if draft.isEmpty || draft.hasSuffix(" ") { draft += prefix } else { draft += " " + prefix }
        focused = true
    }

    private func send(withEnter: Bool) {
        let text = draft
        let textEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // With an image attached, an empty message is fine — the image is the
        // message. Otherwise there's nothing to send.
        guard !textEmpty || hasPendingAttachment else { return }
        if !textEmpty { learnCommand(text) }
        // AppState composes: the pending image's path is typed first, then this
        // text, then Enter when requested.
        onSend(text, withEnter)
        draft = ""
        // Keep the keyboard up so the user can fire off several commands.
    }

    private func insertSuggestion(_ command: String) {
        if chatMode {
            // A slash command replaces the whole draft ("/lo" → "/loop ").
            draft = command + " "
            focused = true
            return
        }
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

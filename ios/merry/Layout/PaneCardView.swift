import SwiftUI

struct PaneCardView: View {
    let title: String
    let isFocused: Bool
    let hasNotification: Bool
    let isTranscribing: Bool
    let transcript: String
    var terminalText: String = ""
    var contentScale: CGFloat = 1.0
    /// The focused surface's live screen, when the bridge streams one and a
    /// subscribe has succeeded. Non-nil makes the card render history above
    /// the bridge-rendered live screen in one text view; nil (no support,
    /// subscribe still pending, or a non-focused card) renders exactly as
    /// before.
    var liveScreen: ScreenModel?
    /// Reports the live card's content size (the area a fitted pane should
    /// fill), on first layout and whenever it changes.
    var onLiveSizeChanged: ((CGSize) -> Void)? = nil
    /// What a live card shows ABOVE the emulator: the conversation for an
    /// agent surface, the polled scrollback for a plain shell.
    var liveHistoryText: String = ""
    /// True when `liveHistoryText` is a polled screen read (scrollback plus
    /// the visible screen), so the rows the emulator already shows must be
    /// trimmed off its end; false for a conversation transcript.
    var liveHistoryIsPolledScreen: Bool = false
    var isBrowser: Bool = false
    var browserURL: String = ""
    /// When true, scrolling to the top of a focused card opens the conversation
    /// full-screen (claude agent surfaces, whose card already shows it inline).
    var canOpenHistory: Bool = false
    var onOpenHistory: (() -> Void)?
    /// The surface's screen moved on its latest poll — its agent/command is
    /// actively producing output. Shows the pulsing dots in the title bar.
    var isWorking: Bool = false
    /// Reports selection begin/end in the terminal text so the parent can
    /// hold back gestures that would fight a selection drag.
    var onSelectionActiveChanged: ((Bool) -> Void)? = nil
    /// Find-in-surface: every match is highlighted, the current one is scrolled
    /// to, and the count is reported back for the "3/17" readout.
    var searchQuery: String = ""
    var currentMatchIndex: Int = 0
    var onSearchMatchCount: ((Int) -> Void)? = nil
    /// Bumped by the parent to jump this card to the newest output.
    var scrollToBottomRequest: Int = 0
    /// Asks the parent to bump `scrollToBottomRequest`.
    var onJumpToBottom: (() -> Void)? = nil
    /// The open agent surface's chat body. When set it replaces the terminal
    /// and live-screen bodies (the frame stream keeps running for the peek).
    var chatBody: ChatCardBody? = nil
    /// A small card's or switcher tile's glance body, replacing the 7pt
    /// terminal mirror with something readable at tile size.
    var glanceBody: GlanceBody? = nil
    /// A switcher tile for the surface that is open: a brighter border.
    var isCurrent: Bool = false
    @State private var terminalAtTop = false
    @State private var terminalAtBottom = true

    var body: some View {
        if isFocused {
            // The open surface: no card, no title bar, no ring. Its content
            // runs edge to edge under the screen's header; the header carries
            // the title and status.
            bodyArea
        } else {
            tile
        }
    }

    /// A switcher tile: a neutral rounded rectangle with a hairline border,
    /// brighter for the open surface. Needs-you shows in the glance's status
    /// row (or as a small dot by the title), never as a ring.
    private var tile: some View {
        VStack(spacing: 0) {
            titleBar
            bodyArea
        }
        .background(Theme.c.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(isCurrent ? 0.55 : 0.08), lineWidth: isCurrent ? 1.5 : 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTranscribing ? Color.red.opacity(0.03) : .clear)
        )
    }

    private var bodyArea: some View {
        ZStack(alignment: .topLeading) {
            if isBrowser {
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: isFocused ? 28 : 16))
                        .foregroundStyle(.white.opacity(0.2))
                    if !browserURL.isEmpty {
                        Text(browserURL
                            .replacingOccurrences(of: "https://", with: "")
                            .replacingOccurrences(of: "http://", with: ""))
                            .font(.system(size: isFocused ? 10 : 7, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: isFocused ? 9 : 7, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let chatBody {
                chatBody
            } else if let glanceBody {
                glanceBody
            } else if let liveScreen {
                liveContentView(liveScreen)
            } else if !terminalText.isEmpty {
                terminalContentView
            } else {
                // Loading state for terminals before content arrives
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white.opacity(0.3))
                    Text("Loading…")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Live speech transcript OVERLAYS the content while recording.
            // It must not be a sibling branch of `terminalContentView`:
            // that view is a UITextView (UIViewRepresentable), and
            // swapping it out mid-recording leaves its UIKit layer on
            // screen so the transcript never appears. Overlaying keeps the
            // terminal mounted and paints the transcript on top.
            if isTranscribing && !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.green.opacity(0.9))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial.opacity(0.9))
                    .environment(\.colorScheme, .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Live terminal content

    /// The live card: the surface's history (conversation or polled
    /// scrollback) above the bridge-rendered live screen, in the one text view
    /// every card uses — same scrolling, selection, search and anchoring.
    private func liveContentView(_ screen: ScreenModel) -> some View {
        LiveTextCard(screen: screen, onSizeChanged: onLiveSizeChanged) { screen, width in
            // Fit the screen's columns into the card (minus the text view's
            // 8pt insets); history keeps the card's normal type size.
            let liveFont = FrameFit.fontSize(
                forColumns: screen.cols, viewWidth: max(0, width - 16),
                advanceOfMAt1pt: LiveCellMetrics.advanceOfMAt1pt
            )
            let history = liveHistoryIsPolledScreen
                ? FrameFit.historyAboveLiveScreen(polledText: liveHistoryText, usedRows: screen.usedRows)
                : liveHistoryText
            textContent(text: history, liveScreen: screen.attributed(fontSize: liveFont), liveVersion: screen.version)
        }
    }

    private var historyButton: some View {
        Button {
            onOpenHistory?()
        } label: {
            Image(systemName: "text.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                )
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        }
        .accessibilityLabel("View conversation history")
    }

    // MARK: - Terminal content

    private var terminalContentView: some View {
        textContent(text: terminalText, liveScreen: nil, liveVersion: 0)
    }

    private func textContent(text: String, liveScreen: NSAttributedString?, liveVersion: Int) -> some View {
        // UITextView-backed so output is selectable (copy) and URLs are tappable.
        // A claude card's text is its conversation with the live screen below it;
        // pulling past the top opens the same conversation full-screen, which is
        // an easier read than this card's 9pt type.
        TerminalTextView(
            text: text,
            fontSize: textFontSize(hasLiveScreen: liveScreen != nil),
            textOpacity: isFocused ? 0.85 : 0.5,
            onScrolledToTop: (isFocused && canOpenHistory) ? { onOpenHistory?() } : nil,
            onTopStateChanged: (isFocused && canOpenHistory) ? { terminalAtTop = $0 } : nil,
            onSelectionActiveChanged: onSelectionActiveChanged,
            searchQuery: searchQuery,
            currentMatchIndex: currentMatchIndex,
            onSearchMatchCount: onSearchMatchCount,
            scrollToBottomRequest: scrollToBottomRequest,
            onAtBottomChanged: { terminalAtBottom = $0 },
            liveScreen: liveScreen,
            liveVersion: liveVersion
        )
        .overlay(alignment: .top) {
            // Only surface the affordance once the user is at the top; a further
            // pull-up past the top opens the full-screen reader.
            if isFocused && canOpenHistory && terminalAtTop {
                historyHint
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Offered only when it would do something: the card is scrolled up
            // and no search is holding the position on a match.
            if isFocused && !terminalAtBottom && searchQuery.isEmpty {
                jumpToBottomButton
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: terminalAtTop)
        .animation(.easeInOut(duration: 0.18), value: terminalAtBottom)
    }

    /// A focused plain shell reads at 11.5pt at least. Not applied with a
    /// live screen below the text (FrameFit sizes that one to its columns, and
    /// history at a different size above it would jump) or to agent cards in
    /// terminal mode, which keep today's size.
    private func textFontSize(hasLiveScreen: Bool) -> CGFloat {
        let base = (isFocused ? 9 : 7) * contentScale
        guard isFocused, !hasLiveScreen, !canOpenHistory else { return base }
        return max(11.5, base)
    }

    private var jumpToBottomButton: some View {
        Button {
            onJumpToBottom?()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                )
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                // The visual stays a small 32pt puck (it shouldn't cover more
                // of the card than it needs to), but the tappable area is
                // widened to Apple's 44x44 minimum so it's reliably hittable
                // on a phone where this sits at a card's corner.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Jump to newest output")
    }

    private var historyHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up")
                .font(.system(size: 8, weight: .semibold))
            Text("pull up to expand")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
        .allowsHitTesting(false)
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            Text(title.isEmpty ? "untitled" : title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            // A notification on a surface whose body has no status row
            // (a shell, a browser): one small orange dot.
            if hasNotification && !(glanceBody?.isAgent ?? false) {
                Circle().fill(Theme.c.attention).frame(width: 6, height: 6)
                    .accessibilityLabel("Needs you")
            }

            Spacer(minLength: 4)

            // A shell's screen is moving. An agent tile says Working in its
            // status row instead.
            if isWorking && !(glanceBody?.isAgent ?? false) {
                WorkingDots()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// Three dots pulsing in sequence — shown in a card's title bar while its
/// agent/command is actively producing output.
private struct WorkingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(animating ? 0.15 : 0.9)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

/// Identifies which surface's conversation history to present full-screen.
struct HistoryTarget: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Full-screen reader for a claude surface's conversation. The card already
/// renders the same transcript inline; this is the roomier, larger-type view of
/// it. Opens pinned to the latest exchange, scroll up for older history.
struct TranscriptSheetView: View {
    @EnvironmentObject var appState: AppState
    let target: HistoryTarget
    // Work rows opened in this viewing; history starts with them folded.
    @State private var expanded: Set<String> = []

    var body: some View {
        ZStack {
            Theme.c.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.1))
                body(for: appState.claudeTranscript[target.id] ?? "")
            }
        }
        .onAppear {
            // Always refetch on open so we show the latest session data, not a
            // stale cache from a previous viewing. Any cached text stays visible
            // (pinned to the bottom) until the fresh transcript replaces it.
            appState.loadClaudeTranscript(target.id, showsSpinner: true)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation history")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(target.title)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                // Diagnostic: the session the bridge resolved this surface to.
                // Lets a "wrong session" report name the exact session at a glance.
                if let session = appState.claudeTranscriptSession[target.id], !session.isEmpty {
                    Text("session \(session.prefix(8))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { appState.loadClaudeTranscript(target.id, showsSpinner: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 15))
            }
            .tint(.white.opacity(0.6))
            .disabled(appState.claudeTranscriptLoading.contains(target.id))
            Button { appState.presentedHistory = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22))
            }
            .tint(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func body(for text: String) -> some View {
        if text.isEmpty {
            VStack(spacing: 10) {
                if appState.claudeTranscriptLoading.contains(target.id) {
                    ProgressView().tint(.white.opacity(0.4))
                    Text("Loading history…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                } else if appState.claudeTranscriptMissing.contains(target.id) {
                    // Say so plainly rather than showing the newest session in
                    // the same folder, which is a different conversation.
                    Text("This surface's session file is missing")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("This surface is bound to session \(appState.claudeTranscriptSession[target.id]?.prefix(8) ?? ""), whose transcript is no longer on disk.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                } else {
                    Text("No conversation history")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let events = appState.transcriptEvents[target.id], !events.isEmpty {
            // The conversation as chat, with text selection on.
            // A plain ScrollView is safe here; the sheet has no card gestures.
            ScrollView {
                ChatTranscriptView(
                    items: ChatGrouping.items(from: events),
                    expanded: expanded,
                    onToggle: { id in
                        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                    },
                    selectable: true
                )
            }
            .defaultScrollAnchor(.bottom)
        } else {
            TerminalTextView(text: text, fontSize: 12.5, textOpacity: 0.9, trimMarkdownLinks: true)
                .padding(.horizontal, 4)
        }
    }
}

/// Observes a surface's ScreenModel (its `version`) and re-renders the
/// card's text content through `content` whenever an update lands, handing it
/// the card's width so the live screen's columns can be fitted.
private struct LiveTextCard<Content: View>: View {
    @ObservedObject var screen: ScreenModel
    let onSizeChanged: ((CGSize) -> Void)?
    let content: (ScreenModel, CGFloat) -> Content

    init(screen: ScreenModel, onSizeChanged: ((CGSize) -> Void)?, @ViewBuilder content: @escaping (ScreenModel, CGFloat) -> Content) {
        self.screen = screen
        self.onSizeChanged = onSizeChanged
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            content(screen, geo.size.width)
                .onChange(of: geo.size, initial: true) { _, size in
                    onSizeChanged?(size)
                }
        }
    }
}

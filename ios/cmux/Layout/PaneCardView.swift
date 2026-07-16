import SwiftUI

struct PaneCardView: View {
    let title: String
    let isFocused: Bool
    let hasNotification: Bool
    let isTranscribing: Bool
    let transcript: String
    var terminalText: String = ""
    var contentScale: CGFloat = 1.0
    var isBrowser: Bool = false
    var browserURL: String = ""
    /// When true, scrolling to the top of a focused card opens conversation
    /// history (claude agent surfaces).
    var canOpenHistory: Bool = false
    var onOpenHistory: (() -> Void)?
    @State private var notificationPulse = false
    @State private var terminalAtTop = false

    var body: some View {
        ZStack {
            // Glass background
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(isFocused ? 0.4 : 0.2))
                .environment(\.colorScheme, .dark)

            // Notification pulse ring
            if hasNotification {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange, lineWidth: 2.5)
                    .opacity(notificationPulse ? 0.4 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: notificationPulse
                    )
                    .onAppear { notificationPulse = true }
                    .onDisappear { notificationPulse = false }
            }

            // Focus glow border
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: isFocused ? 1.5 : 0.5)

            // Content
            VStack(spacing: 0) {
                // Title bar
                titleBar

                // Body area
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
        }
        .shadow(color: isFocused ? .white.opacity(0.08) : .clear, radius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTranscribing ? Color.red.opacity(0.03) : .clear)
        )
    }

    // MARK: - Terminal content

    private var terminalContentView: some View {
        // UITextView-backed so output is selectable (copy) and URLs are tappable.
        // On a focused claude card, pulling to the top opens the conversation
        // history viewer (the terminal itself only shows claude's live viewport).
        TerminalTextView(
            text: terminalText,
            fontSize: (isFocused ? 9 : 7) * contentScale,
            textOpacity: isFocused ? 0.85 : 0.5,
            onScrolledToTop: (isFocused && canOpenHistory) ? { onOpenHistory?() } : nil,
            onTopStateChanged: (isFocused && canOpenHistory) ? { terminalAtTop = $0 } : nil
        )
        .overlay(alignment: .top) {
            // Only surface the affordance once the user is at the top; a further
            // pull-up past the top opens history.
            if isFocused && canOpenHistory && terminalAtTop {
                historyHint
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: terminalAtTop)
    }

    private var historyHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up")
                .font(.system(size: 8, weight: .semibold))
            Text("pull up for history")
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
            // Surface type icon
            Image(systemName: isBrowser ? "globe" : "terminal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isFocused ? .white.opacity(0.5) : .white.opacity(0.2))

            // Title
            Text(title.isEmpty ? "untitled" : title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isFocused ? .white.opacity(0.7) : .white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Recording indicator
            if isTranscribing {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .shadow(color: .red.opacity(0.6), radius: 3)
                    Text("REC")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Rectangle()
                .fill(isFocused ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
        )
        // Top corners only
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12
            )
        )
    }

    private var borderColor: Color {
        if hasNotification { return Color.orange.opacity(0.6) }
        if isFocused { return Color.white.opacity(0.5) }
        return Color.white.opacity(0.08)
    }
}

/// Identifies which surface's conversation history to present full-screen.
struct HistoryTarget: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Full-screen viewer for a claude surface's conversation transcript. Loads on
/// appear, opens pinned to the latest exchange, scroll up for older history.
struct TranscriptSheetView: View {
    @EnvironmentObject var appState: AppState
    let target: HistoryTarget

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.1))
                body(for: appState.claudeTranscript[target.id] ?? "")
            }
        }
        .onAppear {
            if appState.claudeTranscript[target.id] == nil {
                appState.loadClaudeTranscript(target.id)
            }
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
            Button { appState.loadClaudeTranscript(target.id) } label: {
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
                } else {
                    Text("No conversation history")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TerminalTextView(text: text, fontSize: 12.5, textOpacity: 0.9)
                .padding(.horizontal, 4)
        }
    }
}

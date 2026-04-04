import SwiftUI

struct PaneCardView: View {
    let title: String
    let isFocused: Bool
    let hasNotification: Bool
    let isTranscribing: Bool
    let transcript: String
    var terminalText: String = ""
    var isBrowser: Bool = false
    var browserURL: String = ""
    var hasFullHistory: Bool = false
    var isLoadingHistory: Bool = false
    var onLoadHistory: (() -> Void)?

    @State private var notificationPulse = false
    @State private var userScrolledUp = false

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
                    if isTranscribing && !transcript.isEmpty {
                        Text(transcript)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    } else if isBrowser {
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
                    } else if !isBrowser {
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
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Load history button at the top (focused cards only)
                    if isFocused && !hasFullHistory {
                        Button {
                            onLoadHistory?()
                        } label: {
                            HStack(spacing: 6) {
                                if isLoadingHistory {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .tint(.white.opacity(0.4))
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                        .font(.system(size: 10))
                                }
                                Text(isLoadingHistory ? "Loading…" : "Load history")
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                            }
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .disabled(isLoadingHistory)
                        .id("top")
                    }

                    Text(terminalText)
                        .font(.system(size: isFocused ? 9 : 7, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(isFocused ? 0.85 : 0.5))
                        .lineSpacing(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)

                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if value.translation.height > 5 {
                            userScrolledUp = true
                        } else if value.translation.height < -5 {
                            userScrolledUp = false
                        }
                    }
            )
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: terminalText) {
                if !userScrolledUp {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
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

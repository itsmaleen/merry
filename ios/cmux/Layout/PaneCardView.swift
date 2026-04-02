import SwiftUI

struct PaneCardView: View {
    let title: String
    let isFocused: Bool
    let hasNotification: Bool
    let isTranscribing: Bool
    let transcript: String

    @State private var notificationPulse = false

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
                ZStack {
                    if isTranscribing && !transcript.isEmpty {
                        Text(transcript)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .shadow(color: isFocused ? .white.opacity(0.08) : .clear, radius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTranscribing ? Color.red.opacity(0.03) : .clear)
        )
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            // Terminal icon
            Image(systemName: "terminal")
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

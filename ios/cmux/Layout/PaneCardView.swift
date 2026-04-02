import SwiftUI

struct PaneCardView: View {
    let pane: Pane
    let surfaceTitle: String
    let hasNotification: Bool
    let isTranscribing: Bool
    let transcript: String

    var body: some View {
        ZStack {
            // Card background
            RoundedRectangle(cornerRadius: 10)
                .fill(cardFill)

            // Notification ring
            if hasNotification {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange, lineWidth: 2.5)
            }

            // Focus ring
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: pane.isFocused ? 1.5 : 1)

            VStack(alignment: .leading, spacing: 0) {
                // Traffic lights
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 1, green: 0.73, blue: 0.1)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 0.19, green: 0.8, blue: 0.39)).frame(width: 7, height: 7)
                }
                .padding(.leading, 8)
                .padding(.top, 8)

                Spacer()

                // Surface title / transcript
                Group {
                    if isTranscribing && !transcript.isEmpty {
                        Text(transcript)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .padding(.horizontal, 8)
                    } else if !surfaceTitle.isEmpty {
                        Text(surfaceTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(pane.isFocused ? .white : .white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                    }
                }

                // Tab count pill
                if pane.surfaceIDs.count > 1 {
                    Text("\(pane.surfaceIDs.count) tabs")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                } else {
                    Spacer().frame(height: 2)
                }

                Spacer().frame(height: 6)
            }

            // Recording indicator
            if isTranscribing {
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
    }

    private var cardFill: Color {
        if pane.isFocused {
            return Color.white.opacity(0.12)
        }
        return Color.white.opacity(0.04)
    }

    private var borderColor: Color {
        if hasNotification {
            return Color.orange.opacity(0.6)
        }
        if pane.isFocused {
            return Color.white.opacity(0.7)
        }
        return Color.white.opacity(0.15)
    }
}

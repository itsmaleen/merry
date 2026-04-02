import SwiftUI

struct PaneCardView: View {
    let title: String
    let isFocused: Bool
    let hasNotification: Bool
    let isTranscribing: Bool
    let transcript: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(cardFill)

            if hasNotification {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange, lineWidth: 2.5)
            }

            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isFocused ? 1.5 : 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 1, green: 0.73, blue: 0.1)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 0.19, green: 0.8, blue: 0.39)).frame(width: 7, height: 7)
                }
                .padding(.leading, 8)
                .padding(.top, 8)

                Spacer()

                if isTranscribing && !transcript.isEmpty {
                    Text(transcript)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .padding(.horizontal, 8)
                } else if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isFocused ? .white : .white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                }

                Spacer().frame(height: 10)
            }

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
        isFocused ? Color.white.opacity(0.12) : Color.white.opacity(0.04)
    }

    private var borderColor: Color {
        if hasNotification { return Color.orange.opacity(0.6) }
        if isFocused { return Color.white.opacity(0.7) }
        return Color.white.opacity(0.15)
    }
}

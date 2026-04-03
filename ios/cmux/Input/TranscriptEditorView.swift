import SwiftUI

struct TranscriptEditorView: View {
    @Binding var isPresented: Bool
    @State var text: String
    var onSend: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .foregroundStyle(.white.opacity(0.7))

                Spacer()

                Text("Edit Transcript")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer()

                Button("Send") {
                    onSend(text)
                    isPresented = false
                }
                .foregroundStyle(.green)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            TextEditor(text: $text)
                .focused($isFocused)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.08))
                )
                .padding(.horizontal, 16)

            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            isFocused = true
        }
    }
}

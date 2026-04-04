import SwiftUI

struct TranscriptEditorView: View {
    @Binding var isPresented: Bool
    @State var text: String
    var onSend: (String) -> Void

    @FocusState private var isFocused: Bool
    @StateObject private var commandDict = CommandDictionary()

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
                    learnCommand(text)
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

            // Command suggestions bar
            commandSuggestionsBar
                .padding(.top, 8)

            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            isFocused = true
        }
    }

    // MARK: - Suggestions bar

    private var currentWord: String {
        // Get the last word being typed (after last space or newline)
        let trimmed = text.replacingOccurrences(of: "\n", with: " ")
        return trimmed.split(separator: " ").last.map(String.init) ?? ""
    }

    private var commandSuggestionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commandDict.suggestions(for: currentWord), id: \.self) { cmd in
                    Button {
                        insertSuggestion(cmd)
                    } label: {
                        Text(cmd)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.white.opacity(0.1))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 36)
    }

    private func insertSuggestion(_ command: String) {
        // Replace the current word with the suggestion
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty {
            text = command + " "
        } else {
            var updated = parts
            updated[updated.count - 1] = command
            text = updated.joined(separator: " ") + " "
        }
    }

    private func learnCommand(_ input: String) {
        // Learn the first word of what was sent (the command)
        let firstWord = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        if !firstWord.isEmpty {
            commandDict.add(firstWord)
        }
    }
}

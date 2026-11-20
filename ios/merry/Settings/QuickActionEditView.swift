import SwiftUI

struct QuickActionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var action: CustomQuickAction
    @State private var autoEnter: Bool
    var onSave: (CustomQuickAction) -> Void

    private static let iconOptions = [
        "terminal", "brain", "bolt.shield", "arrow.clockwise", "play.circle",
        "wrench.and.screwdriver", "chevron.left.forwardslash.chevron.right",
        "text.cursor", "cpu", "network", "globe", "doc.text",
        "folder", "arrow.right", "star", "flag", "paperplane",
        "command", "apple.terminal", "gear",
    ]

    private static let sectionOptions = ["AI", "Custom"]

    init(action: CustomQuickAction, onSave: @escaping (CustomQuickAction) -> Void) {
        _action = State(initialValue: action)
        _autoEnter = State(initialValue: action.command.hasSuffix("\n"))
        self.onSave = onSave
    }

    private var commandWithoutNewline: String {
        action.command.hasSuffix("\n") ? String(action.command.dropLast()) : action.command
    }

    var body: some View {
        Form {
            Section("Label") {
                TextField("Action name", text: $action.label)
                    .font(.system(size: 14, design: .monospaced))
            }

            Section("Command") {
                TextField("e.g. claude --continue", text: Binding(
                    get: { commandWithoutNewline },
                    set: { newValue in
                        action.command = autoEnter ? newValue + "\n" : newValue
                    }
                ))
                .font(.system(size: 14, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)

                Toggle("Press Enter after command", isOn: $autoEnter)
                    .font(.system(size: 13))
                    .onChange(of: autoEnter) { _, newValue in
                        let base = commandWithoutNewline
                        action.command = newValue ? base + "\n" : base
                    }
            }

            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 7), spacing: 12) {
                    ForEach(Self.iconOptions, id: \.self) { icon in
                        let isSelected = action.icon == icon
                        Button {
                            action.icon = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 16))
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Section") {
                Picker("Section", selection: $action.section) {
                    ForEach(Self.sectionOptions, id: \.self) { section in
                        Text(section).tag(section)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(action.label.isEmpty ? "New Action" : "Edit Action")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(action)
                }
                .disabled(action.label.isEmpty || action.command.replacingOccurrences(of: "\n", with: "").isEmpty)
            }
        }
    }
}

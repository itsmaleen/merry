import SwiftUI

struct QuickActionSettingsView: View {
    @EnvironmentObject var store: QuickActionStore
    @State private var editingAction: CustomQuickAction?
    @State private var isAddingNew = false

    // Built-in action definitions for the toggle list
    private static let builtInActions: [(label: String, icon: String, section: String)] = [
        ("Enter", "return", "Input"),
        ("Ctrl+C", "xmark.circle", "Input"),
        ("Ctrl+D", "eject", "Input"),
        ("Ctrl+Z", "pause.circle", "Input"),
        ("Clear", "trash", "Input"),
        ("Tab", "arrow.right.to.line", "Input"),
        ("Escape", "escape", "Input"),
        ("Up Arrow", "arrow.up", "Input"),
        ("Down Arrow", "arrow.down", "Input"),
        ("Split Right", "rectangle.split.2x1", "Terminal"),
        ("Split Down", "rectangle.split.1x2", "Terminal"),
        ("New Tab", "plus.rectangle", "Terminal"),
        ("New YOLO Tab", "bolt.fill", "Terminal"),
        ("Close Surface", "xmark.rectangle", "Terminal"),
        ("New Workspace", "square.grid.2x2", "Workspace"),
        ("Zoom", "arrow.up.left.and.arrow.down.right", "Terminal"),
        ("Fullscreen", "rectangle.fill", "Workspace"),
        ("Close Workspace", "xmark.square", "Workspace"),
    ]

    private var builtInSections: [(String, [(label: String, icon: String, section: String)])] {
        let grouped = Dictionary(grouping: Self.builtInActions, by: \.section)
        return ["Input", "Terminal", "Workspace"].compactMap { section in
            guard let items = grouped[section] else { return nil }
            return (section, items)
        }
    }

    private var customSections: [(String, [CustomQuickAction])] {
        let grouped = Dictionary(grouping: store.customActions, by: \.section)
        let order = grouped.keys.sorted()
        return order.map { ($0, grouped[$0]!) }
    }

    var body: some View {
        List {
            // One-tap chips above the input bar, in the order shown there.
            Section {
                if store.pinnedLabels.isEmpty {
                    Text("Nothing pinned. Tap a pin below to add one.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.pinnedLabels, id: \.self) { label in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: label))
                            .font(.system(size: 14))
                            .frame(width: 24)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(label)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                        Spacer()
                        usageBadge(label)
                    }
                }
                .onMove { store.movePinned(from: $0, to: $1) }
                .onDelete { indexSet in
                    for idx in indexSet.sorted(by: >) { store.togglePinned(store.pinnedLabels[idx]) }
                }
            } header: {
                HStack {
                    Text("Pinned")
                    Spacer()
                    EditButton().font(.system(size: 11, weight: .medium))
                }
            } footer: {
                Text("Pinned actions show as small buttons at the top right of the focused surface. Drag to reorder, swipe to unpin.")
            }

            // Custom / AI actions
            ForEach(customSections, id: \.0) { section, actions in
                Section(section) {
                    ForEach(actions) { action in
                        HStack(spacing: 12) {
                            Image(systemName: action.icon)
                                .font(.system(size: 14))
                                .frame(width: 24)
                                .foregroundStyle(.white.opacity(0.6))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.label)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                Text(action.command.replacingOccurrences(of: "\n", with: ""))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            usageBadge(action.label)
                            pinButton(action.label)

                            Toggle("", isOn: Binding(
                                get: { !action.isHidden },
                                set: { _ in store.toggleHidden(action) }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingAction = action
                        }
                    }
                    .onDelete { indexSet in
                        // Map section-local indices to the actual actions
                        for idx in indexSet {
                            store.delete(actions[idx])
                        }
                    }
                }
            }

            Section {
                Button {
                    isAddingNew = true
                } label: {
                    Label("Add Action", systemImage: "plus.circle")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
            }

            // Built-in actions
            ForEach(builtInSections, id: \.0) { section, actions in
                Section("Built-in: \(section)") {
                    ForEach(actions, id: \.label) { action in
                        HStack(spacing: 12) {
                            Image(systemName: action.icon)
                                .font(.system(size: 14))
                                .frame(width: 24)
                                .foregroundStyle(.white.opacity(0.6))

                            Text(action.label)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))

                            Spacer()

                            usageBadge(action.label)
                            pinButton(action.label)

                            Toggle("", isOn: Binding(
                                get: { !store.isBuiltInHidden(action.label) },
                                set: { _ in store.toggleBuiltIn(action.label) }
                            ))
                            .labelsHidden()
                        }
                    }
                }
            }
        }
        .navigationTitle("Quick Actions")
        .sheet(item: $editingAction) { action in
            NavigationStack {
                QuickActionEditView(action: action) { updated in
                    store.update(updated)
                    editingAction = nil
                }
            }
        }
        .sheet(isPresented: $isAddingNew) {
            NavigationStack {
                QuickActionEditView(
                    action: CustomQuickAction(label: "", icon: "terminal", section: "AI", command: "")
                ) { newAction in
                    store.add(newAction)
                    isAddingNew = false
                }
            }
        }
    }

    // MARK: - Pin + usage helpers

    private func icon(for label: String) -> String {
        Self.builtInActions.first(where: { $0.label == label })?.icon
            ?? store.customActions.first(where: { $0.label == label })?.icon
            ?? "questionmark.square"
    }

    @ViewBuilder
    private func usageBadge(_ label: String) -> some View {
        let n = store.usage(label)
        if n > 0 {
            Text("\(n)×")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func pinButton(_ label: String) -> some View {
        Button {
            store.togglePinned(label)
        } label: {
            Image(systemName: store.isPinned(label) ? "pin.fill" : "pin")
                .font(.system(size: 13))
                .foregroundStyle(store.isPinned(label) ? Color.orange : Color.white.opacity(0.35))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(store.isPinned(label) ? "Unpin \(label)" : "Pin \(label)")
    }
}

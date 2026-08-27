import Foundation
import SwiftUI

// MARK: - Persistable custom action

struct CustomQuickAction: Codable, Identifiable {
    var id: UUID
    var label: String
    var icon: String
    var section: String
    var command: String
    var isHidden: Bool

    init(id: UUID = UUID(), label: String, icon: String, section: String = "AI", command: String, isHidden: Bool = false) {
        self.id = id
        self.label = label
        self.icon = icon
        self.section = section
        self.command = command
        self.isHidden = isHidden
    }
}

// MARK: - Store

@MainActor
final class QuickActionStore: ObservableObject {
    private static let customActionsKey = "customQuickActions"
    private static let hiddenBuiltInKey = "hiddenBuiltInLabels"
    private static let seededKey = "quickActionsSeeded"

    @Published var customActions: [CustomQuickAction] = []
    @Published var hiddenBuiltInLabels: Set<String> = []

    init() {
        load()
        seedDefaultsIfNeeded()
    }

    // MARK: - Defaults

    static let defaultAIActions: [CustomQuickAction] = [
        CustomQuickAction(label: "Claude", icon: "brain", command: "claude\n"),
        CustomQuickAction(label: "Claude Continue", icon: "arrow.clockwise", command: "claude --continue\n"),
        CustomQuickAction(label: "Claude YOLO", icon: "bolt.shield", command: "claude --dangerously-skip-permissions\n"),
        CustomQuickAction(label: "Claude Resume", icon: "play.circle", command: "claude --resume\n"),
    ]

    private func seedDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seededKey) else { return }
        customActions = Self.defaultAIActions
        save()
        UserDefaults.standard.set(true, forKey: Self.seededKey)
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.customActionsKey),
           let decoded = try? JSONDecoder().decode([CustomQuickAction].self, from: data) {
            customActions = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.hiddenBuiltInKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            hiddenBuiltInLabels = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customActions) {
            UserDefaults.standard.set(data, forKey: Self.customActionsKey)
        }
        if let data = try? JSONEncoder().encode(hiddenBuiltInLabels) {
            UserDefaults.standard.set(data, forKey: Self.hiddenBuiltInKey)
        }
    }

    // MARK: - Custom actions

    func add(_ action: CustomQuickAction) {
        customActions.append(action)
        save()
    }

    func update(_ action: CustomQuickAction) {
        guard let idx = customActions.firstIndex(where: { $0.id == action.id }) else { return }
        customActions[idx] = action
        save()
    }

    func delete(_ action: CustomQuickAction) {
        customActions.removeAll { $0.id == action.id }
        save()
    }

    func toggleHidden(_ action: CustomQuickAction) {
        guard let idx = customActions.firstIndex(where: { $0.id == action.id }) else { return }
        customActions[idx].isHidden.toggle()
        save()
    }

    func moveCustomActions(from source: IndexSet, to destination: Int) {
        customActions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Built-in visibility

    func isBuiltInHidden(_ label: String) -> Bool {
        hiddenBuiltInLabels.contains(label)
    }

    func toggleBuiltIn(_ label: String) {
        if hiddenBuiltInLabels.contains(label) {
            hiddenBuiltInLabels.remove(label)
        } else {
            hiddenBuiltInLabels.insert(label)
        }
        save()
    }
}

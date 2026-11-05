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
    private static let pinnedKey = "pinnedQuickActionLabels"
    private static let usageKey = "quickActionUsageCounts"

    @Published var customActions: [CustomQuickAction] = []
    @Published var hiddenBuiltInLabels: Set<String> = []
    /// Labels shown as one-tap chips above the input bar, in order. Keyed by
    /// label (like `hiddenBuiltInLabels`) so built-in and custom actions share
    /// one list.
    @Published var pinnedLabels: [String] = QuickActionStore.defaultPinned
    /// How many times each action has run, by label. Feeds the "Top" section
    /// of the full menu and the counts in Settings.
    @Published var usageCounts: [String: Int] = [:]

    /// A plain new tab, and a new tab straight into claude YOLO (which
    /// covers what a separate "Claude YOLO" button would do).
    static let defaultPinned = ["New Tab", "New YOLO Tab"]
    private static let pinnedMigratedKey = "pinnedDroppedClaudeYOLO"

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
        // "New Terminal" was renamed "New Tab"; carry a hidden flag across.
        if hiddenBuiltInLabels.remove("New Terminal") != nil {
            hiddenBuiltInLabels.insert("New Tab")
        }
        if let data = UserDefaults.standard.data(forKey: Self.pinnedKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            pinnedLabels = decoded
        }
        // Builds before this pinned "Claude YOLO" next to "New YOLO Tab";
        // drop it once, so a later re-pin by hand sticks.
        if !UserDefaults.standard.bool(forKey: Self.pinnedMigratedKey) {
            pinnedLabels.removeAll { $0 == "Claude YOLO" }
            UserDefaults.standard.set(true, forKey: Self.pinnedMigratedKey)
            save()
        }
        if let data = UserDefaults.standard.data(forKey: Self.usageKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            usageCounts = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customActions) {
            UserDefaults.standard.set(data, forKey: Self.customActionsKey)
        }
        if let data = try? JSONEncoder().encode(hiddenBuiltInLabels) {
            UserDefaults.standard.set(data, forKey: Self.hiddenBuiltInKey)
        }
        if let data = try? JSONEncoder().encode(pinnedLabels) {
            UserDefaults.standard.set(data, forKey: Self.pinnedKey)
        }
        if let data = try? JSONEncoder().encode(usageCounts) {
            UserDefaults.standard.set(data, forKey: Self.usageKey)
        }
    }

    // MARK: - Pinned + usage

    func isPinned(_ label: String) -> Bool { pinnedLabels.contains(label) }

    func togglePinned(_ label: String) {
        if let idx = pinnedLabels.firstIndex(of: label) {
            pinnedLabels.remove(at: idx)
        } else {
            pinnedLabels.append(label)
        }
        save()
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        pinnedLabels.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func recordUse(_ label: String) {
        usageCounts[label, default: 0] += 1
        save()
    }

    func usage(_ label: String) -> Int { usageCounts[label] ?? 0 }

    // MARK: - Custom actions

    func add(_ action: CustomQuickAction) {
        customActions.append(action)
        save()
    }

    func update(_ action: CustomQuickAction) {
        guard let idx = customActions.firstIndex(where: { $0.id == action.id }) else { return }
        // A rename keeps the action's pin and its usage count.
        let oldLabel = customActions[idx].label
        if oldLabel != action.label {
            if let p = pinnedLabels.firstIndex(of: oldLabel) { pinnedLabels[p] = action.label }
            if let n = usageCounts.removeValue(forKey: oldLabel) { usageCounts[action.label, default: 0] += n }
        }
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

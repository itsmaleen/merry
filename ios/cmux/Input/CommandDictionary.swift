import Foundation

@MainActor
final class CommandDictionary: ObservableObject {
    @Published var commands: [String] {
        didSet { save() }
    }

    private static let storageKey = "commandDictionary"

    static let defaultCommands: [String] = [
        // Navigation
        "ls", "cd", "pwd", "cat", "less", "head", "tail", "find", "tree",
        // Files
        "cp", "mv", "rm", "mkdir", "touch", "chmod", "chown", "ln",
        // Git
        "git status", "git diff", "git log", "git add", "git commit", "git push",
        "git pull", "git checkout", "git branch", "git stash", "git merge",
        // Process
        "ps", "top", "kill", "fg", "bg", "jobs",
        // Network
        "curl", "wget", "ssh", "ping", "dig", "nc",
        // Tools
        "grep", "sed", "awk", "sort", "uniq", "wc", "xargs", "jq",
        // Package managers
        "brew", "npm", "yarn", "pip", "cargo",
        // Docker
        "docker", "docker-compose",
        // Misc
        "echo", "export", "env", "which", "man", "clear", "history",
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            self.commands = saved
        } else {
            self.commands = Self.defaultCommands
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func add(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !commands.contains(trimmed) else { return }
        commands.insert(trimmed, at: 0)
    }

    func remove(_ command: String) {
        commands.removeAll { $0 == command }
    }

    func reset() {
        commands = Self.defaultCommands
    }

    func suggestions(for input: String) -> [String] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            return Array(commands.prefix(20))
        }
        // Show matches: prefix first, then contains
        let prefix = commands.filter { $0.lowercased().hasPrefix(query) }
        let contains = commands.filter { $0.lowercased().contains(query) && !$0.lowercased().hasPrefix(query) }
        return Array((prefix + contains).prefix(20))
    }
}

import Foundation

@MainActor
final class CommandDictionary: ObservableObject {
    @Published var commands: [String] {
        didSet {
            lowercasedCommands = commands.map { $0.lowercased() }
            save()
        }
    }

    /// Lowercased mirror of `commands`, kept in sync in didSet.
    /// suggestions(for:) runs on every keystroke; lowercasing the whole list
    /// (twice) per call was per-keystroke allocation churn.
    private var lowercasedCommands: [String]

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
        // didSet doesn't fire during init, so set the mirror explicitly.
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            self.commands = saved
            self.lowercasedCommands = saved.map { $0.lowercased() }
        } else {
            self.commands = Self.defaultCommands
            self.lowercasedCommands = Self.defaultCommands.map { $0.lowercased() }
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
        // Show matches: prefix first, then contains — one pass, no per-call
        // lowercasing.
        var prefixMatches: [String] = []
        var containsMatches: [String] = []
        for (i, lower) in lowercasedCommands.enumerated() {
            if lower.hasPrefix(query) {
                prefixMatches.append(commands[i])
            } else if lower.contains(query) {
                containsMatches.append(commands[i])
            }
        }
        return Array((prefixMatches + containsMatches).prefix(20))
    }
}

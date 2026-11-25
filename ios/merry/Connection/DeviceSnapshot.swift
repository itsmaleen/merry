import Foundation

/// One session on a paired device the phone is not showing right now: just
/// enough to list it and open it.
struct PeekSession: Identifiable, Equatable {
    let id: String
    let title: String
    let workspaceID: String?
    let workspaceTitle: String
    /// "claude", "opencode", … when an agent runs in it.
    let agentKind: String?
    /// idle / working / blocked / done, from runtimes that report it (herdr).
    let agentStatus: String?

    /// From a `surface.list` entry. Browsers are left out: there is nothing
    /// to glance at or resume in one.
    init?(_ dict: [String: Any], workspaceTitle: String) {
        guard let id = dict["id"] as? String else { return nil }
        let type = (dict["type"] as? String) ?? "terminal"
        guard type != "browser" else { return nil }
        self.id = id
        self.title = (dict["title"] as? String) ?? type
        self.workspaceID = dict["workspace_id"] as? String
        self.workspaceTitle = workspaceTitle
        self.agentKind = (dict["resume_binding"] as? [String: Any])?["kind"] as? String
        self.agentStatus = dict["agent_status"] as? String
    }

    var isAgent: Bool { agentKind != nil }
    var needsYou: Bool { agentStatus == "blocked" }
    var isWorking: Bool { agentStatus == "working" }

    /// "Needs you", "Working", "Done", or nil when there is nothing to say.
    var statusLabel: String? {
        switch agentStatus {
        case "blocked": return "Needs you"
        case "working": return "Working"
        case "done": return "Done"
        default: return nil
        }
    }

    /// Where it lives and what runs in it: "merry · claude", "merry", "claude".
    var detail: String {
        let kind = agentKind ?? "shell"
        return workspaceTitle.isEmpty || workspaceTitle == title ? kind : "\(workspaceTitle) · \(kind)"
    }
}

/// What the phone knows about one other paired device.
struct DeviceSnapshot: Equatable {
    enum Reach: Equatable { case connecting, online, offline }

    var reach: Reach = .connecting
    var sessions: [PeekSession] = []

    var needsYou: Int { sessions.filter(\.needsYou).count }
    var working: Int { sessions.filter(\.isWorking).count }

    /// The order the list shows: sessions that need you, then working
    /// agents, then other agents, then shells. Stable within each group, so
    /// a refresh never shuffles rows of the same kind.
    static func ordered(_ sessions: [PeekSession]) -> [PeekSession] {
        func rank(_ s: PeekSession) -> Int {
            if s.needsYou { return 0 }
            if s.isWorking { return 1 }
            return s.isAgent ? 2 : 3
        }
        return sessions.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

enum DeviceName {
    /// A bridge's name without the daemon's own words: "merry-bridge-mini"
    /// and "desktop-bridge" read as "mini" and "desktop" on a chip. A name
    /// the user typed is left as it is unless it follows the same pattern.
    static func short(_ name: String) -> String {
        if name == "merry-bridge" || name == "cmux-bridge" { return "Mac" }
        var out = name
        for prefix in ["merry-bridge-", "cmux-bridge-"] where out.hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count))
        }
        for suffix in ["-bridge"] where out.hasSuffix(suffix) && out.count > suffix.count {
            out = String(out.dropLast(suffix.count))
        }
        return out.isEmpty ? name : out
    }
}

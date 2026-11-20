import Foundation

@main
struct DeviceSnapshotTests {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) {
        print((ok ? "  ok   " : "  FAIL ") + name)
        if !ok { failures += 1 }
    }

    static func session(_ id: String, kind: String? = nil, status: String? = nil, type: String? = nil, title: String? = nil) -> PeekSession? {
        var dict: [String: Any] = ["id": id, "workspace_id": "w1"]
        if let title { dict["title"] = title }
        if let type { dict["type"] = type }
        if let kind { dict["resume_binding"] = ["kind": kind] as [String: Any] }
        if let status { dict["agent_status"] = status }
        return PeekSession(dict, workspaceTitle: "merry")
    }

    static func main() {
        print("== Sessions")
        check("a browser is not a session", session("b", type: "browser") == nil)
        check("an entry with no id is dropped", PeekSession(["title": "x"], workspaceTitle: "") == nil)
        let shell = session("s", title: "~/merry")!
        check("a shell has no status", shell.statusLabel == nil && !shell.isAgent)
        check("a shell's detail names its workspace", shell.detail == "merry · shell")
        let blocked = session("a", kind: "claude", status: "blocked", title: "fix")!
        check("blocked reads as needs you", blocked.needsYou && blocked.statusLabel == "Needs you")
        check("an agent's detail names its kind", blocked.detail == "merry · claude")
        check("a title equal to the workspace is not repeated", session("t", kind: "claude", title: "merry")!.detail == "claude")

        print("== Order")
        let list = [
            session("shell1")!,
            session("idle", kind: "claude", status: "idle")!,
            session("work", kind: "claude", status: "working")!,
            session("shell2")!,
            session("block", kind: "opencode", status: "blocked")!,
            session("done", kind: "claude", status: "done")!,
        ]
        let ordered = DeviceSnapshot.ordered(list).map(\.id)
        check("needs you, working, agents, shells; stable within", ordered == ["block", "work", "idle", "done", "shell1", "shell2"])
        let snap = DeviceSnapshot(reach: .online, sessions: list)
        check("counts", snap.needsYou == 1 && snap.working == 1)

        print("== Names")
        check("merry-bridge-mini is mini", DeviceName.short("merry-bridge-mini") == "mini")
        check("desktop-bridge is desktop", DeviceName.short("desktop-bridge") == "desktop")
        check("a bare merry-bridge is Mac", DeviceName.short("merry-bridge") == "Mac")
        check("a typed name is kept", DeviceName.short("Work MacBook") == "Work MacBook")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

// Tests for ScreenDialogDetector against real Claude Code screens captured
// with tmux (scripts/fixtures/screens/, 100x40, v2.1.327): the pickers slash
// commands open, a permission prompt and the folder-trust check must be
// found; the idle prompt, a working spinner and commands that only print
// must not.
//
// Run via ./ios/scripts/run-tests.sh (from ios/).
import Foundation

private var failures = 0

private func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what)")
    }
}

private func screen(_ name: String) -> [String] {
    let path = "scripts/fixtures/screens/\(name).txt"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        failures += 1
        print("  FAIL missing fixture \(path)")
        return []
    }
    return text.components(separatedBy: "\n")
}

@main
enum ScreenDialogTests {
static func main() {

print("Negatives: no dialog")
for name in ["idle", "working", "working2", "agents", "output-style", "app-fixture-claude"] {
    check(ScreenDialogDetector.detect(rows: screen(name)) == nil, "\(name): no dialog")
}
check(ScreenDialogDetector.detect(rows: []) == nil, "empty screen: no dialog")
// Transcript text that happens to say "Esc to cancel" above the prompt.
var quoted = screen("idle")
quoted.insert("  The dialog says Enter to confirm · Esc to cancel", at: 10)
check(ScreenDialogDetector.detect(rows: quoted) == nil, "a hint quoted in the conversation above the prompt: no dialog")

print("/model: numbered options")
if let d = ScreenDialogDetector.detect(rows: screen("model")) {
    check(d.title == "Select model", "title is the dialog's first line (got \(d.title ?? "nil"))")
    check(d.options.count == 5, "five numbered models (got \(d.options.count))")
    check(d.options.map(\.number) == [1, 2, 3, 4, 5], "numbers 1-5")
    check(d.options[0].label == "Default (recommended)", "label splits at the column gap (got \(d.options[0].label))")
    check(d.options[0].detail == "Opus 5.5 · Best for everyday, complex tasks", "detail is the rest")
    check(d.selectedIndex == 2, "cursor on Fable (index 2)")
    check(d.options[2].label == "Fable 5.2" && d.options[2].detail == "Current · For your toughest challenges",
          "the ✔ becomes 'Current' in the detail (got \(d.options[2].label) / \(d.options[2].detail ?? "nil"))")
    check(d.hint?.hasSuffix("Esc to cancel") == true, "hint is the footer")
    check(d.keys(toChoose: 3) == ["4"], "a numbered dialog is answered with the number")
    check(d.rawRows.last == d.hint.map { "  " + $0 }, "rawRows end with the hint row")
} else { check(false, "/model detected") }

print("Permission prompt: numbered options")
if let d = ScreenDialogDetector.detect(rows: screen("approval")) {
    check(d.title == "Bash command", "title under the rule (got \(d.title ?? "nil"))")
    check(d.options.map(\.label) == ["Yes", "Yes, and always allow access to /tmp from this project",
                                     "Yes, and switch to auto mode · auto mode handles these prompts for you", "No"],
          "four options, single-spaced text stays in the label")
    check(d.selectedIndex == 0, "cursor on Yes")
    check(d.hint == "Esc to cancel · Tab to amend", "hint")
} else { check(false, "approval detected") }

print("Folder trust: unnumbered cursor list")
if let d = ScreenDialogDetector.detect(rows: screen("trust")) {
    check(d.title == "Accessing workspace", "title (got \(d.title ?? "nil"))")
    check(d.options.map(\.label) == ["No, exit", "Yes, I trust this folder"], "two rows aligned with the cursor's text")
    check(d.options.allSatisfy { $0.number == nil }, "no numbers")
    check(d.selectedIndex == 0, "cursor on 'No, exit'")
    check(d.keys(toChoose: 1) == ["Down", "enter"], "moves down one and confirms")
    check(d.keys(toChoose: 0) == ["enter"], "the cursor row is just Enter")
} else { check(false, "trust detected") }

print("Pickers that fall back to the peek (dialog, no options)")
let peeks: [(String, String?)] = [
    ("config", nil), ("resume", "Resume session"), ("mcp", nil), ("permissions", nil), ("status", nil), ("memory", "Memory"),
]
for (name, title) in peeks {
    if let d = ScreenDialogDetector.detect(rows: screen(name)) {
        check(d.options.isEmpty, "\(name): detected, not offered as a list (got \(d.options.count) options)")
        if let title { check(d.title == title, "\(name): title \(title) (got \(d.title ?? "nil"))") }
        check(d.hint != nil && !d.rawRows.isEmpty, "\(name): hint and rows kept for the peek")
    } else {
        check(false, "\(name): detected")
    }
}

print("Unit rules")
check(ScreenDialogDetector.isDialogHint("Enter to confirm · Esc to cancel"), "Enter/Esc hint")
check(ScreenDialogDetector.isDialogHint("  ↑/↓ to navigate · Enter to select · Esc to close"), "navigate hint")
check(!ScreenDialogDetector.isDialogHint("  ⏸ manual mode on · esc to interrupt"), "working footer is not a hint")
check(ScreenDialogDetector.isRule(String(repeating: "─", count: 40)), "─ rule")
check(!ScreenDialogDetector.isRule(String(repeating: "╌", count: 40)), "dashed separator inside a dialog is not its top")
let split = ScreenDialogDetector.splitLabel("Sonnet 5.5             Most efficient")
check(split.0 == "Sonnet 5.5" && split.1 == "Most efficient", "label/detail split")
check(ScreenDialogDetector.parseNumbered(["  1. A", "  3. B"]) == nil, "numbers must run 1, 2, 3")
check(ScreenDialogDetector.parseNumbered(["  1. A"]) == nil, "one numbered row is not a list")

print("Short and narrow terminals")
if let d = ScreenDialogDetector.detect(rows: screen("model-narrow")) {
    check(d.options.count == 5 && d.hiddenAbove == 0 && d.hiddenBelow == 0, "narrow: all five options, nothing hidden")
    check(d.options[1].detail == "For complex work and everyday tasks", "narrow: a wrapped description is joined")
} else { check(false, "narrow: dialog found") }
let clipped = ScreenDialogDetector.detect(rows: screen("model-short-clipped"))
check(clipped?.options.map(\.number) == [2, 3] && clipped?.hiddenAbove == 1 && clipped?.hiddenBelow == 3, "short: window 2-3 with 1 above, 3 below, footer off screen")
check(clipped?.selectedIndex == 1 && clipped?.scrollUpPresses == 2 && clipped?.scrollDownPresses == 1, "short: presses to scroll past each edge")
check(clipped?.keys(toChoose: 0) == ["2"], "short: a row is picked by its own number")
let top = ScreenDialogDetector.detect(rows: screen("model-short-top"))
check(top?.options.map(\.number) == [1, 2] && top?.hiddenAbove == 0 && top?.hiddenBelow == 4, "short, at the top: 1-2 with 4 below, not a two-option list")
let one = ScreenDialogDetector.detect(rows: screen("model-short-one"))
check(one?.options.map(\.number) == [3] && one?.hiddenAbove == 2 && one?.hiddenBelow == 3, "one row in view")
if let top, let clipped {
    let merged = top.merging(clipped)
    check(merged.options.map(\.number) == [1, 2, 3] && merged.hiddenAbove == 0 && merged.hiddenBelow == 3, "scrolling keeps the rows already seen")
    check(merged.options.filter(\.selected).map(\.number) == [1], "the cursor is the newest frame's")
    check(merged.options[2].label == "Fable 5.2", "remembered row keeps its label")
}
check(ScreenDialogDetector.parseNumbered(["  2. A", "  3. B"]) == nil, "a run not starting at 1 needs a more-marker")

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
}
}

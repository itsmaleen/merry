// Tests for TranscriptEvent decoding and ChatGrouping — how an agent
// transcript's events become chat rows, work-row summaries and glances.
//
// Run via ./ios/scripts/run-tests.sh. UIKit-free on purpose: the grouping and
// the one-sentence glance are what the small cards are trusted for, so they
// must be checkable without the app.
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

private func decode(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

// The contract's example reply (plans/session-ui.md), verbatim.
private let contractExample = """
{"supported": true, "session_id": "abc", "fingerprint": "f", "source": "binding",
 "events": [
  {"id": "u1", "kind": "user", "ts": 1794000000, "text": "fix the flaky poller test"},
  {"id": "a1", "kind": "text", "text": "I'll look at the poller first."},
  {"id": "toolu_1", "kind": "tool", "tool": "Read", "arg": "bridge/internal/poller/poller.go", "status": "ok"},
  {"id": "toolu_2", "kind": "tool", "tool": "Bash", "arg": "go test ./internal/poller", "status": "error", "output": "--- FAIL: TestDedup (0.01s)\\nFAIL"},
  {"id": "toolu_3", "kind": "tool", "tool": "Edit", "arg": "bridge/internal/poller/poller.go", "status": "ok", "added": 4, "removed": 1},
  {"id": "a2", "kind": "text", "text": "The dedup map was reset on every poll. Fixed."},
  {"id": "toolu_4", "kind": "question", "questions": [{"question": "Also fix the cmux path?", "header": "Scope", "multi": false, "options": [{"label": "Yes", "description": "Same bug there"}, {"label": "No", "description": "Leave it"}]}], "answered": false}
 ],
 "pending": {"kind": "question", "event_id": "toolu_4"}}
"""

@main
enum ChatGroupingTests {
static func main() {

print("TranscriptEvent decoding")
let reply = decode(contractExample)
let events = TranscriptEvent.decodeList(reply["events"])
check(events.count == 7, "all seven contract events decode")
check(events[0].kind == .user && events[0].ts == 1794000000, "user event keeps its ts")
check(events[1].ts == nil, "a missing ts stays nil")
check(events[3].status == .error && events[3].output == "--- FAIL: TestDedup (0.01s)\nFAIL", "tool error keeps its output tail")
check(events[4].added == 4 && events[4].removed == 1, "edit keeps +/- counts")
check(events[6].questions.first?.options.count == 2, "question options decode")
check(events[6].questions.first?.header == "Scope", "question header decodes")
let pending = PendingState(reply["pending"])
check(pending == PendingState(kind: .question, eventID: "toolu_4"), "pending question decodes")
check(PendingState(NSNull()) == nil, "null pending is nil")
check(PendingState(nil) == nil, "absent pending is nil")
check(PendingState(["kind": "brand-new"]) == PendingState(kind: .unknown), "unknown pending kind reads as unknown")
let approval = PendingState(["kind": "approval", "event_id": "t", "tool": "Bash", "arg": "rm -rf build"])
check(approval?.tool == "Bash" && approval?.arg == "rm -rf build", "pending approval keeps tool and arg")

let tolerant = TranscriptEvent.decodeList([
    ["id": "x", "kind": "tool"],                 // no tool, arg, status
    ["kind": "text", "text": "no id"],           // dropped: no id
    ["id": "y", "kind": "thinking"],             // dropped: unknown kind
    ["id": "z", "kind": "text", "ts": "12.5"],   // numeric string ts
] as [[String: Any]])
check(tolerant.count == 2, "entries without id or with unknown kinds are skipped")
check(tolerant[0].tool == "" && tolerant[0].status == .running, "a tool with no status reads as running")
check(tolerant[1].ts == 12.5, "a numeric-string ts is accepted")
check(TranscriptEvent.decodeList("garbage").isEmpty, "a non-array events field decodes to nothing")

print("ChatGrouping.items")
let items = ChatGrouping.items(from: events)
check(items.map(\.id) == ["u1", "a1", "toolu_1", "a2", "toolu_4"], "tools between prose fold into one work row")
if case .work(let g) = items[2] {
    check(g.tools.count == 3, "the work row holds all three calls")
    check(g.summary == "read 1 file, edited 1 file, ran 1 command", "summary counts by kind")
    check(g.duration == nil, "no timestamps: no duration")
    check(g.title == "Worked", "no duration: title is just Worked")
    check(g.failedCount == 1, "failed call counted")
    check(!g.isRunning, "finished run is not running")
} else {
    check(false, "third item is a work row")
}
check(ChatGrouping.items(from: []).isEmpty, "no events, no items")

// A longer, timed session: two runs, the first spanning 2 minutes.
let timed: [TranscriptEvent] = [
    .init(id: "u", kind: .user, ts: 1000, text: "fix it"),
    .init(id: "t1", kind: .tool, ts: 1005, tool: "Read", arg: "a/b.go"),
    .init(id: "t2", kind: .tool, ts: 1010, tool: "Read", arg: "a/c.go"),
    .init(id: "t3", kind: .tool, ts: 1020, tool: "Read", arg: "a/b.go"),
    .init(id: "t4", kind: .tool, ts: 1030, tool: "Bash", arg: "go test"),
    .init(id: "t5", kind: .tool, ts: 1040, tool: "grep", arg: "drain"),
    .init(id: "p", kind: .text, ts: 1125, text: "Found it."),
    .init(id: "t6", kind: .tool, ts: 1130, tool: "Bash", arg: "go test -count=50", status: .running),
]
let timedItems = ChatGrouping.items(from: timed)
check(timedItems.count == 4, "user, run, prose, run")
if case .work(let g) = timedItems[1] {
    check(g.duration == 120, "run lasts from its first call to the next prose")
    check(g.title == "Worked 2m", "two minutes formats as 2m")
    check(g.summary == "read 2 files, ran 1 command, 1 search", "files count once; opencode lowercase tools count")
    check(g.label == "Worked 2m · read 2 files, ran 1 command, 1 search", "label joins title and summary")
} else { check(false, "second item is a work row") }
if case .work(let g) = timedItems[3] {
    check(g.isRunning, "trailing run with a running call is running")
    check(g.title == "Working", "a lone running call has no span yet")
} else { check(false, "fourth item is a work row") }

let blankProse: [TranscriptEvent] = [
    .init(id: "t1", kind: .tool, tool: "Bash", arg: "ls"),
    .init(id: "b", kind: .text, text: "  \n"),
    .init(id: "t2", kind: .tool, tool: "Bash", arg: "pwd"),
]
check(ChatGrouping.items(from: blankProse).count == 1, "blank prose doesn't split a run")

print("ChatGrouping.formatDuration")
check(ChatGrouping.formatDuration(0) == "1s", "zero reads as 1s")
check(ChatGrouping.formatDuration(40) == "40s", "seconds")
check(ChatGrouping.formatDuration(150) == "2m", "minutes round down")
check(ChatGrouping.formatDuration(3900) == "1h 5m", "hours and minutes")
check(ChatGrouping.formatDuration(7200) == "2h", "whole hours")
check(ChatGrouping.formatDuration(-1) == nil, "negative is nil")

print("ChatGrouping.line")
check(ChatGrouping.line(for: events[2]) == ToolLine(category: .read, verb: "Read", subject: "poller.go", detail: ""), "read shows the file name")
check(ChatGrouping.line(for: events[3]).detail == "failed", "error shows failed")
check(ChatGrouping.line(for: events[4]).detail == "+4 −1", "edit shows +/-")
check(ChatGrouping.line(for: timed[7]).detail == "running", "running shows running")
check(ChatGrouping.line(for: timed[5]).subject == "“drain”", "search quotes its pattern")
check(ChatGrouping.basename("plain") == "plain", "a bare word stays as is")

print("ChatGrouping.glance")
let g1 = ChatGrouping.glance(events: events, pending: pending, agentStatus: nil, isWorking: false)
check(g1.status == .asks && g1.sentence == "Also fix the cmux path?", "pending question: asks + the question")
check(g1.added == 4 && g1.removed == 1, "glance sums +/-")
check(g1.needsYou, "a question needs you")
let g2 = ChatGrouping.glance(events: events, pending: approval, agentStatus: "blocked", isWorking: false)
check(g2.status == .approve && g2.sentence == "Wants to run `rm -rf build`", "pending approval: approve + the command")
let g3 = ChatGrouping.glance(events: Array(events.prefix(6)), pending: nil, agentStatus: "idle", isWorking: false)
check(g3.status == .done && g3.sentence == "The dedup map was reset on every poll. Fixed.", "idle: done + lead sentences of last reply")
let g4 = ChatGrouping.glance(events: timed, pending: nil, agentStatus: nil, isWorking: true)
check(g4.status == .working, "no backend status + screen activity reads as working")
check(g4.sentence == "Found it.", "working keeps the last reply as its sentence (nothing more to add)")
let g4idle = ChatGrouping.glance(events: timed, pending: nil, agentStatus: "idle", isWorking: true)
check(g4idle.status == .done, "idle + a trailing running call reads as done (the backend's word wins)")
let g4quiet = ChatGrouping.glance(events: timed, pending: nil, agentStatus: nil, isWorking: false)
check(g4quiet.status == .done, "no backend status, no screen activity: a trailing running call alone is not working")
let g4work = ChatGrouping.glance(events: Array(events.prefix(6)), pending: nil, agentStatus: "working", isWorking: false)
check(g4work.status == .working, "a working status reads as working")
check(ChatGrouping.agentIsWorking(agentStatus: "done", screenActive: true) == false, "agentIsWorking: done + screen activity is not working")
check(ChatGrouping.agentIsWorking(agentStatus: "working", screenActive: false), "agentIsWorking: working status")
check(ChatGrouping.agentIsWorking(agentStatus: nil, screenActive: true), "agentIsWorking: no status falls back to screen activity")
check(ChatGrouping.leadSentences(of: "Found it. The reader stops early. More text here that goes on.") == "Found it. The reader stops early. More text here that goes on.", "short sentences join until long enough")
check(ChatGrouping.leadSentences(of: "A long enough first sentence that says plenty on its own here. Second.") == "A long enough first sentence that says plenty on its own here.", "a long first sentence stands alone")
let g5 = ChatGrouping.glance(events: events, pending: PendingState(kind: .unknown), agentStatus: "blocked", isWorking: false)
check(g5.status == .waiting && g5.needsYou, "unknown block: waiting, needs you")
let g6 = ChatGrouping.glance(events: [], pending: nil, agentStatus: "working", isWorking: false)
check(g6.status == .working && g6.sentence == "No reply yet.", "empty transcript has a placeholder sentence")
let g7 = ChatGrouping.glance(events: events, pending: nil, agentStatus: "blocked", isWorking: false)
check(g7.status == .waiting, "blocked with no pending still needs you")

print("ChatGrouping.firstSentence")
check(ChatGrouping.firstSentence(of: "## Done\nmore") == "Done", "heading marker dropped, first line only")
check(ChatGrouping.firstSentence(of: "Edited `a.b c` here. Then more.") == "Edited `a.b c` here.", "a dot inside inline code is not a sentence end")
check(ChatGrouping.firstSentence(of: "**Fixed**: it works! Yes.") == "Fixed: it works!", "bold dropped, ! ends a sentence")
check(ChatGrouping.firstSentence(of: String(repeating: "a", count: 300)).count == 180, "long text is capped")

print("ChatGrouping.canAnswerByKey")
check(ChatGrouping.canAnswerByKey(events[6]), "single single-select question answers by key")
var multi = events[6]
multi.questions = [.init(question: "q", header: "", multi: true, options: [.init(label: "a", description: "")])]
check(!ChatGrouping.canAnswerByKey(multi), "multi-select falls back to the peek")
var two = events[6]
two.questions = two.questions + two.questions
check(!ChatGrouping.canAnswerByKey(two), "two questions fall back to the peek")
var done = events[6]
done.answered = true
check(!ChatGrouping.canAnswerByKey(done), "an answered question takes no key")

print("ChatGrouping.plainText")
let text = ChatGrouping.plainText(events)
check(text.hasPrefix("› You\nfix the flaky poller test"), "starts with the user turn")
check(text.contains("⚙ Bash: go test ./internal/poller (failed)\n--- FAIL"), "failed tool keeps its output")
check(text.contains("  1. Yes"), "question options are numbered")

print("Slash commands and scheduled runs")
let loopEvents = TranscriptEvent.decodeList([
    ["id": "u7", "kind": "user", "ts": 1794000900, "command": "/loop", "text": "5m check the deploy", "skill_loaded": true],
    ["id": "a7", "kind": "text", "ts": 1794000901, "text": "Deploy is green."],
    ["id": "u9", "kind": "user", "ts": 1794001200, "command": "/loop", "text": "5m check the deploy", "skill_loaded": true, "scheduled": true, "run": 1],
    ["id": "t9", "kind": "tool", "ts": 1794001201, "tool": "Bash", "arg": "gh run list", "status": "ok"],
    ["id": "a9", "kind": "text", "ts": 1794001210, "text": "Still green."],
    ["id": "u10", "kind": "user", "ts": 1794001500, "text": "keep an eye on it", "scheduled": true],
    ["id": "a10", "kind": "text", "ts": 1794001510, "text": "Green again."],
] as [[String: Any]])
check(loopEvents[0].command == "/loop" && loopEvents[0].text == "5m check the deploy" && loopEvents[0].skillLoaded, "command, args and skill_loaded decode")
check(!loopEvents[0].scheduled && loopEvents[0].run == nil, "a human command is not scheduled and has no run")
check(loopEvents[2].scheduled && loopEvents[2].run == 1, "scheduled and run decode")
check(loopEvents[5].scheduled && loopEvents[5].command == nil, "scheduled can be set without a command")
let oldBridge = TranscriptEvent.decodeList([["id": "o1", "kind": "user", "text": "/loop 5m check"]] as [[String: Any]])
check(oldBridge[0].command == nil && !oldBridge[0].scheduled && !oldBridge[0].skillLoaded, "an older bridge's plain /text has no command fields")
if case .user = ChatGrouping.items(from: oldBridge)[0] {} else { check(false, "an older bridge's /text stays a user bubble") }
let emptyCommand = TranscriptEvent.decodeList([["id": "e", "kind": "user", "command": "", "text": "hi"]] as [[String: Any]])
check(emptyCommand[0].command == nil, "an empty command reads as none")
check(loopEvents[0].typedText == "/loop 5m check the deploy", "typed text joins command and args")
check(TranscriptEvent(id: "x", kind: .user, command: "/clear").typedText == "/clear", "a command with no args types as the name")

let loopItems = ChatGrouping.items(from: loopEvents)
check(loopItems.map(\.id) == ["u7", "a7", "u9", "t9", "a9", "u10", "a10"], "commands and scheduled runs are their own rows")
if case .command = loopItems[0] {} else { check(false, "a human command is a command chip") }
if case .scheduled = loopItems[2] {} else { check(false, "a scheduled command is a divider") }
if case .scheduled = loopItems[5] {} else { check(false, "a scheduled plain line is a divider") }
check(ChatGrouping.scheduledLabel(loopEvents[2], time: "2:15 PM") == "Loop run 1 · 2:15 PM", "divider: name, run and time")
check(ChatGrouping.scheduledLabel(loopEvents[5], time: "2:15 PM") == "Scheduled run · 2:15 PM", "divider without command or run")
check(ChatGrouping.scheduledLabel(loopEvents[2], time: nil) == "Loop run 1", "divider without a time")
var run4 = loopEvents[5]; run4.run = 4
check(ChatGrouping.scheduledTitle(run4) == "Scheduled run 4", "scheduled with run, no command")
check(ChatGrouping.commandTitle("/code-review") == "Code-review", "command title drops the slash and capitalises")

let loopGlance = ChatGrouping.glance(events: loopEvents, pending: nil, agentStatus: "idle", isWorking: false)
check(loopGlance.sentence == "Green again.", "glance: the last reply, not a scheduled line")

let loopText = ChatGrouping.plainText(loopEvents)
check(loopText.hasPrefix("› You\n/loop 5m check the deploy"), "plain text prints the command line")
check(loopText.contains("— Loop run 1 —\n⚙ Bash"), "plain text prints a scheduled run as a divider")
check(loopText.contains("— Scheduled run —\n\n⏺ Claude\nGreen again."), "plain text: a reply after a divider gets its speaker")
check(!loopText.contains("keep an eye on it"), "plain text leaves a scheduled line's text out")

print("Queued events")
let withQueue = TranscriptEvent.decodeList([
    ["id": "u1", "kind": "user", "ts": 100, "text": "fix it"],
    ["id": "t1", "kind": "tool", "ts": 101, "tool": "Bash", "arg": "go test", "status": "running"],
    ["id": "q:200", "kind": "user", "ts": 200, "text": "also the docs", "queued": true],
    ["id": "q:201", "kind": "user", "ts": 201, "command": "/compact", "text": "", "queued": true],
] as [[String: Any]])
check(withQueue[2].queued && !withQueue[0].queued, "queued decodes, defaults to false")
let qItems = ChatGrouping.items(from: withQueue)
check(qItems.map(\.id) == ["u1", "t1", "q:200", "q:201"], "queued events follow as outbox rows")
if case .work(let g) = qItems[1] { check(g.isRunning && g.title == "Working", "a queued event doesn't end the run before it") } else { check(false, "second row is a work row") }
if case .outbox(let o) = qItems[3] { check(o.label == .queued && o.typedText == "/compact", "a queued command keeps its command") } else { check(false, "queued rows are outbox rows") }
let echo = LocalEcho(id: "e1", text: "hello", sentAt: 300)
let qLocal = ChatGrouping.items(from: withQueue, local: [echo])
check(qLocal.map(\.id).suffix(3) == ["q:200", "q:201", "local:e1"], "local echoes come after real queued events")
let qGlance = ChatGrouping.glance(events: withQueue, pending: nil, agentStatus: "idle", isWorking: false)
check(qGlance.sentence == "No reply yet.", "glance ignores queued lines")
check(ChatGrouping.conversation(withQueue).count == 2, "conversation drops queued events")

print("Command output")
let withOutput = TranscriptEvent.decodeList([
    ["id": "c1", "kind": "user", "ts": 300, "command": "/model", "text": "",
     "command_output": "Set model to `Opus 5` and saved as your default\n"],
    ["id": "c2", "kind": "user", "ts": 301, "command": "/bogus", "text": "", "command_output": "Unknown command", "command_error": true],
    ["id": "c3", "kind": "user", "ts": 302, "command": "/clear", "text": "", "command_output": "   ", "command_error": true],
] as [[String: Any]])
check(withOutput[0].commandOutput == "Set model to `Opus 5` and saved as your default" && !withOutput[0].commandError, "command_output decodes, trimmed")
check(withOutput[1].commandError, "command_error decodes")
check(withOutput[2].commandOutput == nil && !withOutput[2].commandError, "blank output is no output, and no error")
let outText = ChatGrouping.plainText(withOutput)
check(outText.contains("/model\n  ⎿ Set model to `Opus 5`"), "plain text shows the output under the command")
if case .command(let e) = ChatGrouping.items(from: withOutput)[0] {
    check(ChatGrouping.searchText(.command(e)).contains("saved as your default"), "find matches the output")
} else { check(false, "a command with output is still a chip") }

print("SlashCommands")
let seenCmds = SlashCommands.seen(in: TranscriptEvent.decodeList([
    ["id": "1", "kind": "user", "command": "/deploy"],
    ["id": "2", "kind": "user", "command": "/loop", "scheduled": true],
    ["id": "3", "kind": "user", "command": "/deploy"],
    ["id": "4", "kind": "user", "text": "/notacommand"],
] as [[String: Any]]))
check(seenCmds == ["/deploy", "/loop"], "seen: most recent first, deduplicated, commands only")
check(SlashCommands.suggestions(draft: "", seen: []) == [], "no slash, no suggestions")
check(SlashCommands.suggestions(draft: "hi /lo", seen: []) == [], "a slash later in the draft is not a command")
check(SlashCommands.suggestions(draft: "/loop ", seen: []) == [], "a space ends the suggestions")
check(SlashCommands.suggestions(draft: "/", seen: []) == SlashCommands.builtIn, "a bare slash offers every built-in")
check(SlashCommands.suggestions(draft: "/", seen: ["/deploy", "/loop"]).prefix(3) == ["/deploy", "/loop", "/clear"], "seen commands come first, built-ins after, once each")
check(SlashCommands.suggestions(draft: "/c", seen: []) == ["/clear", "/compact", "/code-review", "/context", "/cost", "/config"], "prefix filter keeps the list order")
check(SlashCommands.suggestions(draft: "/CO", seen: []).first == "/compact", "matching ignores case")
check(SlashCommands.suggestions(draft: "/re", seen: ["/release"]) == ["/release", "/resume", "/review"], "seen matches lead the filtered list")
check(SlashCommands.suggestions(draft: "/mcp", seen: []) == [], "an exact single match offers nothing more")
check(SlashCommands.suggestions(draft: "/zzz", seen: []) == [], "no match, no row")

print("Compaction")
let compactEvents = TranscriptEvent.decodeList([
    ["id": "u1", "kind": "user", "ts": 1794000000, "text": "before"],
    ["id": "c1", "kind": "user", "ts": 1794000100, "compacted": true],
    ["id": "u2", "kind": "user", "ts": 1794000200, "text": "after"],
] as [[String: Any]])
let compactItems = ChatGrouping.items(from: compactEvents)
check(compactEvents.count == 3 && compactEvents[1].compacted, "compacted decodes with empty text")
if compactItems.count == 3, case .compacted = compactItems[1] {} else { check(false, "a compaction is a divider row, not a user bubble") }

print("Markdown tables")
let tableLines = ["Intro", "| Check | Result |", "|---|:--:|", "| Pods | 6 of 6 |", "| Code | `a|b` \\| c |", "| Short |", "", "After"]
if let found = MarkdownTable.parse(tableLines, from: 1) {
    check(found.table.header == ["Check", "Result"] && found.count == 5, "header, and the table ends at the blank line")
    check(found.table.rows[0] == ["Pods", "6 of 6"], "cells are trimmed")
    check(found.table.rows[1] == ["Code", "`a|b` | c"], "pipes in code or escaped stay in the cell")
    check(found.table.rows[2] == ["Short", ""], "a short row is padded")
} else { check(false, "table parses") }
check(MarkdownTable.parse(tableLines, from: 0) == nil, "prose is not a table")
check(MarkdownTable.parse(["a | b", "plain text"], from: 0) == nil, "a pipe without a delimiter row is not a table")
check(MarkdownTable.parse(["| a | b |", "|---|"], from: 0) == nil, "delimiter must match the header's columns")
check(MarkdownTable.parse(["a | b", "--- | ---", "1 | 2"], from: 0)?.table.rows == [["1", "2"]], "outer pipes are optional")
check(MarkdownTable.cells("| a | b | c | d |").count == 4, "four columns")

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
}
}

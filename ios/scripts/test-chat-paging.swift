// Tests for ChatPaging (one ordered event list per surface: tail merges,
// page prepends, the cap, the page-request decision, prepend detection, the
// "New since you were here" marker) and ChatOutbox (local echo matching).
//
// Run via ./ios/scripts/run-tests.sh.
import CoreGraphics
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

private func ev(_ id: String, _ kind: TranscriptEvent.Kind = .text, ts: Double? = nil, text: String = "x",
                queued: Bool = false, command: String? = nil, scheduled: Bool = false) -> TranscriptEvent {
    TranscriptEvent(id: id, kind: kind, ts: ts, text: text, command: command, scheduled: scheduled, queued: queued)
}

private func ids(_ events: [TranscriptEvent]) -> [String] { events.map(\.id) }

@main
enum ChatPagingTests {
static func main() {

var p0 = ChatPaging.Merged(events: [], hasMore: false)
print("ChatPaging.mergeTail")
let held = ["a", "b", "c", "d"].map { ev($0) }
var m = ChatPaging.mergeTail(existing: [], existingHasMore: false, tail: held, tailHasMore: true)
check(ids(m.events) == ["a", "b", "c", "d"] && m.hasMore, "first load: the list is the tail, with its has_more")
m = ChatPaging.mergeTail(existing: held, existingHasMore: false, tail: [ev("c"), ev("d"), ev("e")], tailHasMore: true)
check(ids(m.events) == ["a", "b", "c", "d", "e"], "tail replaces from its first id onward")
check(!m.hasMore, "a tail found in the list keeps the list's has_more (older pages already loaded)")
var changed = ev("d"); changed.text = "edited"
m = ChatPaging.mergeTail(existing: held, existingHasMore: true, tail: [ev("c"), changed], tailHasMore: true)
check(m.events.last?.text == "edited" && m.events.count == 4, "a changed last event replaces the old one")
m = ChatPaging.mergeTail(existing: held, existingHasMore: false, tail: [ev("x"), ev("y")], tailHasMore: true)
check(ids(m.events) == ["x", "y"] && m.hasMore, "tail's first id not in the list: the list becomes the tail")
m = ChatPaging.mergeTail(existing: held, existingHasMore: true, tail: [], tailHasMore: false)
check(m.events.isEmpty && !m.hasMore, "an empty tail empties the list")
let withQueued = held + [ev("q:1", .user, queued: true)]
m = ChatPaging.mergeTail(existing: withQueued, existingHasMore: false, tail: [ev("d"), ev("e"), ev("q:2", .user, queued: true)], tailHasMore: true)
check(ids(m.events) == ["a", "b", "c", "d", "e", "q:2"], "queued events come from the newest tail only")
m = ChatPaging.mergeTail(existing: held, existingHasMore: false, tail: [ev("q:9", .user, queued: true)], tailHasMore: false)
check(ids(m.events) == ["q:9"], "a tail of only queued events has no anchor: the list becomes it")

print("Duplicate ids")
var dupB = ev("b"); dupB.text = "newer"
let deduped = TranscriptEvent.uniqued([ev("a"), ev("b"), ev("c"), dupB, ev("a")])
check(ids(deduped) == ["a", "b", "c"], "each id once, at its first position")
check(deduped[1].text == "newer", "the later copy's content wins")
check(TranscriptEvent.uniqued([]).isEmpty, "empty stays empty")
let decoded = TranscriptEvent.decodeList([["id": "x", "kind": "text", "text": "1"], ["id": "x", "kind": "text", "text": "2"]])
check(decoded.count == 1 && decoded[0].text == "2", "decodeList drops a repeated id")
m = ChatPaging.mergeTail(existing: held, existingHasMore: false, tail: [ev("c"), ev("a"), ev("e")], tailHasMore: false)
check(Set(ids(m.events)).count == m.events.count, "a tail repeating a held id yields unique ids")
p0 = ChatPaging.prepend(existing: [ev("a"), ev("a")], page: [ev("z")], pageHasMore: false)
check(ids(p0.events) == ["z", "a"], "prepend yields unique ids")
let dupItems = ChatGrouping.items(from: TranscriptEvent.uniqued([ev("t1", .tool), ev("u", .user), ev("t1", .tool)]))
check(Set(dupItems.map(\.id)).count == dupItems.count, "rows built from deduped events have unique ids")

print("ChatPaging window")
let rowIDs = (0..<200).map { "r\($0)" }
check(ChatPaging.windowStart(ids: rowIDs, anchorID: nil, base: 60) == 140, "following: the last 60 rows")
check(ChatPaging.windowStart(ids: Array(rowIDs.prefix(10)), anchorID: nil, base: 60) == 0, "short list: everything")
check(ChatPaging.windowStart(ids: [], anchorID: nil) == 0, "empty list")
check(ChatPaging.windowStart(ids: rowIDs, anchorID: "r100", base: 60) == 100, "frozen: starts at the anchor")
check(ChatPaging.windowStart(ids: rowIDs + ["r200", "r201"], anchorID: "r100", base: 60) == 100, "frozen: rows arriving below don't move the start")
check(ChatPaging.windowStart(ids: rowIDs, anchorID: "gone", base: 60) == 140, "an anchor no longer held falls back to following")
check(ChatPaging.windowStart(ids: rowIDs, anchorID: nil, base: 60, mustInclude: [50]) == 48, "the marker row (and two above) is mounted")
check(ChatPaging.windowStart(ids: rowIDs, anchorID: nil, base: 60, mustInclude: [-1, 999]) == 140, "out-of-range includes are ignored")
check(ChatPaging.grownAnchor(ids: rowIDs, start: 140, step: 60) == "r80", "growing moves the anchor a step up")
check(ChatPaging.grownAnchor(ids: rowIDs, start: 30, step: 60) == "r0", "growing stops at the first row")
check(ChatPaging.grownAnchor(ids: [], start: 0) == nil, "nothing to grow")

print("ChatPaging cap")
let many = (0..<10).map { ev("e\($0)") }
m = ChatPaging.mergeTail(existing: many, existingHasMore: false, tail: [ev("e8"), ev("e9"), ev("e10"), ev("e11")], tailHasMore: false, limit: 10)
check(ids(m.events).first == "e2" && m.events.count == 10 && m.hasMore, "past the cap the oldest drop and has_more returns")
let manyQueued = (0..<10).map { ev("e\($0)") } + [ev("q:1", .user, queued: true), ev("q:2", .user, queued: true)]
m = ChatPaging.mergeTail(existing: [], existingHasMore: false, tail: manyQueued, tailHasMore: false, limit: 10)
check(m.events.count == 12 && !m.hasMore, "queued events don't count toward the cap")

print("ChatPaging.prepend")
var p = ChatPaging.prepend(existing: held, page: [ev("y"), ev("z"), ev("a")], pageHasMore: true)
check(ids(p.events) == ["y", "z", "a", "b", "c", "d"] && p.hasMore, "a page goes in front, deduped by id")
p = ChatPaging.prepend(existing: held, page: [], pageHasMore: false)
check(ids(p.events) == ids(held) && !p.hasMore, "an empty page (id not found) ends paging")
p = ChatPaging.prepend(existing: many, page: [ev("p1"), ev("p2"), ev("p3")], pageHasMore: false, limit: 12)
check(ids(p.events).prefix(2) == ["p2", "p3"] && p.events.count == 12 && p.hasMore, "a page past the cap keeps the events nearest the list")
check(ChatPaging.pageAnchor([ev("a"), ev("b")]) == "a", "a page is anchored on the oldest event")
check(ChatPaging.pageAnchor([ev("q", .user, queued: true)]) == nil, "queued events are never an anchor")

print("ChatPaging.shouldRequestPage")
check(ChatPaging.shouldRequestPage(offsetY: 900, viewportHeight: 700, hasMore: true, inFlight: false, count: 300), "within 1.5 screens of the top asks")
check(!ChatPaging.shouldRequestPage(offsetY: 1100, viewportHeight: 700, hasMore: true, inFlight: false, count: 300), "further down does not")
check(!ChatPaging.shouldRequestPage(offsetY: 0, viewportHeight: 700, hasMore: false, inFlight: false, count: 300), "no has_more (or an older bridge): never")
check(!ChatPaging.shouldRequestPage(offsetY: 0, viewportHeight: 700, hasMore: true, inFlight: true, count: 300), "one request at a time")
check(!ChatPaging.shouldRequestPage(offsetY: 0, viewportHeight: 700, hasMore: true, inFlight: false, count: ChatPaging.maxKept), "at the cap: no more pages")
check(!ChatPaging.shouldRequestPage(offsetY: 0, viewportHeight: 0, hasMore: true, inFlight: false, count: 0), "no viewport yet: wait")
check(ChatPaging.isAtCap(count: ChatPaging.maxKept, hasMore: true) && !ChatPaging.isAtCap(count: ChatPaging.maxKept, hasMore: false), "at cap only with older events left")

print("ChatPaging.classify")
check(ChatPaging.classify(oldTop: "a|0", newTop: "y|0", oldTail: "d", newTail: "d") == .prepend, "first row changed, last stayed: prepend")
check(ChatPaging.classify(oldTop: "a|0", newTop: "a|1", oldTail: "d", newTail: "d") == .prepend, "the loading row appearing above is a prepend too")
check(ChatPaging.classify(oldTop: "a|0", newTop: "a|0", oldTail: "d", newTail: "e") == .other, "a tail append is not a prepend")
check(ChatPaging.classify(oldTop: "a|0", newTop: "a|0", oldTail: "d", newTail: "d") == .other, "a row toggling (same top and tail) is not a prepend")
check(ChatPaging.classify(oldTop: "a|0", newTop: "x|0", oldTail: "d", newTail: "y") == .other, "a replaced list is not a prepend")
check(ChatPaging.classify(oldTop: "|0", newTop: "a|0", oldTail: "", newTail: "") == .other, "an empty list filling is not a prepend")
check(ChatPaging.compensatedOffset(current: 120, heightDelta: 800) == 920, "offset moves by exactly the height added above")

print("ChatPaging.markerItemID")
let conv: [TranscriptEvent] = [ev("u1", .user), ev("a1"), ev("t1", .tool), ev("t2", .tool), ev("a2"), ev("q:1", .user, queued: true)]
let convItems = ChatGrouping.items(from: conv)
check(ChatPaging.markerItemID(items: convItems, events: conv, lastSeenID: "a1") == "t1", "marker goes before the first unseen row")
check(ChatPaging.markerItemID(items: convItems, events: conv, lastSeenID: "t1") == "t1", "seen mid-run: marker before that run's row")
check(ChatPaging.markerItemID(items: convItems, events: conv, lastSeenID: "a2") == nil, "nothing new but a queued line: no marker")
check(ChatPaging.markerItemID(items: convItems, events: conv, lastSeenID: nil) == nil, "first visit: no marker")
check(ChatPaging.markerItemID(items: convItems, events: conv, lastSeenID: "gone") == nil, "seen event not loaded: no marker")
check(ChatPaging.openOffset(markerY: 2000, topMargin: 12, bottomOffset: 5000) == 1988, "opens with the marker near the top")
check(ChatPaging.openOffset(markerY: 4900, topMargin: 12, bottomOffset: 4500) == 4500, "everything after the marker fits: the bottom")

print("ChatOutbox")
check(ChatOutbox.splitCommand("/loop 5m check").command == "/loop" && ChatOutbox.splitCommand("/loop 5m check").args == "5m check", "a slash command splits into name and args")
check(ChatOutbox.splitCommand("hello /x").command == nil, "plain text has no command")
let e1 = LocalEcho(id: "1", text: "  fix the docs \n", sentAt: 1000)
let e2 = LocalEcho(id: "2", text: "/compact keep tests", sentAt: 1001)
var out = ChatOutbox.resolve([e1, e2], events: [ev("u", .user, ts: 998, text: "fix the docs")], now: 1002)
check(out.map(\.id) == ["2"], "a matching user event (trimmed) within the clock slack drops the echo")
out = ChatOutbox.resolve([e1], events: [ev("u", .user, ts: 900, text: "fix the docs")], now: 1002)
check(out.map(\.id) == ["1"], "an older identical message doesn't count")
out = ChatOutbox.resolve([e2], events: [ev("q:1", .user, ts: 1003, text: "keep tests", queued: true, command: "/compact")], now: 1004)
check(out.isEmpty, "a queued slash command matches command + space + args")
out = ChatOutbox.resolve([e1, LocalEcho(id: "3", text: "fix the docs", sentAt: 1001)], events: [ev("u", .user, ts: 1001, text: "fix the docs")], now: 1002)
check(out.map(\.id) == ["3"], "one event answers one echo")
out = ChatOutbox.resolve([e1], events: [ev("s", .user, ts: 1001, text: "fix the docs", scheduled: true)], now: 1002)
check(out.count == 1, "a scheduled fire is not the human's message")
out = ChatOutbox.resolve([e1], events: [], now: 1059)
check(out.first?.state == .sending, "under 60 s: still sending")
out = ChatOutbox.resolve([e1], events: [], now: 1061)
check(out.first?.state == .unconfirmed, "60 s with no match and the agent never worked: Not delivered?")
check(OutboxItem(echo: out[0]).label?.text == "Not delivered?", "the unconfirmed wording is not alarming")
let worked = ChatOutbox.agentWorking([e1], now: 1010)
check(worked[0].sawWorking, "the agent working after the send marks it received")
check(!ChatOutbox.agentWorking([e1], now: 990)[0].sawWorking, "working before the send says nothing about it")
check(ChatOutbox.resolve(worked, events: [], now: 1030).first?.state == .sending, "received: still Sending under 60 s")
check(ChatOutbox.resolve(worked, events: [], now: 1061).isEmpty, "received and unmatched after 60 s: dropped silently")
out = ChatOutbox.resolve([e1], events: [], now: 1066)
check(out.isEmpty, "one poll later it is removed (never resent)")
out = ChatOutbox.resolve([e1], events: [ev("u", .user, text: "fix the docs")], now: 1002)
check(out.isEmpty, "an event with no ts still matches")
let o = OutboxItem(echo: LocalEcho(id: "9", text: "/loop 5m check", sentAt: 0))
check(o.command == "/loop" && o.text == "5m check" && o.label == nil && o.id == "local:9", "a command echo renders as the chip it will become, with no label")
check(OutboxItem(echo: e1).label == .sending, "a plain echo says Sending")

print("ChatOutbox: slash commands and dialogs")
let m1 = LocalEcho(id: "m", text: "/model", sentAt: 1000)
check(m1.isCommand && !e1.isCommand, "isCommand")
check(ChatOutbox.resolve([m1], events: [ev("u", .user, ts: 1004, text: "", command: "/model")], now: 1005).isEmpty,
      "a matching command event drops the command echo")
check(ChatOutbox.resolve([m1], events: [], now: 1059).count == 1, "a command waits under 60 s")
check(ChatOutbox.resolve([m1], events: [], now: 1061).isEmpty, "a command unmatched after 60 s is dropped silently, never 'Not confirmed'")
let opened = ChatOutbox.dialogOpened([m1, e1], now: 1002)
check(opened[0].sawDialog && !opened[1].sawDialog, "a dialog after a command marks that command, not plain text")
check(ChatOutbox.dialogClosed(opened).map(\.id) == ["1"], "the dialog closing removes the command that opened it")
check(ChatOutbox.dialogClosed([m1]).count == 1, "a dialog closing before it was seen leaves an unmarked command")
let later = LocalEcho(id: "m2", text: "/model", sentAt: 1100)
check(!ChatOutbox.dialogOpened([later], now: 1002)[0].sawDialog, "a command sent after the dialog opened did not open it")

print("Long text")
check(LongText.preview("short message") == nil, "a short message shows whole")
let tenLines = (1...10).map { "line \($0)" }.joined(separator: "\n")
check(LongText.preview(tenLines) == nil, "ten short lines show whole")
let fortyLines = (1...40).map { "line \($0)" }.joined(separator: "\n")
let pv = LongText.preview(fortyLines)
check(pv?.hasPrefix("line 1\nline 2") == true && pv?.hasSuffix("\u{2026}") == true, "a 40-line message previews its first lines")
check(pv.map { $0.split(separator: "\n").count } == 10, "the preview is 10 lines")
let wall = String(repeating: "word ", count: 400)
let wp = LongText.preview(wall)
check(wp != nil && wp!.count <= 702 && !wp!.dropLast().hasSuffix(" wor"), "one long line previews at a word boundary within the char cap")
check(LongText.chunks("small") == ["small"], "short text is one chunk")
let paras = (1...300).map { "paragraph \($0) with a few words" }.joined(separator: "\n")
let ch = LongText.chunks(paras, maxChars: 500)
check(ch.count > 1 && ch.allSatisfy { $0.count <= 500 }, "chunks stay under the cap")
check(ch.joined(separator: "\n") == paras, "chunks cut at line breaks join back to the text")
let wc = LongText.chunks(wall, maxChars: 300)
check(wc.allSatisfy { $0.count <= 300 } && wc.joined() == wall, "a single long line is cut at spaces and joins back")
let noSpace = String(repeating: "x", count: 1000)
check(LongText.chunks(noSpace, maxChars: 300).map(\.count) == [300, 300, 300, 100], "a line with no spaces is cut hard")
check(LongText.chunks("a\n\nb", maxChars: 1) == ["a", "", "b"], "blank lines survive")

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
}
}

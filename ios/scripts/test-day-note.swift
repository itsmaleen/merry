import Foundation

@main
struct DayNoteTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failures += 1; print("  FAIL (line \(line)): \(what)") }
    }

    static func main() {
        // Partials replace each other; a final phrase is kept.
        var t = TranscriptAccumulator()
        t.update("I finished")
        t.update("I finished the permit report")
        check(t.text == "I finished the permit report", "partials replace the live phrase")
        t.commit()
        t.update("and called")
        t.update("And called the landlord.")
        check(t.text == "I finished the permit report And called the landlord.", "a committed phrase stays in front")

        // The recogniser starting over mid-task does not drop what was said.
        var r = TranscriptAccumulator()
        r.update("Sent the deck to Aviv this morning")
        r.update("Then")
        check(r.text == "Sent the deck to Aviv this morning Then", "a restart keeps the earlier text")
        r.update("Then I fixed the sync")
        check(r.text == "Sent the deck to Aviv this morning Then I fixed the sync", "and goes on from there")

        // A revision that shortens a little, or begins the same way, is not a restart.
        var v = TranscriptAccumulator()
        v.update("Send the deck to a viv this morning")
        v.update("Sent the deck to Aviv")
        check(v.text == "Sent the deck to Aviv", "a revision replaces")
        check(!TranscriptAccumulator.startedOver(from: "Sent the deck to Aviv this morning", to: "Sent the"), "same opening is a revision")
        check(!TranscriptAccumulator.startedOver(from: "Hi", to: ""), "short text never restarts")

        check(TranscriptAccumulator.join(" a ", "") == "a" && TranscriptAccumulator.join("", " b") == "b", "join trims")

        // A note after midnight belongs to the day that just ended.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Toronto")!
        let iso = ISO8601DateFormatter()
        check(DayNote.date(for: iso.date(from: "2026-11-21T03:30:00Z")!, calendar: cal) == "2026-11-20", "22:30 is today")
        check(DayNote.date(for: iso.date(from: "2026-11-21T06:30:00Z")!, calendar: cal) == "2026-11-20", "01:30 is still yesterday")
        check(DayNote.date(for: iso.date(from: "2026-11-21T09:00:00Z")!, calendar: cal) == "2026-11-21", "04:00 turns over")

        // Decoding a note with Sunny's outcome.
        let note = DayNote([
            "id": "n1", "date": "2026-11-20", "text": "Did things", "createdAt": "2026-11-21T03:30:00.000Z",
            "processedAt": "2026-11-21T09:31:00.000Z",
            "outcome": [["kind": "logged", "text": "Called the landlord", "title": "Call the landlord"], ["kind": "kept", "text": "Tired"]],
        ])
        check(note?.isRead == true && note?.lines.count == 2 && note?.lines.first?.label == "Logged as done", "outcome decodes")
        check(DayNote(["id": "n2", "date": "2026-11-20", "text": "x"])?.isRead == false, "a new note is unread")
        check(DayNote(["id": "n3"]) == nil, "a note with no text is refused")

        print(failures == 0 ? "  day-note: all passed" : "  day-note: \(failures) failed")
        if failures > 0 { exit(1) }
    }
}

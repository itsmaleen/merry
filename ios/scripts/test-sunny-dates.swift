import Foundation

@main
struct SunnyDatesTests {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) {
        print((ok ? "  ok   " : "  FAIL ") + name)
        if !ok { failures += 1 }
    }

    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = SunnyDates.parse("2026-11-20T15:00:00.000Z")!

        print("== Dates")
        check("fractional seconds parse", SunnyDates.parse("2026-11-09T14:55:55.916Z") != nil)
        check("whole seconds parse", SunnyDates.parse("2026-11-09T14:55:55Z") != nil)
        check("same day is today", SunnyDates.day(SunnyDates.parse("2026-11-20T01:00:00Z")!, now: now, calendar: cal) == "today")
        check("the day before is yesterday", SunnyDates.day(SunnyDates.parse("2026-11-19T23:00:00Z")!, now: now, calendar: cal) == "yesterday")
        check("this year has no year", SunnyDates.day(SunnyDates.parse("2026-11-09T14:55:55Z")!, now: now, calendar: cal) == "9 Nov")
        check("another year shows it", SunnyDates.day(SunnyDates.parse("2025-12-31T10:00:00Z")!, now: now, calendar: cal) == "31 Dec 2025")
        check("the stamp adds the time", SunnyDates.stamp(SunnyDates.parse("2026-11-09T14:55:55Z")!, now: now, calendar: cal) == "9 Nov, 14:55")

        print("== Task context")
        let logged = SunnyTaskContext([
            "createdAt": "2026-11-09T14:55:55.916Z",
            "events": [
                ["kind": "asked", "text": "the address", "at": "2026-11-10T09:00:00.000Z"],
                ["kind": "started", "text": "Sent to the desktop", "at": "2026-11-11T09:00:00.000Z"],
                ["kind": "activity", "text": "Reading the repo", "at": "2026-11-11T09:05:00.000Z"],
                ["kind": "asked", "text": "a permit package", "at": "2026-11-12T09:00:00.000Z"],
            ] as [[String: Any]],
        ])
        check("asked is the latest ask", logged.askedAt == SunnyDates.parse("2026-11-12T09:00:00.000Z"))
        check("started is the session start", logged.startedAt == SunnyDates.parse("2026-11-11T09:00:00.000Z"))
        check("the agent date is its latest sign of life", logged.agentAt == SunnyDates.parse("2026-11-11T09:05:00.000Z"))
        check("created leads the timeline when the log began later", logged.timeline.first?.kind == "created" && logged.timeline.count == 5)

        let old = SunnyTaskContext(["createdAt": "2026-10-21T18:35:06.790Z", "agentActivity": "Working again", "agentActivityAt": "2026-10-30T18:30:53.013Z"])
        check("without a log the last agent date still shows", old.agentAt != nil && old.askedAt == nil)
        let mine = SunnyTaskContext(["events": [
            ["kind": "answered", "at": "2026-11-20T14:23:45.100Z"],
            ["kind": "activity", "text": "Answered from Merry", "at": "2026-11-20T14:23:45.393Z"],
        ] as [[String: Any]]])
        check("my own answer is not an agent update", mine.agentAt == nil)
        check("my answer shows once, as mine", mine.timeline.count == 1 && mine.timeline[0].label == "You answered")
        check("a task with no dates has an empty line", SunnyTaskContext([:]).dateLine.isEmpty)

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

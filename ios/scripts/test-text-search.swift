// Tests for TextSearch, the surface-search matching rules.
//
// The iOS app has no test target, so this is a standalone program compiled
// against the real source file:
//
//   ./ios/scripts/run-tests.sh
//
// It must stay free of UIKit/SwiftUI imports so it compiles on its own.
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

/// Match ranges as "location+length" strings — tuples aren't Equatable, and a
/// failure message reading `["3+6"]` is easier to act on than a range dump.
private func ranges(_ query: String, _ text: String) -> [String] {
    TextSearch.matches(of: query, in: text).map { "\($0.location)+\($0.length)" }
}

@main
enum TextSearchTests {
static func main() {
print("TextSearch.matches")
check(ranges("", "anything").isEmpty, "empty query matches nothing")
check(ranges("x", "").isEmpty, "empty text matches nothing")
check(ranges("zz", "abc").isEmpty, "absent query matches nothing")
check(ranges("b", "abcabc") == ["1+1", "4+1"], "finds every occurrence in order")
check(ranges("ERROR", "an error and an ERROR") == ["3+5", "16+5"], "case-insensitive")
check(ranges("resume", "résumé") == ["0+6"], "diacritic-insensitive")
check(ranges("aa", "aaaa") == ["0+2", "2+2"], "non-overlapping: aa in aaaa is 2, not 3")
check(ranges("c", "abc") == ["2+1"], "match at end of text")
check(ranges("a.b", "a.b axb") == ["0+3"], "'.' is literal, not a regex wildcard")
check(ranges("[1]", "tail [1] head") == ["5+3"], "brackets are literal")
check(ranges("*", "a * b") == ["2+1"], "'*' is literal")

// UTF-16 offsets: the ranges address NSAttributedString, so an emoji ahead of
// the match must shift it by 2, not 1.
let emoji = "🙂 needle"
check(ranges("needle", emoji) == ["3+6"], "offsets are UTF-16 (emoji counts as 2)")
check((emoji as NSString).substring(with: NSRange(location: 3, length: 6)) == "needle",
      "reported range slices the intended substring back out")

// A one-character query over a big buffer is the pathological case.
let big = String(repeating: "x", count: 5000)
check(TextSearch.matches(of: "x", in: big).count == TextSearch.maxMatches,
      "match count is capped at maxMatches")

print("TextSearch.step")
check(TextSearch.step(from: 0, by: 1, count: 3) == 1, "steps forward")
check(TextSearch.step(from: 2, by: 1, count: 3) == 0, "wraps past the last match")
check(TextSearch.step(from: 0, by: -1, count: 3) == 2, "wraps below the first match")
check(TextSearch.step(from: 0, by: 1, count: 0) == 0, "no matches: stays at 0")
check(TextSearch.step(from: 5, by: 1, count: 3) == 0, "a stale index still lands in range")

print("TextSearch.clamp")
check(TextSearch.clamp(7, to: 3) == 2, "clamps past the end (text shrank under an active search)")
check(TextSearch.clamp(-1, to: 3) == 0, "clamps below the start")
check(TextSearch.clamp(4, to: 0) == 0, "no matches: index 0")

print("TextSearch.highlightPlan")
let three = [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1), NSRange(location: 9, length: 1)]
let mid = TextSearch.highlightPlan(matches: three, current: 1)
check(mid.current == NSRange(location: 5, length: 1), "current match is the one at the index")
check(mid.others.count == 2 && !mid.others.contains(NSRange(location: 5, length: 1)),
      "the current match is not also styled as an ordinary one")
let stale = TextSearch.highlightPlan(matches: three, current: 99)
check(stale.current == NSRange(location: 9, length: 1), "a stale index clamps to the last match")
let none = TextSearch.highlightPlan(matches: [], current: 3)
check(none.current == nil && none.others.isEmpty, "no matches: nothing to highlight")

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nall passed")
}
}

import Foundation

/// Literal text search over a surface's rendered text.
///
/// Deliberately free of UIKit and SwiftUI so it can be exercised directly by
/// `ios/scripts/test-text-search.swift` — the app has no test target, and the
/// matching rules (UTF-16 ranges, non-overlapping advance, fold options) are
/// exactly the part worth pinning down.
enum TextSearch {
    /// How a query is compared against the text: case- and diacritic-insensitive,
    /// literal (never a regex — terminal output is full of `*`, `[`, `.` and a
    /// user searching for `[1]` means those characters).
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .literal]

    /// Every non-overlapping match of `query` in `text`, in document order.
    ///
    /// - Returns: UTF-16 ranges, which is what `NSAttributedString` and
    ///   `UITextView` address — Swift `String.Index` would have to be converted
    ///   at every call site.
    static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let haystack = text as NSString
        var results: [NSRange] = []
        var searchStart = 0
        while searchStart < haystack.length {
            let remaining = NSRange(location: searchStart, length: haystack.length - searchStart)
            let found = haystack.range(of: query, options: options, range: remaining)
            guard found.location != NSNotFound, found.length > 0 else { break }
            results.append(found)
            // Advance past the whole match: overlapping hits ("aa" in "aaa")
            // would double-count and make next/previous stutter.
            searchStart = found.location + found.length
            if results.count >= maxMatches { break }
        }
        return results
    }

    /// Upper bound on matches tracked for one search. A one-character query
    /// against a full scrollback matches tens of thousands of times; past this
    /// point the count is not useful to a reader and the highlight pass is pure
    /// cost. Reported counts are clamped here, not silently truncated: callers
    /// show `500+`.
    static let maxMatches = 500

    /// The next match index when stepping by `delta`, wrapping at both ends.
    ///
    /// Wrapping matters more on a phone than in an editor: with no visible
    /// scrollbar, running off the end with nothing happening reads as a broken
    /// button.
    static func step(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Clamps a match index to a (possibly changed) match count. The focused
    /// surface repolls every few seconds, so the text under an active search
    /// changes and the count with it.
    static func clamp(_ index: Int, to count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// Splits matches into the one that is current and the rest, so the caller
    /// styles each group once. Keeps the clamp and the current-match choice in
    /// one tested place instead of in the renderer, where it can only be
    /// exercised by running the app.
    static func highlightPlan(matches: [NSRange], current index: Int) -> (current: NSRange?, others: [NSRange]) {
        guard !matches.isEmpty else { return (nil, []) }
        let currentIndex = clamp(index, to: matches.count)
        var others = matches
        let currentRange = others.remove(at: currentIndex)
        return (currentRange, others)
    }
}

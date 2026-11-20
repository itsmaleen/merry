import CoreGraphics
import Foundation

/// The one ordered event list a surface keeps, and the scroll decisions that
/// go with paging older events into it (contract "Paging older events").
///
/// UIKit-free on purpose: exercised by `ios/scripts/test-chat-paging.swift`.
/// Queued events (`queued: true`) are never part of the conversation proper:
/// they sit after it, come only from the newest tail, and don't count toward
/// the cap.
enum ChatPaging {
    /// Events asked for per page, and per tail poll.
    static let pageSize = 300
    /// The most conversation events kept per surface. Past this the oldest are
    /// dropped and `has_more` goes back to true. The chat's SwiftUI content is
    /// hosted in a UIScrollView, so it is not lazy: this bounds the work.
    /// Measured with `-UITestPerf` (Debug, iPhone 17 Pro simulator): a tail
    /// poll that changes the last event re-lays out every row, 80-200 ms at
    /// 3000 events, 35-55 ms at 1200; first build 500 ms vs 230 ms.
    static let maxKept = 1200
    /// How near the top (in viewport heights) scrolling asks for older events.
    static let nearTopScreens: CGFloat = 1.5

    struct Merged: Equatable {
        var events: [TranscriptEvent]
        var hasMore: Bool
    }

    /// Lands a tail poll. The list is replaced from the tail's first id
    /// onward; when that id isn't in the list (first load, or the session
    /// moved on past everything we hold) the list becomes the tail and takes
    /// the tail's `has_more`. Queued events always come from the tail alone.
    static func mergeTail(existing: [TranscriptEvent], existingHasMore: Bool,
                          tail: [TranscriptEvent], tailHasMore: Bool,
                          limit: Int = maxKept) -> Merged {
        let held = existing.filter { !$0.queued }
        let tailConversation = tail.filter { !$0.queued }
        let tailQueued = tail.filter { $0.queued }
        var conversation: [TranscriptEvent]
        var hasMore: Bool
        if let first = tailConversation.first, let index = held.firstIndex(where: { $0.id == first.id }) {
            conversation = Array(held[..<index]) + tailConversation
            hasMore = existingHasMore
        } else {
            conversation = tailConversation
            hasMore = tailHasMore
        }
        if conversation.count > limit {
            conversation.removeFirst(conversation.count - limit)
            hasMore = true
        }
        return Merged(events: TranscriptEvent.uniqued(conversation + tailQueued), hasMore: hasMore)
    }

    /// Lands a page of older events in front of the list, skipping any id the
    /// list already holds. A page that would take the list past `limit` is cut
    /// from its old end (the events nearest the list stay) and leaves
    /// `has_more` true.
    static func prepend(existing: [TranscriptEvent], page: [TranscriptEvent], pageHasMore: Bool,
                        limit: Int = maxKept) -> Merged {
        let ids = Set(existing.map(\.id))
        var fresh = page.filter { !ids.contains($0.id) && !$0.queued }
        var hasMore = pageHasMore
        let room = max(0, limit - conversationCount(existing))
        if fresh.count > room {
            fresh.removeFirst(fresh.count - room)
            hasMore = true
        }
        return Merged(events: TranscriptEvent.uniqued(fresh + existing), hasMore: hasMore)
    }

    static func conversationCount(_ events: [TranscriptEvent]) -> Int {
        events.reduce(0) { $0 + ($1.queued ? 0 : 1) }
    }

    /// The id a page request is anchored on: the oldest conversation event.
    static func pageAnchor(_ events: [TranscriptEvent]) -> String? {
        events.first(where: { !$0.queued })?.id
    }

    /// Whether to ask for the next page now.
    static func shouldRequestPage(offsetY: CGFloat, viewportHeight: CGFloat, hasMore: Bool,
                                  inFlight: Bool, count: Int, limit: Int = maxKept) -> Bool {
        guard hasMore, !inFlight, viewportHeight > 0, count < limit else { return false }
        return offsetY < viewportHeight * nearTopScreens
    }

    /// The list is full: older events exist but this phone keeps no more.
    static func isAtCap(count: Int, hasMore: Bool, limit: Int = maxKept) -> Bool {
        hasMore && count >= limit
    }

    // MARK: - Mounted window

    /// Rows mounted at the bottom while following the newest message. The
    /// chat is a non-lazy SwiftUI stack in a UIScrollView, so every mounted
    /// row costs layout on every update; mounting a bounded window keeps an
    /// update that changes the last event independent of history length.
    static let windowBase = 60
    /// Rows added each time the reader nears the top of the window.
    static let windowStep = 60
    /// Measurement switch (`-UITestLegacy`, Debug): mount every row.
    nonisolated(unsafe) static var legacyMountAll = false

    /// The index of the first mounted row.
    /// - anchorID: the first mounted row while the reader is scrolled up
    ///   (frozen, so rows arriving at the bottom never shift what is on
    ///   screen); nil while following the bottom, when the last `base` rows
    ///   are mounted.
    /// - mustInclude: row indexes that must be mounted (the marker, a find
    ///   match); a little context above each is mounted too.
    static func windowStart(ids: [String], anchorID: String?, base: Int = windowBase, mustInclude: [Int] = []) -> Int {
        guard !ids.isEmpty, !legacyMountAll else { return 0 }
        var start = max(0, ids.count - base)
        if let anchorID, let i = ids.firstIndex(of: anchorID) { start = i }
        for i in mustInclude where i >= 0 && i < ids.count { start = min(start, max(0, i - 2)) }
        return start
    }

    /// The anchor that grows the window by `step` rows above `start`.
    static func grownAnchor(ids: [String], start: Int, step: Int = windowStep) -> String? {
        guard !ids.isEmpty else { return nil }
        return ids[max(0, min(ids.count - 1, start - step))]
    }

    // MARK: - Scroll anchoring

    /// What a content change did, for the scroll view's anchoring. `top` is
    /// everything above the first conversation row (that row's id plus the
    /// loading / start-of-conversation rows); `tail` is the last conversation
    /// row's id. Queued and just-sent rows sit after the tail and are in
    /// neither, so they never read as a prepend.
    enum Change: Equatable {
        /// Only what is above the old first row changed: keep the rows on
        /// screen where they are by moving the offset by the height delta.
        case prepend
        /// Anything else (an append, a row growing, a toggle, nothing):
        /// today's rule, follow the bottom only if the reader was there.
        case other
    }

    static func classify(oldTop: String, newTop: String, oldTail: String, newTail: String) -> Change {
        (oldTop != newTop && oldTail == newTail && !oldTail.isEmpty) ? .prepend : .other
    }

    /// The offset that keeps the rows on screen still after content of
    /// `heightDelta` lands above them.
    static func compensatedOffset(current: CGFloat, heightDelta: CGFloat) -> CGFloat {
        current + heightDelta
    }

    // MARK: - New since you were here

    /// The item the "New since you were here" divider goes before: the one
    /// holding the first event after `lastSeenID`. nil when nothing was seen
    /// before (first visit), the seen event isn't loaded, or nothing came
    /// after it. Queued events don't count as new conversation.
    static func markerItemID(items: [ChatItem], events: [TranscriptEvent], lastSeenID: String?) -> String? {
        let conversation = events.filter { !$0.queued }
        guard let lastSeenID, let index = conversation.firstIndex(where: { $0.id == lastSeenID }),
              index + 1 < conversation.count else { return nil }
        let next = conversation[index + 1].id
        return items.first(where: { $0.containsEvent(next) })?.id
    }

    /// The offset that opens the chat with the marker near the top; when
    /// everything after it fits on screen this is just the bottom.
    static func openOffset(markerY: CGFloat, topMargin: CGFloat, bottomOffset: CGFloat) -> CGFloat {
        max(0, min(markerY - topMargin, bottomOffset))
    }
}

extension ChatItem {
    /// Whether this row draws the event with `id`.
    func containsEvent(_ id: String) -> Bool {
        switch self {
        case .work(let g): return g.tools.contains { $0.id == id }
        default: return self.id == id
        }
    }
}

/// Long text in the chat. SwiftUI draws every mounted Text into one layer
/// whose backing store is its full size, visible or not: a 17 KB pasted
/// message is about 9,000 pt tall, ~100 MB of pixels at 3x. Long user
/// messages show a preview until opened, and long blocks are drawn as
/// several Texts so no single layer grows without bound.
enum LongText {
    /// The first `maxLines` lines (at most `maxChars`) of a message longer
    /// than that, or nil when it is short enough to show whole.
    static func preview(_ text: String, maxLines: Int = 10, maxChars: Int = 700) -> String? {
        var lines = 0
        var end = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                lines += 1
                if lines >= maxLines { end = i; break }
            }
            i = text.index(after: i)
            end = i
        }
        let cut = text.distance(from: text.startIndex, to: end) > maxChars
            ? text.index(text.startIndex, offsetBy: maxChars) : end
        guard cut < text.endIndex else { return nil }
        // Back up to a word boundary when cutting mid-line.
        var head = text[..<cut]
        if text[cut] != "\n", let space = head.lastIndex(where: { $0 == " " || $0 == "\n" }),
           head.distance(from: space, to: head.endIndex) < 80 {
            head = head[..<space]
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }

    /// The text cut at line breaks into pieces of at most `maxChars`; a
    /// single longer line is cut after a space. Joined with "\n" (and the
    /// long-line cuts with nothing) they give back the text.
    static func chunks(_ text: String, maxChars: Int = 1500) -> [String] {
        guard text.count > maxChars else { return [text] }
        var out: [String] = []
        var current: String? = nil
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            if rest.count > maxChars {
                if let c = current { out.append(c); current = nil }
                while rest.count > maxChars {
                    let limit = rest.index(rest.startIndex, offsetBy: maxChars)
                    var cut = rest[..<limit].lastIndex(of: " ").map { rest.index(after: $0) } ?? limit
                    if cut == rest.startIndex { cut = limit }
                    out.append(String(rest[..<cut]))
                    rest = rest[cut...]
                }
            }
            if let c = current, c.count + 1 + rest.count <= maxChars {
                current = c + "\n" + rest
            } else {
                if let c = current { out.append(c) }
                current = String(rest)
            }
        }
        if let c = current { out.append(c) }
        return out
    }
}

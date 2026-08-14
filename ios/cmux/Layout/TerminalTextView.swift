import SwiftUI
import UIKit

/// A UITextView-backed terminal renderer that supports text selection (copy)
/// and tappable links — neither of which SwiftUI's `Text` can do. It scrolls
/// itself and keeps pinned to the bottom for live output, but yields to the
/// user the moment they scroll up or start a selection.
///
/// Attributed-string construction and link detection run off the main thread
/// (see `TerminalTextRenderer`): a deep scrollback read is thousands of lines,
/// and building that inline in `updateUIView` — plus UIKit's synchronous
/// whole-document rescan that `dataDetectorTypes` performs on every
/// `attributedText` assignment — caused visible hitches whenever a poll landed
/// during an animation (keyboard, card resize).
struct TerminalTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textOpacity: Double
    /// When true, trailing markdown/punctuation is trimmed from detected links
    /// (e.g. `**url**` → `url`). Used by the transcript viewer, whose text is
    /// raw markdown. Live terminal cards keep links exactly as detected.
    var trimMarkdownLinks: Bool = false
    /// Fired (throttled) when the user deliberately over-scrolls past the top
    /// (a rubber-band pull) — the hook for opening the conversation-history viewer.
    var onScrolledToTop: (() -> Void)? = nil
    /// Reports whether the content is scrolled to its top, so callers can show a
    /// "pull for history" affordance only when it's actually reachable.
    var onTopStateChanged: ((Bool) -> Void)? = nil
    /// Reports when a text selection starts or clears, so parents can veto
    /// gestures (surface-cycle swipes) that would fight a selection drag.
    var onSelectionActiveChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        // Links come from our own detector pass in TerminalTextRenderer, not
        // dataDetectorTypes; tapping a .link attribute behaves the same either
        // way, but our pass runs off-main.
        tv.linkTextAttributes = [
            .foregroundColor: UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1.0),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.showsVerticalScrollIndicator = false
        tv.alwaysBounceVertical = true
        tv.delegate = context.coordinator
        // Terminal output is not natural language — don't fight the user with it.
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        context.coordinator.render(TerminalTextSnapshot(self), into: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator
        coord.onScrolledToTop = onScrolledToTop
        coord.onTopStateChanged = onTopStateChanged
        coord.onSelectionActiveChanged = onSelectionActiveChanged
        coord.render(TerminalTextSnapshot(self), into: tv)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// Whether new output should keep the view pinned to the bottom.
        /// True while the user is at (or near) the bottom; false once they
        /// scroll up to read scrollback.
        var autoScroll = true
        var onScrolledToTop: (() -> Void)?
        var onTopStateChanged: ((Bool) -> Void)?
        var onSelectionActiveChanged: ((Bool) -> Void)?
        private var lastTopFire: TimeInterval = 0
        private var atTop = false
        private var selectionActive = false

        /// What the text view currently shows. Compared against incoming
        /// snapshots, NOT tv.attributedText: the injected link attributes mean
        /// a freshly built string never equals what's on screen, and SwiftUI
        /// calls updateUIView far more often than the text changes.
        private var applied: TerminalTextSnapshot?
        /// The snapshot most recently handed to the background builder, so a
        /// re-render of the parent view doesn't queue a duplicate build.
        private var pending: TerminalTextSnapshot?
        private var generation = 0

        fileprivate func render(_ snapshot: TerminalTextSnapshot, into tv: UITextView) {
            if snapshot == pending || snapshot == applied { return }
            pending = snapshot
            generation += 1
            let gen = generation
            Task.detached(priority: .userInitiated) { [weak self, weak tv] in
                let attr = TerminalTextRenderer.build(snapshot)
                await MainActor.run {
                    // Only the newest build may land — an older one finishing
                    // late would put stale text (and a stale scroll) on screen.
                    guard let self, let tv, gen == self.generation else { return }
                    self.apply(attr, for: snapshot, to: tv)
                }
            }
        }

        fileprivate func apply(_ attr: NSAttributedString, for snapshot: TerminalTextSnapshot, to tv: UITextView) {
            // Don't clobber an in-progress selection (a live poll would
            // otherwise yank the text out from under the user mid-copy).
            // Resetting `pending` lets the next update retry once it clears.
            if tv.selectedRange.length > 0 {
                pending = applied
                return
            }

            // A history load prepends content above the viewport while the user
            // is reading scrollback. Detect it (old text is a strict suffix of
            // the new) so we can keep the same lines on screen instead of
            // letting them jump.
            let oldText = applied?.text ?? ""
            let isPrepend = !autoScroll && !oldText.isEmpty
                && snapshot.text.count > oldText.count && snapshot.text.hasSuffix(oldText)
            let oldHeight = tv.contentSize.height
            let oldOffset = tv.contentOffset

            tv.attributedText = attr
            applied = snapshot
            if autoScroll {
                scrollToBottom(tv)
            } else if isPrepend {
                // Layout synchronously so contentSize reflects the prepended
                // text, then shift the offset by exactly the added height — the
                // viewport stays anchored on the text the user was reading.
                tv.layoutIfNeeded()
                let delta = tv.contentSize.height - oldHeight
                if delta > 0 {
                    tv.setContentOffset(CGPoint(x: oldOffset.x, y: oldOffset.y + delta), animated: false)
                }
            }
        }

        private func scrollToBottom(_ tv: UITextView) {
            // Defer a runloop so layout reflects the new content size first.
            DispatchQueue.main.async {
                // Force pending layout so contentSize is correct for large
                // appends (e.g. a full-scrollback load), otherwise we under-scroll.
                tv.layoutIfNeeded()
                let bottom = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
                if bottom > 0 {
                    tv.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let threshold: CGFloat = 24
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            autoScroll = scrollView.contentOffset.y >= maxOffset - threshold

            // Report reaching the top so the history hint appears only then —
            // but only for USER-driven scrolls. A programmatic setContentOffset
            // (e.g. the prepend anchor) also lands here synchronously; mutating
            // SwiftUI @State from a view-update pass is a violation.
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                let nowAtTop = scrollView.contentOffset.y <= 4
                if nowAtTop != atTop {
                    atTop = nowAtTop
                    onTopStateChanged?(nowAtTop)
                }
            }

            // Trigger history on a deliberate over-scroll PAST the top — a
            // rubber-band pull (offset well negative), not just reaching the top.
            guard let onScrolledToTop,
                  scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating,
                  scrollView.contentOffset.y < -70
            else { return }
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastTopFire > 1.5 {
                lastTopFire = now
                onScrolledToTop()
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // UIKit fires this for caret-only/no-op changes too; only real
            // select/deselect transitions should reach the parent.
            let active = textView.selectedRange.length > 0
            guard active != selectionActive else { return }
            selectionActive = active
            onSelectionActiveChanged?(active)
        }
    }
}

/// The inputs that determine a rendered attributed string, captured as a value
/// so the background builder works from an immutable copy.
private struct TerminalTextSnapshot: Equatable {
    let text: String
    let fontSize: CGFloat
    let textOpacity: Double
    let trimMarkdownLinks: Bool

    init(_ view: TerminalTextView) {
        text = view.text
        fontSize = view.fontSize
        textOpacity = view.textOpacity
        trimMarkdownLinks = view.trimMarkdownLinks
    }
}

/// Builds TerminalTextView's attributed string. A standalone enum (not a member
/// of the View type) so its statics carry no MainActor isolation and can run in
/// a detached task.
private enum TerminalTextRenderer {
    static func build(_ snapshot: TerminalTextSnapshot) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        let attr = NSMutableAttributedString(
            string: snapshot.text,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: snapshot.fontSize, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(snapshot.textOpacity),
                .paragraphStyle: style,
            ]
        )
        addLinks(to: attr, trimTrailingJunk: snapshot.trimMarkdownLinks)
        return attr
    }

    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Trailing characters that prose/markdown commonly places right after a URL
    /// but that aren't part of it. Data detectors grab them greedily — e.g.
    /// `**https://example.com/x**` yields `https://example.com/x**`, so the tap
    /// opens a broken URL. `)` is handled separately to preserve balanced parens.
    private static let trailingJunk = CharacterSet(charactersIn: "*_~`.,;:!?\"']}>")

    /// Detects URLs in the plain text and adds `.link` attributes. With
    /// `trimTrailingJunk` the trailing markdown/punctuation the detector
    /// over-captures is trimmed off first (transcript viewer); without it the
    /// detector's match is extended across terminal hard-wraps when a URL was
    /// broken over multiple rows (live terminal cards).
    private static func addLinks(to attr: NSMutableAttributedString, trimTrailingJunk trim: Bool) {
        guard let detector = linkDetector else { return }
        let ns = attr.string as NSString
        let matches = detector.matches(in: attr.string, range: NSRange(location: 0, length: ns.length))
        // Line table for re-joining hard-wrapped URLs — live terminal text
        // only; transcript text is logical lines, never width-wrapped.
        let lines = trim ? [] : lineRanges(of: ns)
        let maxLineLength = lines.reduce(0) { max($0, $1.length) }
        var linkedEnd = 0
        for match in matches {
            // A wrapped URL's tail can re-match as its own link; if a previous
            // match was extended over this text, skip the scrap.
            guard match.range.location >= linkedEnd else { continue }
            var range = match.range
            var url = match.url
            if trim {
                while range.length > 0 {
                    let unit = ns.character(at: range.location + range.length - 1)
                    guard let scalar = Unicode.Scalar(unit) else { break }
                    if scalar == ")" {
                        // Keep a ) that closes a ( inside the URL (e.g.
                        // wiki/Foo_(bar)) — but trim unbalanced extras, as in
                        // "(see wiki/Foo_(bar))" where the last ) is prose.
                        let candidate = ns.substring(with: range)
                        let opens = candidate.lazy.filter { $0 == "(" }.count
                        let closes = candidate.lazy.filter { $0 == ")" }.count
                        if closes <= opens { break }
                    } else if !trailingJunk.contains(scalar) {
                        break
                    }
                    range.length -= 1
                }
                guard range.length > 0 else { continue }
                url = URL(string: ns.substring(with: range))
            } else if let joined = joinedAcrossWraps(match, in: ns, lines: lines, maxLineLength: maxLineLength) {
                range = joined.0
                url = joined.1
            }
            guard let url else { continue }
            attr.addAttribute(.link, value: url, range: range)
            linkedEnd = range.location + range.length
        }
    }

    /// Content range of each line (newlines excluded), in order.
    private static func lineRanges(of ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while start <= ns.length {
            let rest = NSRange(location: start, length: ns.length - start)
            let newline = ns.range(of: "\n", options: [], range: rest)
            if newline.location == NSNotFound {
                ranges.append(rest)
                break
            }
            ranges.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + newline.length
        }
        return ranges
    }

    /// Characters that can legitimately continue a URL on the next row.
    private static let urlScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
        return set
    }()

    /// Rows shorter than this never count as "full width", so small snapshots
    /// can't trigger bogus joins.
    private static let minWrapWidth = 40

    /// A URL the terminal hard-wrapped shows up as a match that runs to the
    /// edge of a full-width row, with the URL's remainder starting the next
    /// row — linkifying just the first row produces a truncated link that
    /// leads nowhere. Returns the range spanning the break(s) plus the URL
    /// with them removed, or nil when the match doesn't look wrapped. The
    /// PTY's width isn't in the protocol, so "full width" means the longest
    /// row in this snapshot.
    private static func joinedAcrossWraps(
        _ match: NSTextCheckingResult, in ns: NSString, lines: [NSRange], maxLineLength: Int
    ) -> (NSRange, URL)? {
        guard maxLineLength >= minWrapWidth else { return nil }
        let matchEnd = match.range.location + match.range.length
        guard var lineIndex = lines.firstIndex(where: {
            NSLocationInRange(match.range.location, $0) && matchEnd == $0.location + $0.length
        }), lines[lineIndex].length == maxLineLength else { return nil }

        var urlString = ns.substring(with: match.range)
        var end = matchEnd
        while lineIndex + 1 < lines.count {
            let next = lines[lineIndex + 1]
            let nextText = ns.substring(with: next)
            let continuation = String(nextText.unicodeScalars.prefix(while: urlScalars.contains))
            guard !continuation.isEmpty else { break }
            urlString += continuation
            end = next.location + (continuation as NSString).length
            // Only a row that is entirely URL characters at full width can
            // wrap onward; anything less means the URL ended on this row.
            guard end == next.location + next.length, next.length == maxLineLength else { break }
            lineIndex += 1
        }
        guard end > matchEnd, let url = URL(string: urlString) else { return nil }
        return (NSRange(location: match.range.location, length: end - match.range.location), url)
    }
}

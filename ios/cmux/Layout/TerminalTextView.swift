import SwiftUI
import UIKit

/// A UITextView-backed terminal renderer that supports text selection (copy)
/// and tappable links via data detectors — neither of which SwiftUI's `Text`
/// can do. It scrolls itself and keeps pinned to the bottom for live output,
/// but yields to the user the moment they scroll up or start a selection.
struct TerminalTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textOpacity: Double
    /// When true, links are detected ourselves and trailing markdown/punctuation
    /// is trimmed (e.g. `**url**` → `url`). Used by the transcript viewer, whose
    /// text is raw markdown. Left off for live terminal cards, which use the
    /// native data detector so their touch/scroll behavior is unchanged.
    var trimMarkdownLinks: Bool = false
    /// Fired (throttled) when the user deliberately over-scrolls past the top
    /// (a rubber-band pull) — the hook for opening the conversation-history viewer.
    var onScrolledToTop: (() -> Void)? = nil
    /// Reports whether the content is scrolled to its top, so callers can show a
    /// "pull for history" affordance only when it's actually reachable.
    var onTopStateChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        if trimMarkdownLinks {
            // We linkify URLs ourselves in `attributed()` (trimming trailing
            // markdown like `**url**`), so the built-in detector must stay off —
            // it would otherwise re-link the raw run greedily and swallow those markers.
            tv.dataDetectorTypes = []
            tv.linkTextAttributes = [
                .foregroundColor: UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1.0),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        } else {
            tv.dataDetectorTypes = [.link]          // linkify URLs in the output
        }
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.showsVerticalScrollIndicator = false
        tv.alwaysBounceVertical = true
        tv.delegate = context.coordinator
        // Terminal output is not natural language — don't fight the user with it.
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.attributedText = attributed()
        context.coordinator.recordApplied(text: text, fontSize: fontSize, opacity: textOpacity)
        context.coordinator.onScrolledToTop = onScrolledToTop
        context.coordinator.onTopStateChanged = onTopStateChanged
        // Content is often already present at creation (cached surfaceContent);
        // updateUIView would then early-return without scrolling, leaving the
        // view pinned to the TOP. Scroll to the bottom so the latest output shows.
        if !text.isEmpty {
            scrollToBottom(tv)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator
        coord.onScrolledToTop = onScrolledToTop
        coord.onTopStateChanged = onTopStateChanged
        // Compare against what we last applied, NOT tv.attributedText: with
        // dataDetectorTypes the view injects link attributes into its own
        // attributedText, so reading it back never equals a freshly built plain
        // string once a URL is on screen — which would reassign (and re-scroll)
        // on every poll.
        if text == coord.lastText, fontSize == coord.lastFontSize, textOpacity == coord.lastOpacity {
            return
        }
        // Don't clobber an in-progress selection (a live poll would otherwise
        // yank the text out from under the user mid-copy); reapplies once cleared.
        if tv.selectedRange.length > 0 { return }

        // A history load prepends content above the viewport while the user is
        // reading scrollback. Detect it (old text is a strict suffix of the new)
        // so we can keep the same lines on screen instead of letting them jump.
        let oldText = coord.lastText ?? ""
        let isPrepend = !coord.autoScroll && !oldText.isEmpty
            && text.count > oldText.count && text.hasSuffix(oldText)
        let oldHeight = tv.contentSize.height
        let oldOffset = tv.contentOffset

        tv.attributedText = attributed()
        coord.recordApplied(text: text, fontSize: fontSize, opacity: textOpacity)
        if coord.autoScroll {
            scrollToBottom(tv)
        } else if isPrepend {
            // Layout synchronously so contentSize reflects the prepended text,
            // then shift the offset by exactly the added height — the viewport
            // stays anchored on the text the user was reading.
            tv.layoutIfNeeded()
            let delta = tv.contentSize.height - oldHeight
            if delta > 0 {
                tv.setContentOffset(CGPoint(x: oldOffset.x, y: oldOffset.y + delta), animated: false)
            }
        }
    }

    private func attributed() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        let attr = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(textOpacity),
                .paragraphStyle: style,
            ]
        )
        if trimMarkdownLinks {
            Self.addLinks(to: attr)
        }
        return attr
    }

    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Trailing characters that prose/markdown commonly places right after a URL
    /// but that aren't part of it. Data detectors grab them greedily — e.g.
    /// `**https://example.com/x**` yields `https://example.com/x**`, so the tap
    /// opens a broken URL. `)` is handled separately to preserve balanced parens.
    private static let trailingJunk = CharacterSet(charactersIn: "*_~`.,;:!?\"']}>")

    /// Detects URLs in the plain text and adds `.link` attributes, trimming the
    /// trailing markdown/punctuation the detector over-captures.
    private static func addLinks(to attr: NSMutableAttributedString) {
        guard let detector = linkDetector else { return }
        let ns = attr.string as NSString
        let matches = detector.matches(in: attr.string, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            var range = match.range
            while range.length > 0 {
                let unit = ns.character(at: range.location + range.length - 1)
                guard let scalar = Unicode.Scalar(unit) else { break }
                if scalar == ")" {
                    // Keep a ) that closes a ( inside the URL (e.g. wiki/Foo_(bar)).
                    if ns.substring(with: range).contains("(") { break }
                } else if !trailingJunk.contains(scalar) {
                    break
                }
                range.length -= 1
            }
            guard range.length > 0,
                  let url = URL(string: ns.substring(with: range)) else { continue }
            attr.addAttribute(.link, value: url, range: range)
        }
    }

    private func scrollToBottom(_ tv: UITextView) {
        // Defer a runloop so layout reflects the new content size first.
        DispatchQueue.main.async {
            // Force pending layout so contentSize is correct for large appends
            // (e.g. a full-scrollback load), otherwise we under-scroll.
            tv.layoutIfNeeded()
            let bottom = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            if bottom > 0 {
                tv.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// Whether new output should keep the view pinned to the bottom.
        /// True while the user is at (or near) the bottom; false once they
        /// scroll up to read scrollback.
        var autoScroll = true
        var onScrolledToTop: (() -> Void)?
        var onTopStateChanged: ((Bool) -> Void)?
        private var lastTopFire: TimeInterval = 0
        private var atTop = false

        // Last values actually applied to the text view, for change detection.
        private(set) var lastText: String?
        private(set) var lastFontSize: CGFloat?
        private(set) var lastOpacity: Double?

        func recordApplied(text: String, fontSize: CGFloat, opacity: Double) {
            lastText = text
            lastFontSize = fontSize
            lastOpacity = opacity
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let threshold: CGFloat = 24
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            autoScroll = scrollView.contentOffset.y >= maxOffset - threshold

            // Report reaching the top so the history hint appears only then —
            // but only for USER-driven scrolls. A programmatic setContentOffset
            // (e.g. the prepend anchor) also lands here synchronously inside
            // updateUIView; mutating SwiftUI @State from there is a "modifying
            // state during view update" violation.
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
    }
}

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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.dataDetectorTypes = [.link]          // linkify URLs in the output
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
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator
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
        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(textOpacity),
                .paragraphStyle: style,
            ]
        )
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
        }
    }
}

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
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Don't clobber an in-progress selection (a live poll would otherwise
        // yank the text out from under the user mid-copy).
        if tv.selectedRange.length > 0 { return }

        let newAttr = attributed()
        if tv.attributedText != newAttr {
            tv.attributedText = newAttr
            if context.coordinator.autoScroll {
                scrollToBottom(tv)
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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let threshold: CGFloat = 24
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            autoScroll = scrollView.contentOffset.y >= maxOffset - threshold
        }
    }
}

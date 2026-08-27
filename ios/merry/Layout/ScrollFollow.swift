import CoreGraphics

/// The "keep following new output" decision for a scrolling terminal view.
///
/// Split out of `TerminalTextView` and free of UIKit so it can be exercised by
/// `ios/scripts/test-scroll-follow.swift`. The rules are small but they were
/// wrong in a way no build catches: a programmatic scroll that landed short of
/// the bottom used to turn following OFF permanently, and the card then sat
/// mid-output while new lines arrived below it.
enum ScrollFollow {
    /// How close to the bottom still counts as "at the bottom". A few points of
    /// slack, because a fractional content height (line fragments rarely land on
    /// whole points) otherwise reads as scrolled-up forever.
    static let bottomThreshold: CGFloat = 24

    /// Whether the viewport is at (or within `threshold` of) the end of the content.
    static func isAtBottom(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        threshold: CGFloat = bottomThreshold
    ) -> Bool {
        offsetY >= contentHeight - viewportHeight - threshold
    }

    /// The offset that puts the end of the content at the bottom of the viewport.
    /// Never negative: content shorter than the viewport has nothing to scroll.
    static func bottomOffset(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(0, contentHeight - viewportHeight + bottomInset)
    }

    /// Whether following should stay on after a scroll event.
    ///
    /// The `isProgrammatic` gate is the fix: UIScrollView reports self-inflicted
    /// offsets through the same delegate callback as finger ones, so without it
    /// a single short landing — `scrollToBottom` computing its target from a
    /// contentSize that was stale because the card was mid-animation — reads as
    /// "the user scrolled up" and following never comes back.
    static func follow(current: Bool, atBottom: Bool, isProgrammatic: Bool) -> Bool {
        isProgrammatic ? current : atBottom
    }
}

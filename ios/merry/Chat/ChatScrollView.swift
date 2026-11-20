import QuartzCore
import SwiftUI
import UIKit

/// A UIKit scroll view hosting SwiftUI chat content: one continuous
/// conversation, older events paged in as the reader nears the top.
///
/// Why not a SwiftUI ScrollView: exact control of the offset when a page
/// lands above the rows on screen (below), which a SwiftUI ScrollView does
/// not give. The rows are a non-lazy SwiftUI stack, so ChatCardBody mounts a
/// bounded window of them (ChatPaging.windowStart).
///
/// Anchoring (ChatPaging.classify): when only what is above the first row
/// changed (a page prepended, the loading row coming or going), the offset
/// moves by the height delta in the same update, without animation, so the
/// rows on screen stay put. Anything else follows the bottom only if the
/// reader was there (ScrollFollow).
/// A scroll view that says when its viewport height changes. KVO on
/// `bounds` does not fire for a resize done by Auto Layout (the keyboard, a
/// pending panel under the chat), so the check runs in layoutSubviews.
final class ResizeReportingScrollView: UIScrollView {
    var onHeightChange: ((_ old: CGFloat, _ new: CGFloat) -> Void)?
    private var lastHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        guard abs(h - lastHeight) > 0.5 else { return }
        let old = lastHeight
        lastHeight = h
        if old > 0 { onHeightChange?(old, h) }
    }
}

struct ChatScrollView<Content: View & Equatable>: UIViewRepresentable {
    enum OpenPosition: Equatable {
        case bottom
        /// Wait for `openAnchorY` (the "New since you were here" row), then
        /// put it near the top, or the bottom if what follows it fits.
        case anchor
        /// Screenshot fixture: the top, or a fraction of the way down.
        case top
        case fraction(CGFloat)
    }

    struct ScrollTarget: Equatable {
        let y: CGFloat
        let token: Int
    }

    let content: Content
    /// Everything above the first conversation row, as a token.
    var topToken: String = ""
    /// The last conversation row's id.
    var tailToken: String = ""
    /// The content has rows; the open position is applied on the first
    /// update where it does.
    var hasContent: Bool = true
    var openPosition: OpenPosition = .bottom
    var openAnchorY: CGFloat? = nil
    /// Older events can be asked for; `onNearTop` fires near the top.
    var canPage: Bool = false
    var onNearTop: (() -> Void)? = nil
    var onAtBottomChanged: ((Bool) -> Void)? = nil
    /// More than one viewport above the bottom (the jump button).
    var onFarFromBottomChanged: ((Bool) -> Void)? = nil
    /// The content is taller than the viewport.
    var onScrollableChanged: ((Bool) -> Void)? = nil
    /// Bumped by the parent to jump to the newest content.
    var scrollToBottomRequest: Int = 0
    /// A content y to bring into view (find).
    var scrollTarget: ScrollTarget? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ResizeReportingScrollView {
        let sv = ResizeReportingScrollView()
        sv.backgroundColor = .clear
        sv.alwaysBounceVertical = true
        sv.showsHorizontalScrollIndicator = false
        sv.indicatorStyle = .white
        // The status-bar tap goes to the top of what is loaded, which pages
        // in more. The only scroll view on screen that claims it.
        sv.scrollsToTop = true
        // Dragging the conversation lowers the keyboard, as in Messages: the
        // composer has no Done button of its own.
        sv.keyboardDismissMode = .interactive
        sv.delegate = context.coordinator

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        // The card already sits inside the safe area; insets here would pad
        // the conversation a second time.
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(host.view)
        // At least as tall as the viewport, so the content's own alignment
        // decides where a short conversation sits.
        let minHeight = host.view.heightAnchor.constraint(greaterThanOrEqualTo: sv.frameLayoutGuide.heightAnchor)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: sv.frameLayoutGuide.widthAnchor),
            minHeight,
        ])
        let c = context.coordinator
        c.host = host
        c.lastScrollRequest = scrollToBottomRequest
        c.lastTop = topToken
        c.lastTail = tailToken
        c.lastTargetToken = scrollTarget?.token
        // Only the bottom open follows from the start; the others place the
        // view once and leave it.
        c.autoScroll = openPosition == .bottom
        c.observe(sv)
        return sv
    }

    func updateUIView(_ sv: ResizeReportingScrollView, context: Context) {
        let c = context.coordinator
        c.onNearTop = onNearTop
        c.canPage = canPage
        c.onAtBottomChanged = onAtBottomChanged
        c.onFarFromBottomChanged = onFarFromBottomChanged
        c.onScrollableChanged = onScrollableChanged

        let change = ChatPaging.classify(oldTop: c.lastTop, newTop: topToken, oldTail: c.lastTail, newTail: tailToken)
        c.lastTop = topToken
        c.lastTail = tailToken
        let perfStart = ChatPerf.enabled ? CACurrentMediaTime() : 0
        if change == .prepend && c.positioned {
            c.applyPrepend(sv, content: content)
        } else if c.host?.rootView != content {
            c.host?.rootView = content
            c.host?.view.invalidateIntrinsicContentSize()
            if ChatPerf.enabled { sv.layoutIfNeeded() }
        } else if ChatPerf.enabled {
            ChatPerf.log("unchanged, skipped")
        }
        if ChatPerf.enabled {
            ChatPerf.log(String(format: "update+layout %.1f ms, content %.0f pt", (CACurrentMediaTime() - perfStart) * 1000, sv.contentSize.height))
        }

        if !c.positioned, hasContent {
            c.position(sv, openPosition, anchorY: openAnchorY)
        }
        if scrollToBottomRequest != c.lastScrollRequest {
            c.lastScrollRequest = scrollToBottomRequest
            c.autoScroll = true
            c.scrollToBottom(sv)
        }
        if let scrollTarget, scrollTarget.token != c.lastTargetToken {
            c.lastTargetToken = scrollTarget.token
            c.reveal(sv, y: scrollTarget.y)
        }
        c.checkNearTop(sv)
    }

    static func dismantleUIView(_ sv: ResizeReportingScrollView, coordinator: Coordinator) {
        coordinator.sizeObservation = nil
        sv.onHeightChange = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var host: UIHostingController<Content>?
        var onNearTop: (() -> Void)?
        var canPage = false
        var onAtBottomChanged: ((Bool) -> Void)?
        var onFarFromBottomChanged: ((Bool) -> Void)?
        var onScrollableChanged: ((Bool) -> Void)?
        var lastScrollRequest = 0
        var lastTargetToken: Int?
        var lastTop = ""
        var lastTail = ""
        var autoScroll = true
        var sizeObservation: NSKeyValueObservation?
        /// The open position has been applied; paging checks wait for it so
        /// the brief offset-0 moment before the first pin doesn't ask for a
        /// page on every focus.
        private(set) var positioned = false
        private var positioning = false
        private var anchorFallbackArmed = false
        private var pendingReveal: CGFloat?
        private var compensating = false
        private var isProgrammaticScroll = false
        private var reportedAtBottom = true
        private var reportedFar = false
        private var reportedScrollable: Bool?

        /// New content grows the scroll view; while following, keep the
        /// newest message in view. KVO rather than updateUIView because the
        /// hosting view resizes a layout pass after its rootView changes.
        func observe(_ sv: UIScrollView) {
            sizeObservation = sv.observe(\.contentSize, options: [.old, .new]) { [weak self] sv, change in
                guard let self, change.oldValue != change.newValue, !self.compensating else { return }
                if self.autoScroll && !sv.isTracking && !sv.isDecelerating && (self.positioned || self.positioning) {
                    self.scrollToBottom(sv)
                }
                self.reportGeometry(sv)
            }
            // The viewport changes height without the content changing when
            // the keyboard or a pending panel comes or goes. Following, the
            // newest rows must stay in view; either way the jump button is
            // re-decided (it used to keep a stale or wrong answer here).
            (sv as? ResizeReportingScrollView)?.onHeightChange = { [weak self, weak sv] old, new in
                guard let self, let sv else { return }
                if ScrollFollow.repinsOnResize(following: self.autoScroll && !sv.isTracking, oldHeight: old, newHeight: new),
                   self.positioned || self.positioning {
                    // In this layout pass, so no frame shows the rows
                    // displaced; then the usual settle passes.
                    self.isProgrammaticScroll = true
                    sv.contentOffset.y = self.bottomOffset(sv)
                    self.isProgrammaticScroll = false
                    self.scrollToBottom(sv)
                }
                self.reportGeometry(sv)
            }
        }

        /// Lands content that grew above the rows on screen: lay it out now,
        /// in this update, and move the offset by exactly the added height,
        /// so no frame shows the rows displaced.
        func applyPrepend(_ sv: UIScrollView, content: Content) {
            compensating = true
            let before = sv.contentSize.height
            host?.rootView = content
            host?.view.invalidateIntrinsicContentSize()
            sv.layoutIfNeeded()
            let delta = sv.contentSize.height - before
            compensating = false
            if ChatPerf.enabled { ChatPerf.log(String(format: "prepend delta %.1f pt at offset %.1f", delta, sv.contentOffset.y)) }
            guard delta != 0 else { return }
            if autoScroll {
                pin(sv)
            } else {
                isProgrammaticScroll = true
                sv.contentOffset.y = ChatPaging.compensatedOffset(current: sv.contentOffset.y, heightDelta: delta)
                isProgrammaticScroll = false
            }
            reportGeometry(sv)
        }

        /// Applies the open position once there is content to place.
        func position(_ sv: UIScrollView, _ open: OpenPosition, anchorY: CGFloat?) {
            guard !positioning else { return }
            if open == .anchor && anchorY == nil {
                // The marker row reports its position a layout pass after it
                // appears; if it never does, open at the bottom.
                guard !anchorFallbackArmed else { return }
                anchorFallbackArmed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak sv] in
                    guard let self, let sv, !self.positioned, !self.positioning else { return }
                    self.autoScroll = true
                    self.position(sv, .bottom, anchorY: nil)
                }
                return
            }
            positioning = true
            // Two passes, like scrollToBottom: a card still settling reports
            // a short contentSize on the first.
            DispatchQueue.main.async { [weak self, weak sv] in
                guard let self, let sv else { return }
                self.place(sv, open, anchorY: anchorY)
                DispatchQueue.main.async { [weak self, weak sv] in
                    guard let self, let sv else { return }
                    self.place(sv, open, anchorY: anchorY)
                    self.positioned = true
                    self.positioning = false
                    if let y = self.pendingReveal {
                        self.pendingReveal = nil
                        self.reveal(sv, y: y)
                    }
                    self.reportGeometry(sv)
                    self.checkNearTop(sv)
                }
            }
        }

        private func place(_ sv: UIScrollView, _ open: OpenPosition, anchorY: CGFloat?) {
            sv.layoutIfNeeded()
            let bottom = bottomOffset(sv)
            let y: CGFloat
            switch open {
            case .bottom: pin(sv); return
            case .anchor: y = ChatPaging.openOffset(markerY: anchorY ?? .infinity, topMargin: 12, bottomOffset: bottom)
            case .top: y = 0
            case .fraction(let f): y = (bottom * f).rounded()
            }
            autoScroll = y >= bottom - 0.5
            isProgrammaticScroll = true
            sv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            isProgrammaticScroll = false
            report(atBottom: autoScroll)
        }

        func scrollToBottom(_ sv: UIScrollView) {
            DispatchQueue.main.async { [weak self, weak sv] in
                guard let self, let sv else { return }
                self.pin(sv)
                // A card still settling (focus change, keyboard) reports a
                // short contentSize on the first pass; one more pass lands it.
                DispatchQueue.main.async { [weak self, weak sv] in
                    guard let self, let sv else { return }
                    self.pin(sv)
                }
            }
        }

        /// Brings a content y into view, a third of the way down (find).
        func reveal(_ sv: UIScrollView, y: CGFloat) {
            // Before the open position lands, it would be overridden: hold it.
            guard positioned else { pendingReveal = y; return }
            autoScroll = false
            let target = min(max(0, y - sv.bounds.height * 0.3), bottomOffset(sv))
            sv.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        }

        private func bottomOffset(_ sv: UIScrollView) -> CGFloat {
            ScrollFollow.bottomOffset(
                contentHeight: sv.contentSize.height,
                viewportHeight: sv.bounds.height,
                bottomInset: sv.adjustedContentInset.bottom
            )
        }

        private func pin(_ sv: UIScrollView) {
            isProgrammaticScroll = true
            sv.layoutIfNeeded()
            let bottom = bottomOffset(sv)
            if abs(sv.contentOffset.y - bottom) > 0.5 {
                sv.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }
            isProgrammaticScroll = false
            report(atBottom: true)
            reportGeometry(sv)
        }

        private func report(atBottom: Bool) {
            guard reportedAtBottom != atBottom else { return }
            reportedAtBottom = atBottom
            onAtBottomChanged?(atBottom)
        }

        /// Far-from-bottom and scrollable, reported only on change.
        private func reportGeometry(_ sv: UIScrollView) {
            let viewport = sv.bounds.height
            guard viewport > 0 else { return }
            let far = ScrollFollow.showsJump(following: autoScroll, offsetY: sv.contentOffset.y,
                                             contentHeight: sv.contentSize.height, viewportHeight: viewport,
                                             bottomInset: sv.adjustedContentInset.bottom)
            if far != reportedFar {
                reportedFar = far
                onFarFromBottomChanged?(far)
            }
            let scrollable = sv.contentSize.height > viewport + 1
            if scrollable != reportedScrollable {
                reportedScrollable = scrollable
                onScrollableChanged?(scrollable)
            }
        }

        func checkNearTop(_ sv: UIScrollView) {
            guard positioned, canPage, let onNearTop else { return }
            if sv.contentOffset.y < sv.bounds.height * ChatPaging.nearTopScreens {
                onNearTop()
            }
        }

        func scrollViewDidScroll(_ sv: UIScrollView) {
            let atBottom = ScrollFollow.isAtBottom(
                offsetY: sv.contentOffset.y,
                contentHeight: sv.contentSize.height,
                viewportHeight: sv.bounds.height
            )
            autoScroll = ScrollFollow.follow(current: autoScroll, atBottom: atBottom, isProgrammatic: isProgrammaticScroll)
            if !isProgrammaticScroll { report(atBottom: atBottom) }
            reportGeometry(sv)
            checkNearTop(sv)
        }

        func scrollViewShouldScrollToTop(_ sv: UIScrollView) -> Bool {
            autoScroll = false
            return true
        }

        func scrollViewDidScrollToTop(_ sv: UIScrollView) {
            checkNearTop(sv)
        }
    }
}

/// Timing for the 3000-event check (`-UITestPerf`): off unless the fixture
/// turns it on, and then it forces each update's layout synchronously so the
/// number printed is the whole cost of that update.
enum ChatPerf {
    static var enabled = false
    /// `-UITestEchoCycle`: log every jump-button change.
    static let jumpLog = ProcessInfo.processInfo.arguments.contains("-UITestEchoCycle")
    static func log(_ line: String) {
        guard enabled else { return }
        print("[ChatPerf] \(line)")
    }
    static func mark(_ line: String) { log(line) }
}

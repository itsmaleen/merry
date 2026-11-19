import SafariServices
import SwiftUI
import UIKit

/// Lowers whatever keyboard is up (the composer, Find) by resigning the
/// first responder. One place for every "this doesn't need the keyboard"
/// entry point; the composer's focus state follows the resign.
@MainActor
enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// A web page to show in the in-app browser sheet.
struct LinkSheetTarget: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Where a tapped link goes, for links in the chat (SwiftUI's openURL) and
/// in terminal text (UITextView): web pages open in a sheet over the
/// session; merry-bridge surface links are handled in-app; any other scheme
/// goes to the system as before.
@MainActor
enum LinkRouter {
    static func open(_ url: URL) {
        if let state = AppState.current { state.openLink(url) } else { UIApplication.shared.open(url) }
    }

    static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}

/// SFSafariViewController as a SwiftUI sheet. Done (or a swipe down) clears
/// the binding, returning to the session as it was.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        vc.preferredControlTintColor = .label
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}

/// Installs a left-edge swipe (the iOS back gesture) on the window while
/// this view is on screen. A UIScreenEdgePanGestureRecognizer only begins
/// from the screen edge, and other pans in the window wait for it to fail
/// (it fails at once for a touch that starts anywhere else), so vertical
/// scrolling, text selection and horizontal scrollers keep working.
struct LeftEdgeSwipe: UIViewRepresentable {
    var isEnabled: Bool
    let onSwipe: () -> Void

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.onSwipe = onSwipe
        view.isEnabled = isEnabled
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.onSwipe = onSwipe
        view.isEnabled = isEnabled
    }

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        var onSwipe: (() -> Void)?
        var isEnabled = true { didSet { recognizer.isEnabled = isEnabled } }
        private lazy var recognizer: UIScreenEdgePanGestureRecognizer = {
            let r = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            r.edges = .left
            r.delegate = self
            return r
        }()

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            recognizer.view?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }

        @objc private func handle(_ r: UIScreenEdgePanGestureRecognizer) {
            guard r.state == .ended, let view = r.view else { return }
            let dx = r.translation(in: view).x
            let vx = r.velocity(in: view).x
            if dx > 60 || (dx > 20 && vx > 400) { onSwipe?() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Scroll views and SwiftUI drags wait for the edge to decide.
            other is UIPanGestureRecognizer && other !== g
        }
    }
}

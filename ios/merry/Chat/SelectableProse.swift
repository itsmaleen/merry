import SwiftUI
import UIKit

/// Chat text you can select a range of: a UITextView that never scrolls or
/// edits, sized to its text. SwiftUI's `textSelection` on iOS only copies a
/// whole Text, so prose, headings, code and your own bubbles use this.
/// Links go through LinkRouter, like every other link in the app.
struct SelectableProse: UIViewRepresentable {
    enum Style { case body, heading, code }

    let text: AttributedString
    var style: Style = .body
    /// As wide as the text needs (a bubble) instead of the width offered.
    var hugsWidth = false
    /// Takes link taps instead of LinkRouter, for text shown in a sheet or
    /// cover: the router's browser opens over the session, underneath it.
    var onLink: ((URL) -> Void)? = nil

    // Read so a theme or text-size change rebuilds the attributed text.
    @AppStorage(MerryTheme.storageKey) private var themeID = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onLink = onLink
        let key = Key(text: text, style: style, theme: themeID, size: typeSize)
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let color = UIColor(Theme.c.text)
        view.linkTextAttributes = [
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.attributedText = Self.attributed(text, style: style, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let offered = proposal.width ?? 0
        let width = offered.isFinite && offered > 0 ? offered : UIScreen.main.bounds.width
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: hugsWidth ? min(width, ceil(fit.width)) : width, height: ceil(fit.height))
    }

    struct Key: Equatable {
        let text: AttributedString
        let style: Style
        let theme: String
        let size: DynamicTypeSize
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var key: Key?
        var onLink: ((URL) -> Void)?

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            guard interaction == .invokeDefaultAction else { return true }
            if let onLink { onLink(URL) } else { LinkRouter.open(URL) }
            return false
        }
    }

    /// The markdown runs as UIKit attributes: bold, italic, inline code,
    /// strikethrough and links, on the style's Dynamic Type font.
    static func attributed(_ text: AttributedString, style: Style, color: UIColor) -> NSAttributedString {
        let base: UIFont
        var textColor = color
        let paragraph = NSMutableParagraphStyle()
        switch style {
        case .body:
            base = .preferredFont(forTextStyle: .body)
            paragraph.lineSpacing = 3
        case .heading:
            base = .preferredFont(forTextStyle: .headline)
        case .code:
            base = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            textColor = color.withAlphaComponent(0.6)
        }
        let out = NSMutableAttributedString()
        for run in text.runs {
            var font = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            } else {
                var traits = base.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if traits != base.fontDescriptor.symbolicTraits,
                   let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: descriptor, size: 0)
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attrs))
        }
        return out
    }
}

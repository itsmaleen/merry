import CoreGraphics

/// Sizing rules for an image on its way to an agent.
///
/// UIKit-free so `ios/scripts/test-image-scaling.swift` can exercise it: the
/// arithmetic here decides how much of a phone photo travels over the LAN, and
/// getting it wrong is invisible in a build.
enum ImageScaling {
    /// Longest edge an image is reduced to before sending.
    ///
    /// Claude resizes anything larger than roughly this before it looks at it,
    /// so sending a 4032px camera photo spends LAN time and disk on detail that
    /// is discarded on arrival. Anything already smaller is left alone — a
    /// screenshot of code is exactly the case where every pixel matters.
    static let maxDimension: CGFloat = 1568

    /// The size to render an image at, preserving aspect ratio.
    ///
    /// - Returns: the original size when it already fits. Never upscales: a
    ///   small image blown up carries no more information, just more bytes.
    static func targetSize(for size: CGSize, maxDimension: CGFloat = maxDimension) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return size }
        let scale = maxDimension / longest
        // Round rather than truncate, and never to zero: a 4000x3 panorama must
        // still have a height.
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }
}

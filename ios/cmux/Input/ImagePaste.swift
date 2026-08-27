import UIKit

/// Turns an image on the phone into something a terminal agent can receive.
///
/// A TUI reads bytes from a pty, so it cannot be handed a picture directly. The
/// bridge writes the image to a file on the Mac and types its path into the
/// surface, which is how a local clipboard-image paste works and how Claude Code
/// picks the image up. This side's job is to get the bytes there: reasonably
/// sized, in a format the bridge accepts.
enum ImagePaste {
    /// An image ready to send.
    struct Encoded {
        let base64: String
        /// Format label for the bridge's response; the bridge sniffs the bytes
        /// itself and does not trust this.
        let format: String
        /// Encoded byte count, for the "sent 240 KB" style confirmation.
        let bytes: Int
    }

    /// What kind of thing is attached, which decides how the bridge stores it:
    /// an image is downscaled and pasted via `surface.paste_image`; any other
    /// file is uploaded as-is via `surface.paste_file`.
    enum Kind: Equatable { case image, file }

    /// Something attached to the compose bar, awaiting a message. Carries the
    /// full encoded payload plus a small thumbnail (images only) for the preview
    /// chip, so the chip never decodes the much larger send payload to draw.
    struct Attachment: Equatable {
        let kind: Kind
        let base64: String
        let format: String
        let bytes: Int
        /// A readable label for the chip: a filename for files, "Image" for a
        /// pasted photo.
        let label: String
        /// A small PNG for the preview chip, when the attachment is an image.
        let thumbnail: Data?
    }

    /// Encodes a pasteboard/library image and a preview thumbnail together. Runs
    /// the heavy redraw/encode once; call it off the main actor.
    static func attachment(from image: UIImage) -> Attachment? {
        guard let encoded = encode(image) else { return nil }
        return Attachment(
            kind: .image,
            base64: encoded.base64,
            format: encoded.format,
            bytes: encoded.bytes,
            label: "Image",
            thumbnail: thumbnailPNG(image)
        )
    }

    /// Builds an attachment from an arbitrary picked file. An image file goes
    /// through the same downscale as a pasted photo (so a 12MP photo picked via
    /// "File" doesn't blow the size limit); anything else is attached verbatim
    /// and uploaded as-is.
    static func attachment(fileData data: Data, filename: String) -> Attachment? {
        guard !data.isEmpty else { return nil }
        if let image = UIImage(data: data) {
            return attachment(from: image)
        }
        let name = filename.isEmpty ? "file" : filename
        let ext = (name as NSString).pathExtension.lowercased()
        return Attachment(
            kind: .file,
            base64: data.base64EncodedString(),
            format: ext,
            bytes: data.count,
            label: name,
            thumbnail: nil
        )
    }

    /// A small square-ish PNG preview (long edge ~160px) for the compose chip.
    private static func thumbnailPNG(_ image: UIImage) -> Data {
        let size = ImageScaling.targetSize(for: image.size, maxDimension: 160)
        let thumb = size == image.size ? image : redraw(image, at: size)
        return thumb.pngData() ?? Data()
    }

    /// JPEG quality for photographs. High enough that text in a screenshot stays
    /// legible, low enough that a phone photo lands in the hundreds of KB.
    static let jpegQuality: CGFloat = 0.82

    /// Largest file the bridge accepts (mirrors imagepaste.MaxFileBytes). The
    /// client rejects anything larger before base64-encoding it, so a huge file
    /// neither exhausts memory nor exceeds the WebSocket frame limit and drops
    /// the connection.
    static let maxFileBytes = 12 * 1024 * 1024

    /// The image currently on the pasteboard, if any.
    ///
    /// Reading the pasteboard shows iOS's "Allow Paste?" prompt the first time,
    /// which is the system telling the user what we're about to do — worth it
    /// over a photo picker for something explicitly framed as a paste.
    static func pasteboardImage() -> UIImage? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else { return nil }
        return pasteboard.image
    }

    /// Downscales and encodes an image for transport.
    ///
    /// PNG when the image has an alpha channel (screenshots with transparency,
    /// diagrams), JPEG otherwise — PNG on a photograph is several times larger
    /// for no visible gain, and the whole payload crosses a phone's wifi.
    static func encode(_ image: UIImage) -> Encoded? {
        let target = ImageScaling.targetSize(for: image.size)
        let resized = target == image.size ? image : redraw(image, at: target)

        if hasAlpha(resized), let png = resized.pngData() {
            return Encoded(base64: png.base64EncodedString(), format: "png", bytes: png.count)
        }
        if let jpeg = resized.jpegData(compressionQuality: jpegQuality) {
            return Encoded(base64: jpeg.base64EncodedString(), format: "jpg", bytes: jpeg.count)
        }
        // A CIImage-backed UIImage can refuse both encoders; PNG of the redrawn
        // bitmap is the last resort rather than sending nothing.
        guard let png = redraw(resized, at: target).pngData() else { return nil }
        return Encoded(base64: png.base64EncodedString(), format: "png", bytes: png.count)
    }

    private static func redraw(_ image: UIImage, at size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        // Draw at exactly the pixel size computed above: the renderer would
        // otherwise apply the screen's scale and undo the downscale.
        format.scale = 1
        format.opaque = !hasAlpha(image)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        guard let alpha = image.cgImage?.alphaInfo else { return false }
        switch alpha {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }
}

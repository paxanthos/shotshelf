import AppKit
import ImageIO

enum Clipboard {
    /// Puts an image on the pasteboard as pixels *and* as the file, so it pastes as an image
    /// in Messages/Notes/Figma and as the real file in Finder/Slack/Mail.
    @discardableResult
    static func copy(_ url: URL) -> Bool {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)

        let ext = url.pathExtension.lowercased()
        if ext == "png", let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
        } else if let png = pngData(for: url) {
            item.setData(png, forType: .png)
        }
        if ext == "pdf", let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .pdf)
        }
        if let tiff = NSImage(contentsOf: url)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private static func pngData(for url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

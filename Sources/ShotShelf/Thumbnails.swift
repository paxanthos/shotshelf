import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Downsampled thumbnails via ImageIO, cached by path + mtime.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 400
    }

    func image(for item: ShotItem, maxPixel: CGFloat) async -> NSImage? {
        let key = "\(item.url.path)|\(item.modified.timeIntervalSince1970)|\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let url = item.url
        let image: NSImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.render(url: url, maxPixel: maxPixel))
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func render(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

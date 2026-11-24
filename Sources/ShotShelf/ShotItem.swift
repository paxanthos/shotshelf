import Foundation

struct ShotItem: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let size: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Static visual assets only — anything Quick Look / ImageIO can thumbnail.
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp",
        "tif", "tiff", "bmp", "icns", "avif", "pdf", "svg", "psd"
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

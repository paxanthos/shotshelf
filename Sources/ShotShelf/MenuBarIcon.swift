import AppKit

/// Draws the status-bar icon: a neutral glyph when idle, and the newest screenshot
/// (with a draining progress bar) while a recent chip is live.
enum MenuBarIcon {
    static let size = NSSize(width: 24, height: 18)

    static func idle() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "ShotShelf")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShotShelf")
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "ShotShelf")
        let image = symbol?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// Shown for a moment after ⌃⌥⌘C copies the latest image.
    static func copied() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    static func compose(thumb: NSImage?, progress: Double) -> NSImage {
        let canvas = size
        let image = NSImage(size: canvas, flipped: false) { rect in
            let frame = rect.insetBy(dx: 0.5, dy: 0.5)
            let rounded = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            rounded.addClip()

            NSColor.black.withAlphaComponent(0.30).setFill()
            frame.fill()

            if let thumb {
                drawAspectFill(thumb, in: frame)
            }

            let clamped = max(0, min(1, progress))
            if clamped > 0 {
                let height: CGFloat = 2.5
                let bar = NSRect(x: frame.minX, y: frame.minY, width: frame.width * clamped, height: height)
                NSColor.controlAccentColor.setFill()
                bar.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return }
        let scale = max(rect.width / source.width, rect.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        let target = NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

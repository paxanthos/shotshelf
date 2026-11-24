import AppKit

// Generates fake "screenshots" for testing the shelf without touching ~/Documents.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct Spec {
    let name: String
    let size: NSSize
    let top: NSColor
    let bottom: NSColor
    let caption: String
}

let specs: [Spec] = [
    Spec(name: "Screenshot 2026-10-28 at 9.02.11 AM.png", size: .init(width: 1440, height: 900), top: .systemIndigo, bottom: .systemBlue, caption: "App window"),
    Spec(name: "Screenshot 2026-10-28 at 9.14.40 AM.png", size: .init(width: 900, height: 1400), top: .systemPink, bottom: .systemOrange, caption: "Tall capture"),
    Spec(name: "Screenshot 2026-10-28 at 9.31.05 AM.png", size: .init(width: 1200, height: 800), top: .systemTeal, bottom: .systemGreen, caption: "Chart"),
    Spec(name: "Screenshot 2026-10-28 at 10.05.52 AM.png", size: .init(width: 800, height: 600), top: .systemGray, bottom: .systemPurple, caption: "Dialog"),
    Spec(name: "Screenshot 2026-10-27 at 4.48.19 PM.png", size: .init(width: 1600, height: 1000), top: .systemYellow, bottom: .systemRed, caption: "Wide"),
    Spec(name: "logo-asset.png", size: .init(width: 512, height: 512), top: .black, bottom: .systemMint, caption: "asset")
]

for (index, spec) in specs.enumerated() {
    let image = NSImage(size: spec.size, flipped: false) { rect in
        let gradient = NSGradient(starting: spec.top, ending: spec.bottom)
        gradient?.draw(in: rect, angle: -70)
        let text = NSAttributedString(
            string: spec.caption,
            attributes: [
                .font: NSFont.systemFont(ofSize: max(28, rect.height / 12), weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
        )
        let size = text.size()
        text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let url = out.appendingPathComponent(spec.name)
    try? png.write(to: url)
    // Stagger mtimes so the ordering test is meaningful.
    let date = Date().addingTimeInterval(Double(index - specs.count) * 3600)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

print("wrote \(specs.count) test images to \(out.path)")

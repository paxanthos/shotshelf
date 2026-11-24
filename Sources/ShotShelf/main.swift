import AppKit

// Headless probe: `ShotShelf.app/Contents/MacOS/ShotShelf --probe`
// Prints the resolved config + the files the shelf would show, then exits.
enum Probe {
    static func run() {
        let config = ShotShelfConfig.load()
        print("config: \(ShotShelfConfig.path.path)")
        print("folders:")
        for f in config.folders { print("  - \(f)") }
        print("expiry: \(Int(config.expirySeconds))s")
        print("screenshots save to: \(ScreenshotSettings.location().path) as \(ScreenshotSettings.fileType())")
        let library = ShotLibrary(indexText: false)
        library.scanNowForProbe()
        let indexed = library.items.filter { library.textIndex.text(for: $0) != nil }.count
        print("items: \(library.items.count)  (text read for \(indexed))")
        for item in library.items.prefix(10) {
            let words = library.textIndex.text(for: item).map { "\($0.split(whereSeparator: \.isWhitespace).count) words" } ?? "not read"
            print("  \(item.modified.formatted(date: .abbreviated, time: .standard))  \(item.sizeLabel)  \(item.name)  [\(words)]")
        }
    }
}

let args = CommandLine.arguments
if args.contains("--probe") {
    Probe.run()
    exit(0)
}
if let index = args.firstIndex(of: "--ocr"), args.count > index + 1 {
    // Print the text ShotShelf's search would see for each image (timing on stderr).
    for path in args[(index + 1)...] where !path.hasPrefix("--") {
        let url = URL(fileURLWithPath: path)
        let start = Date()
        let text = TextIndex.recognize(url: url)
        FileHandle.standardError.write(Data(String(format: "%.2fs  %@\n", Date().timeIntervalSince(start), url.lastPathComponent).utf8))
        print(text ?? "(could not read \(url.path))")
    }
    exit(0)
}
if let index = args.firstIndex(of: "--render") {
    let out = args.count > index + 1 ? args[index + 1] : "gallery.png"
    let query = args.firstIndex(of: "--query").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    RenderPreview.run(outputPath: out, dark: !args.contains("--light"), query: query)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

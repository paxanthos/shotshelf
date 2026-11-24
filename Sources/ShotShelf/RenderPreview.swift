import AppKit
import SwiftUI

/// Dev tool: renders the gallery to a PNG without needing a display grab.
/// Usage: ShotShelf --render /tmp/gallery.png
enum RenderPreview {
    private static var stepLog: URL?
    private static func step(_ message: String) {
        guard let url = stepLog else { return }
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func run(outputPath: String, dark: Bool = true, query: String? = nil) {
        stepLog = URL(fileURLWithPath: outputPath + ".steps.log")
        try? FileManager.default.removeItem(at: stepLog!)
        step("start")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if dark {
            app.appearance = NSAppearance(named: .darkAqua)
        }

        step("app ready")
        let library = ShotLibrary(indexText: false)
        library.scanNowForProbe()
        step("scanned \(library.items.count)")
        if let first = library.items.first, library.recent == nil {
            library.promoteRecent(first)
        }

        let model = GalleryModel()
        model.prewarm(library.items)
        if let query {
            library.textIndex.indexNowForPreview(Array(library.items.prefix(60)))
            model.query = query
            step("indexed text for query \(query)")
        }

        let actions = GalleryActions(
            open: { _ in }, reveal: { _ in }, trash: { _ in }, copy: { _ in }, quickLook: { _ in },
            addFolder: {}, removeFolder: { _ in }, openFolder: { _ in }, close: {},
            requestAccess: { _ in }, openPrivacySettings: {}
        )

        step("prewarmed")
        let host = NSHostingView(rootView: GalleryView(library: library, textIndex: library.textIndex, model: model, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: 396, height: 520)
        step("host created")
        host.layoutSubtreeIfNeeded()
        step("layout done")

        // Let SwiftUI settle (async thumbnail publishes, layout passes).
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        step("runloop drained")
        host.layoutSubtreeIfNeeded()
        step("layout 2 done")

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("render failed: no bitmap rep")
            return
        }
        step("rep ok")
        host.cacheDisplay(in: host.bounds, to: rep)
        step("cached")
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("render failed: no png data")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: outputPath))
            print("rendered: \(outputPath) (\(library.items.count) items)")
        } catch {
            print("render failed: \(error)")
        }
    }
}

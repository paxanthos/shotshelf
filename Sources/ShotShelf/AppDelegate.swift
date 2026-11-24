import AppKit
import Quartz

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var library: ShotLibrary?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lib = ShotLibrary()
        library = lib
        statusController = StatusItemController(library: lib)
        lib.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // Quick Look looks for a controller along the key window's responder chain,
    // which ends at the app delegate.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.attach(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

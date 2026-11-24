import Foundation
import CoreFoundation

/// Reads and writes macOS's own screenshot preferences (the `com.apple.screencapture` domain):
/// where ⇧⌘3/4/5 save, which file type they write, and the floating thumbnail.
enum ScreenshotSettings {
    private static let domain = "com.apple.screencapture" as CFString

    struct FileType {
        let id: String       // value macOS stores, also the file extension
        let label: String
    }

    static let fileTypes: [FileType] = [
        FileType(id: "png", label: "PNG"),
        FileType(id: "jpg", label: "JPEG"),
        FileType(id: "heic", label: "HEIC"),
        FileType(id: "pdf", label: "PDF"),
        FileType(id: "tiff", label: "TIFF"),
        FileType(id: "gif", label: "GIF"),
        FileType(id: "psd", label: "PSD")
    ]

    // MARK: - Read

    private static func string(_ key: String) -> String? {
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Where screenshots land. Newer macOS keeps `location-screenshot`; older uses `location`.
    static func location() -> URL {
        if let raw = string("location-screenshot") ?? string("location") {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func fileType() -> String {
        let raw = string("type")?.lowercased() ?? "png"
        return raw == "jpeg" ? "jpg" : raw
    }

    static func showsFloatingThumbnail() -> Bool {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("show-thumbnail" as CFString, domain) as? Bool ?? true
    }

    // MARK: - Write

    static func setLocation(_ folder: URL) {
        let path = (folder.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
        for key in ["location", "location-last", "location-screenshot"] {
            defaults(["write", "com.apple.screencapture", key, "-string", path])
        }
        restartScreenshotUI()
    }

    static func setFileType(_ id: String) {
        defaults(["write", "com.apple.screencapture", "type", "-string", id])
        restartScreenshotUI()
    }

    static func setShowsFloatingThumbnail(_ on: Bool) {
        defaults(["write", "com.apple.screencapture", "show-thumbnail", "-bool", on ? "true" : "false"])
        restartScreenshotUI()
    }

    // MARK: - Plumbing

    private static func defaults(_ arguments: [String]) {
        run("/usr/bin/defaults", arguments)
        CFPreferencesAppSynchronize(domain)
    }

    /// The screenshot UI caches its prefs; restarting SystemUIServer makes changes stick.
    private static func restartScreenshotUI() {
        run("/usr/bin/killall", ["SystemUIServer"])
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("ShotShelf: \(tool) failed: \(error)")
        }
    }
}

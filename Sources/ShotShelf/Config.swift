import Foundation

struct ShotShelfConfig: Codable {
    var folders: [String]
    var expirySeconds: Double
    var hideSystemPreview: Bool
    /// ⌃⌥⌘C copies the newest image to the clipboard from anywhere.
    var copyShortcut: Bool

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ShotShelf", isDirectory: true)
    }()

    static let path = supportDir.appendingPathComponent("config.json")

    /// Where macOS itself writes screenshots (System Settings → Screenshot → Save to).
    static func systemScreenshotFolder() -> URL {
        ScreenshotSettings.location()
    }

    init(folders: [String], expirySeconds: Double, hideSystemPreview: Bool, copyShortcut: Bool) {
        self.folders = folders
        self.expirySeconds = expirySeconds
        self.hideSystemPreview = hideSystemPreview
        self.copyShortcut = copyShortcut
    }

    /// Tolerant decoding: keys added in later versions fall back to defaults instead of
    /// discarding the user's existing config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaultConfig
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? fallback.folders
        expirySeconds = try c.decodeIfPresent(Double.self, forKey: .expirySeconds) ?? fallback.expirySeconds
        hideSystemPreview = try c.decodeIfPresent(Bool.self, forKey: .hideSystemPreview) ?? fallback.hideSystemPreview
        copyShortcut = try c.decodeIfPresent(Bool.self, forKey: .copyShortcut) ?? fallback.copyShortcut
    }

    static var defaultConfig: ShotShelfConfig {
        // Only the real screenshot folder by default: adding Desktop floods the shelf
        // with unrelated images. More folders can be added from the popover.
        ShotShelfConfig(
            folders: [systemScreenshotFolder().path],
            expirySeconds: 60,
            hideSystemPreview: false,
            copyShortcut: true
        )
    }

    static func load() -> ShotShelfConfig {
        guard let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode(ShotShelfConfig.self, from: data) else {
            let fresh = defaultConfig
            fresh.save()
            return fresh
        }
        return decoded
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.path, options: .atomic)
        } catch {
            NSLog("ShotShelf: could not save config: \(error)")
        }
    }
}

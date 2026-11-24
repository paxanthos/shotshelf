import Foundation

/// Small status beacon so the app can be verified without a screen grab.
/// Writes ~/Library/Application Support/ShotShelf/status.json on every scan.
enum Diagnostics {
    static var url: URL {
        ShotShelfConfig.supportDir.appendingPathComponent("status.json")
    }

    static func write(_ payload: [String: Any]) {
        var merged = payload
        merged["updated"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? FileManager.default.createDirectory(at: ShotShelfConfig.supportDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

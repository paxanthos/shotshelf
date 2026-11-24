import Foundation
import Combine
import AppKit

/// Watches one or more folders, keeps them sorted newest-first, and promotes the
/// newest arrival to a time-limited "recent" chip that can be dragged out.
final class ShotLibrary: ObservableObject {
    @Published private(set) var items: [ShotItem] = []
    @Published private(set) var recent: ShotItem?
    @Published private(set) var recentProgress: Double = 0   // 1.0 → 0.0
    @Published private(set) var folders: [URL] = []
    @Published private(set) var expirySeconds: Double = 60
    @Published private(set) var unreadableFolders: [URL] = []
    @Published private(set) var copyShortcut = true

    /// OCR over every item so search finds the words inside screenshots.
    let textIndex: TextIndex

    private var config: ShotShelfConfig
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var ticker: Timer?
    private var pendingScan: DispatchWorkItem?
    private var recentDeadline: Date?
    private var lastSeenMax: Date = .distantPast
    private var primed = false
    private var started = false
    private var textSynced = false

    private static let resourceKeys: Set<URLResourceKey> = [
        .contentModificationDateKey, .fileSizeKey, .isRegularFileKey
    ]

    /// `indexText: false` for the headless dev entry points (no background OCR).
    init(indexText: Bool = true) {
        config = ShotShelfConfig.load()
        textIndex = TextIndex(enabled: indexText)
        expirySeconds = config.expirySeconds
        copyShortcut = config.copyShortcut
        folders = config.folders
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        folders = folders.filter { FileManager.default.fileExists(atPath: $0.path) }
        if folders.isEmpty {
            folders = [ShotShelfConfig.systemScreenshotFolder()]
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        watchFolders()
        scan(promoteFresh: true)
        startTicker()
    }

    func rescanNow() {
        scan(promoteFresh: false)
    }

    /// Used by --probe (no watchers, no timers).
    func scanNowForProbe() {
        scan(promoteFresh: false)
    }

    // MARK: - Recent chip

    func promoteRecent(_ item: ShotItem) {
        recent = item
        recentDeadline = Date().addingTimeInterval(expirySeconds)
        recentProgress = 1
        Diagnostics.write([
            "event": "promoted",
            "recent": item.name,
            "expirySeconds": expirySeconds,
            "items": items.count
        ])
    }

    /// Called once a drag completes — the chip is consumed.
    func consumeRecent() {
        let name = recent?.name ?? "-"
        recent = nil
        recentDeadline = nil
        recentProgress = 0
        Diagnostics.write(["event": "cleared", "was": name])
    }

    // MARK: - Folders

    func addFolder(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard !folders.contains(where: { $0.standardizedFileURL == normalized }) else { return }
        folders.append(normalized)
        persist()
        watchFolders()
        scan(promoteFresh: false)
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if folders.isEmpty { folders = [ShotShelfConfig.systemScreenshotFolder()] }
        persist()
        watchFolders()
        scan(promoteFresh: false)
    }

    /// The screenshot save location moved: watch the new folder in place of the old one.
    func replaceFolder(_ old: URL, with new: URL) {
        let normalized = new.standardizedFileURL
        if let index = folders.firstIndex(where: { $0.standardizedFileURL == old.standardizedFileURL }) {
            folders[index] = normalized
        } else {
            folders.insert(normalized, at: 0)
        }
        var seen = Set<String>()
        folders = folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
        persist()
        watchFolders()
        scan(promoteFresh: false)
    }

    func setCopyShortcut(_ on: Bool) {
        copyShortcut = on
        persist()
    }

    func setExpiry(_ seconds: Double) {
        expirySeconds = seconds
        // Re-base the live countdown so a change takes effect immediately.
        if recent != nil, let deadline = recentDeadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let elapsed = max(0, expirySeconds - remaining)
            recentDeadline = Date().addingTimeInterval(max(0, expirySeconds - elapsed))
            recentProgress = expirySeconds > 0 ? max(0, min(1, remaining / expirySeconds)) : 0
        }
        persist()
    }

    private func persist() {
        config.folders = folders.map(\.path)
        config.expirySeconds = expirySeconds
        config.copyShortcut = copyShortcut
        config.save()
    }

    // MARK: - Scanning

    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan(promoteFresh: false) }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func scan(promoteFresh: Bool) {
        let fm = FileManager.default
        var found: [ShotItem] = []

        var blocked: [URL] = []

        for folder in folders {
            let urls: [URL]
            do {
                urls = try fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
            } catch {
                // Usually TCC: macOS is waiting for the user to allow Documents access.
                blocked.append(folder)
                continue
            }

            for url in urls where ShotItem.isSupported(url) {
                guard let values = try? url.resourceValues(forKeys: Self.resourceKeys),
                      values.isRegularFile == true else { continue }
                found.append(ShotItem(
                    url: url,
                    modified: values.contentModificationDate ?? .distantPast,
                    size: Int64(values.fileSize ?? 0)
                ))
            }
        }

        found.sort { $0.modified > $1.modified }
        if found.count > 800 { found.removeLast(found.count - 800) }
        if found != items || !textSynced {
            items = found
            textSynced = true
            textIndex.sync(with: found)
        }
        if blocked != unreadableFolders { unreadableFolders = blocked }

        Diagnostics.write([
            "items": found.count,
            "folders": folders.map(\.path),
            "readableFolders": folders.filter { FileManager.default.isReadableFile(atPath: $0.path) }.map(\.path),
            "newest": found.first?.name ?? "-",
            "recent": recent?.name ?? "-",
            "unreadable": blocked.map(\.path),
            "expirySeconds": expirySeconds
        ])

        guard let newest = found.first else { return }

        if !primed {
            primed = true
            lastSeenMax = newest.modified
            // A screenshot taken seconds before launch still deserves the chip.
            if promoteFresh, newest.modified > Date().addingTimeInterval(-expirySeconds) {
                promoteRecent(newest)
            }
            return
        }

        if newest.modified > lastSeenMax.addingTimeInterval(0.2) {
            lastSeenMax = newest.modified
            promoteRecent(newest)
        } else if newest.modified > lastSeenMax {
            lastSeenMax = newest.modified
        }
    }

    // MARK: - Watching

    private func watchFolders() {
        for (_, source) in watchers { source.cancel() }
        watchers.removeAll()

        for folder in folders {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleScan() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[folder.path] = source
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let deadline = self.recentDeadline else { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                self.consumeRecent()
            } else {
                self.recentProgress = max(0, min(1, remaining / self.expirySeconds))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}

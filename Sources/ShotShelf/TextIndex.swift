import Foundation
import Combine
import ImageIO
import Vision

/// On-device OCR (Vision) for every shelf item, so search matches the words *inside* images.
/// Results are cached in ~/Library/Application Support/ShotShelf/text-index.json, keyed by
/// path + modification date, so each file is read once. New captures are indexed newest-first.
final class TextIndex: ObservableObject {
    /// Bumps (throttled) whenever new text lands, so views re-run their search.
    @Published private(set) var revision = 0
    /// Items still waiting for OCR.
    @Published private(set) var pending = 0

    private struct Entry: Codable {
        var modified: Double
        var text: String
    }

    static let url = ShotShelfConfig.supportDir.appendingPathComponent("text-index.json")

    // Main-thread state.
    private var entries: [String: Entry] = [:]
    private var queued: [ShotItem] = []
    private var inFlight: String?
    private var flushScheduled = false
    private var saveWork: DispatchWorkItem?
    private let enabled: Bool

    private let worker = DispatchQueue(label: "shotshelf.ocr", qos: .utility)

    init(enabled: Bool = true) {
        self.enabled = enabled
        load()
    }

    var indexedCount: Int { entries.count }

    func text(for item: ShotItem) -> String? {
        guard let entry = entries[item.id],
              entry.modified == item.modified.timeIntervalSince1970 else { return nil }
        return entry.text
    }

    /// Re-sync with the library: queue new/changed files (newest first), forget deleted ones.
    func sync(with items: [ShotItem]) {
        guard enabled else { return }

        // Prune only files that are really gone: a folder that is briefly unreadable
        // (TCC prompt pending) must not wipe its text.
        let live = Set(items.map(\.id))
        let before = entries.count
        entries = entries.filter { live.contains($0.key) || FileManager.default.fileExists(atPath: $0.key) }
        if entries.count != before { scheduleSave() }

        queued = items.filter { text(for: $0) == nil && $0.id != inFlight }
        pending = queued.count + (inFlight == nil ? 0 : 1)
        pump()
    }

    /// Dev renderer only: read text synchronously so a `--query` render shows real matches.
    func indexNowForPreview(_ items: [ShotItem]) {
        for item in items where text(for: item) == nil {
            let text = autoreleasepool { Self.recognize(url: item.url) } ?? ""
            entries[item.id] = Entry(modified: item.modified.timeIntervalSince1970, text: text)
        }
    }

    // MARK: - Work loop

    private func pump() {
        guard inFlight == nil, !queued.isEmpty else { return }
        let item = queued.removeFirst()
        inFlight = item.id
        worker.async { [weak self] in
            let text = autoreleasepool { Self.recognize(url: item.url) } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.entries[item.id] = Entry(modified: item.modified.timeIntervalSince1970, text: text)
                self.inFlight = nil
                self.scheduleFlush()
                self.scheduleSave()
                self.pump()
            }
        }
    }

    /// Publishing per image would re-render the grid constantly; batch it.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.revision &+= 1
            self.pending = self.queued.count + (self.inFlight == nil ? 0 : 1)
        }
    }

    // MARK: - OCR

    static func recognize(url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: ShotShelfConfig.supportDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: Self.url, options: .atomic)
        } catch {
            NSLog("ShotShelf: could not save text index: \(error)")
        }
    }
}

// MARK: - Search

enum TextSearch {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every term must appear in the file name or in the recognized text.
    static func matches(_ item: ShotItem, text: String?, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = item.name + "\n" + (text ?? "")
        return terms.allSatisfy { contains(haystack, $0) }
    }

    /// The recognized line that explains a match, when the name alone doesn't.
    static func snippet(_ item: ShotItem, text: String?, terms: [String]) -> String? {
        guard let text, !terms.isEmpty,
              !terms.allSatisfy({ contains(item.name, $0) }) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        let best = lines.max { a, b in
            terms.filter { contains(a, $0) }.count < terms.filter { contains(b, $0) }.count
        }
        guard let line = best, terms.contains(where: { contains(line, $0) }) else { return nil }
        return trimmed(line, around: terms.first { contains(line, $0) } ?? "")
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func trimmed(_ line: String, around term: String, radius: Int = 34) -> String {
        guard line.count > radius * 2,
              let range = line.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return line
        }
        let matchStart = line.distance(from: line.startIndex, to: range.lowerBound)
        let start = max(0, matchStart - radius)
        let end = min(line.count, matchStart + term.count + radius)
        let lo = line.index(line.startIndex, offsetBy: start)
        let hi = line.index(line.startIndex, offsetBy: end)
        return (start > 0 ? "…" : "") + line[lo..<hi] + (end < line.count ? "…" : "")
    }
}

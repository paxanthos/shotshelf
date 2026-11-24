import SwiftUI
import AppKit
import Combine

struct GalleryActions {
    var open: (ShotItem) -> Void
    var reveal: (ShotItem) -> Void
    var trash: (ShotItem) -> Void
    var copy: (ShotItem) -> Void
    var quickLook: (ShotItem) -> Void
    var addFolder: () -> Void
    var removeFolder: (URL) -> Void
    var openFolder: (URL) -> Void
    var close: () -> Void
    var requestAccess: (URL) -> Void
    var openPrivacySettings: () -> Void
}

/// All mutable UI state lives here so the views stay macro-free
/// (SwiftUI's @State macro is unavailable in a Command-Line-Tools-only build).
final class GalleryModel: ObservableObject {
    @Published var query = ""
    @Published var hovering: String?
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    private var inFlight = Set<String>()

    func thumbnail(for item: ShotItem, maxPixel: CGFloat) -> NSImage? {
        let key = "\(item.id)|\(Int(maxPixel))"
        if let image = thumbnails[key] { return image }
        load(item: item, key: key, maxPixel: maxPixel)
        return nil
    }

    func reset() {
        query = ""
        hovering = nil
    }

    /// Synchronous fill, used by the offscreen renderer (no async loading there).
    func prewarm(_ items: [ShotItem]) {
        for item in items.prefix(60) {
            if let image = ThumbnailCache.render(url: item.url, maxPixel: 320) {
                thumbnails["\(item.id)|320"] = image
            }
            if let big = ThumbnailCache.render(url: item.url, maxPixel: 800) {
                thumbnails["\(item.id)|800"] = big
            }
        }
    }

    private func load(item: ShotItem, key: String, maxPixel: CGFloat) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        // Deferred: never publish while SwiftUI is evaluating a body.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let image = await ThumbnailCache.shared.image(for: item, maxPixel: maxPixel)
                self.inFlight.remove(key)
                if let image {
                    if self.thumbnails.count > 500 { self.thumbnails.removeAll() }
                    self.thumbnails[key] = image
                }
            }
        }
    }
}

private struct DayGroup: Identifiable {
    let day: Date
    let items: [ShotItem]
    var id: Date { day }
}

struct GalleryView: View {
    @ObservedObject var library: ShotLibrary
    @ObservedObject var textIndex: TextIndex
    @ObservedObject var model: GalleryModel
    let actions: GalleryActions

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 132), spacing: 8)]

    private var terms: [String] { TextSearch.terms(model.query) }

    /// Matches file names and the OCR'd text inside each image.
    private var filtered: [ShotItem] {
        let terms = self.terms
        guard !terms.isEmpty else { return library.items }
        return library.items.filter { TextSearch.matches($0, text: textIndex.text(for: $0), terms: terms) }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for item in filtered {
            let day = calendar.startOfDay(for: item.modified)
            if let last = result.last, calendar.isDate(last.day, inSameDayAs: day) {
                result[result.count - 1] = DayGroup(day: last.day, items: last.items + [item])
            } else {
                result.append(DayGroup(day: day, items: [item]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 396, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Shelf")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Search text in images", text: Binding(
                    get: { model.query },
                    set: { model.query = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 150)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let recent = library.recent, terms.isEmpty {
                    RecentCard(
                        item: recent,
                        remaining: max(0, library.recentProgress * library.expirySeconds),
                        expiry: max(1, library.expirySeconds),
                        image: model.thumbnail(for: recent, maxPixel: 800),
                        actions: actions
                    )
                }

                if filtered.isEmpty {
                    emptyState
                } else {
                    let terms = self.terms
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(dayLabel(group.day))
                                .font(.system(size: 9, weight: .bold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(group.items) { item in
                                    ThumbnailCell(
                                        item: item,
                                        image: model.thumbnail(for: item, maxPixel: 320),
                                        snippet: TextSearch.snippet(item, text: textIndex.text(for: item), terms: terms),
                                        hovering: model.hovering == item.id,
                                        actions: actions,
                                        onHover: { inside in
                                            if inside {
                                                model.hovering = item.id
                                            } else if model.hovering == item.id {
                                                model.hovering = nil
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if let blocked = library.unreadableFolders.first {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("ShotShelf can’t read “\(blocked.lastPathComponent)” yet")
                    .font(.system(size: 11, weight: .medium))
                Text("macOS is holding access until you allow it. Look for the permission dialog, or grant it in System Settings → Privacy & Security → Files and Folders.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                HStack(spacing: 10) {
                    Button("Choose Folder…") { actions.requestAccess(blocked) }
                        .font(.system(size: 11))
                    Button("System Settings…") { actions.openPrivacySettings() }
                        .font(.system(size: 11))
                }
                .padding(.top, 2)
            } else {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "No images in the watched folders yet" : "Nothing matches “\(model.query)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !model.query.isEmpty, textIndex.pending > 0 {
                    Text("Still reading text in \(textIndex.pending) image\(textIndex.pending == 1 ? "" : "s")…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let folder = library.folders.first {
                    Button("Open \(folder.lastPathComponent)") { actions.openFolder(folder) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(library.folders, id: \.self) { folder in
                HStack(spacing: 3) {
                    Button {
                        actions.openFolder(folder)
                    } label: {
                        Text(folder.lastPathComponent)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(folder.path)

                    Button {
                        actions.removeFolder(folder)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Button(action: actions.addFolder) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Watch another folder")

            Spacer(minLength: 0)

            if textIndex.pending > 0 {
                Text("reading text · \(textIndex.pending) left")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("ShotShelf reads the text inside each image on this Mac so search can find it.")
            }
            Text(countLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private extension GalleryView {
    var countLabel: String {
        let total = library.items.count
        if !terms.isEmpty { return "\(filtered.count) of \(total)" }
        return "\(total) image\(total == 1 ? "" : "s")"
    }
}

// MARK: - Recent card

private struct RecentCard: View {
    let item: ShotItem
    let remaining: Double
    let expiry: Double
    let image: NSImage?
    let actions: GalleryActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("LATEST")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.6)
                Text("drag it out · \(Int(remaining.rounded(.up)))s")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.10))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(5)
                }
            }
            .frame(height: 138)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            )
            .overlay(alignment: .bottomLeading) {
                Text(item.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(7)
                    .frame(maxWidth: 280, alignment: .leading)
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: geo.size.width * progressFraction, height: 2.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            .onTapGesture(count: 2) { actions.open(item) }
            .contextMenu { ItemMenu(item: item, actions: actions) }
            .help("Drag \(item.name) into any app")
        }
    }

    private var progressFraction: CGFloat {
        CGFloat(max(0, min(1, remaining / expiry)))
    }
}

// MARK: - Grid cell

private struct ThumbnailCell: View {
    let item: ShotItem
    let image: NSImage?
    let snippet: String?
    let hovering: Bool
    let actions: GalleryActions
    let onHover: (Bool) -> Void

    var body: some View {
        // The image lives in an overlay so an aspect-fill thumbnail can never
        // widen the cell past its grid column.
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.10))
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .overlay(alignment: .bottom) { caption }
        .frame(height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0.07), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { actions.open(item) }
        .contextMenu { ItemMenu(item: item, actions: actions) }
        .help("\(item.name)\n\(item.sizeLabel) · \(item.modified.formatted(date: .abbreviated, time: .shortened))")
    }

    @ViewBuilder
    private var caption: some View {
        if let snippet {
            HStack(alignment: .top, spacing: 3) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 7, weight: .semibold))
                Text(snippet)
                    .font(.system(size: 8))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.68))
        } else if hovering {
            Text(item.name)
                .font(.system(size: 8))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.6))
        }
    }
}

// MARK: - Context menu

private struct ItemMenu: View {
    let item: ShotItem
    let actions: GalleryActions

    var body: some View {
        Button("Open") { actions.open(item) }
        Button("Quick Look") { actions.quickLook(item) }
        Button("Reveal in Finder") { actions.reveal(item) }
        Button("Copy") { actions.copy(item) }
        Divider()
        Button("Move to Trash") { actions.trash(item) }
    }
}

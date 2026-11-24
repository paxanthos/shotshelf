import AppKit
import Combine
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let library: ShotLibrary
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let chip = DragChipView(frame: .zero)
    private let galleryModel = GalleryModel()
    private var bag = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var recentThumb: NSImage?
    private var popoverIsOpen = false
    private var copyHotKey: HotKey?
    private var flashUntil: Date?
    private var draggedItem: ShotItem?

    init(library: ShotLibrary) {
        self.library = library
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarIcon.idle()
            button.imagePosition = .imageOnly
            button.title = ""
            chip.controller = self
            chip.frame = button.bounds
            chip.autoresizingMask = [.width, .height]
            button.addSubview(chip)
            button.toolTip = "ShotShelf"
        }

        buildPopover()
        observeLibrary()
        refreshIcon()
        updateHotKey()

        Diagnostics.write([
            "statusItemButton": statusItem.button != nil,
            "statusItemFrame": statusItem.button.map { NSStringFromRect($0.frame) } ?? "-",
            "popoverReady": popover.contentViewController != nil
        ])
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }

        if let until = flashUntil, until > Date() {
            button.image = MenuBarIcon.copied()
        } else if let recent = library.recent {
            button.image = MenuBarIcon.compose(thumb: recentThumb, progress: library.recentProgress)
            button.toolTip = "\(recent.name) — drag it out, or click for the shelf"
        } else {
            button.image = MenuBarIcon.idle()
            button.toolTip = "ShotShelf"
        }

        // Keep the drag surface on top and matched to the button.
        if chip.superview !== button {
            button.addSubview(chip)
        } else {
            button.addSubview(chip, positioned: .above, relativeTo: nil)
        }
        chip.frame = button.bounds
    }

    private func observeLibrary() {
        library.$recent
            .removeDuplicates()
            .sink { [weak self] item in
                guard let self else { return }
                self.recentThumb = nil
                self.refreshIcon()
                guard let item else { return }
                Task { @MainActor in
                    let thumb = await ThumbnailCache.shared.image(for: item, maxPixel: 96)
                    if self.library.recent?.id == item.id {
                        self.recentThumb = thumb
                        self.refreshIcon()
                    }
                }
            }
            .store(in: &bag)

        library.$recentProgress
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &bag)

        // While Quick Look is up, it follows the pointer across thumbnails.
        galleryModel.$hovering
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self, QuickLook.shared.isVisible, let id,
                      let item = self.library.items.first(where: { $0.id == id }) else { return }
                QuickLook.shared.show(item.url)
            }
            .store(in: &bag)
    }

    // MARK: - Popover

    private func buildPopover() {
        let actions = GalleryActions(
            open: { [weak self] item in self?.open(item) },
            reveal: { [weak self] item in self?.reveal(item) },
            trash: { [weak self] item in self?.moveToTrash(item) },
            copy: { [weak self] item in self?.copy(item) },
            quickLook: { item in QuickLook.shared.show(item.url) },
            addFolder: { [weak self] in self?.chooseFolder() },
            removeFolder: { [weak self] url in self?.library.removeFolder(url) },
            openFolder: { url in NSWorkspace.shared.open(url) },
            close: { [weak self] in self?.closePopover() },
            requestAccess: { [weak self] folder in self?.requestAccess(to: folder) },
            openPrivacySettings: {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
                NSWorkspace.shared.open(url)
            }
        )
        let root = GalleryView(library: library, textIndex: library.textIndex, model: galleryModel, actions: actions)
        let host = NSHostingController(rootView: root)
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 396, height: 520)
        popover.behavior = .applicationDefined   // we close it ourselves so drags survive
        popover.animates = false
        popover.delegate = self
    }

    func togglePopover() {
        popoverIsOpen ? closePopover() : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        galleryModel.reset()
        library.rescanNow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverIsOpen = true
        popover.contentViewController?.view.window?.makeKey()
        installOutsideMonitor()
    }

    private func closePopover() {
        QuickLook.shared.close()
        popover.performClose(nil)
        popoverIsOpen = false
        removeOutsideMonitor()
    }

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Only fires for events delivered to *other* apps; our own clicks are ignored.
            self?.closePopover()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let quickLookUp = QuickLook.shared.isVisible
            switch Int(event.keyCode) {
            case kVK_Escape:
                if quickLookUp { QuickLook.shared.close() } else { self.closePopover() }
                return nil
            case kVK_Space:
                if quickLookUp {
                    QuickLook.shared.close()
                    return nil
                }
                // Space types into the search field once a query is under way.
                let typing = NSApp.keyWindow?.firstResponder is NSText && !self.galleryModel.query.isEmpty
                if !typing, let id = self.galleryModel.hovering,
                   let item = self.library.items.first(where: { $0.id == id }) {
                    QuickLook.shared.show(item.url)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeOutsideMonitor() {
        if let monitor = outsideMonitor {
            NSEvent.removeMonitor(monitor)
            outsideMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverIsOpen = false
        removeOutsideMonitor()
    }

    // MARK: - Drag out of the menu bar

    /// The icon always drags the newest image — the live chip just makes it visible.
    func beginDrag(mouseDown: NSEvent, dragEvent: NSEvent, from view: DragChipView) {
        guard let item = library.recent ?? library.items.first else { return }
        draggedItem = item
        let liveThumb = library.recent?.id == item.id ? recentThumb : nil
        let dragImage = liveThumb
            ?? ThumbnailCache.render(url: item.url, maxPixel: 192)
            ?? NSWorkspace.shared.icon(forFile: item.url.path)

        let sourceSize = dragImage.size
        let width: CGFloat = 96
        let height = sourceSize.width > 0 ? max(48, min(140, width * sourceSize.height / sourceSize.width)) : 96
        let point = view.convert(dragEvent.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)

        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        draggingItem.setDraggingFrame(frame, contents: dragImage)

        // AppKit requires the originating mouse-down event, not the drag event.
        let session = view.beginDraggingSession(with: [draggingItem], event: mouseDown, source: view)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func dragDidFinish() {
        // "Once I click and drag, the latest populated finally goes away."
        if let dragged = draggedItem, library.recent?.id == dragged.id {
            library.consumeRecent()
        }
        draggedItem = nil
    }

    // MARK: - Copy latest (⌃⌥⌘C)

    private func updateHotKey() {
        copyHotKey = nil
        guard library.copyShortcut else { return }
        copyHotKey = HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
            self?.copyLatest()
        }
    }

    private func copyLatest() {
        guard let item = library.recent ?? library.items.first else {
            NSSound.beep()
            return
        }
        copy(item)
    }

    /// Brief checkmark in the menu bar so a copy from the keyboard is visible.
    private func flashCopied() {
        let until = Date().addingTimeInterval(0.9)
        flashUntil = until
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            guard let self, self.flashUntil == until else { return }
            self.flashUntil = nil
            self.refreshIcon()
        }
    }

    // MARK: - Item actions

    private func open(_ item: ShotItem) {
        NSWorkspace.shared.open(item.url)
    }

    private func reveal(_ item: ShotItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func copy(_ item: ShotItem) {
        if Clipboard.copy(item.url) {
            flashCopied()
        } else {
            NSSound.beep()
        }
    }

    private func moveToTrash(_ item: ShotItem) {
        NSWorkspace.shared.recycle([item.url]) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.library.rescanNow()
        }
    }

    /// Opens a panel *inside* the blocked folder: picking it grants access without TCC.
    private func requestAccess(to folder: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Use This Folder"
        panel.message = "Select the folder ShotShelf should watch."
        if panel.runModal() == .OK, let url = panel.url {
            library.addFolder(url)
            library.rescanNow()
        }
    }

    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders whose images should appear in the shelf."
        if panel.runModal() == .OK {
            for url in panel.urls { library.addFolder(url) }
        }
    }

    // MARK: - Right-click menu

    func showContextMenu(event: NSEvent, from view: NSView) {
        let menu = NSMenu()

        let copyLatestItem = item("Copy Latest Screenshot", #selector(menuCopyLatest))
        if library.copyShortcut {
            copyLatestItem.keyEquivalent = "c"
            copyLatestItem.keyEquivalentModifierMask = [.command, .option, .control]
        }
        copyLatestItem.isEnabled = library.recent != nil || !library.items.isEmpty
        menu.addItem(copyLatestItem)

        menu.addItem(item("Open \(library.folders.first?.lastPathComponent ?? "Screenshot") Folder", #selector(menuOpenFolder)))
        menu.addItem(item("Add Folder…", #selector(menuAddFolder)))

        menu.addItem(.separator())

        // macOS's own screenshot settings, one level down.
        let header = NSMenuItem(title: "macOS Screenshots", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let saveTo = NSMenuItem(title: "Save To", action: nil, keyEquivalent: "")
        saveTo.submenu = saveLocationMenu()
        menu.addItem(saveTo)

        let format = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        let formats = NSMenu()
        let current = ScreenshotSettings.fileType()
        for type in ScreenshotSettings.fileTypes {
            let entry = item(type.label, #selector(menuSetFileType(_:)))
            entry.representedObject = type.id
            entry.state = type.id == current ? .on : .off
            formats.addItem(entry)
        }
        format.submenu = formats
        menu.addItem(format)

        let preview = item("Floating Thumbnail", #selector(menuToggleSystemPreview))
        preview.state = ScreenshotSettings.showsFloatingThumbnail() ? .on : .off
        menu.addItem(preview)

        menu.addItem(.separator())

        let expiryItem = NSMenuItem(title: "Latest Chip Lasts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in [15.0, 30.0, 60.0, 120.0, 300.0] {
            let title = seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds >= 120 ? "s" : "")"
            let entry = item(title, #selector(menuSetExpiry(_:)))
            entry.representedObject = seconds
            entry.state = abs(library.expirySeconds - seconds) < 0.5 ? .on : .off
            submenu.addItem(entry)
        }
        expiryItem.submenu = submenu
        menu.addItem(expiryItem)

        let shortcut = item("Copy Shortcut ⌃⌥⌘C", #selector(menuToggleCopyShortcut))
        shortcut.state = library.copyShortcut ? .on : .off
        menu.addItem(shortcut)

        let login = item("Open at Login", #selector(menuToggleLogin))
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = item("Quit ShotShelf", #selector(menuQuit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func saveLocationMenu() -> NSMenu {
        let menu = NSMenu()
        let current = ScreenshotSettings.location().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        var choices = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true)
        ]
        if !choices.contains(where: { $0.standardizedFileURL == current }) {
            choices.insert(current, at: 0)
        }
        for folder in choices {
            let entry = item(folder.lastPathComponent, #selector(menuSetSaveLocation(_:)))
            entry.representedObject = folder
            entry.state = folder.standardizedFileURL == current ? .on : .off
            entry.toolTip = folder.path
            entry.image = NSWorkspace.shared.icon(forFile: folder.path)
            entry.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Other…", #selector(menuChooseSaveLocation)))
        return menu
    }

    @objc private func menuCopyLatest() {
        copyLatest()
    }

    @objc private func menuOpenFolder() {
        if let folder = library.folders.first { NSWorkspace.shared.open(folder) }
    }

    @objc private func menuAddFolder() {
        chooseFolder()
    }

    @objc private func menuSetSaveLocation(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        setSaveLocation(folder)
    }

    @objc private func menuChooseSaveLocation() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ScreenshotSettings.location()
        panel.prompt = "Save Screenshots Here"
        panel.message = "macOS will save new screenshots to this folder, and ShotShelf will watch it."
        if panel.runModal() == .OK, let url = panel.url {
            setSaveLocation(url)
        }
    }

    private func setSaveLocation(_ folder: URL) {
        let old = ScreenshotSettings.location()
        guard old.standardizedFileURL != folder.standardizedFileURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ScreenshotSettings.setLocation(folder)
        library.replaceFolder(old, with: folder)
    }

    @objc private func menuSetFileType(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ScreenshotSettings.setFileType(id)
    }

    @objc private func menuToggleSystemPreview() {
        ScreenshotSettings.setShowsFloatingThumbnail(!ScreenshotSettings.showsFloatingThumbnail())
    }

    @objc private func menuToggleCopyShortcut() {
        library.setCopyShortcut(!library.copyShortcut)
        updateHotKey()
    }

    @objc private func menuSetExpiry(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        library.setExpiry(seconds)
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func menuToggleLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("ShotShelf: login item change failed: \(error)")
            NSSound.beep()
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Drag surface on top of the status item

final class DragChipView: NSView, NSDraggingSource {
    weak var controller: StatusItemController?
    private var mouseDownPoint: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownEvent = event
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let start = mouseDownPoint, let down = mouseDownEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        didStartDrag = true
        controller?.beginDrag(mouseDown: down, dragEvent: event, from: self)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = didStartDrag
        mouseDownPoint = nil
        mouseDownEvent = nil
        didStartDrag = false
        if !wasDrag { controller?.togglePopover() }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, from: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { controller?.dragDidFinish() }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

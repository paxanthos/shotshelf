# ShotShelf

A menu bar shelf for screenshots, in the spirit of the late Screenie. macOS drops its floating
screenshot thumbnail after a couple of seconds; ShotShelf keeps the newest capture in the menu
bar so you can drag it somewhere useful, keeps every capture one click away in a scrollable
visual finder, and lets you search the **text inside** your screenshots.

```
shotshelf/
├── Sources/ShotShelf/       # app sources (AppKit + SwiftUI)
├── Resources/Info.plist     # LSUIElement menu bar app
├── tools/make-test-images.swift
├── build.sh                 # → dist/ShotShelf.app
└── dist/ShotShelf.app
```

## Behavior

**New capture → menu bar chip.** A file-system watcher on the screenshot folder promotes the
newest arrival to a "recent" chip: the menu bar icon becomes a live thumbnail of it with a
progress bar draining along the bottom edge. It clears when the timer runs out (default 60s,
right-click → *Latest Chip Lasts*) or as soon as you drag it out.

**Drag it out.** Press and drag the menu bar icon into any app that accepts files (Finder,
Slack, Mail, Figma, an upload field). The dragged payload is the file URL, so the receiving
app gets the real file, not a copy. This works even after the chip has expired: the icon
always drags the newest image.

**Search the text in your images.** Every image is OCR'd on-device with Vision, newest first,
in the background (the footer shows *reading text · N left*). The search field matches file
names and recognized text; each term must match. Matching thumbnails show the line that
matched. The first OCR after launch waits 15–40s while Vision loads its model; after that it
takes about 0.1s per image. Results are cached, so each file is read only once.

**Copy the latest: ⌃⌥⌘C.** A global shortcut copies the newest image to the clipboard, as
pixels and as the file. It pastes as an image in Messages, Notes, and Figma, and as the
file in Finder, Slack, and Mail. The menu bar icon flashes a checkmark. You can turn it off
from the right-click menu. Copy in the item menu does the same.

**Quick Look.** Hover a thumbnail and press Space. While the preview is open it follows the
pointer from thumbnail to thumbnail. Press Space or Esc to close it.

**macOS screenshot settings, from the menu bar.** Right-click → *macOS Screenshots* →
*Save To* (Desktop / Documents / Downloads / Pictures / Other…), *Format* (PNG, JPEG, HEIC,
PDF, TIFF, GIF, PSD), and *Floating Thumbnail*. These write `com.apple.screencapture`, the
same settings ⇧⌘5 → Options uses. Changing the save location also moves the shelf's watch
to the new folder.

**Click → shelf.** A popover with the LATEST card pinned on top (draggable, with a countdown)
and every image in the watched folders below, grouped by day, newest first. Filter by name,
double-click to open, right-click for Quick Look / Reveal / Copy / Trash.

**Any static visual asset.** Not just screenshots: png, jpg, jpeg, heic, heif, gif, webp, tif,
tiff, bmp, icns, avif, pdf, svg, psd. Add more folders with the `+` in the footer.

## Run it

```bash
git clone https://github.com/paxanthos/shotshelf.git
cd shotshelf
./build.sh
open dist/ShotShelf.app
```

Drag `dist/ShotShelf.app` to `/Applications` if you want it out of the build directory.
Right-click the menu bar icon → **Open at Login** to keep it running.

## First launch: one permission click

ShotShelf watches the folder macOS saves screenshots to (`com.apple.screencapture location`,
the Desktop by default). If that folder is inside a protected location such as `~/Documents`
or `~/Desktop`, macOS shows *"ShotShelf would like to access files in your … folder"*. Click
**Allow**. If it was dismissed, the popover shows a lock state with
**Choose Folder…** and **System Settings…** buttons.

Because the bundle is ad-hoc signed, a *rebuild* changes its code hash and macOS may ask again.

## Config

`~/Library/Application Support/ShotShelf/config.json`

```json
{
  "folders": ["/Users/you/Desktop"],
  "copyShortcut": true,
  "expirySeconds": 60,
  "hideSystemPreview": false
}
```

`~/Library/Application Support/ShotShelf/text-index.json` holds the OCR text, keyed by path +
modification time. Delete it to force a re-read.

`~/Library/Application Support/ShotShelf/status.json` is a live beacon (items found, newest
file, promoted/cleared events) — handy for checking behavior without watching the screen.

## License

MIT. See [LICENSE](LICENSE).

## Dev entry points

```bash
dist/ShotShelf.app/Contents/MacOS/ShotShelf --probe                  # list what the shelf sees
dist/ShotShelf.app/Contents/MacOS/ShotShelf --render /tmp/g.png      # render the popover to PNG
dist/ShotShelf.app/Contents/MacOS/ShotShelf --render /tmp/g.png --light
dist/ShotShelf.app/Contents/MacOS/ShotShelf --render /tmp/g.png --query "invoice"   # search UI (OCRs synchronously)
dist/ShotShelf.app/Contents/MacOS/ShotShelf --ocr ~/Desktop/a.png ~/Desktop/b.png     # text search sees, timing on stderr
swift tools/make-test-images.swift ~/some/folder                     # synthetic test images
```

`--render` exists because this project builds with Command Line Tools only. Note that
**SwiftUI's `@State`/`@Observable` macros ship with Xcode, not CLT** — the UI therefore keeps
all mutable state in `GalleryModel` (`ObservableObject` + `@Published`), which compiles fine.
Keep it that way unless you install Xcode.

## How the drag works

`DragChipView` sits on top of the `NSStatusItem` button and hit-tests everything. `mouseDown`
records the event, `mouseDragged` past a 4pt threshold starts an `NSDraggingSession` with the
file URL as the pasteboard writer — and passes the **mouse-down** event, which AppKit requires.
`mouseUp` without a drag opens the popover instead. When the session ends with a real drop,
`dragDidFinish()` consumes the chip.

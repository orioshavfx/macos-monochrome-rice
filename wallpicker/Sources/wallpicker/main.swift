import AppKit
import ImageIO
import QuartzCore

// wallpicker: a full-screen carousel of the pictures in ~/Pictures/Wallpapers.
// Left and Right move through them. Return writes the picture into the macOS
// wallpaper store for every display and every Space, then restarts
// WallpaperAgent. Escape closes without changing anything.

/// Previews and backdrop in greys, to match the monochrome rice. Set to false for colour.
let greyscale = true

let homeFolder = FileManager.default.homeDirectoryForCurrentUser
let picturesFolder = homeFolder.appendingPathComponent("Pictures/Wallpapers", isDirectory: true)
let wallpaperStore = homeFolder.appendingPathComponent(
    "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
let backupFolder = homeFolder.appendingPathComponent(".local/state/monochrome-macos-rice/wallpaper-backup", isDirectory: true)
let imageProvider = "com.apple.wallpaper.choice.image"
let pictureTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp"]

func wallpaperFiles() -> [URL] {
    try? FileManager.default.createDirectory(at: picturesFolder, withIntermediateDirectories: true)
    let items = (try? FileManager.default.contentsOfDirectory(at: picturesFolder, includingPropertiesForKeys: nil)) ?? []
    return items
        .filter { pictureTypes.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// A downscaled copy of the picture, in greys when `greyscale` is set.
func loadPicture(_ url: URL, maxSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    guard greyscale,
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage() ?? image
}

enum StoreError: Error, CustomStringConvertible {
    case unreadable(String)

    var description: String {
        switch self {
        case .unreadable(let why): return why
        }
    }
}

/// Points every image choice in the store at `url`. Each choice keeps its
/// other settings. Returns the new tree and how many choices changed.
func pointImageChoices(_ node: Any, at url: String, changed: inout Int) -> Any {
    if var dict = node as? [String: Any] {
        if let choices = dict["Choices"] as? [[String: Any]] {
            dict["Choices"] = choices.map { choice -> [String: Any] in
                var choice = choice
                guard (choice["Provider"] as? String) == imageProvider,
                      let blob = choice["Configuration"] as? Data,
                      var configuration = (try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil)) as? [String: Any],
                      var image = configuration["url"] as? [String: Any]
                else { return choice }
                image["relative"] = url
                configuration["url"] = image
                guard let newBlob = try? PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0) else {
                    return choice
                }
                choice["Configuration"] = newBlob
                changed += 1
                return choice
            }
        }
        for (key, value) in dict where key != "Choices" {
            dict[key] = pointImageChoices(value, at: url, changed: &changed)
        }
        return dict
    }
    if let array = node as? [Any] {
        return array.map { pointImageChoices($0, at: url, changed: &changed) }
    }
    return node
}

/// Writes the picture into the wallpaper store for every Space and display,
/// keeping a timestamped backup of the store first, then restarts WallpaperAgent.
func applyWallpaper(_ picture: URL) throws {
    let data = try Data(contentsOf: wallpaperStore)
    guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        throw StoreError.unreadable("the wallpaper store is not a dictionary")
    }

    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    try FileManager.default.copyItem(at: wallpaperStore, to: backupFolder.appendingPathComponent("Index.plist.\(stamp)"))

    var changed = 0
    let updated = pointImageChoices(root, at: picture.absoluteString, changed: &changed)
    guard changed > 0, let updatedRoot = updated as? [String: Any] else {
        throw StoreError.unreadable("no image choices found in the store")
    }
    let out = try PropertyListSerialization.data(fromPropertyList: updatedRoot, format: .binary, options: 0)
    try out.write(to: wallpaperStore)

    let killall = Process()
    killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    killall.arguments = ["WallpaperAgent"]
    try? killall.run()
    killall.waitUntilExit()
}

/// A borderless window can only take keys if it says it can become key.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class CarouselView: NSView {
    private let files: [URL]
    private var index = 0
    private var cards: [CALayer] = []
    private var previews: [CGImage?] = []
    private var backdropCache: [Int: CGImage] = [:]
    private let backdrop = CALayer()
    private let shade = CALayer()
    private let caption = CATextLayer()
    /// How much each card leans, as a shear. Larger leans more.
    private let lean: CGFloat = 0.4

    init(frame: NSRect, files: [URL]) {
        self.files = files
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        shade.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.addSublayer(backdrop)
        layer?.addSublayer(shade)

        previews = files.map { loadPicture($0, maxSize: 900) }
        for preview in previews {
            let card = CALayer()
            card.contentsGravity = .resizeAspectFill
            card.masksToBounds = true
            card.borderColor = NSColor.white.cgColor
            card.contents = preview
            layer?.addSublayer(card)
            cards.append(card)
        }

        caption.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        caption.fontSize = 14
        caption.foregroundColor = NSColor.white.cgColor
        caption.alignmentMode = .center
        caption.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(caption)

        if files.isEmpty {
            caption.string = "No pictures in ~/Pictures/Wallpapers. Press Escape."
        } else {
            showBackdrop()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        layoutCards(animated: false)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: move(-1)            // left arrow
        case 124: move(1)             // right arrow
        case 36, 76: apply()          // return, keypad enter
        case 49: apply()              // space
        case 53: NSApp.terminate(nil) // escape
        default: super.keyDown(with: event)
        }
    }

    private func move(_ step: Int) {
        guard !files.isEmpty else { return }
        index = (index + step + files.count) % files.count
        showBackdrop()
        layoutCards(animated: true)
    }

    private func showBackdrop() {
        if backdropCache[index] == nil {
            backdropCache[index] = loadPicture(files[index], maxSize: 1920)
        }
        backdrop.contents = backdropCache[index]
        caption.string = files[index].lastPathComponent
    }

    private func apply() {
        guard !files.isEmpty else { return }
        do {
            try applyWallpaper(files[index])
            NSApp.terminate(nil)
        } catch {
            caption.string = "Not changed: \(error)"
        }
    }

    private func layoutCards(animated: Bool) {
        let bounds = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        backdrop.frame = bounds
        shade.frame = bounds

        let cardHeight = bounds.height * 0.42
        let cardWidth = cardHeight * 16 / 9
        let spacing = cardWidth * 0.62
        for (i, card) in cards.enumerated() {
            let offset = i - index
            let distance = CGFloat(abs(offset))
            let scale: CGFloat = offset == 0 ? 1 : max(0.55, 1 - 0.16 * distance)
            card.bounds = CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
            card.position = CGPoint(x: bounds.midX + CGFloat(offset) * spacing, y: bounds.midY)
            card.setAffineTransform(CGAffineTransform(a: scale, b: 0, c: lean * scale, d: scale, tx: 0, ty: 0))
            card.opacity = offset == 0 ? 1 : Float(max(0.35, 0.85 - 0.2 * Double(distance)))
            card.zPosition = -distance
            card.borderWidth = offset == 0 ? 2 : 0
        }

        caption.frame = CGRect(x: 0, y: 28, width: bounds.width, height: 22)
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: KeyWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }
        let win = KeyWindow(contentRect: screen.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false, screen: screen)
        win.level = .floating
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = CarouselView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                files: wallpaperFiles())
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

// Kept in a global so NSApplication (which holds its delegate weakly) does not lose it.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()

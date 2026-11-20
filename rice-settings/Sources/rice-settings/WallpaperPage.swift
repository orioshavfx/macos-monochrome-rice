import AppKit

/// Wallpaper: the folder that opt+w (wallpicker) shows and the accent colour of its carousel.
/// Both are saved to ~/.config/wallpicker/config.toml (see WallpickerConf); wallpicker reads them each time it opens.
final class WallpaperPage: NSView {
    /// File extensions wallpicker shows; the same list as in wallpicker's main.swift.
    private static let pictureExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp",
    ]

    private let folderDetail: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = "The folder opt+w shows"
        return label
    }()
    private let accentWell = ColorWell()
    private let accentHex = PageKit.valueLabel(width: 80)
    private let status = NSTextField(wrappingLabelWithString: "")
    /// The accent as it is in config.toml now ("#rrggbb").
    private var savedAccent: String

    init() {
        let stored = WallpickerConf.read("accent") ?? WallpickerConf.defaultAccent
        savedAccent = NSColor(hex: stored) != nil ? stored : WallpickerConf.defaultAccent
        super.init(frame: .zero)
        build()
        refreshFolder()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build() {
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder(_:)))
        let defaultButton = NSButton(title: "Default", target: self, action: #selector(useDefaultFolder(_:)))
        let folderCard = CardView(rows: [
            PageKit.settingRow("Folder", "", [defaultButton, chooseButton], detailLabel: folderDetail),
        ])

        accentWell.color = NSColor(hex: savedAccent) ?? .white
        accentWell.onChange = { [weak self] in self?.accentChanged() }
        accentWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        accentWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        accentHex.stringValue = savedAccent
        let accentCard = CardView(rows: [
            PageKit.settingRow("Accent colour",
                               "The border of the selected picture and its name. Takes effect the next time opt+w opens.",
                               [accentHex, accentWell]),
        ])

        let tabs = [
            PageTab(name: "Wallpaper",
                    subtitle: "~/.config/wallpicker/config.toml, read by opt+w each time it opens",
                    sections: [
                        PageKit.section("Folder",
                                        "Pictures opt+w shows, sorted by name. Choosing a folder does not copy or move anything.",
                                        [folderCard]),
                        PageKit.section("Carousel", "Colours of the carousel.", [accentCard]),
                    ]),
        ]
        status.stringValue = ""
        PageKit.embed(TabbedPageView(title: "Wallpaper", tabs: tabs, status: status), in: self)
    }

    // MARK: - Folder

    /// The folder as written in config.toml, or the default one.
    private var storedFolder: String {
        WallpickerConf.read("folder") ?? WallpickerConf.defaultFolder
    }

    /// Shows the folder with the number of pictures in it, or that it is missing.
    private func refreshFolder() {
        let path = (storedFolder as NSString).expandingTildeInPath
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            folderDetail.stringValue = "\(storedFolder) · folder not found"
            return
        }
        let count = items.filter { Self.pictureExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.count
        folderDetail.stringValue = "\(storedFolder) · \(count == 1 ? "1 picture" : "\(count) pictures")"
    }

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Pictures in this folder are shown by opt+w."
        panel.directoryURL = URL(fileURLWithPath: (storedFolder as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder((url.path as NSString).abbreviatingWithTildeInPath)
    }

    @objc private func useDefaultFolder(_ sender: Any?) {
        saveFolder(WallpickerConf.defaultFolder)
    }

    private func saveFolder(_ value: String) {
        do {
            let changed = try WallpickerConf.write("folder", value)
            status.stringValue = changed
                ? "Saved folder \(value). Takes effect the next time opt+w opens."
                : "The folder is already \(value). Nothing was written."
        } catch {
            status.stringValue = "Not saved: \(error.localizedDescription)"
        }
        refreshFolder()
    }

    // MARK: - Accent

    /// Called when the colour panel of the well closes: writes `accent = "#rrggbb"`.
    private func accentChanged() {
        let hex = accentWell.color.hexString
        if hex.lowercased() == savedAccent.lowercased() { return }
        do {
            if try WallpickerConf.write("accent", hex) {
                savedAccent = hex
                accentHex.stringValue = hex
                status.stringValue = "Saved accent \(hex). Takes effect the next time opt+w opens."
            }
        } catch {
            accentWell.color = NSColor(hex: savedAccent) ?? .white
            status.stringValue = "Could not save the accent colour: \(error.localizedDescription)"
        }
    }
}

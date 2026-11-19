import AppKit

/// fastfetch: whether fish runs fastfetch at start-up (the `fastfetch` line inside
/// `if status is-interactive` of ~/.config/fish/config.fish, toggled between `fastfetch` and `# fastfetch`),
/// a button that opens ~/.config/fastfetch/config.jsonc in the default app, and one checkbox per fastfetch
/// module that adds or removes it in the "modules" array of that file (see FastfetchConf).
final class FastfetchPage: NSView {
    private static let configPath = ".config/fastfetch/config.jsonc"
    private static let modulesHelp = "Each checkbox adds or removes one module in the modules array. "
        + "Only that array is rewritten; comments and other settings stay as they are. "
        + "The first save keeps a copy as config.jsonc" + ConfigFile.backupSuffix + "."

    private let fastfetchSwitch = ToggleView()
    private let openButton = NSButton(title: "Open fastfetch config", target: nil, action: nil)
    private let modulesNote = NSTextField(wrappingLabelWithString: "")
    private var moduleBoxes: [String: NSButton] = [:]
    /// The module checkboxes, opened with "Edit info lines".
    private var modulesDrawer: DrawerView?
    private let status = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        build()
        let problems = [loadFish(), loadModules()].compactMap { $0 }
        status.stringValue = problems.joined(separator: "\n")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build() {
        fastfetchSwitch.target = self
        fastfetchSwitch.action = #selector(fastfetchChanged(_:))
        openButton.target = self
        openButton.action = #selector(openConfig(_:))
        openButton.bezelStyle = .rounded
        modulesNote.stringValue = Self.modulesHelp

        let startupCard = CardView(rows: [
            PageKit.settingRow("Show fastfetch when a fish shell starts",
                               "Off = the line is commented out as # fastfetch; it is never deleted.",
                               [fastfetchSwitch]),
        ])
        let configCard = CardView(rows: [
            PageKit.settingRow("fastfetch config",
                               "Opens ~/" + Self.configPath + " in its default app. If the file does not exist, it is not created.",
                               [openButton]),
        ])
        let modulesCard = CardView(rows: [buildModuleGrid()])
        modulesDrawer = DrawerView(title: "Info lines", subtitle: "~/" + Self.configPath + " (the \"modules\" array)",
                                   sections: [PageKit.section("Modules", Self.modulesHelp, [modulesCard])])
        let editButton = NSButton(title: "Edit info lines", target: self, action: #selector(openModules(_:)))
        editButton.bezelStyle = .rounded
        let infoCard = CardView(rows: [
            PageKit.settingRow("Info lines", "", [editButton], detailLabel: modulesNote),
        ])

        let tabs = [
            PageTab(name: "Modules",
                    subtitle: "~/" + Self.configPath + " (the \"modules\" array)",
                    sections: [PageKit.section("Info lines", "One checkbox per fastfetch module.", [infoCard])]),
            PageTab(name: "Startup",
                    subtitle: "~/.config/fish/config.fish and ~/" + Self.configPath,
                    sections: [
                        PageKit.section("Start-up", "The fastfetch line in the if status is-interactive block.", [startupCard]),
                        PageKit.section("Config file", "", [configCard]),
                    ]),
        ]
        PageKit.embed(TabbedPageView(title: "fastfetch", tabs: tabs, status: status), in: self)
    }

    /// One checkbox per module, one under the other in fastfetch's order, with card padding.
    /// (One column: the drawer is about 60% of a quarter-screen window wide.)
    private func buildModuleGrid() -> NSView {
        var boxes: [NSButton] = []
        for module in FastfetchConf.modules {
            let box = NSButton(
                checkboxWithTitle: "\(module.label) (\(module.name))", target: self, action: #selector(moduleChanged(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(module.name)
            moduleBoxes[module.name] = box
            boxes.append(box)
        }
        let grid = NSGridView(views: boxes.map { [$0 as NSView] })
        grid.rowSpacing = 8
        grid.columnSpacing = 24
        grid.xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSView()
        holder.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: holder.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -14),
        ])
        return holder
    }

    // MARK: - fish start-up line

    /// Sets the switch from config.fish; returns a problem for the status line, or nil.
    private func loadFish() -> String? {
        let lines: [String]
        do {
            lines = try FishConf.file.readLines()
        } catch {
            fastfetchSwitch.isEnabled = false
            return "Could not read config.fish: \(error.localizedDescription)"
        }
        if let on = FishConf.fastfetchEnabled(in: lines) {
            fastfetchSwitch.state = on ? .on : .off
            return nil
        }
        fastfetchSwitch.isEnabled = false
        return "No fastfetch line found in the if status is-interactive block. The switch is disabled."
    }

    @objc private func fastfetchChanged(_ sender: Any?) {
        let on = fastfetchSwitch.state == .on
        do {
            if try FishConf.setFastfetch(on) {
                status.stringValue = on
                    ? "Saved: fastfetch runs when fish starts"
                    : "Saved: fastfetch is commented out in config.fish"
            }
        } catch {
            status.stringValue = "Could not save config.fish: \(error.localizedDescription)"
            if let lines = try? FishConf.file.readLines(), let actual = FishConf.fastfetchEnabled(in: lines) {
                fastfetchSwitch.state = actual ? .on : .off
            }
        }
    }

    // MARK: - fastfetch modules

    /// Sets every checkbox from the modules array of config.jsonc and lists any other strings of the array
    /// in the note. When the file cannot be read or the array cannot be parsed, all checkboxes are disabled
    /// and the problem is returned for the status line; nil means the checkboxes match the file.
    @discardableResult
    private func loadModules() -> String? {
        let block: FastfetchConf.Block
        do {
            let text = try FastfetchConf.file.readLines().joined(separator: "\n")
            block = try FastfetchConf.parse(text)
        } catch {
            for box in moduleBoxes.values {
                box.isEnabled = false
            }
            return "Module checkboxes are disabled: could not read the modules array of config.jsonc "
                + "(\(error.localizedDescription)). Nothing will be written."
        }
        for (name, box) in moduleBoxes {
            box.state = block.known.contains(name) ? .on : .off
            box.isEnabled = true
        }
        modulesNote.stringValue = block.unknown.isEmpty
            ? Self.modulesHelp
            : Self.modulesHelp + " Also in the array and kept at its end: " + block.unknown.joined(separator: ", ")
        return nil
    }

    @objc private func moduleChanged(_ sender: Any?) {
        guard let box = sender as? NSButton, let name = box.identifier?.rawValue else { return }
        let on = box.state == .on
        do {
            if try FastfetchConf.setModule(name, on) {
                status.stringValue = "Saved. Run fastfetch to see the change."
            }
            if let problem = loadModules() {
                status.stringValue = problem
            }
        } catch {
            let message = "Could not save config.jsonc: \(error.localizedDescription)"
            if let problem = loadModules() {
                status.stringValue = message + "\n" + problem
            } else {
                status.stringValue = message
            }
        }
    }

    @objc private func openModules(_ sender: Any?) {
        guard let host = window?.contentView else { return }
        modulesDrawer?.open(in: host)
    }

    // MARK: - fastfetch config

    @objc private func openConfig(_ sender: Any?) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Self.configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            status.stringValue = "~/\(Self.configPath) does not exist. Nothing was opened or created."
            return
        }
        if NSWorkspace.shared.open(url) {
            status.stringValue = "Opened ~/\(Self.configPath)"
        } else {
            status.stringValue = "Could not open ~/\(Self.configPath): no app is set to open .jsonc files."
        }
    }
}

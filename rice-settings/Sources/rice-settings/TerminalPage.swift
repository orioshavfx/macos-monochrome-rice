import AppKit

/// kitty: font_size, font_family, background_opacity, cursor_shape (kitty.conf) and the theme colours
/// (current-theme.conf, the file kitty.conf includes).
/// fish: alias names and adding an alias. The fastfetch start-up toggle lives on FastfetchPage.
final class TerminalPage: NSView {
    private static let cursorShapes = ["block", "beam", "underline"]

    /// Colour keys of current-theme.conf, in the order of the two colour cards.
    private static let interfaceColorKeys = [
        "foreground", "background", "cursor", "cursor_text_color",
        "selection_foreground", "selection_background", "url_color",
        "active_border_color", "inactive_border_color",
        "active_tab_foreground", "active_tab_background",
        "inactive_tab_foreground", "inactive_tab_background",
    ]
    private static let paletteColorKeys = (0...15).map { "color\($0)" }

    /// Short UI labels; the keys stay as they are in the file.
    private static let colorLabels: [String: String] = [
        "foreground": "Text",
        "background": "Background",
        "cursor": "Cursor",
        "cursor_text_color": "Text under cursor",
        "selection_foreground": "Selected text",
        "selection_background": "Selection",
        "url_color": "Link",
        "active_border_color": "Active border",
        "inactive_border_color": "Inactive border",
        "active_tab_foreground": "Active tab text",
        "active_tab_background": "Active tab",
        "inactive_tab_foreground": "Inactive tab text",
        "inactive_tab_background": "Inactive tab",
        "color0": "Black", "color8": "Bright black",
        "color1": "Red", "color9": "Bright red",
        "color2": "Green", "color10": "Bright green",
        "color3": "Yellow", "color11": "Bright yellow",
        "color4": "Blue", "color12": "Bright blue",
        "color5": "Magenta", "color13": "Bright magenta",
        "color6": "Cyan", "color14": "Bright cyan",
        "color7": "White", "color15": "Bright white",
    ]

    private let sizeSlider = NSSlider(value: 12, minValue: 8, maxValue: 32, target: nil, action: nil)
    private let sizeValue = PageKit.valueLabel()
    private let fontField = NSTextField(string: "")
    private let opacitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityValue = PageKit.valueLabel()
    private let cursorControl = CapsuleSegments(labels: ["Block", "Beam", "Underline"])
    private let aliasCard = CardView()
    private let newNameField = NSTextField(string: "")
    private let newCommandField = NSTextField(string: "")
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var shell: TabbedPageView?
    private var kittyCard: AppCard?
    private var fishCard: AppCard?
    /// The kitty colours (current-theme.conf), opened with "Edit colours" on the kitty card.
    private var colorDrawer: DrawerView?

    private var colorWells: [String: ColorWell] = [:]
    private var colorHexLabels: [String: NSTextField] = [:]
    /// Hex digits (without "#") as they are in current-theme.conf now; a key without an active line is absent.
    private var colorValues: [String: String] = [:]
    /// Alias lines in the `alias NAME='COMMAND'` form; index i belongs to the text field with tag i.
    private var aliases: [FishAlias] = []
    /// config.fish as it was when the alias list was last read; adding an alias needs the file unchanged.
    private var fishLines: [String] = []

    init() {
        super.init(frame: .zero)
        build()
        let problems = [loadKitty(), loadColors(), loadFish()].compactMap { $0 }
        status.stringValue = problems.joined(separator: "\n")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build() {
        for slider in [sizeSlider, opacitySlider] {
            slider.target = self
            slider.action = #selector(kittyChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        fontField.font = .systemFont(ofSize: 13)
        fontField.placeholderString = "Hasklug Nerd Font"
        fontField.target = self
        fontField.action = #selector(kittyChanged(_:))
        fontField.cell?.sendsActionOnEndEditing = true
        fontField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        cursorControl.target = self
        cursorControl.action = #selector(kittyChanged(_:))

        let kittySettings = CardView(rows: [
            PageKit.settingRow("Font size", "font_size", [sizeSlider, sizeValue]),
            PageKit.settingRow("Font", "font_family", [fontField]),
            PageKit.settingRow("Background opacity", "background_opacity", [opacitySlider, opacityValue]),
            PageKit.settingRow("Cursor shape", "cursor_shape", [cursorControl]),
        ])
        let interfaceCard = CardView(rows: Self.interfaceColorKeys.map { colorRow($0) })
        let paletteCard = CardView(rows: Self.paletteColorKeys.map { colorRow($0) })

        newNameField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        newNameField.placeholderString = "name"
        newNameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        newCommandField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        newCommandField.placeholderString = "command, e.g. git status"
        newCommandField.target = self
        newCommandField.action = #selector(addAlias(_:))
        // Return adds; leaving the field does not.
        newCommandField.cell?.sendsActionOnEndEditing = false
        newCommandField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        newCommandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addButton.target = self
        addButton.action = #selector(addAlias(_:))
        addButton.bezelStyle = .rounded
        let addFields = NSStackView()
        addFields.orientation = .horizontal
        addFields.alignment = .centerY
        addFields.spacing = 10
        addFields.distribution = .fill
        addFields.setViews([newNameField, newCommandField], in: .leading)
        let addCard = CardView(rows: [PageKit.row(left: addFields, controls: [addButton])])

        // The colours are opened from a row in the kitty settings below, not from the card.
        let editColors = NSButton(title: "Edit colours", target: self, action: #selector(openColors(_:)))
        editColors.bezelStyle = .rounded
        editColors.controlSize = .small
        let colourCard = CardView(rows: [
            PageKit.settingRow("Colours", "Interface colours and the 16-colour terminal palette.", [editColors],
                               symbol: "paintpalette"),
        ])
        let kitty = AppCard(name: "kitty", detail: "GPU-accelerated terminal with splits",
                            appIcon: Self.kittyIcon(), symbol: "terminal")
        let fish = AppCard(name: "fish", detail: "Friendly shell with suggestions and colors",
                           appIcon: nil, symbol: "chevron.right.circle")
        kitty.onClick = { [weak self] in self?.shell?.selectTab(0) }
        fish.onClick = { [weak self] in self?.shell?.selectTab(1) }
        kittyCard = kitty
        fishCard = fish
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.setViews([kitty, fish], in: .leading)

        let tabs = [
            PageTab(name: "kitty",
                    subtitle: "~/.config/kitty/kitty.conf and ~/.config/kitty/current-theme.conf",
                    sections: [
                        PageKit.section("Font and window",
                                        "kitty.conf. To see changes, reload the kitty config: ctrl+cmd+, or kill -SIGUSR1 <kitty pid>.",
                                        [kittySettings]),
                        PageKit.section("Colours",
                                        "current-theme.conf. Applies after kitty reloads (ctrl+cmd+, or new window).",
                                        [colourCard]),
                    ]),
            PageTab(name: "fish",
                    subtitle: "~/.config/fish/config.fish",
                    sections: [
                        PageKit.section("Aliases",
                                        "Only the alias name can be changed. Press Return to save. Applies in new fish shells.",
                                        [aliasCard]),
                        PageKit.section("Add alias",
                                        "Written as alias NAME='COMMAND' after the last alias line. Name: letters, digits, _ and -. "
                                            + "The command must not contain ' or line breaks. Press Return or Add.",
                                        [addCard]),
                    ]),
        ]
        colorDrawer = DrawerView(
            title: "kitty colours",
            subtitle: "~/.config/kitty/current-theme.conf. Applies after kitty reloads (ctrl+cmd+, or new window).",
            sections: [
                PageKit.section("Interface colors", "", [interfaceCard]),
                PageKit.section("Terminal palette", "The 16 terminal colors.", [paletteCard]),
            ])

        // The kitty and fish cards are the only switch between the two parts of the page.
        let page = TabbedPageView(title: "Terminal", tabs: tabs, accessory: cards, status: status, showsTabBar: false)
        page.onSelect = { [weak self] index in
            self?.kittyCard?.isSelected = index == 0
            self?.fishCard?.isSelected = index == 1
        }
        shell = page
        kitty.isSelected = page.selectedIndex == 0
        fish.isSelected = page.selectedIndex == 1
        PageKit.embed(page, in: self)
    }

    /// "Edit colours": shows kitty's part of the page and opens the colour drawer over the window.
    @objc private func openColors(_ sender: Any?) {
        shell?.selectTab(0)
        guard let host = window?.contentView else { return }
        colorDrawer?.open(in: host)
    }

    /// The kitty app icon when kitty is installed as an app; nil otherwise (the card then shows an SF Symbol).
    private static func kittyIcon() -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.kovidgoyal.kitty") else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// One colour: the label, the hex value (or why the well is disabled) under it, the well on the right.
    private func colorRow(_ key: String) -> NSView {
        let well = ColorWell()
        well.toolTip = key
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        well.onChange = { [weak self] in self?.colorChanged(key) }
        colorWells[key] = well

        let hex = NSTextField(wrappingLabelWithString: "")
        colorHexLabels[key] = hex
        let row = PageKit.settingRow(Self.colorLabels[key] ?? key, "", [well], detailLabel: hex)
        hex.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return row
    }

    /// One alias: the editable name on the left, "runs: COMMAND" (read only) next to it.
    private func aliasRow(_ index: Int, _ alias: FishAlias) -> NSView {
        let field = NSTextField(string: alias.name)
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.tag = index
        field.target = self
        field.action = #selector(aliasChanged(_:))
        field.cell?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let runs = NSTextField(labelWithString: "runs: \(alias.command)")
        runs.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        runs.textColor = .secondaryLabelColor
        runs.lineBreakMode = .byTruncatingTail
        runs.toolTip = alias.command
        runs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let left = NSStackView()
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 10
        left.distribution = .fill
        left.setViews([field, runs], in: .leading)
        return PageKit.row(left: left, controls: [])
    }

    // MARK: - Reading

    /// Sets the kitty controls from kitty.conf; returns a problem for the status line, or nil.
    private func loadKitty() -> String? {
        let lines: [String]
        do {
            lines = try KittyConf.file.readLines()
        } catch {
            for c in [sizeSlider, opacitySlider, fontField] as [NSControl] { c.isEnabled = false }
            cursorControl.isEnabled = false
            sizeValue.stringValue = "—"
            opacityValue.stringValue = "—"
            return "Could not read kitty.conf: \(error.localizedDescription)"
        }
        var missing: [String] = []

        if let v = KittyConf.read("font_size", in: lines)?.value, let n = Double(v) {
            sizeSlider.doubleValue = n
            sizeValue.stringValue = Self.formatSize(n)
        } else {
            sizeSlider.isEnabled = false
            sizeValue.stringValue = "—"
            missing.append("font_size")
        }

        if let v = KittyConf.read("font_family", in: lines)?.value {
            fontField.stringValue = v
        } else {
            fontField.isEnabled = false
            fontField.placeholderString = "not found"
            missing.append("font_family")
        }

        if let v = KittyConf.read("background_opacity", in: lines)?.value, let n = Double(v), (0...1).contains(n) {
            opacitySlider.doubleValue = n
            opacityValue.stringValue = Self.formatOpacity(n)
        } else {
            opacitySlider.isEnabled = false
            opacityValue.stringValue = "—"
            missing.append("background_opacity")
        }

        if let v = KittyConf.read("cursor_shape", in: lines)?.value,
           let i = Self.cursorShapes.firstIndex(of: v) {
            cursorControl.selectedSegment = i
        } else {
            cursorControl.isEnabled = false
            missing.append("cursor_shape")
        }

        if !missing.isEmpty {
            return "Not found or not recognized in kitty.conf: \(missing.joined(separator: ", ")). These fields are not changed."
        }
        return nil
    }

    /// Sets every colour well from current-theme.conf. A key without an active `key #rrggbb` line
    /// gets a disabled well and "not set in current-theme.conf". Returns a problem for the status line, or nil.
    private func loadColors() -> String? {
        colorValues = [:]
        let lines: [String]
        do {
            lines = try KittyTheme.file.readLines()
        } catch {
            for well in colorWells.values { well.isEnabled = false }
            for label in colorHexLabels.values { label.stringValue = "—" }
            return "Could not read current-theme.conf: \(error.localizedDescription)"
        }
        for key in KittyTheme.keys {
            guard let well = colorWells[key], let label = colorHexLabels[key] else { continue }
            if let hex = KittyTheme.read(key, in: lines), let color = NSColor(hex: hex) {
                colorValues[key] = hex
                well.color = color
                well.isEnabled = true
                label.stringValue = "#" + hex
            } else {
                well.isEnabled = false
                label.stringValue = "not set in current-theme.conf"
            }
        }
        return nil
    }

    /// Rebuilds the alias card from config.fish and keeps the lines for addAlias.
    /// Returns a problem for the status line, or nil.
    @discardableResult
    private func loadFish() -> String? {
        aliases = []
        let lines: [String]
        do {
            lines = try FishConf.file.readLines()
        } catch {
            fishLines = []
            aliasCard.setRows([PageKit.settingRow("—", "", [])])
            newNameField.isEnabled = false
            newCommandField.isEnabled = false
            addButton.isEnabled = false
            return "Could not read config.fish: \(error.localizedDescription)"
        }
        fishLines = lines
        newNameField.isEnabled = true
        newCommandField.isEnabled = true
        addButton.isEnabled = true
        aliases = FishConf.aliasEntries(in: lines)
        var rows: [NSView] = aliases.enumerated().map { aliasRow($0.offset, $0.element) }
        for line in FishConf.otherAliasLines(in: lines) {
            let detail = NSTextField(wrappingLabelWithString: line)
            let row = PageKit.settingRow("Not editable", "", [], detailLabel: detail)
            detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            rows.append(row)
        }
        if rows.isEmpty {
            rows.append(PageKit.settingRow("No aliases found", "", []))
        }
        aliasCard.setRows(rows)
        return nil
    }

    // MARK: - Writing

    private static func formatSize(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func formatOpacity(_ v: Double) -> String { String(format: "%.2f", v) }

    @objc private func kittyChanged(_ sender: Any?) {
        let key: String
        let value: String
        if let s = sender as? NSSlider, s === sizeSlider {
            let v = (s.doubleValue * 2).rounded() / 2
            sizeValue.stringValue = Self.formatSize(v)
            key = "font_size"
            value = Self.formatSize(v)
        } else if let s = sender as? NSSlider, s === opacitySlider {
            let v = (s.doubleValue * 20).rounded() / 20
            opacityValue.stringValue = Self.formatOpacity(v)
            key = "background_opacity"
            value = Self.formatOpacity(v)
        } else if let f = sender as? NSTextField, f === fontField {
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else {
                status.stringValue = "An empty font name is not saved."
                return
            }
            key = "font_family"
            value = v
        } else if let c = sender as? CapsuleSegments, c === cursorControl {
            let i = c.selectedSegment
            guard Self.cursorShapes.indices.contains(i) else { return }
            key = "cursor_shape"
            value = Self.cursorShapes[i]
        } else {
            return
        }
        do {
            if try KittyConf.write(key, value) {
                status.stringValue = "Saved: \(key) \(value) in ~/.config/kitty/kitty.conf"
            }
        } catch {
            status.stringValue = "Could not save \(key): \(error.localizedDescription)"
        }
    }

    /// Called when the colour panel of a well closes: rewrites only the hex of that key's line.
    private func colorChanged(_ key: String) {
        guard let well = colorWells[key], let current = colorValues[key] else { return }
        let hex = String(well.color.hexString.dropFirst())
        if hex.lowercased() == current.lowercased() { return }
        do {
            if try KittyTheme.write(key, hex) {
                let lines = try KittyTheme.file.readLines()
                let written = KittyTheme.read(key, in: lines) ?? hex
                colorValues[key] = written
                colorHexLabels[key]?.stringValue = "#" + written
                status.stringValue = "Saved: \(key) #\(written). Applies after kitty reloads (ctrl+cmd+, or new window)."
            }
        } catch {
            well.color = NSColor(hex: current) ?? well.color
            status.stringValue = "Could not save \(key): \(error.localizedDescription)"
        }
    }

    @objc private func aliasChanged(_ sender: NSTextField) {
        let index = sender.tag
        guard aliases.indices.contains(index) else { return }
        let alias = aliases[index]
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if text == alias.name {
            sender.stringValue = alias.name
            return
        }
        do {
            if try FishConf.renameAlias(line: alias.line, from: alias.name, to: text) {
                aliases[index] = FishAlias(line: alias.line, name: text, command: alias.command)
                sender.stringValue = text
                // The app changed the file itself: keep the copy addAlias compares against current.
                if let lines = try? FishConf.file.readLines() { fishLines = lines }
                status.stringValue = "Saved: alias \(text) runs \(alias.command). Applies in new fish shells."
            }
        } catch {
            sender.stringValue = alias.name
            status.stringValue = "Not saved: \(error.localizedDescription)"
        }
    }

    /// Add button or Return in the command field: checks the name and command and inserts one
    /// alias line into config.fish (see FishConf.addAlias). Nothing is written on any problem.
    @objc private func addAlias(_ sender: Any?) {
        let name = newNameField.stringValue
        let command = newCommandField.stringValue
        do {
            let added = try FishConf.addAlias(name: name, command: command, expecting: fishLines)
            newNameField.stringValue = ""
            newCommandField.stringValue = ""
            let problem = loadFish()
            status.stringValue = "Added alias \(added). Applies in new fish shells."
                + (problem.map { "\n" + $0 } ?? "")
        } catch {
            var message = "Not added: \(error.localizedDescription)"
            // When the file changed since it was read, show it as it is now; the fields keep the input.
            if let current = try? FishConf.file.readLines(), current != fishLines {
                loadFish()
                message += " The alias list was read again; check it and press Add again."
            }
            status.stringValue = message
        }
    }
}

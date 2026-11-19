import AppKit

/// cberry (cranberry): settings from ~/.config/cranberry/cberryrc and the key combos of its binds.
/// Each change replaces the value in the existing `cberry config <key> ...` line (or only the combo of a
/// `cberry bind '...'` line), then runs `cberry reload`.
final class CberryPage: NSView {
    private static let modifiers = ["alt", "cmd", "ctrl", "shift", "fn", "off"]
    /// Spellings of on/off that cberry accepts; the one already in the file is kept.
    private static let onOffWords: [(on: String, off: String)] = [
        ("on", "off"), ("true", "false"), ("yes", "no"), ("1", "0"),
    ]

    private let gapField = NSTextField(string: "")
    private let paddingField = NSTextField(string: "")
    private let splitSlider = NSSlider(value: 0.5, minValue: 0.1, maxValue: 0.9, target: nil, action: nil)
    private let splitValue = PageKit.valueLabel()
    private let stepSlider = NSSlider(value: 0.05, minValue: 0.01, maxValue: 0.5, target: nil, action: nil)
    private let stepValue = PageKit.valueLabel()
    private let borderControl = ToggleView()
    private let borderWell = ColorWell()
    private let borderHex = PageKit.valueLabel(width: 80)
    private let focusControl = ToggleView()
    private let modifierControl = CapsuleSegments(labels: CberryPage.modifiers)
    private let bindCard = CardView()
    private let status = NSTextField(wrappingLabelWithString: "")

    /// Values as they are written in the file now; a key without an active line is absent.
    private var values: [String: String] = [:]
    /// Single-quoted bind lines; index i belongs to bindFields[i] and bindButtons[i].
    private var bindEntries: [CberryBind] = []
    /// Bind lines in any other form, shown read only.
    private var otherBinds: [String] = []
    private var bindFields: [NSTextField] = []
    private var bindButtons: [NSButton] = []
    /// The local key-down monitor while a combo is being recorded, and the bind it is for.
    private var keyMonitor: Any?
    private var recordingIndex: Int?
    private var readError: String?

    init() {
        super.init(frame: .zero)
        load()
        build()
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build() {
        for field in [gapField, paddingField] {
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.target = self
            field.action = #selector(valueChanged(_:))
            field.cell?.sendsActionOnEndEditing = true
        }
        gapField.placeholderString = "10"
        gapField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        paddingField.placeholderString = "10 10 10 10"
        paddingField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        for slider in [splitSlider, stepSlider] {
            slider.target = self
            slider.action = #selector(valueChanged(_:))
            // One write and one reload when the slider is released, not on every step of a drag.
            slider.isContinuous = false
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }

        for control in [borderControl, focusControl] {
            control.target = self
            control.action = #selector(valueChanged(_:))
        }
        modifierControl.target = self
        modifierControl.action = #selector(valueChanged(_:))
        borderWell.onChange = { [weak self] in self?.colorChanged() }
        borderWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        borderWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let spacingCard = CardView(rows: [
            row("Gap between windows", "gap", "gap", [gapField]),
            row("Padding from screen edges",
                "padding: 1, 2 (vertical horizontal) or 4 (top right bottom left) numbers",
                "padding", [paddingField]),
            row("First window share on split", "split_ratio", "split_ratio", [splitSlider, splitValue]),
            row("Resize step", "resize_step", "resize_step", [stepSlider, stepValue]),
        ])
        let borderCard = CardView(rows: [
            row("Border around the active window", "border", "border", [borderControl]),
            row("Border color", "border_color", "border_color", [borderWell, borderHex]),
        ])
        let mouseCard = CardView(rows: [
            row("Focus follows mouse", "focus_follows_mouse", "focus_follows_mouse", [focusControl]),
            row("Mouse modifier key", "mouse_modifier", "mouse_modifier", [modifierControl]),
        ])
        buildBindRows()

        let tabs = [
            PageTab(name: "Layout",
                    subtitle: "~/.config/cranberry/cberryrc (cberry config lines)",
                    sections: [
                        PageKit.section("Spacing",
                                        "Only the value in an existing cberry config line is changed; if there is no line, "
                                            + "the setting is not set and is not appended. After saving, cberry reload is run.",
                                        [spacingCard]),
                        PageKit.section("Border", "", [borderCard]),
                        PageKit.section("Mouse", "", [mouseCard]),
                    ]),
            PageTab(name: "Keys",
                    subtitle: "~/.config/cranberry/cberryrc (cberry bind lines)",
                    sections: [
                        PageKit.section("Key bindings",
                                        "Only the key combo can be changed: type it and press Return, or click Record and "
                                            + "press the keys (Escape cancels). Example: shift + alt - h.",
                                        [bindCard]),
                    ]),
        ]
        PageKit.embed(TabbedPageView(title: "WM (Cranberry)", tabs: tabs, status: status), in: self)
    }

    /// One row per bind: the description and the command on the left, the combo field and Record on the right.
    /// Binds in another form are listed read only. The rows are put into bindCard.
    private func buildBindRows() {
        bindFields = []
        bindButtons = []
        var views: [NSView] = []
        if readError != nil {
            views.append(PageKit.settingRow("—", "", []))
        }
        for (index, bind) in bindEntries.enumerated() {
            let field = NSTextField(string: bind.combo)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.tag = index
            field.target = self
            field.action = #selector(bindFieldChanged(_:))
            field.cell?.sendsActionOnEndEditing = true
            field.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let button = NSButton(title: "Record", target: self, action: #selector(recordBind(_:)))
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 100).isActive = true
            bindFields.append(field)
            bindButtons.append(button)
            let detail = NSTextField(wrappingLabelWithString: bind.command)
            let row = PageKit.settingRow(Self.describe(bind.command), "", [field, button], detailLabel: detail)
            detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            views.append(row)
        }
        for other in otherBinds {
            let detail = NSTextField(wrappingLabelWithString: other)
            let row = PageKit.settingRow("Not editable", "", [], detailLabel: detail)
            detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            views.append(row)
        }
        if views.isEmpty {
            views.append(PageKit.settingRow("No key bindings found", "", []))
        }
        bindCard.setRows(views)
    }

    /// A plain description of a bind command; the command itself when it is not in the table.
    static func describe(_ command: String) -> String {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let directions: Set<String> = ["left", "right", "up", "down"]
        if words.count == 3, words[0] == "cberry", directions.contains(words[2]) {
            let dir = words[2]
            switch words[1] {
            case "focus": return "Focus window \(dir)"
            case "swap": return "Swap window \(dir)"
            case "warp": return "Move window \(dir) in layout"
            case "resize": return "Resize window \(dir)"
            default: break
            }
        }
        let fixed: [String: String] = [
            "cberry rotate": "Rotate layout",
            "cberry toggle-split": "Toggle split direction",
            "cberry balance": "Balance window sizes",
            "cberry zoom": "Zoom window",
            "cberry reload": "Reload cranberry",
            "cberry scratchpad toggle files": "Toggle Finder scratchpad",
            "~/bin/wallpicker": "Open wallpicker",
            "open -a Finder": "Open Finder",
            "open -na kitty": "Open new kitty window",
        ]
        return fixed[words.joined(separator: " ")] ?? command
    }

    /// A settings row; when the key has no active line in the file the controls are replaced with "not set".
    private func row(_ title: String, _ detail: String, _ key: String, _ controls: [NSView]) -> NSView {
        if values[key] == nil {
            return PageKit.settingRow(title, detail, [PageKit.placeholder(readError == nil ? "not set" : "—")])
        }
        return PageKit.settingRow(title, detail, controls)
    }

    // MARK: - Reading

    private func load() {
        values = [:]
        bindEntries = []
        otherBinds = []
        readError = nil
        do {
            let lines = try CberryRc.file.readLines()
            for key in CberryRc.keys {
                if let v = CberryRc.read(key, in: lines) { values[key] = v }
            }
            bindEntries = CberryRc.bindEntries(in: lines)
            otherBinds = CberryRc.otherBinds(in: lines)
        } catch {
            readError = error.localizedDescription
        }
    }

    private func apply() {
        if let v = values["gap"] { gapField.stringValue = v }
        if let v = values["padding"] { paddingField.stringValue = v }
        if let v = values["split_ratio"] {
            if let n = Double(v) { splitSlider.doubleValue = n }
            splitValue.stringValue = v
        }
        if let v = values["resize_step"] {
            if let n = Double(v) { stepSlider.doubleValue = n }
            stepValue.stringValue = v
        }
        var unknown: [String] = []
        if let v = values["border"], !select(borderControl, onOff: v) { unknown.append("border \(v)") }
        if let v = values["border_color"] {
            borderWell.color = NSColor(hex: String(v.prefix(6))) ?? .white
            borderHex.stringValue = v
        }
        if let v = values["focus_follows_mouse"], !select(focusControl, onOff: v) {
            unknown.append("focus_follows_mouse \(v)")
        }
        if let v = values["mouse_modifier"] {
            let word = v == "none" ? "off" : v
            if let i = Self.modifiers.firstIndex(of: word) {
                modifierControl.selectedSegment = i
            } else {
                modifierControl.selectedSegment = -1
            }
        }

        if let e = readError {
            status.stringValue = "Could not read cberryrc: \(e)"
            return
        }
        var problems: [String] = []
        let missing = CberryRc.keys.filter { values[$0] == nil }
        if !missing.isEmpty {
            problems.append("Not set in cberryrc: \(missing.joined(separator: ", ")). These lines are not appended.")
        }
        if !unknown.isEmpty {
            problems.append("Not an on/off value in cberryrc: \(unknown.joined(separator: ", ")). The switch shows Off "
                + "until it is changed.")
        }
        status.stringValue = problems.joined(separator: "\n")
    }

    /// Sets the switch from an on/off word; returns false (switch off) when the word is not one cberry knows.
    private func select(_ control: ToggleView, onOff value: String) -> Bool {
        if Self.onOffWords.contains(where: { $0.on == value }) {
            control.state = .on
            return true
        }
        control.state = .off
        return Self.onOffWords.contains(where: { $0.off == value })
    }

    // MARK: - Writing

    /// Two decimals at most, no trailing zeros: 0.5, 0.05, 0.55.
    private static func format(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The on/off word in the same spelling as the current value (on/off, true/false, yes/no, 1/0).
    private static func onOffWord(_ on: Bool, like current: String?) -> String {
        let pair = onOffWords.first { $0.on == current || $0.off == current } ?? onOffWords[0]
        return on ? pair.on : pair.off
    }

    @objc private func valueChanged(_ sender: Any?) {
        let key: String
        let value: String
        if let f = sender as? NSTextField, f === gapField {
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            guard let n = Int(v), n >= 0 else {
                status.stringValue = "gap: needs a whole number of 0 or more. Not saved."
                gapField.stringValue = values["gap"] ?? ""
                return
            }
            key = "gap"
            value = String(n)
        } else if let f = sender as? NSTextField, f === paddingField {
            let parts = f.stringValue.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let numbers = parts.compactMap { Int($0) }
            guard [1, 2, 4].contains(parts.count), numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else {
                status.stringValue = "padding: needs 1, 2 or 4 whole numbers of 0 or more, separated by spaces. Not saved."
                paddingField.stringValue = values["padding"] ?? ""
                return
            }
            key = "padding"
            value = numbers.map(String.init).joined(separator: " ")
        } else if let s = sender as? NSSlider, s === splitSlider {
            let v = (s.doubleValue * 20).rounded() / 20
            key = "split_ratio"
            value = Self.format(v)
            splitValue.stringValue = value
        } else if let s = sender as? NSSlider, s === stepSlider {
            let v = (s.doubleValue * 100).rounded() / 100
            key = "resize_step"
            value = Self.format(v)
            stepValue.stringValue = value
        } else if let c = sender as? ToggleView, c === borderControl {
            key = "border"
            value = Self.onOffWord(c.state == .on, like: values[key])
        } else if let c = sender as? ToggleView, c === focusControl {
            key = "focus_follows_mouse"
            value = Self.onOffWord(c.state == .on, like: values[key])
        } else if let c = sender as? CapsuleSegments, c === modifierControl {
            guard Self.modifiers.indices.contains(c.selectedSegment) else { return }
            let word = Self.modifiers[c.selectedSegment]
            key = "mouse_modifier"
            value = (word == "off" && values[key] == "none") ? "none" : word
        } else {
            return
        }
        save(key, value)
    }

    private func colorChanged() {
        guard let current = values["border_color"] else { return }
        // hexString gives "#rrggbb"; cberryrc keeps it without "#", in the file's letter case,
        // with the alpha byte (RRGGBBAA) kept as it was.
        var hex = String(borderWell.color.hexString.dropFirst())
        if current == current.uppercased() { hex = hex.uppercased() }
        if current.count == 8 { hex += String(current.suffix(2)) }
        borderHex.stringValue = hex
        save("border_color", hex)
    }

    private func save(_ key: String, _ value: String) {
        do {
            if try CberryRc.write(key, value) {
                values[key] = value
                status.stringValue = "Saved: cberry config \(key) \(value). Running cberry reload…"
                reload(after: "cberry config \(key) \(value)")
            }
        } catch {
            status.stringValue = "Could not save \(key): \(error.localizedDescription)"
        }
    }

    // MARK: - Key combos

    @objc private func bindFieldChanged(_ sender: NSTextField) {
        saveBind(sender.tag, sender.stringValue)
    }

    /// Checks the combo and writes it into the bind's line; on any problem the field goes back to the
    /// combo in the file and the reason is shown. Nothing is written when the combo did not change.
    private func saveBind(_ index: Int, _ text: String) {
        guard bindEntries.indices.contains(index), bindFields.indices.contains(index) else { return }
        let bind = bindEntries[index]
        let field = bindFields[index]
        if text.trimmingCharacters(in: .whitespaces) == bind.combo {
            field.stringValue = bind.combo
            return
        }
        do {
            let combo = try CberryRc.checkCombo(text, forLine: bind.line, in: bindEntries)
            if combo == bind.combo {
                field.stringValue = bind.combo
                return
            }
            if try CberryRc.setBindCombo(line: bind.line, from: bind.combo, to: combo) {
                bindEntries[index] = CberryBind(line: bind.line, combo: combo, command: bind.command)
                field.stringValue = combo
                status.stringValue = "Saved: \(combo). Running cberry reload…"
                reload(after: "cberry bind '\(combo) : \(bind.command)'", bindChange: true)
            }
        } catch {
            field.stringValue = bind.combo
            status.stringValue = "Not saved: \(error.localizedDescription)"
        }
    }

    /// Record: the next key down in the app becomes the combo of that bind. Pressing Record again cancels.
    @objc private func recordBind(_ sender: NSButton) {
        let index = sender.tag
        if recordingIndex == index {
            stopRecording()
            status.stringValue = "Recording cancelled."
            return
        }
        stopRecording()
        guard bindEntries.indices.contains(index) else { return }
        // End editing in any field first, so the key press is not typed into it.
        window?.makeFirstResponder(nil)
        recordingIndex = index
        sender.title = "Press keys…"
        status.stringValue = "Press the new combo for \"\(Self.describe(bindEntries[index].command))\". Escape cancels."
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let i = self.recordingIndex else { return event }
            self.finishRecording(i, event)
            return nil
        }
    }

    private func finishRecording(_ index: Int, _ event: NSEvent) {
        stopRecording()
        if event.keyCode == 53 {  // Escape
            status.stringValue = "Recording cancelled."
            return
        }
        do {
            let combo = try Self.combo(from: event)
            if bindFields.indices.contains(index) { bindFields[index].stringValue = combo }
            saveBind(index, combo)
        } catch {
            status.stringValue = "Not saved: \(error.localizedDescription)"
        }
    }

    /// Removes the key monitor (if any) and puts the Record button back.
    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let i = recordingIndex, bindButtons.indices.contains(i) {
            bindButtons[i].title = "Record"
        }
        recordingIndex = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Leaving the page (another sidebar item) ends a recording that is still waiting for a key.
        if newWindow == nil { stopRecording() }
    }

    /// The cranberry spelling of a key press: modifiers (alt + shift + ctrl = meh, all four = hyper), " - ", the key.
    private static func combo(from event: NSEvent) throws -> String {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let arrows: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up"]
        let key: String
        if event.keyCode == 36 {
            key = "return"
        } else if let arrow = arrows[event.keyCode] {
            key = arrow
        } else {
            let typed = event.characters(byApplyingModifiers: [])?.lowercased() ?? ""
            guard typed.range(of: "^[a-z0-9]$", options: .regularExpression) != nil else {
                throw ConfigFileError.rejected("This key is not allowed. Use a-z, 0-9, return or an arrow key "
                    + "(letters need a Latin keyboard layout).")
            }
            key = typed
        }
        let cmd = flags.contains(.command)
        let alt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        // macOS sets the fn flag on every arrow key press; cranberry ignores it for those keys.
        let fn = flags.contains(.function) && arrows[event.keyCode] == nil
        var mods: [String] = []
        if cmd && alt && shift && ctrl {
            mods = ["hyper"]
        } else if alt && shift && ctrl {
            mods = ["meh"]
        } else {
            if cmd { mods.append("cmd") }
            if ctrl { mods.append("ctrl") }
            if shift { mods.append("shift") }
            if alt { mods.append("alt") }
        }
        if fn { mods.append("fn") }
        guard !mods.isEmpty else {
            throw ConfigFileError.rejected("Hold at least one modifier (alt, cmd, ctrl, shift or fn) with the key.")
        }
        return mods.joined(separator: " + ") + " - " + key
    }

    // MARK: - cberry reload

    /// Runs `cberry reload` (CberryRc.reload) and shows the result in the status line.
    /// `bindChange`: the success message is the short "Saved. Reloaded cranberry." used for key combos.
    private func reload(after saved: String, bindChange: Bool = false) {
        CberryRc.reload { [weak self] result in
            let message: String
            switch result {
            case .done:
                message = bindChange ? "Saved. Reloaded cranberry." : "Saved: \(saved). cberry reload done."
            case .failed(let code, let output):
                let detail = output.isEmpty ? "" : ": \(output)"
                message = "Saved: \(saved). cberry reload exited with code \(code)\(detail)"
            case .notStarted(let reason):
                message = "Saved: \(saved). cberry reload could not be started: \(reason)"
            }
            self?.status.stringValue = message
        }
    }
}

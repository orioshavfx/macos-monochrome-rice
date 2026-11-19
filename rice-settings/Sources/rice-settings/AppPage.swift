import AppKit

/// App: the accent colour of this app (~/.config/rice-settings/config.toml, read at launch, see Theme)
/// and the cberry rule that opens this window centred and floating (~/.config/cranberry/cberryrc).
final class AppPage: NSView {
    private let accentWell = ColorWell()
    private let accentHex = PageKit.valueLabel(width: 80)
    private let ruleToggle = ToggleView()
    private let status = NSTextField(wrappingLabelWithString: "")
    /// The accent as it is in config.toml now ("#rrggbb").
    private var savedAccent: String

    init() {
        savedAccent = AppConf.readAccent() ?? "#ffffff"
        super.init(frame: .zero)
        build()
        status.stringValue = loadRule() ?? ""
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build() {
        accentWell.color = NSColor(hex: savedAccent) ?? .white
        accentWell.onChange = { [weak self] in self?.accentChanged() }
        accentWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        accentWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        accentHex.stringValue = savedAccent
        ruleToggle.target = self
        ruleToggle.action = #selector(ruleChanged(_:))

        let appearanceCard = CardView(rows: [
            PageKit.settingRow("Accent colour", "Takes effect on the next launch.", [accentHex, accentWell]),
        ])
        let windowCard = CardView(rows: [
            PageKit.settingRow("Open centred and floating in cberry",
                               "On adds cberry rule grid \(CberryRc.windowRuleGrid) \"\(CberryRc.windowRuleApp)\" "
                                   + "to cberryrc and runs cberry reload; off removes that line.",
                               [ruleToggle]),
        ])
        let tabs = [
            PageTab(name: "App",
                    subtitle: "~/.config/rice-settings/config.toml and ~/.config/cranberry/cberryrc",
                    sections: [
                        PageKit.section("Appearance", "Saved to ~/.config/rice-settings/config.toml.", [appearanceCard]),
                        PageKit.section("Window",
                                        "The window always opens as a centred third of the screen; if cberry is not "
                                            + "running or the rule is off, cberry does not float it.",
                                        [windowCard]),
                    ]),
        ]
        PageKit.embed(TabbedPageView(title: "App", tabs: tabs, status: status), in: self)
    }

    // MARK: - Accent

    /// Called when the colour panel of the well closes: writes `accent = "#rrggbb"`.
    private func accentChanged() {
        let hex = accentWell.color.hexString
        if hex.lowercased() == savedAccent.lowercased() { return }
        do {
            if try AppConf.writeAccent(hex) {
                savedAccent = hex
                accentHex.stringValue = hex
                status.stringValue = "Saved accent \(hex) to ~/.config/rice-settings/config.toml. "
                    + "Takes effect on the next launch."
            }
        } catch {
            accentWell.color = NSColor(hex: savedAccent) ?? .white
            status.stringValue = "Could not save the accent colour: \(error.localizedDescription)"
        }
    }

    // MARK: - cberry rule

    /// Sets the toggle from cberryrc; returns a note or problem for the status line, or nil.
    @discardableResult
    private func loadRule() -> String? {
        let lines: [String]
        do {
            lines = try CberryRc.file.readLines()
        } catch {
            ruleToggle.isEnabled = false
            return "Could not read cberryrc: \(error.localizedDescription)"
        }
        ruleToggle.isEnabled = true
        let found = CberryRc.windowRuleIndices(in: lines)
        ruleToggle.isOn = !found.isEmpty
        if let spec = CberryRc.windowRuleGridSpec(in: lines), spec != CberryRc.windowRuleGrid || found.count > 1 {
            return "cberryrc has its own rule grid line for \(CberryRc.windowRuleApp) (\(spec)). "
                + "Turning the switch off and on again replaces it with \(CberryRc.windowRuleGrid)."
        }
        return nil
    }

    @objc private func ruleChanged(_ sender: Any?) {
        let on = ruleToggle.isOn
        do {
            if try CberryRc.setWindowRule(on) {
                status.stringValue = "Saved. Running cberry reload…"
                CberryRc.reload { [weak self] result in
                    let message: String
                    switch result {
                    case .done:
                        message = "Saved. Reloaded cranberry."
                    case .failed(let code, let output):
                        message = "Saved. cberry reload exited with code \(code)" + (output.isEmpty ? "" : ": \(output)")
                    case .notStarted(let reason):
                        message = "Saved. cberry reload could not be started: \(reason)"
                    }
                    self?.status.stringValue = message
                }
            } else {
                status.stringValue = on
                    ? "The rule is already in cberryrc. Nothing was written."
                    : "There is no rule for \(CberryRc.windowRuleApp) in cberryrc. Nothing was written."
            }
        } catch {
            status.stringValue = "Not saved: \(error.localizedDescription)"
            loadRule()
        }
    }
}

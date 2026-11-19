import AppKit

/// Colour well that reports a change when its colour panel closes.
final class ColorWell: NSColorWell {
    var onChange: (() -> Void)?

    override func deactivate() {
        super.deactivate()
        onChange?()
    }
}

final class SysvizPage: NSView {
    private var config = SysvizConfig.load()

    private let barsSlider = NSSlider(value: 64, minValue: 8, maxValue: 128, target: nil, action: nil)
    private let gapSlider = NSSlider(value: 1, minValue: 0, maxValue: 8, target: nil, action: nil)
    private let fpsSlider = NSSlider(value: 60, minValue: 15, maxValue: 120, target: nil, action: nil)
    private let barsValue = PageKit.valueLabel()
    private let gapValue = PageKit.valueLabel()
    private let fpsValue = PageKit.valueLabel()
    private let modeControl = CapsuleSegments(labels: ["Gradient", "Solid"])
    private let soloWell = ColorWell()
    private let lowWell = ColorWell()
    private let highWell = ColorWell()
    /// The wells of the color row: the two gradient wells or the single solid well, one of them hidden.
    private let gradientRow = NSStackView()
    private let soloRow = NSStackView()
    private let colorDetail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        build()
        apply(config)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        for slider in [barsSlider, gapSlider, fpsSlider] {
            slider.target = self
            slider.action = #selector(valueChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        modeControl.target = self
        modeControl.action = #selector(valueChanged(_:))
        for well in [soloWell, lowWell, highWell] {
            well.onChange = { [weak self] in self?.valueChanged(nil) }
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        for (row, wells) in [(gradientRow, [lowWell, highWell]), (soloRow, [soloWell])] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.setViews(wells, in: .leading)
        }

        let barsCard = CardView(rows: [
            PageKit.settingRow("Number of bars", "bars", [barsSlider, barsValue]),
            PageKit.settingRow("Gap between bars", "bar_gap", [gapSlider, gapValue]),
            PageKit.settingRow("Refresh rate", "framerate, frames per second", [fpsSlider, fpsValue]),
        ])
        let colorCard = CardView(rows: [
            PageKit.settingRow("Bar color", "color_mode", [modeControl]),
            PageKit.settingRow("Colors", "", [gradientRow, soloRow], detailLabel: colorDetail),
        ])
        let subtitle = "~/.config/sysviz/config.toml"
        let tabs = [
            PageTab(name: "Bars", subtitle: subtitle, sections: [
                PageKit.section("Bars", "Every change is saved to the file at once.", [barsCard]),
            ]),
            PageTab(name: "Colors", subtitle: subtitle, sections: [
                PageKit.section("Colors", "Solid uses one color; a gradient goes from the bottom color to the top color.",
                                [colorCard]),
            ]),
        ]
        PageKit.embed(TabbedPageView(title: "sysviz", tabs: tabs, status: status), in: self)
    }

    private func apply(_ c: SysvizConfig) {
        barsSlider.doubleValue = Double(c.bars)
        gapSlider.doubleValue = Double(c.barGap)
        fpsSlider.doubleValue = Double(c.framerate)
        modeControl.selectedSegment = c.colorMode == "solid" ? 1 : 0
        soloWell.color = NSColor(hex: c.color) ?? .white
        lowWell.color = NSColor(hex: c.colorLow) ?? .darkGray
        highWell.color = NSColor(hex: c.colorHigh) ?? .white
        refresh()
    }

    private func collect() -> SysvizConfig {
        var c = config
        c.bars = Int(barsSlider.doubleValue.rounded())
        c.barGap = Int(gapSlider.doubleValue.rounded())
        c.framerate = Int(fpsSlider.doubleValue.rounded())
        c.colorMode = modeControl.selectedSegment == 1 ? "solid" : "gradient"
        c.color = soloWell.color.hexString
        c.colorLow = lowWell.color.hexString
        c.colorHigh = highWell.color.hexString
        return c
    }

    private func refresh() {
        barsValue.stringValue = "\(Int(barsSlider.doubleValue.rounded()))"
        gapValue.stringValue = "\(Int(gapSlider.doubleValue.rounded()))"
        fpsValue.stringValue = "\(Int(fpsSlider.doubleValue.rounded()))"
        let solid = modeControl.selectedSegment == 1
        gradientRow.isHidden = solid
        soloRow.isHidden = !solid
        colorDetail.stringValue = solid ? "color" : "Bottom and top: color_low, color_high"
    }

    @objc private func valueChanged(_ sender: Any?) {
        config = collect()
        refresh()
        do {
            try config.save()
            status.stringValue = "Saved to ~/.config/sysviz/config.toml"
        } catch {
            status.stringValue = "Could not save: \(error.localizedDescription)"
        }
    }
}

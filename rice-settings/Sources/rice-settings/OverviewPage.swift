import AppKit

/// Overview: the start page. Which build of the rice this is (version, commit, build time, macOS)
/// and which of its command-line parts are installed in ~/bin.
/// The commit and build time are written into the app's Info.plist by install.sh and build.sh.
final class OverviewPage: NSView {
    /// The parts installed into ~/bin, in the order of the installer's steps, with an icon each.
    private static let parts: [(name: String, symbol: String)] = [
        ("cberry", "square.grid.2x2"),
        ("musicplayer", "music.note"),
        ("sysviz", "waveform"),
        ("wallpicker", "photo.on.rectangle"),
    ]

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let commit = info["RiceBuildCommit"] as? String ?? "unknown"
        let built = info["RiceBuildDate"] as? String ?? "unknown"

        let buildCard = CardView(rows: [
            Self.infoRow("Version", version, symbol: "tag"),
            Self.infoRow("Commit", commit, symbol: "number"),
            Self.infoRow("Built", built, symbol: "clock"),
            Self.infoRow("macOS", ProcessInfo.processInfo.operatingSystemVersionString, symbol: "laptopcomputer"),
        ])

        let home = FileManager.default.homeDirectoryForCurrentUser
        let installedCard = CardView(rows: Self.parts.map { part -> NSView in
            let present = FileManager.default.fileExists(atPath: home.appendingPathComponent("bin/\(part.name)").path)
            let state = NSTextField(labelWithString: present ? "Installed" : "Missing")
            state.font = .systemFont(ofSize: 13, weight: .medium)
            state.textColor = present ? .labelColor : .secondaryLabelColor
            return PageKit.settingRow(part.name, "~/bin/\(part.name)", [state], symbol: part.symbol)
        })

        let tabs = [
            PageTab(name: "Overview",
                    subtitle: "What this build is and which parts are installed",
                    sections: [
                        PageKit.section("Build",
                                        "Written when the app is built: install.sh or setup --build.",
                                        [buildCard]),
                        PageKit.section("Installed",
                                        "Files in ~/bin. A missing part was not built; the installer prints a warning for it.",
                                        [installedCard]),
                    ]),
        ]
        let status = NSTextField(wrappingLabelWithString: "")
        PageKit.embed(TabbedPageView(title: "Overview", tabs: tabs, status: status, kicker: "Rice Settings"), in: self)
    }

    /// A card row with a value on the right; the value is cut at the tail when the window is narrow.
    private static func infoRow(_ title: String, _ value: String, symbol: String) -> NSView {
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return PageKit.settingRow(title, "", [label], symbol: symbol)
    }
}

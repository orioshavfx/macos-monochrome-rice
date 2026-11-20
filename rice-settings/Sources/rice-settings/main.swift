import AppKit

/// Escape reaches this only when nothing else handled it: an open drawer and a
/// bind being recorded consume Escape first, so this closes the app otherwise.
final class RiceWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    /// The sidebar: groups of rows, each group on one card. The rows, in order, are the pages:
    /// pages[i] belongs to the i-th row. Title, description and SF Symbol per row.
    private let groups: [[(title: String, detail: String, symbol: String)]] = [
        [("Overview", "Build and installed parts", "house")],
        [
            ("Terminal", "kitty, fish, fonts", "terminal"),
            ("WM (Cranberry)", "Tiling, gaps and binds", "square.grid.2x2"),
            ("Wallpaper", "Folder and carousel colour", "photo.on.rectangle"),
        ],
        [
            ("sysviz", "Audio visualiser", "waveform"),
            ("fastfetch", "System info lines", "info.circle"),
        ],
        [("App", "Accent colour and window", "slider.horizontal.3")],
    ]
    private let content = NSView()
    private var pages: [NSView] = []
    private var items: [SidebarItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        pages = [
            OverviewPage(),
            TerminalPage(),
            CberryPage(),
            WallpaperPage(),
            SysvizPage(),
            FastfetchPage(),
            AppPage(),
        ]
        // Always 60% of the screen's width and 70% of its height, centred, not resizable,
        // floating above other windows. With the cberry rule on, cberry floats it in the same place
        // (the rule grid is CberryRc.windowRuleGrid: columns 4-15 and rows 3-16 of a 20 x 20 grid).
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 920)
        let size = NSSize(width: (visible.width * 0.6).rounded(), height: (visible.height * 0.7).rounded())
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        window = RiceWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Rice Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The light fills of cards and the selected sidebar item are made for a dark background.
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .floating
        window.contentView = makeRoot()
        window.setFrame(frame, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        showSection(0)
    }

    private func makeRoot() -> NSView {
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        // Each group is a card; its rows are SidebarItems, numbered in reading order.
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        for group in groups {
            let card = FillView()
            card.fillColor = Theme.cardFill
            card.cornerRadius = Theme.cardRadius
            card.translatesAutoresizingMaskIntoConstraints = false
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 2
            rows.translatesAutoresizingMaskIntoConstraints = false
            var groupItems: [SidebarItem] = []
            for entry in group {
                let index = items.count
                let item = SidebarItem(title: entry.title, detail: entry.detail, symbol: entry.symbol)
                item.onClick = { [weak self] in self?.showSection(index) }
                items.append(item)
                groupItems.append(item)
            }
            rows.setViews(groupItems, in: .top)
            card.addSubview(rows)
            NSLayoutConstraint.activate([
                rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
                rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
                rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
                rows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            ])
            for item in groupItems {
                item.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            column.addView(card, in: .top)
            card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        let divider = FillView()
        divider.fillColor = .separatorColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(column)
        root.addSubview(divider)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            // Below the window buttons, which sit over the sidebar.
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -12),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.sidebarWidth),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func showSection(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        for (i, item) in items.enumerated() { item.isSelected = i == index }
        content.subviews.forEach { $0.removeFromSuperview() }
        PageKit.embed(pages[index], in: content)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

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
    /// Sidebar names and their SF Symbols, in sidebar order; pages[i] belongs to sections[i].
    private let sections = ["Overview", "Terminal", "WM (Cranberry)", "Wallpaper", "sysviz", "fastfetch", "App"]
    private let symbols = ["house", "terminal", "square.grid.2x2", "photo.on.rectangle", "waveform", "info.circle",
                           "slider.horizontal.3"]
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

        for (index, title) in sections.enumerated() {
            let item = SidebarItem(title: title, symbol: symbols[index])
            item.onClick = { [weak self] in self?.showSection(index) }
            items.append(item)
        }
        // A vertical list of rows: each row is as wide as the column.
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setViews(items, in: .top)
        column.translatesAutoresizingMaskIntoConstraints = false
        for item in items {
            item.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
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
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -10),
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

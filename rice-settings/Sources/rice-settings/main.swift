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
    private let sections = ["Terminal", "WM (Cranberry)", "sysviz", "fastfetch", "App"]
    private let symbols = ["terminal", "square.grid.2x2", "waveform", "info.circle", "slider.horizontal.3"]
    private let content = NSView()
    private var pages: [NSView] = []
    private var items: [SidebarItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        pages = [
            TerminalPage(),
            CberryPage(),
            SysvizPage(),
            FastfetchPage(),
            AppPage(),
        ]
        // Always 90% of the screen's width and 80% of its height, centred, not resizable,
        // floating above other windows. With the cberry rule on, cberry floats it in the same place.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 920)
        let size = NSSize(width: (visible.width * 0.9).rounded(), height: (visible.height * 0.8).rounded())
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
        showSection(2)
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
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setViews(items, in: .top)
        column.translatesAutoresizingMaskIntoConstraints = false

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
            column.centerXAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.sidebarWidth / 2),
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

import AppKit

// Shared building blocks of the settings pages: sidebar items, the tab bar, cards, setting rows,
// the capsule segmented control and the page frame (title, subtitle, tabs, scrolling content, status).

/// Document view of a scroll view: flipped, so the content starts at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A layer-backed view with a fill, a corner radius and an optional border.
/// Colours are resolved in the view's own appearance each time the layer is updated.
class FillView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer = layer else { return }
        layer.cornerRadius = cornerRadius
        layer.borderWidth = borderWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = self.fillColor.cgColor
            layer.borderColor = self.borderColor.cgColor
        }
    }
}

/// The app's one switch for motion: every animation goes through `animate`, so the system setting
/// "Reduce motion" turns them all off.
enum Motion {
    static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Runs `changes` in an animation group (`duration`, ease in/out, implicit animation allowed).
    /// With reduce motion on, the changes are applied at once: a zero-length group, so `animator()`
    /// calls inside `changes` do not fall back to the default 0.25 s.
    /// `completion`, if given, runs when the group's animations have finished (at once with reduce motion).
    static func animate(_ duration: TimeInterval = 0.25, _ changes: @escaping () -> Void,
                        completion: (() -> Void)? = nil) {
        guard enabled else {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            NSAnimationContext.current.completionHandler = completion
            changes()
            NSAnimationContext.endGrouping()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }

    /// Applies `changes` at once, in a zero-length group. `animator()` calls inside it replace an
    /// animation of the same property that is still running, so a view can be put in its final state
    /// in the middle of an earlier `animate`.
    static func now(_ changes: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        changes()
        NSAnimationContext.endGrouping()
    }
}

/// A fill that never takes mouse clicks: highlights and hover overlays drawn behind a view's content.
private final class OverlayView: FillView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Adds a hover overlay (white, about 4%) to `host`, behind its content and inset by `inset`,
/// and tracks the mouse over `host`. The owner calls `update()` from updateTrackingAreas and
/// `reset()` when the host moves to another window.
private final class HoverTracker {
    private weak var host: NSView?
    private let overlay = OverlayView()
    private var area: NSTrackingArea?
    private var isHovered = false

    init(host: NSView, inset: NSSize, cornerRadius: CGFloat) {
        self.host = host
        overlay.fillColor = NSColor.white.withAlphaComponent(0.04)
        overlay.cornerRadius = cornerRadius
        overlay.alphaValue = 0
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: host.topAnchor, constant: inset.height),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset.height),
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset.width),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset.width),
        ])
    }

    /// Replaces the tracking area with one over the host's current bounds and syncs the hover state
    /// with where the mouse is now (the bounds change on resize and the row moves when scrolled).
    func update() {
        guard let host = host else { return }
        if let old = area { host.removeTrackingArea(old) }
        let new = NSTrackingArea(rect: host.bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                 owner: host, userInfo: nil)
        host.addTrackingArea(new)
        area = new
        if let window = host.window, NSApp.isActive {
            let point = host.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setHovered(!host.isHiddenOrHasHiddenAncestor && host.bounds.contains(point))
        } else {
            setHovered(false)
        }
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        let overlay = self.overlay
        Motion.animate(0.2) { overlay.animator().alphaValue = hovered ? 1 : 0 }
    }

    /// Clears the hover at once (no animation), e.g. when the page holding the row is taken off screen.
    func reset() {
        isHovered = false
        overlay.alphaValue = 0
    }
}

/// A horizontal 1 pt line in the separator colour, inset from both sides.
final class Hairline: NSView {
    var inset: CGFloat = 16 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: inset, y: 0, width: max(0, bounds.width - 2 * inset), height: bounds.height).fill()
    }
}

// MARK: - Sidebar

/// One sidebar row, as in System Settings: a rounded icon tile, the section name and a short description.
/// The selected row gets a light fill; the rows of a group sit on one card (see RiceSidebar).
final class SidebarItem: FillView {
    var onClick: (() -> Void)?
    /// A change of selection fades the highlight out of the old row and into the new one.
    var isSelected = false { didSet { if isSelected != oldValue { restyle(animated: true) } } }

    /// The selected-row fill, faded in and out instead of switching the row's own fill.
    private let highlight = OverlayView()
    private var hover: HoverTracker?
    private let iconTile = FillView()
    private let imageView = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    init(title: String, detail: String, symbol: String) {
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: detail)
        super.init(frame: .zero)

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: title)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        imageView.image = image?.withSymbolConfiguration(config) ?? image
        imageView.imageScaling = .scaleProportionallyDown
        iconTile.cornerRadius = 8

        cornerRadius = 10
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        toolTip = title

        let texts = NSStackView()
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setViews([titleLabel, detailLabel], in: .top)

        highlight.fillColor = Theme.selectedFill
        highlight.cornerRadius = 10
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // The hover overlay goes under the highlight (it is put below all subviews).
        hover = HoverTracker(host: self, inset: .zero, cornerRadius: 10)

        for view in [iconTile, imageView, texts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconTile.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconTile.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 30),
            iconTile.heightAnchor.constraint(equalToConstant: 30),
            imageView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            texts.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 10),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        restyle(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// True when the query is in the row's name or description (lower case, already trimmed).
    func matches(_ query: String) -> Bool {
        titleLabel.stringValue.lowercased().contains(query) || detailLabel.stringValue.lowercased().contains(query)
    }

    private func restyle(animated: Bool) {
        fillColor = .clear
        let alpha: CGFloat = isSelected ? 1 : 0
        if animated && window != nil {
            let highlight = self.highlight
            Motion.animate(0.22) { highlight.animator().alphaValue = alpha }
        } else {
            highlight.alphaValue = alpha
        }
        iconTile.fillColor = isSelected ? Theme.accent : Theme.controlFill
        imageView.contentTintColor = isSelected ? Theme.onAccent : .labelColor
        titleLabel.textColor = .labelColor
        detailLabel.textColor = .secondaryLabelColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover?.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover?.reset()
    }

    override func mouseEntered(with event: NSEvent) { hover?.setHovered(true) }

    override func mouseExited(with event: NSEvent) { hover?.setHovered(false) }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Tab bar

/// One text tab: the title, with 9 pt under it for the active tab line (drawn by the TabBar).
final class TabItem: NSView {
    var onClick: (() -> Void)?
    var isActive = false { didSet { restyle() } }

    private let label: NSTextField

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            // 7 pt gap + the 2 pt line, as when each tab drew its own line.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The text colour switches at once (NSTextField's textColor does not animate); the line slides.
    private func restyle() {
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A row of text tabs over a thin line.
final class TabBar: NSView {
    var onSelect: ((Int) -> Void)?
    private var items: [TabItem] = []
    /// The 2 pt accent line under the active tab. It is pinned to that tab's edges and slides to the
    /// new one when the selection changes (as the CapsuleSegments pill does).
    private let indicator = OverlayView()
    private var indicatorConstraints: [NSLayoutConstraint] = []
    private var selected: Int?

    init(titles: [String]) {
        super.init(frame: .zero)
        let line = Hairline()
        line.inset = 0
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)  // added first, so the active tab line is drawn over it

        for (index, title) in titles.enumerated() {
            let item = TabItem(title: title)
            item.onClick = { [weak self] in self?.onSelect?(index) }
            items.append(item)
        }
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .bottom
        stack.spacing = 20
        stack.setViews(items, in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        indicator.fillColor = Theme.accent
        indicator.cornerRadius = 1
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)  // over the hairline and the tabs
        NSLayoutConstraint.activate([
            indicator.heightAnchor.constraint(equalToConstant: 2),
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Marks tab `index` active. The line slides to it when the bar is on screen and had a selection
    /// before; the first selection (from init, or while off screen) puts it in place without animation.
    func setSelected(_ index: Int) {
        for (i, item) in items.enumerated() { item.isActive = i == index }
        guard items.indices.contains(index) else {
            indicator.isHidden = true
            selected = nil
            return
        }
        let animated = selected != nil && selected != index && window != nil
        selected = index
        indicator.isHidden = false
        pinIndicator(to: items[index])
        guard animated else { return }
        // The new constraints are laid out inside the animation group, so the line's frame moves there.
        needsLayout = true
        Motion.animate(0.25) { [weak self] in self?.layoutSubtreeIfNeeded() }
    }

    /// Pins the line to the leading and trailing edges of `item` (replacing its previous constraints).
    private func pinIndicator(to item: TabItem) {
        NSLayoutConstraint.deactivate(indicatorConstraints)
        indicatorConstraints = [
            indicator.leadingAnchor.constraint(equalTo: item.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: item.trailingAnchor),
        ]
        NSLayoutConstraint.activate(indicatorConstraints)
    }
}

// MARK: - Capsule segmented control

/// One segment of a CapsuleSegments.
private final class SegmentItem: FillView {
    var onClick: (() -> Void)?
    let label: NSTextField
    let title: String

    init(title: String) {
        self.title = title
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        cornerRadius = 12
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A capsule-shaped choice of several values; the selected segment has the accent fill and dark text.
/// Used like NSSegmentedControl here: `selectedSegment` (-1 = none), `isEnabled`, and target/action,
/// sent when the user clicks a segment.
final class CapsuleSegments: FillView {
    weak var target: AnyObject?
    var action: Selector?
    var selectedSegment: Int = -1 { didSet { restyle(animated: true) } }
    var isEnabled = true { didSet { restyle(animated: false) } }

    private var items: [SegmentItem] = []
    /// The accent capsule under the selected segment. It is pinned to that segment's edges and slides
    /// to the new one when the selection changes; hidden (alpha 0) when nothing is selected.
    private let pill = OverlayView()
    private var pillConstraints: [NSLayoutConstraint] = []
    private var pillShown = false

    init(labels: [String]) {
        super.init(frame: .zero)
        fillColor = Theme.controlFill
        cornerRadius = 14
        for (index, title) in labels.enumerated() {
            let item = SegmentItem(title: title)
            item.onClick = { [weak self] in self?.clicked(index) }
            items.append(item)
        }
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.setViews(items, in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.fillColor = Theme.accent
        pill.cornerRadius = 12
        pill.alphaValue = 0
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)  // under the stack, so the labels are drawn over it
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        if let first = items.first { pinPill(to: first) }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        restyle(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func clicked(_ index: Int) {
        guard isEnabled, items.indices.contains(index) else { return }
        selectedSegment = index
        if let action = action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func restyle(animated: Bool) {
        for (i, item) in items.enumerated() {
            let on = i == selectedSegment
            item.fillColor = .clear
            item.label.textColor = on ? Theme.onAccent : .labelColor
            item.label.stringValue = on ? "✓ \(item.title)" : item.title
        }
        alphaValue = isEnabled ? 1 : 0.4

        let wasShown = pillShown
        pillShown = items.indices.contains(selectedSegment)
        if pillShown { pinPill(to: items[selectedSegment]) }
        let pill = self.pill
        let alpha: CGFloat = pillShown ? 1 : 0
        guard animated, window != nil else {
            pill.alphaValue = alpha
            return
        }
        if wasShown && pillShown {
            // Slide: the new constraints are laid out inside the animation group, so the pill's frame
            // (and the segments, whose widths change with the ✓) move there over the duration.
            needsLayout = true
            Motion.animate(0.25) { [weak self] in self?.layoutSubtreeIfNeeded() }
        } else {
            // Appearing or disappearing: put the pill in place first, then only fade it.
            layoutSubtreeIfNeeded()
            Motion.animate(0.2) { pill.animator().alphaValue = alpha }
        }
    }

    /// Pins the pill to the edges of `item` (replacing its previous constraints).
    private func pinPill(to item: SegmentItem) {
        NSLayoutConstraint.deactivate(pillConstraints)
        pillConstraints = [
            pill.topAnchor.constraint(equalTo: item.topAnchor),
            pill.bottomAnchor.constraint(equalTo: item.bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: item.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: item.trailingAnchor),
        ]
        NSLayoutConstraint.activate(pillConstraints)
    }
}

// MARK: - Cards

/// The background of a card row (PageKit.row): it brightens slightly while the mouse is over it.
/// Only the background reacts; the row's controls handle their own mouse events as before.
private final class HoverRowView: NSView {
    private var hover: HoverTracker?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Inset inside the card, so the overlay's corners stay within the card's rounded corners.
        hover = HoverTracker(host: self, inset: NSSize(width: 4, height: 2), cornerRadius: 8)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover?.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover?.reset()
    }

    override func mouseEntered(with event: NSEvent) { hover?.setHovered(true) }

    override func mouseExited(with event: NSEvent) { hover?.setHovered(false) }
}

/// A rounded card holding rows one under the other, separated by thin lines.
final class CardView: FillView {
    private let stack = NSStackView()

    init(rows: [NSView] = []) {
        super.init(frame: .zero)
        fillColor = Theme.cardFill
        cornerRadius = Theme.cardRadius
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setRows(rows)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Replaces the rows; each row and line spans the card's width.
    func setRows(_ rows: [NSView]) {
        var views: [NSView] = []
        for (i, row) in rows.enumerated() {
            if i > 0 { views.append(Hairline()) }
            views.append(row)
        }
        stack.setViews(views, in: .top)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// An app card: the icon in a 40 x 40 square at the top left, an "In use" badge at the top right,
/// the name and a one-line description at the bottom. Clicking it calls onClick.
final class AppCard: FillView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { borderColor = isSelected ? Theme.accent : .clear } }

    /// A button on the card (bottom right); clicks on it go to the button, not to onClick.
    private let actionButton: NSButton?

    /// `appIcon` is used when given; otherwise the SF Symbol `symbol` is drawn in a rounded square.
    init(name: String, detail: String, appIcon: NSImage?, symbol: String, button: NSButton? = nil) {
        actionButton = button
        super.init(frame: .zero)
        fillColor = Theme.cardFill
        cornerRadius = Theme.cardRadius
        borderWidth = 1.5

        let iconHolder = FillView()
        let imageView = NSImageView()
        if let icon = appIcon {
            imageView.image = icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
        } else {
            iconHolder.fillColor = Theme.controlFill
            iconHolder.cornerRadius = 10
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: name)
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            imageView.image = image?.withSymbolConfiguration(config) ?? image
            imageView.contentTintColor = .labelColor
            imageView.imageScaling = .scaleProportionallyDown
        }

        let badge = FillView()
        badge.fillColor = Theme.accent
        badge.cornerRadius = 9
        let badgeText = NSTextField(labelWithString: "In use")
        badgeText.font = .systemFont(ofSize: 11, weight: .medium)
        badgeText.textColor = Theme.onAccent

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.toolTip = detail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [iconHolder, imageView, badge, badgeText, nameLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(iconHolder)
        iconHolder.addSubview(imageView)
        addSubview(badge)
        badge.addSubview(badgeText)
        addSubview(nameLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 112),
            iconHolder.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            iconHolder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconHolder.widthAnchor.constraint(equalToConstant: 40),
            iconHolder.heightAnchor.constraint(equalToConstant: 40),
            imageView.centerXAnchor.constraint(equalTo: iconHolder.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: iconHolder.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: appIcon == nil ? 28 : 40),
            imageView.heightAnchor.constraint(equalToConstant: appIcon == nil ? 28 : 40),

            badge.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badgeText.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 8),
            badgeText.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -8),
            badgeText.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        if let button = button {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let button = actionButton, let hit = super.hitTest(point), hit === button || hit.isDescendant(of: button) {
            return hit
        }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Toggle

/// An on/off switch drawn in the app's style: a capsule filled with Theme.accent when on, a white knob.
/// Used like NSSwitch here: `state` (.on/.off) or `isOn`, `isEnabled`, and target/action, sent when
/// the user flips it.
final class ToggleView: NSView {
    weak var target: AnyObject?
    var action: Selector?
    var state: NSControl.StateValue = .off {
        didSet {
            needsDisplay = true
            setAccessibilityValue(state == .on ? 1 : 0)
            moveKnob(animated: state != oldValue)
        }
    }
    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
            setAccessibilityEnabled(isEnabled)
        }
    }

    private static let size = NSSize(width: 38, height: 22)

    /// The white knob, a subview so it can slide between the off and on positions.
    private let knob = ToggleKnob()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        knob.wantsLayer = true
        addSubview(knob)
        knob.frame = knobFrame()
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { Self.size }

    private var track: NSRect {
        NSRect(x: (bounds.width - Self.size.width) / 2, y: (bounds.height - Self.size.height) / 2,
               width: Self.size.width, height: Self.size.height)
    }

    /// The knob's frame for the current state: the knob circle plus `ToggleKnob.ring` on every side,
    /// so its ring is not clipped.
    private func knobFrame() -> NSRect {
        let track = self.track
        let d = track.height - 4
        let circle = NSRect(x: isOn ? track.maxX - 2 - d : track.minX + 2, y: track.minY + 2, width: d, height: d)
        return circle.insetBy(dx: -ToggleKnob.ring, dy: -ToggleKnob.ring)
    }

    private func moveKnob(animated: Bool) {
        let frame = knobFrame()
        guard animated, window != nil else {
            knob.frame = frame
            return
        }
        let knob = self.knob
        Motion.animate(0.2) { knob.animator().frame = frame }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        // Re-placed only on a real size change, so a layout pass does not cut a running slide short.
        if newSize != oldSize { knob.frame = knobFrame() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = self.track
        (isOn ? Theme.accent : Theme.toggleOffFill).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        // The knob is drawn by its own subview (ToggleKnob).
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { flip() }

    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }

    private func flip() {
        guard isEnabled else { return }
        isOn.toggle()
        if let action = action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }
}

/// The knob of a ToggleView: a white circle with a thin ring, drawn `ring` points inside its bounds.
/// Clicks go through to the toggle.
private final class ToggleKnob: NSView {
    static let ring: CGFloat = 1

    override func draw(_ dirtyRect: NSRect) {
        let knobPath = NSBezierPath(ovalIn: bounds.insetBy(dx: Self.ring, dy: Self.ring))
        NSColor.white.setFill()
        knobPath.fill()
        // A thin ring keeps the white knob visible on a white (or very light) accent.
        NSColor.black.withAlphaComponent(0.25).setStroke()
        knobPath.lineWidth = 0.75
        knobPath.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Drawer

/// The dimmed backdrop of a drawer; a click on it closes the drawer.
private final class DimView: FillView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A panel about 60% of the window wide that slides in from the right over the window content
/// (0.25 s), with a dimmed backdrop. Closes on a click on the backdrop, the close button or Esc.
/// The content scrolls. One instance can be opened and closed many times.
final class DrawerView: NSView {
    private let dim = DimView()
    private let panel = FillView()
    /// panel.trailing = self.trailing + constant: 0 when open, the panel width when closed.
    private var slide: NSLayoutConstraint!
    private var keyMonitor: Any?
    private(set) var isOpen = false

    init(title: String, subtitle: String, sections: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        dim.fillColor = NSColor.black.withAlphaComponent(0.45)
        dim.onClick = { [weak self] in self?.close() }
        panel.fillColor = .windowBackgroundColor
        panel.borderColor = .separatorColor
        panel.borderWidth = 1

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isSelectable = false
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.setViews([titleLabel, subtitleLabel], in: .top)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked(_:)))
        if let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
            closeButton.image = x
            closeButton.imagePosition = .imageOnly
        }
        closeButton.isBordered = false
        closeButton.toolTip = "Close (Esc)"

        let scroll = PageKit.scrollingStack(sections, margin: 20)
        for view in [dim, panel, header, closeButton, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(dim)
        addSubview(panel)
        panel.addSubview(header)
        panel.addSubview(closeButton)
        panel.addSubview(scroll)

        slide = panel.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.6),
            slide,
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
            subtitleLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
            closeButton.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts the drawer over all of `host` (the window's content view) and slides the panel in.
    func open(in host: NSView) {
        guard !isOpen else { return }
        isOpen = true
        if superview !== host {
            removeFromSuperview()
            translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(self, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: host.topAnchor),
                leadingAnchor.constraint(equalTo: host.leadingAnchor),
                trailingAnchor.constraint(equalTo: host.trailingAnchor),
                bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        // Start closed: lay out with the panel just off the right edge, then animate it in.
        host.layoutSubtreeIfNeeded()
        slide.constant = panel.frame.width > 0 ? panel.frame.width : host.bounds.width * 0.6
        dim.alphaValue = 0
        host.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.slide.animator().constant = 0
            self.dim.animator().alphaValue = 1
        }
        window?.makeFirstResponder(self)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isOpen, event.keyCode == 53 else { return event }  // 53 = Escape
            self.close()
            return nil
        }
    }

    /// Slides the panel out and removes the drawer from the window.
    func close() {
        guard isOpen else { return }
        isOpen = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        let width = panel.frame.width
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.slide.animator().constant = width
            self.dim.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.isOpen else { return }
            self.removeFromSuperview()
        })
    }

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func closeClicked(_ sender: Any?) { close() }
}

// MARK: - Page frame

/// One tab of a page: its name in the tab bar, the subtitle shown under the page title while it is
/// selected (it names the file the tab edits), and the sections shown one under the other.
struct PageTab {
    let name: String
    let subtitle: String
    let sections: [NSView]
}

/// The frame of every page: title (22 pt semibold) and subtitle (13 pt secondary), an optional accessory
/// (the app cards), the tab bar when there is more than one tab, the selected tab's scrolling content,
/// and the page's single status line at the bottom right.
final class TabbedPageView: NSView {
    /// Called after a tab is selected by the user or by selectTab(_:).
    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0

    private let tabs: [PageTab]
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var scrolls: [NSScrollView] = []
    /// Per scroll view, its leading and trailing constraints to the content area: the incoming tab
    /// slides in by shifting both constants (Auto Layout stays in charge of its frame).
    private var scrollOffsets: [[NSLayoutConstraint]] = []
    /// The view the scroll views are pinned to.
    private let area = NSView()
    /// Counts tab switches, so the completion of an older switch does not hide a view a newer one shows.
    private var switchGeneration = 0
    private var tabBar: TabBar?

    /// `showsTabBar: false` hides the tab bar; the page then switches tabs itself with selectTab(_:).
    /// `kicker` is a small uppercase line above the title (the app or section it belongs to); nil for none.
    init(title: String, tabs: [PageTab], accessory: NSView? = nil, status: NSTextField, showsTabBar: Bool = true,
         kicker: String? = nil) {
        self.tabs = tabs
        super.init(frame: .zero)
        build(title, kicker, accessory, status, showsTabBar)
        selectTab(0, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows tab `index`. On screen, the old tab fades out while the new one fades in and slides 12 pt
    /// into place from the side of the change (from the right for a later tab, from the left for an
    /// earlier one), and the new tab scrolls back to its top. `animated: false` switches at once.
    func selectTab(_ index: Int, animated: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        let previous = selectedIndex
        selectedIndex = index
        switchGeneration += 1
        let generation = switchGeneration

        // Final state of any earlier switch first, so a fast second click never leaves a tab hidden or
        // half faded: everything opaque and in place, only the old and the new tab not hidden.
        // The fade of a running switch is a layer animation: remove it, then set the values through a
        // zero-length group, which also replaces a running animation of the offset constants.
        for (i, scroll) in scrolls.enumerated() {
            scroll.layer?.removeAllAnimations()
            let offsets = scrollOffsets[i]
            Motion.now {
                scroll.animator().alphaValue = 1
                offsets.forEach { $0.animator().constant = 0 }
            }
            scroll.isHidden = i != index && i != previous
        }

        if index != previous && scrolls.indices.contains(index) {
            PageKit.smoothScroll(scrolls[index], to: 0)
        }

        if animated && window != nil && index != previous && scrolls.indices.contains(previous)
            && scrolls.indices.contains(index) {
            let outgoing = scrolls[previous]
            let incoming = scrolls[index]
            let offsets = scrollOffsets[index]
            let shift: CGFloat = index > previous ? 12 : -12
            incoming.alphaValue = 0
            offsets.forEach { $0.constant = shift }
            area.layoutSubtreeIfNeeded()
            Motion.animate(0.25, {
                outgoing.animator().alphaValue = 0
                incoming.animator().alphaValue = 1
                offsets.forEach { $0.animator().constant = 0 }
            }, completion: { [weak self] in
                // A newer switch has already set its own state; leave it alone.
                guard let self = self, self.switchGeneration == generation else { return }
                outgoing.isHidden = true
                outgoing.alphaValue = 1
            })
        } else if scrolls.indices.contains(previous) && previous != index {
            scrolls[previous].isHidden = true  // instant switch: the old tab goes at once
        }

        subtitleLabel.stringValue = tabs[index].subtitle
        tabBar?.setSelected(index)
        onSelect?(index)
    }

    private func build(_ title: String, _ kicker: String?, _ accessory: NSView?, _ status: NSTextField, _ showsTabBar: Bool) {
        let margin = Theme.pageMargin
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 26, weight: .medium)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isSelectable = false

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        var headerViews: [NSView] = [titleLabel, subtitleLabel]
        if let kicker = kicker {
            let kickerLabel = NSTextField(labelWithString: "")
            kickerLabel.attributedStringValue = NSAttributedString(string: kicker.uppercased(), attributes: [
                .kern: 1.2,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            headerViews.insert(kickerLabel, at: 0)
        }
        header.setViews(headerViews, in: .top)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        var constraints: [NSLayoutConstraint] = [
            header.topAnchor.constraint(equalTo: topAnchor, constant: Theme.titlebarInset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            subtitleLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
        ]
        var last: NSView = header

        if let accessory = accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            constraints += [
                accessory.topAnchor.constraint(equalTo: last.bottomAnchor, constant: 12),
                accessory.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            ]
            last = accessory
        }

        if tabs.count > 1 && showsTabBar {
            let bar = TabBar(titles: tabs.map { $0.name })
            bar.onSelect = { [weak self] index in self?.selectTab(index) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            constraints += [
                bar.topAnchor.constraint(equalTo: last.bottomAnchor, constant: 12),
                bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            ]
            last = bar
            tabBar = bar
        }

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)

        area.translatesAutoresizingMaskIntoConstraints = false
        // The incoming tab starts 12 pt to one side: keep it inside the content area (over the sidebar
        // otherwise). Before macOS 14 views clip their subviews already.
        if #available(macOS 14.0, *) { area.clipsToBounds = true }
        addSubview(area)
        constraints += [
            area.topAnchor.constraint(equalTo: last.bottomAnchor, constant: 8),
            area.leadingAnchor.constraint(equalTo: leadingAnchor),
            area.trailingAnchor.constraint(equalTo: trailingAnchor),
            area.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ]

        for tab in tabs {
            let scroll = PageKit.scrollingStack(tab.sections, margin: margin)
            scroll.wantsLayer = true  // its alpha is animated on a tab switch
            area.addSubview(scroll)
            let offsets = [
                scroll.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            ]
            constraints += offsets + [
                scroll.topAnchor.constraint(equalTo: area.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            ]
            scrolls.append(scroll)
            scrollOffsets.append(offsets)
        }
        NSLayoutConstraint.activate(constraints)
    }
}

// MARK: - Helpers

enum PageKit {
    /// A vertical scroll view whose content is `sections` one under the other (24 pt apart), each as wide
    /// as the scroll view minus `margin` on both sides. The content starts at the top.
    static func scrollingStack(_ sections: [NSView], margin: CGFloat) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.setViews(sections, in: .top)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        var constraints: [NSLayoutConstraint] = [
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
        ]
        for section in sections {
            section.translatesAutoresizingMaskIntoConstraints = false
            constraints.append(section.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return scroll
    }

    /// Scrolls `scroll` so the document's point `y` is at the top, clamped to 0...(the last position),
    /// with an ease-out animation of `duration`. Off screen, or already there, it moves at once / not at all.
    static func smoothScroll(_ scroll: NSScrollView, to y: CGFloat, duration: TimeInterval = 0.35) {
        let clip = scroll.contentView
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let maxY = max(0, documentHeight - clip.bounds.height)
        let target = NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maxY))
        guard clip.bounds.origin != target else { return }
        guard scroll.window != nil else {
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
            return
        }
        Motion.animate(duration, {
            NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
        }, completion: {
            scroll.reflectScrolledClipView(clip)  // scroller in its final place
        })
    }

    /// Pins `child` to all four edges of `page`.
    static func embed(_ child: NSView, in page: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: page.topAnchor),
            child.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
    }

    /// A section: title (18 pt semibold), subtitle (13 pt secondary, hidden when empty), then `content`
    /// (usually one CardView), each as wide as the section.
    static func section(_ title: String, _ subtitle: String, _ content: [NSView]) -> NSStackView {
        return section(title, subtitleLabel: subtitle.isEmpty ? nil : NSTextField(wrappingLabelWithString: subtitle), content)
    }

    /// Same, with a subtitle label the page keeps and updates; nil for no subtitle.
    static func section(_ title: String, subtitleLabel: NSTextField?, _ content: [NSView]) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        var views: [NSView] = content
        if let subtitle = subtitleLabel {
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = .secondaryLabelColor
            subtitle.isSelectable = false
            views.insert(subtitle, at: 0)
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setViews([titleLabel] + views, in: .top)
        stack.setCustomSpacing(4, after: titleLabel)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A card row: title (15 pt medium) and detail (12 pt secondary) on the left, `controls` on the right.
    /// `detailLabel` is used instead of a new label when the page updates the detail text later.
    static func settingRow(_ title: String, _ detail: String = "", _ controls: [NSView],
                           detailLabel: NSTextField? = nil, symbol: String? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = title
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        left.setViews([titleLabel], in: .top)
        // No detail line at all when there is no text and no label to fill in later.
        if detailLabel != nil || !detail.isEmpty {
            let detailView = detailLabel ?? NSTextField(wrappingLabelWithString: detail)
            detailView.font = .systemFont(ofSize: 12)
            detailView.textColor = .secondaryLabelColor
            detailView.isSelectable = false
            detailView.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            left.addView(detailView, in: .top)
            detailView.translatesAutoresizingMaskIntoConstraints = false
            detailView.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        }
        guard let symbol = symbol else {
            return row(left: left, controls: controls)
        }
        let pair = NSStackView()
        pair.orientation = .horizontal
        pair.alignment = .centerY
        pair.spacing = 12
        pair.setViews([iconTile(symbol), left], in: .leading)
        return row(left: pair, controls: controls)
    }

    /// A 28 pt rounded tile with an SF Symbol, placed at the start of a row.
    static func iconTile(_ symbol: String) -> NSView {
        let tile = FillView()
        tile.fillColor = Theme.controlFill
        tile.cornerRadius = 8
        let imageView = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        imageView.contentTintColor = .labelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 28),
            tile.heightAnchor.constraint(equalToConstant: 28),
            imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        return tile
    }

    /// A card row with any view on the left and `controls` on the right; at least 52 pt high,
    /// 16 pt side padding. The left view takes the width the controls leave.
    static func row(left: NSView, controls: [NSView]) -> NSView {
        let row = HoverRowView()
        let right = NSStackView()
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 8
        right.setViews(controls, in: .trailing)
        right.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)

        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(left)
        row.addSubview(right)

        let fill = left.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -16)
        fill.priority = NSLayoutConstraint.Priority(300)
        let tight = row.heightAnchor.constraint(equalToConstant: 0)
        tight.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            left.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            left.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 12),
            left.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -12),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            fill,
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            right.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            right.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            right.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            tight,
        ])
        return row
    }

    /// A right-aligned value label with monospaced digits, `width` points wide.
    static func valueLabel(width: CGFloat = 44) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// Secondary text used in place of controls ("not set", "—").
    static func placeholder(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }
}

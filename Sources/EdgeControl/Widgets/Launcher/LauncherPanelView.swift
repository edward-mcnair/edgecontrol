import AppKit
import UniformTypeIdentifiers

@MainActor final class LauncherPanelView: NSView {
    let routingID = UUID()
    private(set) var items: [LauncherItem?] = []
    private(set) var page = 0
    private var showNames = true
    private var active = false
    private var save: ([LauncherItem?]) -> Void = { _ in }
    private var controls: [NSControl] = []
    private var geometry = CGSize.zero
    private var managing: Int?
    private var message: String?
    private var picker: NSOpenPanel?
    private var iconCache: [String: NSImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.045, alpha: 1).cgColor
        layer?.cornerRadius = 8
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    func configure(items: [LauncherItem?], showNames: Bool, active: Bool, save: @escaping ([LauncherItem?]) -> Void) {
        self.save = save
        let changed = self.items != items || self.showNames != showNames || self.active != active
        // Icons are re-read when the list changes, so a reinstalled or updated
        // app doesn't keep a stale or "missing" icon.
        if self.items != items { iconCache.removeAll() }
        self.items = items; self.showNames = showNames; self.active = active
        if !active { deactivate() }
        if changed || controls.isEmpty { rebuild() }
    }
    func deactivate() {
        active = false
        for slot in controls.compactMap({ $0 as? LauncherSlot }) { slot.touchEnded(cancelled: true) }
        MediaTouchRouting.shared.unregisterToolbar(routingID)
        picker?.cancel(nil)
        managing = nil
    }
    override func layout() {
        super.layout()
        if geometry != bounds.size { geometry = bounds.size; rebuild() }
    }
    private func label(_ text: String, frame: NSRect, size: CGFloat = 12) {
        let label = NSTextField(labelWithString: text)
        label.frame = frame; label.font = .systemFont(ofSize: size, weight: .medium)
        label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    @discardableResult
    private func button(_ title: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame; button.bezelStyle = .regularSquare
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.wantsLayer = true; button.layer?.cornerRadius = 8; button.layer?.masksToBounds = true
        button.isEnabled = active
        addSubview(button); controls.append(button)
        return button
    }
    private func rebuild() {
        for slot in controls.compactMap({ $0 as? LauncherSlot }) { slot.touchEnded(cancelled: true) }
        subviews.forEach { $0.removeFromSuperview() }
        controls = []
        guard bounds.width > 0, bounds.height > 0 else { return }
        if let index = managing {
            let name = item(at: index)?.name ?? "Application"
            label(name, frame: NSRect(x: 16, y: bounds.height - 44, width: bounds.width - 32, height: 24), size: 17)
            for (offset, pair) in [
                ("Replace App…", #selector(replaceApp)), ("Remove from Launcher", #selector(removeApp)),
                ("Cancel", #selector(closeManagement)),
            ].enumerated() {
                button(
                    pair.0,
                    frame: NSRect(
                        x: 16, y: bounds.height - 100 - CGFloat(offset) * 52,
                        width: bounds.width - 32, height: 44), action: pair.1)
            }
        } else {
            let grid = LauncherGrid(size: bounds.size)
            page = min(page, grid.pageCount(itemCount: items.count) - 1)
            let cellWidth = (bounds.width - 24) / CGFloat(grid.columns)
            let cellHeight = (bounds.height - 56) / CGFloat(grid.rows)
            for offset in 0..<grid.capacity {
                let index = page * grid.capacity + offset
                let slot = LauncherSlot(
                    frame: NSRect(
                        x: 12 + CGFloat(offset % grid.columns) * cellWidth,
                        y: bounds.height - 12 - CGFloat(offset / grid.columns + 1) * cellHeight,
                        width: cellWidth, height: cellHeight))
                let app = item(at: index)
                slot.appName = app?.name ?? ""; slot.showName = showNames; slot.isEnabled = active
                if let app {
                    if let cached = iconCache[app.path] {
                        slot.appIcon = cached
                    } else {
                        let url = app.resolvedURL()
                        let icon =
                            url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Application missing")
                        slot.appIcon = icon
                        // A missing app's placeholder isn't cached, so the real
                        // icon appears as soon as the app is back.
                        if url != nil { iconCache[app.path] = icon }
                    }
                }
                slot.setAccessibilityLabel(app.map { "Launch " + $0.name } ?? "Add application")
                // Hold / right-click equivalent for VoiceOver (VO-Command-Space).
                slot.setAccessibilityCustomActions(
                    app == nil
                        ? []
                        : [
                            NSAccessibilityCustomAction(name: "Replace or remove") { [weak self] in
                                self?.manageSlot(index)
                                return true
                            }
                        ])
                slot.toolTip =
                    app.map { $0.name + " — hold or right-click to manage" }
                    ?? "Choose an application, or drop one here"
                slot.activate = { [weak self] in self?.activateSlot(index) }
                slot.manage = { [weak self] in self?.manageSlot(index) }
                slot.dropApplication = { [weak self] url in self?.assign(url, at: index) ?? false }
                addSubview(slot); controls.append(slot)
            }
            let pages = grid.pageCount(itemCount: items.count)
            if pages > 1 {
                label(
                    "\(page + 1) / \(pages)",
                    frame: NSRect(x: 16, y: 14, width: max(30, bounds.width - 124), height: 18))
                button(
                    "‹", frame: NSRect(x: bounds.width - 108, y: 0, width: 44, height: 44),
                    action: #selector(previousPage)
                ).isEnabled = active && page > 0
                button(
                    "›", frame: NSRect(x: bounds.width - 56, y: 0, width: 44, height: 44), action: #selector(nextPage)
                ).isEnabled = active && page + 1 < pages
            } else {
                label(
                    message ?? "Hold an icon to edit", frame: NSRect(x: 16, y: 14, width: bounds.width - 32, height: 18)
                )
            }
        }
        if active { MediaTouchRouting.shared.registerToolbar(routingID, root: self, controls: controls) }
    }
    private func item(at index: Int) -> LauncherItem? { items.indices.contains(index) ? items[index] : nil }

    @discardableResult func assign(_ url: URL, at index: Int) -> Bool {
        guard active, index >= 0, let app = LauncherItem.application(at: url) else { return false }
        while items.count <= index { items.append(nil) }
        items[index] = app
        managing = nil; message = nil
        save(items); rebuild()
        return true
    }
    private func activateSlot(_ index: Int) {
        guard active else { return }
        guard let app = item(at: index) else { chooseApp(at: index); return }
        guard let url = app.resolvedURL() else {
            message = "\(app.name) is missing. Replace the app."
            manageSlot(index); return
        }
        if let note = LauncherWindowPlacement.prepare() {
            message = note
            rebuild()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            let failed = error != nil
            Task { @MainActor [weak self] in
                if let application {
                    LauncherWindowPlacement.relocateWindows(of: application) { [weak self] text in
                        self?.message = text
                        self?.rebuild()
                    }
                }
                guard failed, let self else { return }
                message = "Couldn’t open \(app.name). Hold to replace."
                rebuild()
            }
        }
    }
    private func manageSlot(_ index: Int) {
        guard active else { return }
        guard item(at: index) != nil else { chooseApp(at: index); return }
        managing = index; rebuild()
    }
    private func chooseApp(at index: Int) {
        guard active, picker == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"; panel.prompt = "Add App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker = panel
        DashboardFocus.activateForSystemSheet(window)
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in DashboardFocus.releaseIfIdle() }
            guard let self else { return }
            picker = nil
            if response == .OK, let url = panel.url { _ = assign(url, at: index) }
        }
    }
    @objc private func replaceApp() { if let managing { chooseApp(at: managing) } }
    @objc private func removeApp() {
        guard let managing, items.indices.contains(managing) else { return }
        items[managing] = nil
        while !items.isEmpty && items.last! == nil { items.removeLast() }
        self.managing = nil; message = nil; save(items); rebuild()
    }
    @objc private func closeManagement() { managing = nil; rebuild() }
    @objc private func previousPage() { page = max(0, page - 1); rebuild() }
    @objc private func nextPage() { page += 1; rebuild() }
}

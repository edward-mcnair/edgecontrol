import AppKit

/// One interaction implementation for physical touch and mouse. A completed
/// hold consumes the press, so releasing it never launches the application.
@MainActor final class LauncherSlot: NSButton, NativeTouchPressControl {
    var appIcon: NSImage?
    var appName = ""
    var showName = true
    var activate: (() -> Void)?
    var manage: (() -> Void)?
    var dropApplication: ((URL) -> Bool)?
    private var holdTask: Task<Void, Never>?
    private var tracking = false
    private var held = false
    private var mouseOrigin = CGPoint.zero
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        target = self; action = #selector(tapped)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped() { guard isEnabled else { return }; activate?() }

    func touchBegan() {
        guard isEnabled else { return }
        holdTask?.cancel()
        tracking = true; held = false; needsDisplay = true
        holdTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, tracking else { return }
            held = true; needsDisplay = true
            manage?()
        }
    }
    func touchMoved(distance: CGFloat) {
        if distance > 12 { touchEnded(cancelled: true) }
    }
    func touchEnded(cancelled: Bool) {
        holdTask?.cancel(); holdTask = nil
        let shouldActivate = tracking && !held && !cancelled && isEnabled
        tracking = false; needsDisplay = true
        if shouldActivate { activate?() }
    }
    override func mouseDown(with event: NSEvent) {
        // Control-click is the Mac's secondary click: manage, don't launch.
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        mouseOrigin = event.locationInWindow
        touchBegan()
    }
    override func mouseDragged(with event: NSEvent) {
        touchMoved(distance: hypot(event.locationInWindow.x - mouseOrigin.x, event.locationInWindow.y - mouseOrigin.y))
    }
    override func mouseUp(with event: NSEvent) {
        touchEnded(cancelled: !bounds.contains(convert(event.locationInWindow, from: nil)))
    }
    override func rightMouseDown(with event: NSEvent) {
        touchEnded(cancelled: true)
        if isEnabled { manage?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        // Custom drawing replaces NSButton's bezel. Clear its previous pixels
        // when resizing so old icon/label positions cannot remain visible.
        NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
        bounds.fill()
        let iconSize = max(24, min(bounds.width - 16, bounds.height - (showName ? 28 : 12)))
        let iconRect = NSRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize + (showName ? 24 : 0)) / 2,
            width: iconSize, height: iconSize)
        if tracking {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        }
        if let appIcon {
            appIcon.draw(in: iconRect)
        } else {
            let shape = NSBezierPath(roundedRect: iconRect.insetBy(dx: 3, dy: 3), xRadius: 13, yRadius: 13)
            NSColor.white.withAlphaComponent(0.035).setFill(); shape.fill()
            NSColor.white.withAlphaComponent(0.18).setStroke(); shape.lineWidth = 1; shape.stroke()
            NSColor.secondaryLabelColor.setStroke()
            let plus = NSBezierPath()
            plus.lineWidth = 2; plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: iconRect.midX - 9, y: iconRect.midY))
            plus.line(to: NSPoint(x: iconRect.midX + 9, y: iconRect.midY))
            plus.move(to: NSPoint(x: iconRect.midX, y: iconRect.midY - 9))
            plus.line(to: NSPoint(x: iconRect.midX, y: iconRect.midY + 9))
            plus.stroke()
        }
        if showName {
            let style = NSMutableParagraphStyle()
            style.alignment = .center; style.lineBreakMode = .byTruncatingTail
            (appName.isEmpty ? "Add app" : appName).draw(
                in: NSRect(x: 3, y: iconRect.minY - 24, width: bounds.width - 6, height: 18),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: appName.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    .paragraphStyle: style,
                ])
        }
    }
    private func droppedURL(_ sender: any NSDraggingInfo) -> URL? {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL])?.first
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, let url = droppedURL(sender), LauncherItem.application(at: url) != nil else { return [] }
        return .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEnabled, let url = droppedURL(sender) else { return false }
        return dropApplication?(url) ?? false
    }
}

import AppKit
import SwiftUI
import WebKit

/// Native controls can opt into a complete press lifecycle (for press-and-hold).
@MainActor protocol NativeTouchPressControl: AnyObject {
    func touchBegan()
    func touchMoved(distance: CGFloat)
    func touchEnded(cancelled: Bool)
}

/// Captures only gestures that begin inside a live media tile. The existing
/// HID service remains the sole device owner; no system mouse events are posted.
@MainActor
final class MediaTouchRouting {
    static let shared = MediaTouchRouting()
    private struct Region {
        weak var anchor: NSView?
        var frame: CGRect
    }
    private struct ToolbarControls {
        weak var root: NSView?
        var controls: [NSControl]
    }
    private var toolbars: [UUID: ToolbarControls] = [:]
    func registerToolbar(_ id: UUID, root: NSView, controls: [NSControl]) {
        toolbars[id] = ToolbarControls(root: root, controls: controls)
    }
    func unregisterToolbar(_ id: UUID) { toolbars.removeValue(forKey: id) }

    // Resolve native controls from their actual view frames, before SwiftUI's
    // dashboard gesture layers can intercept the normal window hit test.
    private func toolbarControl(at point: CGPoint, in window: NSWindow) -> NSControl? {
        for entry in toolbars.values {
            guard let root = entry.root, root.window === window,
                !root.isHiddenOrHasHiddenAncestor
            else { continue }
            for control in entry.controls where !control.isHiddenOrHasHiddenAncestor {
                if control.bounds.contains(control.convert(point, from: nil)) { return control }
            }
        }
        return nil
    }
    private var regions: [UUID: Region] = [:]
    private var captured: UUID?
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var dragged = false
    private var pressControl: (any NativeTouchPressControl)?

    func register(_ id: UUID, anchor: NSView, frame: CGRect) {
        regions[id] = Region(anchor: anchor, frame: frame)
    }
    func unregister(_ id: UUID) {
        regions.removeValue(forKey: id)
        if captured == id {
            pressControl?.touchEnded(cancelled: true)
            // Retain the gesture capture until release, without any action.
        }
    }
    func cancel() {
        pressControl?.touchEnded(cancelled: true)
        pressControl = nil
        captured = nil; dragged = false
    }

    func handle(point: CGPoint, pressed: Bool, wasPressed: Bool) -> Bool {
        if pressed && !wasPressed {
            cancel()
            captured =
                regions.filter { $0.value.frame.contains(point) && $0.value.anchor?.window != nil }
                .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }?
                .key
            start = point; previous = point; dragged = false
        }
        guard let id = captured else { return false }
        defer {
            previous = point
            if !pressed { cancel() }
        }
        // Keep a removed/disabled tile's gesture captured through release so it
        // cannot accidentally turn into a dashboard tap or page swipe.
        guard let region = regions[id], let anchor = region.anchor, let window = anchor.window else { return true }
        if hypot(point.x - start.x, point.y - start.y) > 12 { dragged = true }
        let local = CGPoint(x: point.x - region.frame.minX, y: anchor.bounds.height - (point.y - region.frame.minY))
        let windowPoint = anchor.convert(local, to: nil)
        if pressed && !wasPressed,
            let control = toolbarControl(at: windowPoint, in: window) as? any NativeTouchPressControl
        {
            pressControl = control
            control.touchBegan()
        }
        if let control = pressControl {
            if pressed {
                control.touchMoved(distance: hypot(point.x - start.x, point.y - start.y))
            } else {
                control.touchEnded(cancelled: dragged || !region.frame.contains(point))
                pressControl = nil
            }
            return true
        }
        if pressed && dragged {
            // User preference: dragging downward advances down the page.
            let delta = point.y - previous.y
            if abs(delta) > 0.1, let content = window.contentView,
                let target = content.hitTest(content.convert(windowPoint, from: nil)),
                let cg = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: Int32(delta), wheel2: 0, wheel3: 0)
            {
                // Without a location the event carries the desktop pointer's
                // position, and WebKit scrolls whatever is under the pointer
                // (usually the whole page) instead of the panel under the
                // finger. A window-less NSEvent reports its location in
                // screen space as `locationInWindow`, so place the event at
                // the touch's window coordinates (in top-left global space).
                let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
                cg.location = CGPoint(x: windowPoint.x, y: desktopTop - windowPoint.y)
                if let event = NSEvent(cgEvent: cg) { target.scrollWheel(with: event) }
            }
        } else if !pressed && wasPressed && !dragged && region.frame.contains(point) {
            Self.click(at: windowPoint, in: window)
        }
        return true
    }
    @discardableResult
    static func click(at point: CGPoint, in window: NSWindow) -> String {
        guard let content = window.contentView else { return "Tap outside content" }
        guard
            let target = shared.toolbarControl(at: point, in: window)
                ?? content.hitTest(content.convert(point, from: nil))
        else { return "Tap outside content" }
        // AppKit controls are invoked directly. NSWindow.sendEvent can resolve
        // SwiftUI controls using the physical pointer rather than this HID point.
        var controlAncestor: NSView? = target
        while let view = controlAncestor {
            if let button = view as? NSButton {
                guard button.isEnabled else { return "Disabled control" }
                button.performClick(nil)
                return "Toolbar button activated"
            }
            if let field = view as? NSTextField, field.isEditable {
                DashboardFocus.takeKeyboard(window)
                window.makeFirstResponder(field)
                field.selectText(nil)
                return "Toolbar search focused"
            }
            controlAncestor = view.superview
        }
        var ancestor: NSView? = target
        var browser: WKWebView?
        while let view = ancestor {
            if let web = view as? WKWebView { browser = web; break }
            ancestor = view.superview
        }
        if let browser {
            // Deliver through WebKit's hit view using public NSResponder
            // methods, without a global mouse event. WebKit accepts these as
            // trusted user taps even while another app is frontmost, so a tap
            // on the video doesn't take keyboard focus from the app you're
            // typing in; only a tap into a text field activates this app.
            window.makeFirstResponder(browser)
        }
        let time = ProcessInfo.processInfo.systemUptime
        let types: [NSEvent.EventType] =
            browser == nil ? [.leftMouseDown, .leftMouseUp] : [.mouseMoved, .leftMouseDown, .leftMouseUp]
        for type in types {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
            {
                if browser != nil {
                    switch type {
                    case .mouseMoved: target.mouseMoved(with: event)
                    case .leftMouseDown: target.mouseDown(with: event)
                    case .leftMouseUp: target.mouseUp(with: event)
                    default: break
                    }
                } else {
                    window.sendEvent(event)
                }
            }
        }
        if let browser { activateIfTyping(in: browser, window: window) }
        return browser == nil ? "Native tap sent" : "Web tap sent"
    }

    static let editableFocusScript = """
        (() => { const e = document.activeElement;
          return !!e && (e.isContentEditable || ['INPUT','TEXTAREA','SELECT'].includes(e.tagName)); })()
        """

    /// Brings this app forward only when the tap focused something you type
    /// into (YouTube's search box), so the keyboard reaches it.
    private static func activateIfTyping(in browser: WKWebView, window: NSWindow) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard (try? await browser.evaluateJavaScript(editableFocusScript)) as? Bool == true else { return }
            DashboardFocus.takeKeyboard(window)
        }
    }
}

struct MediaTouchAnchor: NSViewRepresentable {
    let id: UUID
    let frame: CGRect
    let enabled: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.id = id
        if enabled {
            MediaTouchRouting.shared.register(id, anchor: view, frame: frame)
        } else {
            MediaTouchRouting.shared.unregister(id)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(id: id) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        MediaTouchRouting.shared.unregister(coordinator.id)
    }
    @MainActor final class Coordinator {
        var id: UUID
        init(id: UUID) { self.id = id }
    }
}

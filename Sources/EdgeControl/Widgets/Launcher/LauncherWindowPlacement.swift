import AppKit
import ApplicationServices

/// AX uses a top-left desktop origin, while AppKit uses bottom-left.
enum LauncherWindowGeometry {
    static func accessibilityFrame(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }
    static func destination(for window: CGRect, excluded: CGRect, target: CGRect) -> CGRect? {
        guard excluded.contains(CGPoint(x: window.midX, y: window.midY)) else { return nil }
        let size = CGSize(width: min(window.width, target.width), height: min(window.height, target.height))
        return CGRect(
            x: target.midX - size.width / 2, y: target.midY - size.height / 2, width: size.width, height: size.height)
    }
    /// Where launched windows go: the display with the desktop pointer (where
    /// you're working) unless that's the XENEON, otherwise the menu-bar display
    /// (index 0) or the first other one. Frames are AppKit screen frames.
    static func targetIndex(screens: [CGRect], edgeIndex: Int, pointer: CGPoint) -> Int? {
        let others = screens.indices.filter { $0 != edgeIndex }
        if let underPointer = others.first(where: { screens[$0].contains(pointer) }) { return underPointer }
        return others.first
    }
}

@MainActor enum LauncherWindowPlacement {
    private static var generations: [pid_t: UUID] = [:]
    private static var tasks: [pid_t: Task<Void, Never>] = [:]
    private static var edge: NSScreen? {
        NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("XENEON") }
    }

    private static var askedForAccessibility = false

    /// Never blocks a launch. Returns a note for the launcher when its windows
    /// can't be kept off the XENEON: no other display, or no Accessibility
    /// permission (the system prompt is offered once per session).
    static func prepare() -> String? {
        guard let edge else { return nil }
        guard NSScreen.screens.contains(where: { $0 !== edge }) else {
            return "Only the XENEON is connected, so apps open here."
        }
        guard AXIsProcessTrusted() else {
            if !askedForAccessibility {
                askedForAccessibility = true
                // The value of kAXTrustedCheckOptionPrompt; the global itself isn't
                // concurrency-safe to reference under Swift 6.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return "To keep apps off the XENEON, allow EdgeControl in Privacy & Security → Accessibility."
        }
        return nil
    }

    // Safety net. With the dashboard never taking focus (DashboardFocus),
    // apps already open on the display you're using; this only moves a
    // window that still lands on the XENEON, such as one restored to a saved
    // position there.
    /// How long after a launch new windows are watched for.
    nonisolated static let watchDuration: Duration = .seconds(15)

    static func relocateWindows(of app: NSRunningApplication, report: @escaping @MainActor @Sendable (String) -> Void) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted(),
            let edgeIndex = NSScreen.screens.firstIndex(where: {
                $0.localizedName.localizedCaseInsensitiveContains("XENEON")
            }),
            let primary = NSScreen.screens.first,
            let targetIndex = LauncherWindowGeometry.targetIndex(
                screens: NSScreen.screens.map(\.frame), edgeIndex: edgeIndex, pointer: NSEvent.mouseLocation)
        else { return }
        // Screen geometry is read here, on the main actor; the Accessibility
        // calls below can each wait on a busy, just-launched app, so they run
        // off the main thread and never stall the dashboard or touch handling.
        let top = primary.frame.maxY
        let excluded = LauncherWindowGeometry.accessibilityFrame(NSScreen.screens[edgeIndex].frame, desktopTop: top)
        let destination = LauncherWindowGeometry.accessibilityFrame(
            NSScreen.screens[targetIndex].visibleFrame, desktopTop: top)
        tasks[pid]?.cancel()
        let generation = UUID()
        generations[pid] = generation
        tasks[pid] = Task.detached(priority: .utility) {
            // Apps create windows asynchronously (splash screens, restored
            // documents). Watch this launch for a while; this is not an ongoing
            // window manager, so windows opened later by other actions stay put.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: watchDuration)
            var reported = false
            while clock.now < deadline, !Task.isCancelled, kill(pid, 0) == 0 {
                if moveWindows(of: pid, excluded: excluded, destination: destination), !reported {
                    reported = true
                    await report("This app won’t allow its window to be moved.")
                }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
            }
            await MainActor.run {
                if generations[pid] == generation { tasks[pid] = nil; generations[pid] = nil }
            }
        }
    }

    /// One pass over the app's windows. Returns true when a move was refused.
    nonisolated private static func moveWindows(of pid: pid_t, excluded: CGRect, destination: CGRect) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return false }
        var refused = false
        for window in windows {
            guard let frame = frame(of: window),
                let moved = LauncherWindowGeometry.destination(for: frame, excluded: excluded, target: destination)
            else { continue }
            var position = moved.origin, size = moved.size
            if size != frame.size, let sizeValue = AXValueCreate(.cgSize, &size) {
                _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
            if let point = AXValueCreate(.cgPoint, &position),
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point) != .success
            {
                refused = true
            }
        }
        return refused
    }

    nonisolated private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}

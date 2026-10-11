import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

// MARK: - Touch Logger

enum TouchLogger {
    private static let logURL: URL = {
        let base =
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let directory = base.appendingPathComponent("Logs/EdgeControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("touch.log")
    }()

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let maxLogSize = 5_242_880  // 5 MB

    static func log(_ message: String) {
        // Rotate if exceeds 5 MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attrs[.size] as? UInt64, size > maxLogSize
        {
            try? FileManager.default.removeItem(at: logURL)
        }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
            let handle = try? FileHandle(forWritingTo: logURL)
        {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
            return
        }
        try? data.write(to: logURL, options: .atomic)
    }
}

// MARK: - HID Touch Input Source

@MainActor
protocol TouchInputSource: AnyObject {
    var onSample: ((RawTouchSample) -> Void)? { get set }
    var onOpenStatus: ((String) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class HIDTouchInputSource: NSObject, TouchInputSource {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var onSample: ((RawTouchSample) -> Void)?
    var onOpenStatus: ((String) -> Void)?
    private var sample = RawTouchSample()
    private var started = false
    private var openedDevices: [IOHIDDevice] = []
    /// Debug Mode only: raw report logging and the multi-touch mode test.
    var diagnostics: HIDDiagnostics?

    // Corsair XENEON EDGE vendor/product IDs
    private let vendorID = 10176
    private let productID = 2137

    func start() {
        guard !started else { return }
        started = true
        TouchLogger.log("HID touch source start")

        let matchings: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDPrimaryUsagePageKey as String: 1,
                kIOHIDPrimaryUsageKey as String: 2,
            ],
            [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDPrimaryUsagePageKey as String: 13,
                kIOHIDPrimaryUsageKey as String: 4,
            ],
            [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDPrimaryUsagePageKey as String: 65290,
                kIOHIDPrimaryUsageKey as String: 255,
            ],
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchings as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        IOHIDManagerRegisterInputValueCallback(
            manager,
            { context, _, _, value in
                guard let context else { return }
                Unmanaged<HIDTouchInputSource>.fromOpaque(context).takeUnretainedValue().handle(value: value)
            }, Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, _ in
                guard let context else { return }
                Unmanaged<HIDTouchInputSource>.fromOpaque(context).takeUnretainedValue().openMatchedDevicesIfNeeded()
            }, Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, _ in
                guard let context else { return }
                Unmanaged<HIDTouchInputSource>.fromOpaque(context).takeUnretainedValue().refreshOpenStatus()
            }, Unmanaged.passUnretained(self).toOpaque())

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess {
            let status = "manager open failed (\(result))"
            TouchLogger.log(status)
            onOpenStatus?(status)
            return
        }

        openMatchedDevicesIfNeeded()
    }

    func stop() {
        guard started else { return }
        TouchLogger.log("HID touch source stop")
        diagnostics?.detachAll()
        openedDevices.forEach { device in
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        openedDevices.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        started = false
    }

    private func openMatchedDevicesIfNeeded() {
        let devices = ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
            .sorted { usageKey($0) < usageKey($1) }

        openedDevices = devices.filter { device in
            guard !openedDevices.contains(where: { $0 === device }) else { return true }
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            let success = result == kIOReturnSuccess
            TouchLogger.log("device \(usageKey(device)) open \(success ? "ok" : "failed (\(result))")")
            if !success {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            } else {
                diagnostics?.attach(device, key: usageKey(device))
            }
            return success
        }
        refreshOpenStatus()
    }

    private func refreshOpenStatus() {
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        openedDevices = openedDevices.filter { current in devices.contains(where: { $0 === current }) }

        let status: String
        switch (openedDevices.count, devices.count) {
        case (_, 0): status = "no XENEON HID devices found"
        case let (a, t) where a == t: status = "seize active (\(a)/\(t))"
        case (0, let t): status = "seize failed (0/\(t))"
        default: status = "partial seize (\(openedDevices.count)/\(devices.count))"
        }
        TouchLogger.log(status)
        onOpenStatus?(status)
    }

    private func usageKey(_ device: IOHIDDevice) -> String {
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? -1
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? -1
        return "u\(page):\(usage)"
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        switch (IOHIDElementGetUsagePage(element), IOHIDElementGetUsage(element)) {
        case (1, 48): sample.x = IOHIDValueGetIntegerValue(value)
        case (1, 49): sample.y = IOHIDValueGetIntegerValue(value)
        case (9, 1): sample.pressed = IOHIDValueGetIntegerValue(value) != 0
        default: return
        }
        onSample?(sample)
    }
}

// MARK: - Hardware Touch Service

@MainActor
public final class HardwareTouchService: ObservableObject {
    @Published public private(set) var state = TouchRuntimeState()

    // Touch gesture detection
    @Published public private(set) var swipeDirection: SwipeDirection?
    /// Live horizontal finger travel in screen points while a drag is in
    /// progress; nil when no finger is down or the drag is vertical. Lets the
    /// dashboard track the finger instead of waiting for release.
    @Published public private(set) var liveSwipeDX: CGFloat?

    public enum SwipeDirection: Equatable {
        case left, right
    }

    /// Zone registry for tap-to-action (no mouse movement needed)
    public let zoneRegistry = TouchZoneRegistry()

    @Published var guidedCalibration: GuidedCalibration?
    nonisolated static let calibrationCancelZone = "calibration_cancel"
    nonisolated static let calibrationRetryZone = "calibration_retry"
    /// A quick tap during calibration (vs. the one-second hold a target needs).
    private var calibrationTapStart: (point: CGPoint, time: Date)?
    @Published var calibrationNotice = ""
    func beginGuidedCalibration() {
        guard hidStatus.hasPrefix("seize active") else {
            calibrationNotice = "Touch access is unavailable. Check Input Monitoring and reconnect the display."
            return
        }
        MediaTouchRouting.shared.cancel()
        EditTouchRouting.shared.cancelActive()
        touchStartPoint = nil; liveSwipeDX = nil
        guidedCalibration = GuidedCalibration()
        calibrationNotice = ""
        startCalibrationTimer()
        DashboardFocus.takeKeyboard(holder: "calibration")
    }
    func cancelGuidedCalibration() {
        guidedCalibration = nil
        latestSample = RawTouchSample(); previousPressed = false
        stopCalibrationTimer()
        calibrationNotice = "Calibration cancelled. Previous settings retained."
        DashboardFocus.returnKeyboard(holder: "calibration")
    }

    private var touchSource: TouchInputSource?
    private var calibration = CalibrationModel()
    private var dwellCalibration = DwellCalibrationState()
    private var latestSample = RawTouchSample()
    private var renderBounds = CGRect(x: 0, y: 0, width: 2560, height: 720)
    private var timer: Timer?
    private var hidStatus = "starting"
    private var eventSequence = 0
    private var pressSequence = 0
    private var previousPressed = false

    // Swipe tracking
    private var touchStartPoint: CGPoint?
    private var touchStartTime: Date?

    /// Apps that also seize the XENEON's HID device. Only one process can own
    /// it, so this app gives way while one is running and takes the panel
    /// back when it quits. (A side-by-side test build listed the released app
    /// here; nothing is listed upstream.)
    nonisolated static let competingBundleIDs: Set<String> = []
    /// Why touch is off, in words; empty while touch works.
    @Published var touchNotice = ""
    /// Debug Mode: log raw touchscreen reports (see HIDDiagnostics).
    private(set) var diagnosticsEnabled = false
    @Published var diagnosticsNotice = ""
    func setDiagnostics(_ enabled: Bool) {
        guard enabled != diagnosticsEnabled else { return }
        diagnosticsEnabled = enabled
        diagnosticsNotice = enabled ? "Recording touchscreen reports to ~/Library/Logs/EdgeControl/touch.log" : ""
        if wantsTouch { start() }  // reopen the device with or without logging
    }

    private var wantsTouch = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var requestedInputMonitoring = false

    public init() {}

    private var competitorRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            Self.competingBundleIDs.contains($0.bundleIdentifier ?? "")
        }
    }

    private func observeCompetingApps() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard let id = app?.bundleIdentifier, Self.competingBundleIDs.contains(id) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.wantsTouch else { return }
                        // Relaunch either way: start() yields while a competitor
                        // runs and acquires the panel once none does.
                        self.start()
                    }
                })
        }
    }

    /// Plain-language status for the HID open result.
    private func describe(openStatus status: String) -> String {
        if status.hasPrefix("seize active") { return "" }
        if status.hasPrefix("no XENEON") { return "XENEON touchscreen not found. Check its USB-C cable." }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            if !requestedInputMonitoring {
                requestedInputMonitoring = true
                // Adds the app to the Input Monitoring list (and may prompt).
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            return
                "Touch needs Input Monitoring: System Settings → Privacy & Security → Input Monitoring → turn on EdgeControl, then reopen the app."
        }
        return "Touch is unavailable (\(status)). Another app may be using the touchscreen."
    }

    public func start() {
        stop()
        wantsTouch = true
        observeCompetingApps()
        if competitorRunning {
            hidStatus = "yielded to EdgeControl"
            touchNotice =
                "Touch is off while the original EdgeControl is running. Quit it and touch returns automatically."
            TouchLogger.log("touch yielded: competing app running")
            refreshState()
            return
        }
        touchNotice = ""
        TouchLogger.log("hardware touch service start")

        if let saved = CalibrationPersistence.load() {
            calibration = saved
            if saved.validationError() == nil {
                dwellCalibration.markComplete()
            }
        }

        let source = HIDTouchInputSource()
        source.diagnostics = diagnosticsEnabled ? HIDDiagnostics() : nil
        source.onSample = { [weak self] sample in
            self?.handle(sample: sample)
        }
        source.onOpenStatus = { [weak self] status in
            guard let self else { return }
            self.hidStatus = status
            self.touchNotice = self.describe(openStatus: status)
            self.eventSequence += 1
            self.refreshState()
        }
        source.start()
        touchSource = source

        // Start calibration timer only if calibration is still needed
        if dwellCalibration.activeCorner != nil {
            startCalibrationTimer()
        }
        refreshState()
    }

    public func stop() {
        wantsTouch = false
        TouchLogger.log("hardware touch service stop")
        MediaTouchRouting.shared.cancel()
        EditTouchRouting.shared.cancelActive()
        guidedCalibration = nil
        timer?.invalidate()
        timer = nil
        touchSource?.stop()
        touchSource = nil
        latestSample = RawTouchSample()
        hidStatus = "inactive"
        eventSequence = 0
        pressSequence = 0
        previousPressed = false
        state = TouchRuntimeState()
    }

    public func updateRenderBounds(_ bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderBounds = bounds
        refreshState()
    }

    public func resetCalibration() {
        calibration = CalibrationModel()
        dwellCalibration = DwellCalibrationState()
        try? CalibrationPersistence.clear()
        startCalibrationTimer()
        refreshState()
    }

    public func consumeSwipe() {
        swipeDirection = nil
    }

    /// Dashboard-level controls drawn above the page grid.
    private func isDashboardChrome(_ point: CGPoint) -> Bool {
        zoneRegistry.zones.contains { ["edit_toggle", "settings_gear"].contains($0.id) && $0.contains(point) }
    }

    private var bounceFilter = TouchBounceFilter()

    private func handle(sample: RawTouchSample) {
        // A lifting second finger arrives as a separate, too-fast touch.
        guard
            bounceFilter.accept(
                pressed: sample.pressed, wasPressed: previousPressed,
                at: ProcessInfo.processInfo.systemUptime)
        else {
            previousPressed = sample.pressed
            latestSample = sample
            return
        }
        if guidedCalibration != nil {
            // Holds measure targets (tickCalibration). A quick tap can reach
            // only the overlay's Cancel / Try again buttons, mapped through the
            // calibration currently in use.
            let mapped =
                calibration.validationError() == nil
                ? calibration.mappedPoint(for: CGPoint(x: sample.x, y: sample.y), in: renderBounds) : nil
            if sample.pressed && !previousPressed {
                calibrationTapStart = mapped.map { ($0, Date()) }
            } else if !sample.pressed && previousPressed, let start = calibrationTapStart {
                calibrationTapStart = nil
                if Date().timeIntervalSince(start.time) < 0.5 {
                    _ = zoneRegistry.handleTap(
                        at: start.point, only: [Self.calibrationCancelZone, Self.calibrationRetryZone])
                }
            }
            latestSample = sample
            previousPressed = sample.pressed
            refreshState()
            return
        }
        let wasPressed = previousPressed
        if calibration.validationError() == nil,
            let point = calibration.mappedPoint(for: CGPoint(x: sample.x, y: sample.y), in: renderBounds),
            EditTouchRouting.shared.handle(
                point: point, pressed: sample.pressed, wasPressed: wasPressed,
                // The Done/Settings buttons sit over the page; they keep their taps.
                allowStart: !isDashboardChrome(point))
                || MediaTouchRouting.shared.handle(point: point, pressed: sample.pressed, wasPressed: wasPressed)
        {
            touchStartPoint = nil
            touchStartTime = nil
            liveSwipeDX = nil
            previousPressed = sample.pressed
            eventSequence += 1
            latestSample = sample
            refreshState()
            return
        }

        if sample.pressed && !wasPressed {
            pressSequence += 1
            // Swipe start
            let rawPoint = CGPoint(x: sample.x, y: sample.y)
            if let mapped = calibration.mappedPoint(for: rawPoint, in: renderBounds) {
                touchStartPoint = mapped
                touchStartTime = Date()
            }
        }

        if sample.pressed, let startPoint = touchStartPoint {
            let rawPoint = CGPoint(x: sample.x, y: sample.y)
            if let current = calibration.mappedPoint(for: rawPoint, in: renderBounds) {
                let dx = current.x - startPoint.x
                let dy = current.y - startPoint.y
                // Engage once the drag reads as horizontal; stay engaged
                // until release so the page doesn't flicker mid-gesture.
                if liveSwipeDX != nil || (abs(dx) > 12 && abs(dx) > abs(dy) * 1.5) {
                    liveSwipeDX = dx
                }
            }
        }

        if !sample.pressed && wasPressed {
            // Touch release — classify as tap or swipe
            if let startPoint = touchStartPoint,
                let startTime = touchStartTime
            {
                let rawPoint = CGPoint(x: latestSample.x, y: latestSample.y)
                if let endPoint = calibration.mappedPoint(for: rawPoint, in: renderBounds) {
                    let dx = endPoint.x - startPoint.x
                    let dy = endPoint.y - startPoint.y
                    let distance = hypot(dx, dy)
                    let duration = Date().timeIntervalSince(startTime)

                    if abs(dx) > 100 && abs(dx) > abs(dy) * 2 && duration < 1.0 {
                        // Swipe
                        swipeDirection = dx < 0 ? .left : .right
                    } else if distance < 30 && duration < 0.4 {
                        // Tap — hit-test registered touch zones
                        let hit = zoneRegistry.handleTap(at: startPoint)
                        TouchLogger.log("tap at (\(Int(startPoint.x)),\(Int(startPoint.y))) — \(hit ? "hit" : "miss")")
                    }
                }
            }
            touchStartPoint = nil
            touchStartTime = nil
            liveSwipeDX = nil
        }

        previousPressed = sample.pressed
        eventSequence += 1
        latestSample = sample
        refreshState()
    }

    /// Start the 30fps calibration timer (only runs during active calibration).
    private func startCalibrationTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickCalibration(delta: 1.0 / 30.0)
            }
        }
    }

    /// Stop the calibration timer when calibration is complete or idle.
    private func stopCalibrationTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tickCalibration(delta: TimeInterval) {
        if var session = guidedCalibration {
            session.update(sample: latestSample, delta: delta, bounds: renderBounds)
            if session.complete, let candidate = session.candidate {
                do {
                    try CalibrationPersistence.save(candidate)
                    calibration = candidate
                    dwellCalibration.markComplete()
                    guidedCalibration = nil
                    touchStartPoint = nil; previousPressed = latestSample.pressed
                    calibrationNotice = "Touch calibration saved. Center accuracy check passed."
                    stopCalibrationTimer()
                    DashboardFocus.returnKeyboard(holder: "calibration")
                    refreshState()
                    return
                } catch {
                    session.complete = false
                    session.error = "Could not save calibration. Your previous settings remain active."
                }
            }
            guidedCalibration = session
            return
        }

        if let corner = dwellCalibration.activeCorner {
            let rawPoint = CGPoint(x: latestSample.x, y: latestSample.y)
            if dwellCalibration.update(point: rawPoint, pressed: latestSample.pressed, delta: delta) {
                calibration.set(corner, point: rawPoint)
                try? CalibrationPersistence.save(calibration)
                dwellCalibration.advance()
            }
            refreshState()
        } else {
            // Calibration complete or idle — stop the timer
            stopCalibrationTimer()
        }
    }

    private func refreshState() {
        let rawPoint = CGPoint(x: latestSample.x, y: latestSample.y)
        let validation = calibration.validationError()
        let mappedPoint = validation == nil ? calibration.mappedPoint(for: rawPoint, in: renderBounds) : nil
        state = TouchRuntimeState(
            rawSample: latestSample,
            mappedPoint: mappedPoint,
            hidStatus: hidStatus,
            calibrationStatus: dwellCalibration.statusText,
            calibrationValidation: validation ?? "Calibrated",
            calibrationSummary: calibration.summary,
            isCalibrated: validation == nil,
            isPressed: latestSample.pressed,
            sequence: eventSequence,
            pressSequence: pressSequence
        )
    }
}

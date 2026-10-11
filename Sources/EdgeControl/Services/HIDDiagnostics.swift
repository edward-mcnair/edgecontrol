import Foundation
import IOKit.hid

/// Debug Mode's touchscreen diagnostics: records what the XENEON actually
/// sends, for diagnosing touch problems.
///
/// The panel's descriptor offers two ways of reporting: a single-pointer mouse
/// (report 7, what touch uses) and a 10-contact digitizer (report 13),
/// selected by the HID "Input Mode" feature (report 33). Measured on
/// 2026-10-11: on this Mac the panel sends only report 7, and the standard
/// multi-input request (mode 2, device index 0) is acknowledged but changes
/// nothing, so multi-touch isn't available. This logs every report that
/// arrives and the mode the panel reports.
@MainActor
final class HIDDiagnostics {
    static let inputModeReport = 33
    /// Enough to see a few touches without flooding the log.
    private static let reportLogLimit = 1500

    private var buffers: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>)] = []
    private var logged = 0

    /// Starts logging raw input reports from an opened device.
    func attach(_ device: IOHIDDevice, key: String) {
        let size = max(
            64, (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffers.append((device, buffer))
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, size,
            { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                MainActor.assumeIsolated {
                    Unmanaged<HIDDiagnostics>.fromOpaque(context).takeUnretainedValue().log(
                        reportID: reportID, bytes: bytes)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        TouchLogger.log("diag: logging \(key), max input report \(size) bytes")
        if key == "u13:4" {
            let mode = Self.readFeature(device, id: Self.inputModeReport, length: 3)
            TouchLogger.log("diag: input mode report 33 = \(mode.map(Self.hex) ?? "unreadable")")
            let maxContacts = Self.readFeature(device, id: 10, length: 2)
            TouchLogger.log("diag: contact count max report 10 = \(maxContacts.map(Self.hex) ?? "unreadable")")
        }
    }

    /// Stops logging and frees the report buffers. Call before closing devices.
    func detachAll() {
        for (device, buffer) in buffers {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 0, nil, nil)
            buffer.deallocate()
        }
        buffers.removeAll()
    }

    private func log(reportID: UInt32, bytes: [UInt8]) {
        guard logged < Self.reportLogLimit else { return }
        logged += 1
        TouchLogger.log("diag: report \(reportID) (\(bytes.count) bytes) \(Self.hex(Array(bytes.prefix(40))))")
        if logged == Self.reportLogLimit { TouchLogger.log("diag: report log limit reached") }
    }

    private static func readFeature(_ device: IOHIDDevice, id: Int, length: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: length)
        buffer[0] = UInt8(id)
        var size = CFIndex(length)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), &buffer, &size)
        return result == kIOReturnSuccess ? Array(buffer.prefix(size)) : nil
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

import Foundation
import CoreGraphics

/// Stages measurements without changing the saved calibration. Inset targets
/// are extrapolated to panel corners to retain the existing calibration format.
struct GuidedCalibration: Equatable {
    static let targets: [CGPoint] = [
        CGPoint(x: 0.08, y: 0.15), CGPoint(x: 0.92, y: 0.15), CGPoint(x: 0.08, y: 0.85), CGPoint(x: 0.92, y: 0.85),
        CGPoint(x: 0.5, y: 0.5),
    ]
    var step = 0
    var progress: Double = 0
    var awaitingRelease = true
    var error: String?
    private var stable: CGPoint?
    private var measurements: [CGPoint] = []
    var candidate: CalibrationModel?
    var complete = false

    mutating func update(sample: RawTouchSample, delta: Double, bounds: CGRect) {
        guard error == nil, !complete else { return }
        if awaitingRelease {
            if !sample.pressed { awaitingRelease = false }
            return
        }
        guard sample.pressed else { stable = nil; progress = 0; return }
        let point = CGPoint(x: sample.x, y: sample.y)
        if let stable, hypot(point.x - stable.x, point.y - stable.y) <= 100 {
            progress += delta
        } else {
            stable = point; progress = delta
        }
        guard progress >= 1, let measured = stable else { return }
        if step < 4 {
            measurements.append(measured)
            step += 1
            if step == 4 { candidate = Self.model(from: measurements) }
            if step == 4 && candidate == nil {
                error = "Those corner measurements could not be used. Try again and hold the center of each target."
            }
        } else {
            guard let mapped = candidate?.mappedPoint(for: measured, in: bounds),
                hypot(mapped.x - bounds.midX, mapped.y - bounds.midY) <= 25
            else {
                error =
                    "The center check was more than 25 points off. Your previous calibration is unchanged. Try again from your normal seated position."
                return
            }
            complete = true
        }
        awaitingRelease = true; progress = 0; stable = nil
    }

    static func model(from samples: [CGPoint]) -> CalibrationModel? {
        guard samples.count == 4 else { return nil }
        // Reject reversed/folded quadrilaterals while allowing either HID axis direction.
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        let polygon = [samples[0], samples[1], samples[3], samples[2]]
        let signs = (0..<4).map { cross(polygon[$0], polygon[($0 + 1) % 4], polygon[($0 + 2) % 4]) }
        guard signs.allSatisfy({ $0 > 1 }) || signs.allSatisfy({ $0 < -1 }) else { return nil }
        func extrapolate(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let u = (x - 0.08) / 0.84, v = (y - 0.15) / 0.70
            let weights = [(1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v]
            return CGPoint(
                x: zip(samples, weights).reduce(0) { $0 + $1.0.x * $1.1 },
                y: zip(samples, weights).reduce(0) { $0 + $1.0.y * $1.1 })
        }
        var model = CalibrationModel()
        for (corner, p) in zip(
            CalibrationModel.Corner.allCases,
            [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)])
        {
            model.set(corner, point: extrapolate(p.x, p.y))
        }
        return model.validationError() == nil ? model : nil
    }
}

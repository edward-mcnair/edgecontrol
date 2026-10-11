import CoreGraphics
import Foundation

/// Hardware-touch editing for the dashboard. SwiftUI drag gestures only see
/// the mouse, so in edit mode the current page registers a surface here and
/// HardwareTouchService hands it each mapped sample first: drag a widget to
/// move it, drag its bottom-right corner to resize, tap it to select, tap its
/// ✕ to remove. The page applies changes through the same code its mouse
/// gestures use.
@MainActor
final class EditTouchRouting {
    static let shared = EditTouchRouting()

    enum Part: Equatable { case body, resize, remove }
    struct Hit: Equatable {
        let instanceId: String
        let part: Part
    }
    struct Surface {
        let pageId: String
        /// Page origin in dashboard touch coordinates.
        var origin: CGPoint
        /// Hit-tests a page-local point, topmost widget first.
        let hitTest: (CGPoint) -> Hit?
        /// Live feedback while a finger moves (translation in points).
        let update: (Hit, CGSize) -> Void
        /// Gesture finished. `moved` is false for a tap.
        let finish: (Hit, CGSize, _ moved: Bool) -> Void
        /// Gesture abandoned (edit mode ended, page changed).
        let cancel: () -> Void
    }

    /// Movement before a press counts as a drag rather than a tap.
    static let dragThreshold: CGFloat = 8

    private var surface: Surface?
    private var active: Hit?
    private var start = CGPoint.zero
    private var moved = false

    var isTracking: Bool { active != nil }

    func register(_ surface: Surface) {
        if let current = self.surface, current.pageId != surface.pageId { cancelActive() }
        self.surface = surface
    }

    func unregister(pageId: String) {
        guard surface?.pageId == pageId else { return }
        cancelActive()
        surface = nil
    }

    func cancelActive() {
        if active != nil { surface?.cancel() }
        active = nil
        moved = false
    }

    /// Returns true when the sample belongs to an edit gesture. A press that
    /// starts on empty grid, or when `allowStart` is false (dashboard chrome
    /// such as the Done button), is left for the normal tap path.
    func handle(point: CGPoint, pressed: Bool, wasPressed: Bool, allowStart: Bool = true) -> Bool {
        guard let surface else { return false }
        if pressed && !wasPressed {
            cancelActive()
            guard allowStart else { return false }
            let local = CGPoint(x: point.x - surface.origin.x, y: point.y - surface.origin.y)
            guard let hit = surface.hitTest(local) else { return false }
            active = hit
            start = point
            return true
        }
        guard let hit = active else { return false }
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        if hypot(translation.width, translation.height) > Self.dragThreshold { moved = true }
        if pressed {
            if moved, hit.part != .remove { surface.update(hit, translation) }
        } else {
            active = nil
            surface.finish(hit, translation, moved)
            moved = false
        }
        return true
    }
}

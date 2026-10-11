import Foundation

/// Drops the stray "second finger" the XENEON reports in mouse mode.
///
/// The panel reports a single pointer. When two fingers lift a moment apart,
/// the one still down shows up as a separate touch starting a few
/// milliseconds after the first one ended (8–23 ms in the Debug Mode log,
/// 2026-10-11), which would otherwise count as a tap wherever it lands. A
/// person can't release and press again that fast (a quick double tap leaves
/// roughly 80 ms or more between them), so a press that starts within
/// `window` of a release is ignored until it lifts.
struct TouchBounceFilter {
    var window: TimeInterval = 0.05
    private var lastRelease: TimeInterval = -.infinity
    private var ignoring = false

    /// Whether to process this sample. `time` is seconds on any steady clock.
    mutating func accept(pressed: Bool, wasPressed: Bool, at time: TimeInterval) -> Bool {
        if pressed && !wasPressed {
            ignoring = time - lastRelease < window
        }
        let accepted = !ignoring
        if !pressed && wasPressed {
            if !ignoring { lastRelease = time }
            ignoring = false
        }
        return accepted
    }
}

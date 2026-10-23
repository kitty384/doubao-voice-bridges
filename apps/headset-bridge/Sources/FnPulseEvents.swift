import CoreGraphics
import Dispatch

/// Builds events without posting them. Refresh both timestamps when they are
/// actually posted: the preallocated release must not retain its creation time.
enum FnPulseEvents {
    static let marker: Int64 = 0x444f5542414f
    static let duration: Double = 0.06

    static func makePair() -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: false) else { return nil }
        for event in [down, up] {
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: 63)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        return (down, up)
    }

    static func prepare(_ event: CGEvent, down: Bool, currentFlags: CGEventFlags,
                        timestamp: CGEventTimestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)) {
        event.flags = down ? currentFlags.union(.maskSecondaryFn) : currentFlags.subtracting(.maskSecondaryFn)
        event.timestamp = timestamp
    }
}

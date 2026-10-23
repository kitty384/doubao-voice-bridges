import CoreGraphics
import Foundation

@main enum FnPulseEventsTest {
    static func main() {
        guard let pair = FnPulseEvents.makePair() else {
            fputs("Event allocation failed; this check needs macOS event services. No key was posted.\n", stderr)
            exit(1)
        }
        let start: CGEventTimestamp = 1_000_000_000
        pair.up.timestamp = start
        FnPulseEvents.prepare(pair.down, down: true, currentFlags: [.maskShift], timestamp: start)
        FnPulseEvents.prepare(pair.up, down: false, currentFlags: [.maskShift, .maskSecondaryFn], timestamp: start + 60_000_000)
        precondition(pair.down.type == .flagsChanged && pair.up.type == .flagsChanged)
        precondition(pair.down.getIntegerValueField(.keyboardEventKeycode) == 63 && pair.up.getIntegerValueField(.keyboardEventKeycode) == 63)
        precondition([pair.down, pair.up].allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == FnPulseEvents.marker })
        precondition(pair.down.flags == [.maskShift, .maskSecondaryFn])
        precondition(pair.up.flags == [.maskShift])
        precondition(pair.up.timestamp - pair.down.timestamp == 60_000_000)
        // Reuse the same preparation method for a later stop-click pair. Its
        // release must describe that click, not the first click or allocation.
        guard let stop = FnPulseEvents.makePair() else { exit(1) }
        FnPulseEvents.prepare(stop.down, down: true, currentFlags: [], timestamp: start + 5_000_000_000)
        FnPulseEvents.prepare(stop.up, down: false, currentFlags: [.maskSecondaryFn], timestamp: start + 5_060_000_000)
        precondition(stop.down.timestamp > pair.up.timestamp)
        precondition(stop.up.timestamp - stop.down.timestamp == 60_000_000)
        precondition(stop.up.flags.isEmpty)
        stop.up.timestamp = 1
        FnPulseEvents.prepare(stop.up, down: false, currentFlags: [])
        precondition(stop.up.timestamp > 1)
        print("FN_EVENT_SELF_TEST_OK event_checks=10 posted_events=0")
    }
}

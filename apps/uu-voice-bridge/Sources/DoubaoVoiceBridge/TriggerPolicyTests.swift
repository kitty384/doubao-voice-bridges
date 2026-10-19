import CoreGraphics

/// Constructs and inspects events only. Does not post keys or record audio.
enum TriggerPolicyTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append("Fn policy: \(label)") }
        }
        check(FnKeyPolicy.keyCode == 63, "Fn virtual key")
        check(FnKeyPolicy.transition(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn) == true, "Fn down")
        check(FnKeyPolicy.transition(type: .flagsChanged, keyCode: 63, flags: []) == false, "Fn up")
        check(FnKeyPolicy.transition(type: .flagsChanged, keyCode: 59, flags: .maskSecondaryFn) == nil, "left Control is not the trigger")
        check(FnKeyPolicy.transition(type: .flagsChanged, keyCode: 122, flags: []) == nil, "F1 is not Fn")
        check(FnKeyPolicy.transition(type: .flagsChanged, keyCode: 109, flags: []) == nil, "F10 is not Fn")
        check(FnKeyPolicy.transition(type: .keyDown, keyCode: 63, flags: .maskSecondaryFn) == nil, "ignore ordinary keyDown")
        check(FnKeyPolicy.conflictingFlags.contains(.maskControl), "Fn plus Control is a chord")
        let down = LocalFnEventPolicy.flags(down: true, current: [])
        check(down.contains(.maskSecondaryFn), "local event sets Fn")
        check(!down.contains(.maskControl) && down.rawValue & 1 == 0, "local event never adds Control or left-Control device bit")
        let up = LocalFnEventPolicy.flags(down: false, current: [.maskSecondaryFn])
        check(!up.contains(.maskSecondaryFn), "cancel/release clears Fn even if current flags still contain physical Fn")
        let otherModifiers: CGEventFlags = [.maskControl, .maskShift]
        check(LocalFnEventPolicy.flags(down: false, current: otherModifiers.union(.maskSecondaryFn)) == otherModifiers, "preserve unrelated physical modifiers")
        var state = HoldGestureState()
        _ = state.handle(.triggerDown(targetAvailable: true))
        state.reset()
        check(state.handle(.triggerUp) == [.passThrough] && state.phase == .idle, "cancelled hold cannot submit")
        if let pair = LocalFnEventPair.make() {
            check(pair.down.type == .flagsChanged && pair.up.type == .flagsChanged &&
                pair.down.getIntegerValueField(.keyboardEventKeycode) == 63 &&
                pair.up.getIntegerValueField(.keyboardEventKeycode) == 63 &&
                pair.down.flags.contains(.maskSecondaryFn) && !pair.up.flags.contains(.maskSecondaryFn),
                "both local events are Fn down/up, never Control")
            check(pair.down.getIntegerValueField(.eventSourceUserData) == TriggerHoldMonitor.syntheticEventMarker &&
                pair.up.getIntegerValueField(.eventSourceUserData) == TriggerHoldMonitor.syntheticEventMarker,
                "Fn pair carries bridge marker")
            pair.up.timestamp = 1
            LocalFnEventPair.refreshReleaseTimestamp(pair.up)
            check(pair.up.timestamp > 1, "release timestamp refreshed at posting")
        } else { failures.append("Fn pair allocation failed") }
        return failures
    }
}

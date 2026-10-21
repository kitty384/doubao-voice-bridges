import Foundation

/// Monotonic-time recovery. A synthetic headset pulse is never inferred from
/// the physical keyboard flags, which do not describe that pulse.
struct FnPressWatchdog {
    private(set) var pressID: UInt64?
    private var source: FnTriggerSource = .keyboard
    private var beganAt: TimeInterval = 0
    private var quietSince: TimeInterval?

    mutating func begin(id: UInt64, source: FnTriggerSource, now: TimeInterval) {
        pressID = id
        self.source = source
        beganAt = now
        quietSince = nil
    }

    mutating func end(id: UInt64) {
        guard pressID == id else { return }
        pressID = nil
        quietSince = nil
    }

    mutating func recoveryCandidate(now: TimeInterval, physicalFnDown: Bool) -> UInt64? {
        guard let id = pressID else { return nil }
        if source == .headset { return now - beganAt >= 1.0 ? id : nil }
        if physicalFnDown { quietSince = nil; return nil }
        if quietSince == nil { quietSince = now }
        guard now - beganAt >= 0.4, now - (quietSince ?? now) >= 0.3 else { return nil }
        return id
    }
}

/// At most one attempt per real foreground entry. Failed eligibility is not
/// retried, and even separate entries are spaced apart.
struct FnForegroundRearmPolicy {
    private var wasUU = false
    private var lastRearm: TimeInterval?
    mutating func enteredUU(_ isUU: Bool) -> Bool {
        defer { wasUU = isUU }
        return isUU && !wasUU
    }
    mutating func allow(now: TimeInterval) -> Bool {
        if let lastRearm, now - lastRearm < 3.0 { return false }
        lastRearm = now
        return true
    }
}

/// Covers the asynchronous focus handoff after opening/restoring the composer.
/// The next Fn is native even if UU briefly remains the frontmost application.
struct FnComposerHandoffPolicy {
    private var deadline: TimeInterval?
    mutating func suspend(now: TimeInterval) { deadline = now + 0.75 }
    mutating func reset() { deadline = nil }
    mutating func allowsEligibility(targetAvailable: Bool, now: TimeInterval) -> Bool {
        guard targetAvailable else { deadline = nil; return false }
        if let deadline, now < deadline { return false }
        deadline = nil
        return true
    }
}

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

/// One request is retained across temporary ineligibility. Expiry, leaving UU,
/// pause and system failure cancel it; successful refresh consumes it exactly once.
struct FnForegroundRearmPolicy {
    enum Reason: String { case foregroundEntry = "foreground_entry", postDelivery = "post_delivery" }
    struct Request {
        let id: UInt64
        var reason: Reason
        var notBefore: TimeInterval
        var expiresAt: TimeInterval
    }
    private(set) var isUU = false
    private(set) var pending: Request?
    private(set) var lastRearmReason: Reason?
    private var sequence: UInt64 = 0
    private var lastRearm: TimeInterval?
    private var postDeliveryIssuedThisEntry = false
    private var requestsEnabled = false

    /// This also reconciles a missed notification with the actual foreground.
    /// Paused/starting monitors may observe identity without creating a request.
    @discardableResult
    mutating func observeForeground(_ value: Bool, now: TimeInterval, requestsEnabled: Bool = true) -> Bool {
        expire(now: now)
        self.requestsEnabled = requestsEnabled
        let entered = value && !isUU
        isUU = value
        if !value {
            pending = nil
            postDeliveryIssuedThisEntry = false
        } else if entered {
            postDeliveryIssuedThisEntry = false
            if requestsEnabled { create(reason: .foregroundEntry, now: now, delay: 0.15) }
        }
        if !requestsEnabled { pending = nil }
        return entered
    }

    /// A new local composer session can be shorter than a polling tick. Record
    /// it explicitly so a later genuine delivery can request one fresh refresh.
    mutating func noteComposerOpening() { postDeliveryIssuedThisEntry = false }

    @discardableResult
    mutating func deliveryDidSettle(now: TimeInterval) -> Bool {
        expire(now: now)
        guard requestsEnabled, isUU, !postDeliveryIssuedThisEntry else { return false }
        postDeliveryIssuedThisEntry = true
        if var request = pending {
            request.reason = .postDelivery
            request.notBefore = now
            request.expiresAt = now + 5
            pending = request
        } else { create(reason: .postDelivery, now: now, delay: 0) }
        return true
    }

    mutating func candidate(now: TimeInterval) -> Request? {
        expire(now: now)
        guard requestsEnabled, isUU, let request = pending, now >= request.notBefore else { return nil }
        let interval = request.reason == .postDelivery ? 0.25 : 3.0
        guard lastRearm.map({ now - $0 >= interval }) ?? true else { return nil }
        return request
    }

    /// Call only after the worker atomically reserves its idle state. A failed
    /// reservation must not consume a token or start the cooldown.
    @discardableResult
    mutating func didRearm(requestID: UInt64, now: TimeInterval) -> Bool {
        guard let request = candidate(now: now), request.id == requestID else { return false }
        lastRearm = now
        lastRearmReason = request.reason
        pending = nil
        return true
    }

    mutating func cancelPending() { pending = nil }
    mutating func expire(now: TimeInterval) {
        if let request = pending, now >= request.expiresAt { pending = nil }
    }
    private mutating func create(reason: Reason, now: TimeInterval, delay: TimeInterval) {
        sequence &+= 1
        pending = Request(id: sequence, reason: reason, notBefore: now + delay, expiresAt: now + 5)
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

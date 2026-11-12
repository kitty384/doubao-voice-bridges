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

/// A physical Fn hold can be observed even if its event never reaches our tap.
/// This only requests a refresh after release; it does not infer a tap to open
/// the composer. A short tap or a hold spanning a sampling gap may be missed.
struct FnMissRecoveryPolicy {
    private struct ReleasedSample {
        let at: TimeInterval
        let downCount: UInt64
    }
    private struct Hold {
        let beganAt: TimeInterval
        var lastHeldAt: TimeInterval
        let downCount: UInt64
        var samples: Int
    }

    private static let minimumHeldDuration: TimeInterval = 0.15
    private static let maximumSampleGap: TimeInterval = 0.35
    private var releasedSample: ReleasedSample?
    private var hold: Hold?
    private(set) var issuedThisVisit = false

    /// `downCount` is only supplied for an eligible idle tap with no queued or
    /// owned gesture, in the absence of secure input or conflicting modifiers.
    mutating func observe(now: TimeInterval, foregroundIsUU: Bool,
                          physicalFnDown: Bool, downCount: UInt64?) -> Bool {
        guard foregroundIsUU else { resetVisit(); return false }
        guard !issuedThisVisit, let downCount else { dropObservation(); return false }

        if physicalFnDown {
            if var candidate = hold {
                guard candidate.downCount == downCount,
                      Self.samplesAreAdjacent(candidate.lastHeldAt, now) else {
                    dropObservation()
                    return false
                }
                candidate.lastHeldAt = now
                candidate.samples += 1
                hold = candidate
            } else if let released = releasedSample, released.downCount == downCount,
                      Self.samplesAreAdjacent(released.at, now) {
                hold = Hold(beganAt: now, lastHeldAt: now, downCount: downCount, samples: 1)
            }
            // Never start a candidate in the middle of a hold, even when the
            // target only just became eligible or the tap just received Fn.
            releasedSample = nil
            return false
        }

        let completed = hold
        hold = nil
        releasedSample = ReleasedSample(at: now, downCount: downCount)
        guard let completed, completed.downCount == downCount, completed.samples >= 2,
              completed.lastHeldAt - completed.beganAt >= Self.minimumHeldDuration,
              Self.samplesAreAdjacent(completed.lastHeldAt, now) else { return false }
        issuedThisVisit = true
        dropObservation()
        return true
    }

    mutating func dropObservation() { releasedSample = nil; hold = nil }
    mutating func resetVisit() { dropObservation(); issuedThisVisit = false }

    private static func samplesAreAdjacent(_ previous: TimeInterval, _ now: TimeInterval) -> Bool {
        let gap = now - previous
        return gap >= 0 && gap <= maximumSampleGap
    }
}

/// One request is retained across temporary ineligibility. Expiry, leaving UU,
/// pause and system failure cancel it; successful refresh consumes it exactly once.
struct FnForegroundRearmPolicy {
    enum Reason: String {
        case foregroundEntry = "foreground_entry", postDelivery = "post_delivery", missedPress = "missed_press"
    }
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
        requestImmediateRefresh(reason: .postDelivery, now: now)
        return true
    }

    /// Only call after the visit-limited physical hold detector observes release.
    @discardableResult
    mutating func requestMissedPressRefresh(now: TimeInterval) -> Bool {
        expire(now: now)
        guard requestsEnabled, isUU else { return false }
        requestImmediateRefresh(reason: .missedPress, now: now)
        return true
    }

    private mutating func requestImmediateRefresh(reason: Reason, now: TimeInterval) {
        if var request = pending {
            request.reason = reason
            request.notBefore = now
            request.expiresAt = now + 5
            pending = request
        } else { create(reason: reason, now: now, delay: 0) }
    }

    mutating func candidate(now: TimeInterval) -> Request? {
        expire(now: now)
        guard requestsEnabled, isUU, let request = pending, now >= request.notBefore else { return nil }
        let interval = request.reason == .foregroundEntry ? 3.0 : 0.25
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

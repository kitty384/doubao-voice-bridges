import Foundation

enum RoutingMonitorTests {
    static func run() -> (failures: [String], count: Int) {
        var failures: [String] = []
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures.append(name) }
        }
        var keyboard = FnPressWatchdog()
        keyboard.begin(id: 1, source: .keyboard, now: 0)
        check(keyboard.recoveryCandidate(now: 0.05, physicalFnDown: false) == nil, "keyboard initial quiet is not release")
        check(keyboard.recoveryCandidate(now: 0.36, physicalFnDown: false) == nil, "keyboard minimum press age")
        check(keyboard.recoveryCandidate(now: 0.41, physicalFnDown: false) == 1, "keyboard quiet and age recover owned id")
        keyboard.end(id: 1)
        check(keyboard.recoveryCandidate(now: 10, physicalFnDown: false) == nil, "real release removes watchdog")

        keyboard.begin(id: 2, source: .keyboard, now: 1)
        check(keyboard.recoveryCandidate(now: 1.1, physicalFnDown: false) == nil, "first quiet sample waits")
        check(keyboard.recoveryCandidate(now: 1.3, physicalFnDown: true) == nil, "held key resets quiet interval")
        check(keyboard.recoveryCandidate(now: 1.5, physicalFnDown: false) == nil, "new quiet period starts")
        check(keyboard.recoveryCandidate(now: 1.79, physicalFnDown: false) == nil, "continuous quiet required")
        check(keyboard.recoveryCandidate(now: 1.81, physicalFnDown: false) == 2, "continuous quiet recovery")
        keyboard.begin(id: 3, source: .keyboard, now: 2)
        keyboard.end(id: 2)
        check(keyboard.pressID == 3, "old completion cannot end newer press")
        check(keyboard.recoveryCandidate(now: 50, physicalFnDown: true) == nil, "held keyboard never times out from age alone")

        var headset = FnPressWatchdog()
        headset.begin(id: 11, source: .headset, now: 3)
        check(headset.recoveryCandidate(now: 3.6, physicalFnDown: false) == nil, "headset ignores physical released state")
        check(headset.recoveryCandidate(now: 3.99, physicalFnDown: false) == nil, "headset waits full second")
        check(headset.recoveryCandidate(now: 4.01, physicalFnDown: true) == 11, "headset timeout independent of physical Fn")
        headset.end(id: 11)
        check(headset.recoveryCandidate(now: 5, physicalFnDown: false) == nil, "headset release wins over timeout")
        headset.begin(id: 12, source: .headset, now: 6)
        headset.end(id: 11)
        check(headset.pressID == 12, "old headset release does not end current pulse")

        var filter = FnFilterState()
        check(filter.down(eligible: true), "eligible first Fn claimed")
        filter.cancel()
        let cancelledUp = filter.up()
        check(cancelledUp.suppress && !cancelledUp.release, "cancelled tail up swallowed without submission")
        check(filter.phase == .idle, "cancelled natural up resets filter")
        check(!filter.down(eligible: false), "composer Fn remains native")
        check(filter.down(eligible: true), "new UU session becomes eligible")
        filter.abandonAfterVerifiedRelease()
        check(filter.phase == .idle, "verified lost up clears filter")
        check(filter.down(eligible: true), "press after recovery accepted")
        let release = filter.up()
        check(release.suppress && release.release, "new press release survives old recovery")

        var tail = FnFilterState()
        _ = tail.down(eligible: true)
        check(tail.suppressesRecoveredTail, "pending recovery suppresses late up")
        _ = tail.chord()
        check(!tail.suppressesRecoveredTail, "replayed chord must pass its late up")
        tail.abandonAfterVerifiedRelease()
        check(!tail.up().suppress, "passthrough recovery leaves downstream release intact")
        _ = tail.down(eligible: true)
        _ = tail.beginDictation()
        check(tail.suppressesRecoveredTail, "dictating recovery suppresses owned late up")
        tail.cancel()
        check(tail.suppressesRecoveredTail, "cancelled recovery suppresses owned late up")

        // The actual delivery returns focus to UU while its target provider is
        // still unavailable. Merely reading a candidate must not discard it.
        var rearm = FnForegroundRearmPolicy()
        check(!rearm.observeForeground(false, now: 0), "outside UU does not rearm")
        check(rearm.observeForeground(true, now: 0), "real UU entry creates pending request")
        let entryID = rearm.pending!.id
        check(rearm.candidate(now: 0.14) == nil, "foreground request respects earliest attempt")
        check(rearm.candidate(now: 0.15)?.id == entryID, "busy owner can see original request")
        check(rearm.pending?.id == entryID, "busy attempt does not discard token")
        check(rearm.candidate(now: 0.59)?.id == entryID, "delivery busy until cleanup retains token")
        check(rearm.deliveryDidSettle(now: 0.6), "cleanup upgrades pending request")
        check(rearm.pending?.reason == .postDelivery, "cleanup reason recorded")
        check(rearm.candidate(now: 0.6)?.id == entryID, "cleanup permits immediate ready attempt")
        check(rearm.didRearm(requestID: entryID, now: 0.6), "ready reservation consumes request")
        check(rearm.pending == nil && rearm.candidate(now: 0.7) == nil, "success consumes exactly once")
        check(!rearm.observeForeground(true, now: 0.7), "same foreground observation is not new entry")
        check(rearm.pending == nil, "audit after restart cannot create another token")
        check(!rearm.deliveryDidSettle(now: 0.71), "duplicate cleanup cannot create another token")
        check(rearm.pending == nil, "duplicate cleanup remains consumed")

        // A very short subsequent compose/send cycle must not be dropped by
        // the ordinary three-second foreground cooldown.
        rearm.noteComposerOpening()
        check(rearm.deliveryDidSettle(now: 0.8), "new compose cycle permits new cleanup request")
        let fastID = rearm.pending!.id
        check(rearm.candidate(now: 0.8) == nil, "post-delivery refresh still respects quarter-second bound")
        check(rearm.pending?.id == fastID, "quarter-second cooldown retains request")
        check(rearm.candidate(now: 0.86)?.id == fastID, "fast cycle can refresh before three seconds")
        check(rearm.didRearm(requestID: fastID, now: 0.86), "fast cycle consumes once")
        _ = rearm.observeForeground(false, now: 1)
        check(rearm.observeForeground(true, now: 1.1), "ordinary reentry creates token")
        let normalID = rearm.pending!.id
        check(rearm.candidate(now: 2) == nil, "ordinary reentry retains three-second cooldown")
        check(rearm.pending?.id == normalID, "ordinary cooldown does not drop request")
        check(rearm.candidate(now: 3.87)?.id == normalID, "ordinary request eventually becomes ready")
        check(rearm.didRearm(requestID: normalID, now: 3.87), "ordinary ready request consumed")

        // Failed reservation/held modifiers/queued signals are caller-side
        // guards. Without didRearm, neither token nor cooldown is consumed.
        var reservation = FnForegroundRearmPolicy()
        _ = reservation.observeForeground(true, now: 10)
        let reserveID = reservation.pending!.id
        check(reservation.candidate(now: 10.2)?.id == reserveID, "reservation candidate exists")
        check(reservation.candidate(now: 10.21)?.id == reserveID, "failed reservation keeps candidate without cooldown")
        check(!reservation.didRearm(requestID: reserveID + 1, now: 10.21), "stale or foreign request cannot consume token")
        check(reservation.candidate(now: 10.22)?.id == reserveID, "failed consumption does not start cooldown")
        check(reservation.didRearm(requestID: reserveID, now: 10.22), "actual successful reservation consumes token")

        var leaving = FnForegroundRearmPolicy()
        _ = leaving.observeForeground(true, now: 20)
        let oldID = leaving.pending!.id
        _ = leaving.observeForeground(false, now: 20.1)
        check(leaving.pending == nil && leaving.candidate(now: 20.2) == nil, "leaving UU cancels pending refresh")
        check(!leaving.deliveryDidSettle(now: 20.2), "cleanup outside UU cannot steal focus")
        _ = leaving.observeForeground(true, now: 20.3)
        let newID = leaving.pending!.id
        check(newID != oldID, "later foreground entry gets distinct identity")
        check(!leaving.didRearm(requestID: oldID, now: 20.5), "old delayed entry cannot consume new request")
        check(leaving.candidate(now: 20.5)?.id == newID, "new entry survives stale callback")
        leaving.cancelPending()
        check(leaving.pending == nil, "pause or system failure cancels pending refresh")
        check(!leaving.observeForeground(true, now: 20.6), "stop-start preserves foreground identity")
        check(leaving.pending == nil, "internal restart cannot become periodic rearm")
        _ = leaving.observeForeground(true, now: 20.7, requestsEnabled: false)
        check(!leaving.deliveryDidSettle(now: 20.8) && leaving.pending == nil, "disabled monitor cannot revive from cleanup")

        var expired = FnForegroundRearmPolicy()
        _ = expired.observeForeground(true, now: 30)
        check(expired.candidate(now: 34.99) != nil, "busy token lives for five seconds")
        check(expired.candidate(now: 35) == nil && expired.pending == nil, "expired request is cancelled")
        check(!expired.observeForeground(true, now: 35.1) && expired.pending == nil, "expiry does not manufacture periodic request")

        var fallback = FnForegroundRearmPolicy()
        _ = fallback.observeForeground(false, now: 40)
        check(fallback.observeForeground(true, now: 40.1), "actual foreground sample compensates for missed notification")
        let fallbackID = fallback.pending!.id
        check(!fallback.observeForeground(true, now: 40.2), "later duplicate notification is idempotent")
        check(fallback.pending?.id == fallbackID, "duplicate notification preserves original token")
        fallback.cancelPending()
        _ = fallback.observeForeground(true, now: 40.3, requestsEnabled: false)
        _ = fallback.observeForeground(true, now: 40.4, requestsEnabled: true)
        check(fallback.pending == nil, "fresh start at same foreground does not self-schedule another refresh")
        var handoff = FnComposerHandoffPolicy()
        check(handoff.allowsEligibility(targetAvailable: true, now: 0), "idle foreground eligible")
        handoff.suspend(now: 1)
        check(!handoff.allowsEligibility(targetAvailable: true, now: 1), "synchronous refresh cannot undo handoff")
        check(!handoff.allowsEligibility(targetAvailable: true, now: 1.10), "next timer cannot swallow second Fn")
        check(!handoff.allowsEligibility(targetAvailable: false, now: 1.2), "composer activation stays ineligible")
        check(handoff.allowsEligibility(targetAvailable: true, now: 1.3), "later UU return clears handoff")
        handoff.suspend(now: 2)
        check(!handoff.allowsEligibility(targetAvailable: true, now: 2.74), "failed handoff waits bound")
        check(handoff.allowsEligibility(targetAvailable: true, now: 2.76), "failed handoff eventually retries normally")
        handoff.suspend(now: 3)
        handoff.reset()
        check(handoff.allowsEligibility(targetAvailable: true, now: 3.1), "explicit restart clears handoff")
        return (failures, count)
    }
}

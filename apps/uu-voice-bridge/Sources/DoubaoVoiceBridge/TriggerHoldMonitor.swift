import AppKit
import ApplicationServices
import Carbon

enum TriggerMonitorError: LocalizedError {
    case eventTapUnavailable
    var errorDescription: String? { "无法建立监听，请检查权限；监听保持暂停" }
}

/// UI/session orchestration only. Global input is filtered on FnInputTap's thread.
final class TriggerHoldMonitor {
    static let syntheticEventMarker: Int64 = 0x4456_4252
    var onFault: ((String) -> Void)?
    var voiceHoldEnabled: Bool
    private var drainingWorker: FnInputTap?
    private var pendingStart: (() -> Void)?
    private var foregroundRearm = FnForegroundRearmPolicy()
    private var foregroundIsUU = false
    private var rearmCount: UInt64 = 0
    private var composerHandoff = FnComposerHandoffPolicy()
    private var rearmWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval
    private let targetProvider: () -> UURemoteTarget?
    private let foregroundUUProvider: () -> Bool
    private let localComposerReady: () -> Bool
    private let onBegin: (UURemoteTarget, ComposerEntryMode) -> Bool
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private var worker: FnInputTap?
    private var generation = 0
    private var gesture = HoldGestureState()
    private var target: UURemoteTarget?
    private var activePressID: UInt64?
    private var composerOpenedForPress = false
    private var activationWorkItem: DispatchWorkItem?
    private var syntheticDownWorkItem: DispatchWorkItem?
    private var timer: Timer?
    private var preparedFnUp: CGEvent?
    private var syntheticDownAt: Date?
    private var localFocusDeadline: Date?
    private(set) var activeTapLocation: CGEventTapLocation?
    var isGestureIdle: Bool { gesture.phase == .idle }

    init(holdThreshold: TimeInterval, voiceHoldEnabled: Bool = false, foregroundUUProvider: @escaping () -> Bool, targetProvider: @escaping () -> UURemoteTarget?,
         localComposerReady: @escaping () -> Bool, onBegin: @escaping (UURemoteTarget, ComposerEntryMode) -> Bool,
         onRelease: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.holdThreshold = min(max(holdThreshold, 0.18), 0.60)
        self.voiceHoldEnabled = voiceHoldEnabled
        self.targetProvider = targetProvider
        self.foregroundUUProvider = foregroundUUProvider
        self.localComposerReady = localComposerReady
        self.onBegin = onBegin
        self.onRelease = onRelease
        self.onCancel = onCancel
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard worker == nil else { return }
        generation += 1
        let expected = generation
        let launch = { [weak self] in
            guard let self, self.generation == expected else { return }
            self.launch(expected: expected, completion: completion)
        }
        if drainingWorker != nil { pendingStart = launch }
        else { launch() }
    }

    private func launch(expected: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        let input = FnInputTap(onSignal: { [weak self] signal in
            guard let self, self.generation == expected else { return }
            self.handle(signal)
        }, onFault: { [weak self] message in
            guard let self, self.generation == expected else { return }
            self.stop()
            self.onFault?(message)
        })
        worker = input
        input.start { [weak self] result in
            guard let self, self.generation == expected else { return }
            switch result {
            case .success:
                self.activeTapLocation = .cghidEventTap
                // A newly installed tap is already at the head. Synchronize
                // identity without manufacturing another refresh request.
                self.foregroundIsUU = self.foregroundUUProvider()
                self.foregroundRearm.observeForeground(self.foregroundIsUU,
                    now: ProcessInfo.processInfo.systemUptime, requestsEnabled: false)
                self.refreshEligibility()
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.auditAndRefresh()
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            case .failure: self.stop()
            }
            completion(result)
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        pendingStart = nil
        // Keep observed foreground identity: an internal stop/start must not
        // appear as another UU entry and repeatedly rearm itself.
        foregroundRearm.cancelPending()
        composerHandoff.reset()
        rearmWorkItem?.cancel(); rearmWorkItem = nil
        // Wait for the old run loop to exit before any subsequent start. A pause
        // or a newer start invalidates queued launch closures through generation.
        if let old = worker {
            worker = nil
            drainingWorker = old
            old.stop { [weak self, weak old] in
                guard let self, self.drainingWorker === old else { return }
                self.drainingWorker = nil
                let launch = self.pendingStart
                self.pendingStart = nil
                launch?()
            }
        }
        activeTapLocation = nil
        timer?.invalidate(); timer = nil
        reset(notifyCancel: true)
    }

    func refreshEligibility() {
        precondition(Thread.isMainThread)
        let targetAllowed = composerHandoff.allowsEligibility(
            targetAvailable: targetProvider() != nil, now: ProcessInfo.processInfo.systemUptime)
        worker?.setEligible(gesture.phase == .idle && targetAllowed && !IsSecureEventInputEnabled())
    }

    func suspendEligibilityForComposer() {
        precondition(Thread.isMainThread)
        composerHandoff.suspend(now: ProcessInfo.processInfo.systemUptime)
        foregroundRearm.noteComposerOpening()
        worker?.setEligible(false)
    }

    var diagnosticSnapshot: [String: Any] {
        precondition(Thread.isMainThread)
        var snapshot = worker?.diagnosticSnapshot ?? [
            "tap_valid": false, "tap_enabled": false, "eligible": false,
            "filter_phase": "idle", "fn_down_count": 0, "fn_up_count": 0]
        snapshot["gesture_phase"] = String(describing: gesture.phase)
        snapshot["voice_hold_enabled"] = voiceHoldEnabled
        snapshot["teardown_pending"] = drainingWorker != nil
        snapshot["rearm_pending"] = foregroundRearm.pending != nil
        snapshot["rearm_reason"] = foregroundRearm.pending?.reason.rawValue ?? foregroundRearm.lastRearmReason?.rawValue ?? "none"
        snapshot["rearm_count"] = rearmCount
        snapshot["rearm_generation"] = generation
        snapshot["rearm_observed_uu"] = foregroundIsUU
        return snapshot
    }

    /// Preserve one foreground-entry request while delivery or keys are busy.
    /// The common-mode audit retries only that token, never periodic tap order.
    func refreshForForegroundTransition(isUU: Bool) {
        precondition(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        foregroundIsUU = isUU
        let entered = foregroundRearm.observeForeground(isUU, now: now, requestsEnabled: worker != nil)
        if !isUU {
            rearmWorkItem?.cancel(); rearmWorkItem = nil
            composerHandoff.reset()
        }
        refreshEligibility()
        guard entered, let request = foregroundRearm.pending, worker != nil else { return }
        let expected = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected,
                  self.foregroundRearm.pending?.id == request.id else { return }
            self.attemptPendingRearm()
        }
        rearmWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Called once after an actual delivery's final state and cleanup are set.
    /// It upgrades/creates one bounded token, allowing rapid successive entries
    /// without the ordinary foreground transition's three-second cooldown.
    func deliveryDidSettle() {
        precondition(Thread.isMainThread)
        guard worker != nil else { return }
        refreshForForegroundTransition(isUU: foregroundUUProvider())
        let now = ProcessInfo.processInfo.systemUptime
        guard foregroundRearm.deliveryDidSettle(now: now) else { return }
        refreshEligibility()
        attemptPendingRearm()
    }

    private func attemptPendingRearm() {
        precondition(Thread.isMainThread)
        // Foreground identity is independent of targetProvider: delivering
        // temporarily makes that provider nil while UU is still foreground.
        guard foregroundUUProvider() else {
            if foregroundIsUU { refreshForForegroundTransition(isUU: false) }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let request = foregroundRearm.candidate(now: now),
              let input = worker, input.isIdle, gesture.phase == .idle,
              targetProvider() != nil, !IsSecureEventInputEnabled() else { return }
        let flags = CGEventSource.flagsState(.hidSystemState)
        let combinedFlags = CGEventSource.flagsState(.combinedSessionState)
        let modifiers = FnKeyPolicy.conflictingFlags.union(.maskSecondaryFn)
        guard flags.intersection(modifiers).isEmpty,
              combinedFlags.intersection(modifiers).isEmpty else { return }
        // WindowServer queries can be delayed. Recheck focus and the deadline
        // AFTER those queries, before the atomic reservation stops acquiring input.
        guard foregroundUUProvider() else {
            refreshForForegroundTransition(isUU: false)
            return
        }
        let commitNow = ProcessInfo.processInfo.systemUptime
        guard foregroundRearm.candidate(now: commitNow)?.id == request.id,
              input.reserveForegroundRearm(physicalKeysReleased: true) else { return }
        // There is no main-thread interleaving between reservation and token
        // consumption. If invariants ever fail, finish teardown and stay paused.
        guard foregroundRearm.didRearm(requestID: request.id, now: commitNow) else {
            stop()
            onFault?("监听刷新状态改变，已安全暂停，请手动重新启用")
            return
        }
        rearmCount &+= 1
        stop()
        start { [weak self] result in
            if case .failure(let error) = result { self?.onFault?(error.localizedDescription) }
        }
    }

    private func handle(_ signal: FnTapSignal) {
        precondition(Thread.isMainThread)
        switch signal {
        case .pressed(let id, let source):
            // Main may have been busy long enough for watchdog recovery before
            // this queued down was handled. Do not revive that abandoned press.
            guard worker?.wasRecovered(press: id) == false else { return }
            guard gesture.phase == .idle, let target = targetProvider(), !IsSecureEventInputEnabled() else {
                worker?.cancelOwnedPress(); return
            }
            self.target = target
            activePressID = id
            composerOpenedForPress = false
            _ = gesture.handle(.triggerDown(targetAvailable: true))
            if voiceHoldEnabled && FnKeyPolicy.schedulesVoiceHold(source: source) {
                let item = DispatchWorkItem { [weak self] in self?.activate() }
                activationWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: item)
            }
            // The headset bridge's 60ms pulse only opens the composer on release.
            // Its hardware-button duration does not describe a held Fn key.
        case .released(let id):
            guard activePressID == id else { return }
            let action = FnReleasePolicy.action(phase: gesture.phase, hasSyntheticDown: syntheticDownAt != nil)
            switch action {
            case .openComposer:
                openComposeAfterRelease()
            case .finishVoice:
                let started = syntheticDownAt ?? .distantPast
                postPreparedFnUp()
                if Date().timeIntervalSince(started) >= 0.15 {
                    onRelease()
                    reset(notifyCancel: false)
                } else { openComposeAfterRelease() }
            case .ignore:
                reset(notifyCancel: false)
            }
        case .chord(let id):
            guard activePressID == id else { return }
            reset(notifyCancel: false)
        case .cancelled(let id):
            guard activePressID == id else { return }
            reset(notifyCancel: true)
        }
        refreshEligibility()
    }

    private func openComposeAfterRelease() {
        guard let target, !IsSecureEventInputEnabled() else {
            reset(notifyCancel: gesture.phase == .dictating)
            return
        }
        if !composerOpenedForPress {
            // A tap may only open the original foreground UU target.
            guard targetProvider()?.processIdentifier == target.processIdentifier else {
                reset(notifyCancel: false)
                return
            }
            target.captureFocusedWindow()
        }
        // The physical release has already happened: no synthetic Fn-down.
        // Reset first so no voice watchdog can cancel the typing session.
        suspendEligibilityForComposer()
        reset(notifyCancel: false)
        if !onBegin(target, .tapToCompose) { composerHandoff.reset() }
    }

    private func activate() {
        guard gesture.phase == .pending, let target, let id = activePressID,
              targetProvider()?.processIdentifier == target.processIdentifier,
              !IsSecureEventInputEnabled() else {
            worker?.cancelOwnedPress(); reset(notifyCancel: false); return
        }
        guard worker?.beginDictation(press: id) == true else {
            // Fn-up/chord may already be queued on main. Preserve its press ID
            // so that the queued release still opens the composer.
            return
        }
        _ = gesture.handle(.thresholdReached)
        target.captureFocusedWindow()
        guard worker?.isDictating(press: id) == true else { return }
        suspendEligibilityForComposer()
        guard onBegin(target, .holdToTalk) else {
            // A rejected begin may have restored a pre-existing draft. Never
            // synthesize recording events or cancel that unrelated session.
            worker?.cancelOwnedPress()
            reset(notifyCancel: false)
            composerHandoff.reset()
            return
        }
        composerOpenedForPress = true
        localFocusDeadline = Date().addingTimeInterval(0.75)
        checkComposer()
    }

    private func checkComposer() {
        guard gesture.phase == .dictating, preparedFnUp == nil else { return }
        guard let id = activePressID, worker?.isDictating(press: id) == true else { return }
        guard !IsSecureEventInputEnabled() else { cancelOwned(); return }
        guard localComposerReady() else {
            if Date() >= localFocusDeadline ?? .distantPast { cancelOwned(); return }
            let item = DispatchWorkItem { [weak self] in self?.checkComposer() }
            syntheticDownWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
            return
        }
        guard let pair = LocalFnEventPair.make() else { cancelOwned(); return }
        preparedFnUp = pair.up
        pair.down.flags = LocalFnEventPolicy.flags(down: true, current: CGEventSource.flagsState(.combinedSessionState))
        pair.down.post(tap: .cgSessionEventTap)
        syntheticDownAt = Date()
    }

    private func auditAndRefresh() {
        let actualForeground = foregroundUUProvider()
        if actualForeground != foregroundIsUU {
            // Compensate for delayed/missed activation notifications.
            refreshForForegroundTransition(isUU: actualForeground)
        }
        foregroundRearm.expire(now: ProcessInfo.processInfo.systemUptime)
        if let recoveredID = worker?.recoverIfReleased(), activePressID == recoveredID {
            // Recovery abandons this exact press; it must never submit text or
            // cancel a newer gesture whose down was already queued on main.
            reset(notifyCancel: true)
        }
        if gesture.phase == .dictating &&
            (IsSecureEventInputEnabled() || (syntheticDownAt != nil &&
                (!localComposerReady() || Date().timeIntervalSince(syntheticDownAt!) > 90))) {
            cancelOwned()
        }
        refreshEligibility()
        attemptPendingRearm()
    }

    private func cancelOwned() { worker?.cancelOwnedPress(); reset(notifyCancel: true) }
    private func reset(notifyCancel: Bool) {
        if notifyCancel && gesture.phase == .dictating { onCancel() }
        postPreparedFnUp()
        activationWorkItem?.cancel(); activationWorkItem = nil
        syntheticDownWorkItem?.cancel(); syntheticDownWorkItem = nil
        syntheticDownAt = nil
        localFocusDeadline = nil
        gesture.reset()
        target = nil
        activePressID = nil
        composerOpenedForPress = false
    }
    private func postPreparedFnUp() {
        guard let up = preparedFnUp else { return }
        up.flags = LocalFnEventPolicy.flags(down: false, current: CGEventSource.flagsState(.combinedSessionState))
        LocalFnEventPair.refreshReleaseTimestamp(up)
        up.post(tap: .cgSessionEventTap)
        preparedFnUp = nil
    }
}

enum LocalFnEventPair {
    static func refreshReleaseTimestamp(_ up: CGEvent) {
        up.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
    }
    static func make() -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(source: source), let up = CGEvent(source: source) else { return nil }
        for event in [down, up] {
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: FnKeyPolicy.keyCode)
            event.setIntegerValueField(.eventSourceUserData, value: TriggerHoldMonitor.syntheticEventMarker)
        }
        down.flags = LocalFnEventPolicy.flags(down: true, current: [])
        up.flags = []
        return (down, up)
    }
}

enum SyntheticFnRoute: Equatable {
    case remoteHIDPassthrough, localSessionDictation
    var eventTapLocation: CGEventTapLocation {
        self == .remoteHIDPassthrough ? .cghidEventTap : .cgSessionEventTap
    }
}

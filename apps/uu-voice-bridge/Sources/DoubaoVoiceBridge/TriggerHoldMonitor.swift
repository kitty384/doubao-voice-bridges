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
    private let holdThreshold: TimeInterval
    private let targetProvider: () -> UURemoteTarget?
    private let localComposerReady: () -> Bool
    private let onBegin: (UURemoteTarget, ComposerEntryMode) -> Void
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

    init(holdThreshold: TimeInterval, targetProvider: @escaping () -> UURemoteTarget?,
         localComposerReady: @escaping () -> Bool, onBegin: @escaping (UURemoteTarget, ComposerEntryMode) -> Void,
         onRelease: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.holdThreshold = min(max(holdThreshold, 0.18), 0.60)
        self.targetProvider = targetProvider
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
                self.refreshEligibility()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.auditAndRefresh()
                }
            case .failure: self.stop()
            }
            completion(result)
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        // Detach global input before any UI cleanup that could block the main thread.
        worker?.stop()
        worker = nil
        activeTapLocation = nil
        timer?.invalidate(); timer = nil
        reset(notifyCancel: true)
    }

    func refreshEligibility() {
        precondition(Thread.isMainThread)
        worker?.setEligible(gesture.phase == .idle && targetProvider() != nil && !IsSecureEventInputEnabled())
    }

    private func handle(_ signal: FnTapSignal) {
        precondition(Thread.isMainThread)
        switch signal {
        case .pressed(let id, let source):
            guard gesture.phase == .idle, let target = targetProvider(), !IsSecureEventInputEnabled() else {
                worker?.cancelOwnedPress(); return
            }
            self.target = target
            activePressID = id
            composerOpenedForPress = false
            _ = gesture.handle(.triggerDown(targetAvailable: true))
            if FnKeyPolicy.schedulesVoiceHold(source: source) {
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
        reset(notifyCancel: false)
        onBegin(target, .tapToCompose)
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
        composerOpenedForPress = true
        onBegin(target, .holdToTalk)
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
        worker?.recoverIfReleased()
        if gesture.phase == .dictating &&
            (IsSecureEventInputEnabled() || (syntheticDownAt != nil &&
                (!localComposerReady() || Date().timeIntervalSince(syntheticDownAt!) > 90))) {
            cancelOwned()
        }
        refreshEligibility()
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

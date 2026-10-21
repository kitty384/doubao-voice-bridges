import ApplicationServices
import Carbon
import Foundation

enum FnTapSignal { case pressed(UInt64, FnTriggerSource), released(UInt64), chord(UInt64), cancelled(UInt64) }
enum FnFilterPhase { case idle, pending, dictating, passthrough, cancelled }

/// Pure state, also exercised without installing any global event tap.
struct FnFilterState {
    private(set) var phase: FnFilterPhase = .idle
    mutating func down(eligible: Bool) -> Bool {
        if phase == .pending || phase == .dictating || phase == .cancelled { return true }
        guard phase == .idle, eligible else { return false }
        phase = .pending
        return true
    }
    mutating func up() -> (suppress: Bool, release: Bool) {
        let old = phase
        phase = .idle
        return (old == .pending || old == .dictating || old == .cancelled,
                old == .pending || old == .dictating)
    }
    mutating func beginDictation() -> Bool {
        guard phase == .pending else { return false }
        phase = .dictating
        return true
    }
    mutating func chord() -> Bool {
        guard phase == .pending else { return false }
        phase = .passthrough
        return true
    }
    mutating func cancel() {
        if phase == .pending || phase == .dictating { phase = .cancelled }
    }
    var suppressesRecoveredTail: Bool {
        phase == .pending || phase == .dictating || phase == .cancelled
    }
    mutating func abandonAfterVerifiedRelease() { phase = .idle }
    mutating func recoverIfReleased(_ released: Bool) {
        if released && phase == .cancelled { phase = .idle }
    }
}

/// Owns a dedicated run loop. Its callback never invokes AppKit, AX, main.sync,
/// targetProvider, composer callbacks, logging, or UI code.
final class FnInputTap {
    private let lock = NSLock()
    private var state = FnFilterState()
    private var eligible = false
    private var pressID: UInt64 = 0
    private var pressSource: FnTriggerSource = .keyboard
    private var stopped = false
    private var started = false
    private var finished = false
    private var stopCompletions: [() -> Void] = []
    private var watchdog = FnPressWatchdog()
    private var recoveredTailSources = Set<FnTriggerSource>()
    private var lastRecoveredID: UInt64 = 0
    private var pendingSignals = 0
    private var receivedDown: UInt64 = 0
    private var receivedUp: UInt64 = 0
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var interceptedDown: CGEvent?
    private let onSignal: (FnTapSignal) -> Void
    private let onFault: (String) -> Void

    init(onSignal: @escaping (FnTapSignal) -> Void, onFault: @escaping (String) -> Void) {
        self.onSignal = onSignal
        self.onFault = onFault
    }

    func setEligible(_ value: Bool) { lock.lock(); eligible = value; lock.unlock() }
    func beginDictation(press expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && pressID == expected && state.beginDictation()
    }
    func isDictating(press expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && pressID == expected && state.phase == .dictating
    }
    func cancelOwnedPress() { lock.lock(); state.cancel(); lock.unlock() }
    /// Returns only an owned, still-current press. If a real up has already
    /// reached the worker, its queued main-thread release takes precedence.
    func recoverIfReleased() -> UInt64? {
        let physicalDown = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard !stopped, state.phase != .idle,
              let candidate = watchdog.recoveryCandidate(now: now, physicalFnDown: physicalDown),
              candidate == pressID else { return nil }
        watchdog.end(id: candidate)
        lastRecoveredID = candidate
        // A chord already replayed its down to downstream listeners. Its late
        // up must pass through so those listeners can release their own state.
        if state.suppressesRecoveredTail { recoveredTailSources.insert(pressSource) }
        state.abandonAfterVerifiedRelease()
        interceptedDown = nil
        return candidate
    }

    func wasRecovered(press expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return expected <= lastRecoveredID
    }
    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && state.phase == .idle
    }
    /// Atomically stop acquiring input only if no press or queued gesture is
    /// active. The monitor must then call stop and wait for teardown completion.
    func reserveForegroundRearm(physicalKeysReleased: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard physicalKeysReleased, !stopped, eligible,
              state.phase == .idle, pendingSignals == 0 else { return false }
        stopped = true
        eligible = false
        return true
    }

    var diagnosticSnapshot: [String: Any] {
        lock.lock()
        let currentTap = tap
        var snapshot: [String: Any] = [
            "filter_phase": String(describing: state.phase), "eligible": eligible,
            "fn_down_count": receivedDown, "fn_up_count": receivedUp,
            "stopped": stopped, "thread_finished": finished]
        lock.unlock()
        // Never hold the callback's lock while consulting WindowServer.
        snapshot["tap_valid"] = currentTap.map { CFMachPortIsValid($0) } ?? false
        snapshot["tap_enabled"] = currentTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        return snapshot
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(TriggerMonitorError.eventTapUnavailable)) }
            return
        }
        started = true
        lock.unlock()
        let thread = Thread { [self] in run(completion: completion) }
        thread.name = "DoubaoVoiceBridge.FnInput"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Completion runs on main only after the port is disabled/invalidated and
    /// the old run loop has exited. This also handles stop-before-thread-start.
    func stop(completion: (() -> Void)? = nil) {
        lock.lock()
        stopped = true
        eligible = false
        if !started { finished = true }
        let completeNow = finished
        if let completion, !completeNow { stopCompletions.append(completion) }
        let loop = runLoop
        lock.unlock()
        if completeNow, let completion { DispatchQueue.main.async(execute: completion) }
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }

    private func run(completion: @escaping (Result<Void, Error>) -> Void) {
        var installed: CFMachPort?
        var source: CFRunLoopSource?
        let loop = CFRunLoopGetCurrent()!
        defer {
            if let installed { CGEvent.tapEnable(tap: installed, enable: false); CFMachPortInvalidate(installed) }
            if let source { CFRunLoopRemoveSource(loop, source, .commonModes) }
            lock.lock()
            runLoop = nil; tap = nil; finished = true; eligible = false
            let callbacks = stopCompletions; stopCompletions.removeAll()
            lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0() } }
        }
        lock.lock(); let alreadyStopped = stopped; lock.unlock()
        guard !alreadyStopped else {
            DispatchQueue.main.async { completion(.failure(TriggerMonitorError.eventTapUnavailable)) }
            return
        }
        let mask = [CGEventType.flagsChanged, .keyDown, .leftMouseDown,
                    .rightMouseDown, .otherMouseDown, .scrollWheel].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let callback: CGEventTapCallBack = { proxy, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<FnInputTap>.fromOpaque(info).takeUnretainedValue()
                .handle(proxy: proxy, type: type, event: event)
        }
        installed = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let installed else {
            DispatchQueue.main.async { completion(.failure(TriggerMonitorError.eventTapUnavailable)) }
            return
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, installed, 0)
        guard let source else {
            DispatchQueue.main.async { completion(.failure(TriggerMonitorError.eventTapUnavailable)) }
            return
        }
        lock.lock()
        tap = installed
        runLoop = loop
        let shouldStop = stopped
        lock.unlock()
        guard !shouldStop else {
            DispatchQueue.main.async { completion(.failure(TriggerMonitorError.eventTapUnavailable)) }
            return
        }
        CFRunLoopAddSource(loop, source, .commonModes)
        DispatchQueue.main.async { completion(.success(())) }
        CFRunLoopRun()
    }

    private func emit(_ signal: FnTapSignal) {
        lock.lock(); pendingSignals += 1; lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock(); pendingSignals -= 1; lock.unlock()
            onSignal(signal)
        }
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Fail open: never re-enable a tap that macOS disabled to unblock input.
            lock.lock()
            let currentTap = tap
            stopped = true; eligible = false; state.cancel()
            lock.unlock()
            if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: false) }
            CFRunLoopStop(CFRunLoopGetCurrent())
            DispatchQueue.main.async { [onFault] in
                onFault("系统停用了键盘监听，已暂停；不会自动重启监听")
            }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == TriggerHoldMonitor.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        lock.lock()
        if stopped { lock.unlock(); return Unmanaged.passUnretained(event) }
        if let down = FnKeyPolicy.transition(type: type, keyCode: code, flags: event.flags) {
            let source = FnKeyPolicy.source(marker: event.getIntegerValueField(.eventSourceUserData))
            if down { receivedDown &+= 1 } else { receivedUp &+= 1 }
            // A late up after watchdog recovery belongs to the cancelled press.
            // A new down from this source clears the tombstone before acquiring it.
            if down { recoveredTailSources.remove(source) }
            else if recoveredTailSources.remove(source) != nil {
                lock.unlock()
                return nil
            }
            if state.phase != .idle, source != pressSource {
                // A headset pulse cannot release an owned keyboard hold, or vice versa.
                lock.unlock()
                return nil
            }
            if down {
                let wasIdle = state.phase == .idle
                let suppress = state.down(eligible: eligible && event.flags.intersection(FnKeyPolicy.conflictingFlags).isEmpty)
                if wasIdle && suppress {
                    pressID &+= 1
                    pressSource = source
                    watchdog.begin(id: pressID, source: source, now: ProcessInfo.processInfo.systemUptime)
                    interceptedDown = event.copy()
                }
                let id = pressID
                lock.unlock()
                if wasIdle && suppress { emit(.pressed(id, source)) }
                return suppress ? nil : Unmanaged.passUnretained(event)
            }
            let id = pressID
            let decision = state.up()
            watchdog.end(id: id)
            interceptedDown = nil
            lock.unlock()
            if decision.release { emit(.released(id)) }
            return decision.suppress ? nil : Unmanaged.passUnretained(event)
        }
        let id = pressID
        if state.chord() {
            let original = interceptedDown
            interceptedDown = nil
            lock.unlock()
            if let original {
                original.setIntegerValueField(.eventSourceUserData, value: TriggerHoldMonitor.syntheticEventMarker)
                original.tapPostEvent(proxy)
            }
            emit(.chord(id))
        } else if state.phase == .dictating && type == .flagsChanged &&
                    !event.flags.intersection(FnKeyPolicy.conflictingFlags).isEmpty {
            state.cancel()
            lock.unlock()
            emit(.cancelled(id))
        } else { lock.unlock() }
        return Unmanaged.passUnretained(event)
    }
}

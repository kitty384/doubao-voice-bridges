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
    func recoverIfReleased() {
        // This polling happens outside the event callback, on the caller's timer.
        let released = !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        lock.lock(); state.recoverIfReleased(released); lock.unlock()
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        let thread = Thread { [self] in run(completion: completion) }
        thread.name = "DoubaoVoiceBridge.FnInput"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        eligible = false
        let loop = runLoop
        lock.unlock()
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }

    private func run(completion: @escaping (Result<Void, Error>) -> Void) {
        let mask = [CGEventType.flagsChanged, .keyDown, .leftMouseDown,
                    .rightMouseDown, .otherMouseDown, .scrollWheel].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let callback: CGEventTapCallBack = { proxy, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<FnInputTap>.fromOpaque(info).takeUnretainedValue()
                .handle(proxy: proxy, type: type, event: event)
        }
        guard let installed = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, installed, 0) else {
            DispatchQueue.main.async { completion(.failure(TriggerMonitorError.eventTapUnavailable)) }
            return
        }
        let loop = CFRunLoopGetCurrent()!
        lock.lock()
        tap = installed
        runLoop = loop
        let shouldStop = stopped
        lock.unlock()
        if !shouldStop {
            CFRunLoopAddSource(loop, source, .commonModes)
            DispatchQueue.main.async { completion(.success(())) }
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: installed, enable: false)
        CFMachPortInvalidate(installed)
        lock.lock(); runLoop = nil; tap = nil; lock.unlock()
    }

    private func emit(_ signal: FnTapSignal) {
        DispatchQueue.main.async { [onSignal] in onSignal(signal) }
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Fail open: never re-enable a tap that macOS disabled to unblock input.
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            lock.lock(); stopped = true; eligible = false; state.cancel(); lock.unlock()
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
            if (state.phase == .pending || state.phase == .dictating || state.phase == .cancelled), source != pressSource {
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
                    interceptedDown = event.copy()
                }
                let id = pressID
                lock.unlock()
                if wasIdle && suppress { emit(.pressed(id, source)) }
                return suppress ? nil : Unmanaged.passUnretained(event)
            }
            let id = pressID
            let decision = state.up()
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

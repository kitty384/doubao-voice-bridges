import Carbon
import CoreGraphics
import Foundation

/// A macOS-registered chord independent of the custom Fn event tap.
/// Registration and dispatch both stay scoped to the intended foreground.
final class ComposerShortcut {
    static let displayName = "⌃⌥⌘D"
    private static let signature: OSType = 0x4456_424B  // DVBK

    var canDeliver: (() -> Bool)?
    var onReleased: (() -> Void)?
    private var eventHandler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var requested = false
    private var sequence: UInt32 = 0
    private var waitingID: UInt32?
    private(set) var registrationError: OSStatus?
    var isRegistered: Bool { registration != nil }

    func setActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        guard active != requested else { return }
        requested = active
        registrationError = nil
        if !active {
            waitingID = nil
            if let registration { UnregisterEventHotKey(registration) }
            registration = nil
            return
        }

        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyReleased))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                    nil, &id)
                guard status == noErr, id.signature == ComposerShortcut.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let shortcut = Unmanaged<ComposerShortcut>.fromOpaque(context).takeUnretainedValue()
                let deliveredID = id.id
                DispatchQueue.main.async { [weak shortcut] in shortcut?.deliver(deliveredID) }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else { registrationError = status; return }
        }

        sequence &+= 1
        let id = EventHotKeyID(signature: Self.signature, id: sequence)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey),
                                        id, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { registration = ref }
        else { registrationError = status == noErr ? OSStatus(eventInternalErr) : status }
    }

    private func deliver(_ id: UInt32) {
        guard requested, isRegistered, id == sequence, waitingID == nil else { return }
        waitingID = id
        waitForModifierRelease(id: id, deadline: ProcessInfo.processInfo.systemUptime + 1.5)
    }

    private func waitForModifierRelease(id: UInt32, deadline: TimeInterval) {
        guard waitingID == id, id == sequence else { return }
        guard requested, isRegistered, canDeliver?() == true,
              ProcessInfo.processInfo.systemUptime <= deadline else { waitingID = nil; return }
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
        let held = CGEventSource.flagsState(.hidSystemState).union(CGEventSource.flagsState(.combinedSessionState))
        // Wait for UU to receive the actual key releases before raising the
        // local composer; otherwise modifiers can be left held on the remote Mac.
        if held.intersection(modifiers).isEmpty,
           !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_ANSI_D)) {
            waitingID = nil
            onReleased?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.waitForModifierRelease(id: id, deadline: deadline)
            }
        }
    }

    deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

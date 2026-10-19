import ApplicationServices
import Carbon
import Foundation

/// Read-only, twenty-second hardware check. No typed keys, clipboard, audio, or text.
enum TriggerObserver {
    static func run() -> Bool {
        guard CGPreflightListenEventAccess() else {
            fputs("Input Monitoring permission missing for this terminal/executable. No permission was changed.\n", stderr)
            return false
        }
        guard !IsSecureEventInputEnabled() else {
            fputs("Secure Event Input is enabled; leave the password field and retry.\n", stderr)
            return false
        }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 63 {
                print("Fn keycode=63 down=\(event.flags.contains(.maskSecondaryFn))")

            }
            fflush(stdout)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fputs("Unable to create read-only event tap.\n", stderr)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Observe only: press/release Fn in this Terminal. Ends after 20 seconds.")
        print("Quit the bridge first; this confirms event visibility, not Doubao or UU compatibility.")
        fflush(stdout)
        CFRunLoopRunInMode(.defaultMode, 20, false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(tap)
        return true
    }
}

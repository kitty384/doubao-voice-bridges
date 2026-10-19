import AppKit
import ApplicationServices

final class UURemoteTarget {
    let application: NSRunningApplication
    private var focusedWindow: AXUIElement?

    init(application: NSRunningApplication) {
        self.application = application
    }

    var isTerminated: Bool { application.isTerminated }
    var processIdentifier: pid_t { application.processIdentifier }

    @discardableResult
    func captureFocusedWindow() -> Bool {
        focusedWindow = Self.copyFocusedWindow(pid: processIdentifier)
        if let focusedWindow { AXUIElementSetMessagingTimeout(focusedWindow, 0.2) }
        return focusedWindow != nil
    }

    func activateOriginalWindow() {
        application.activate(options: [.activateIgnoringOtherApps])
        guard let focusedWindow else { return }
        AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(focusedWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    func stillMatchesFocusedWindow() -> Bool {
        guard let focusedWindow else { return false }
        guard let current = Self.copyFocusedWindow(pid: processIdentifier) else { return false }
        return CFEqual(focusedWindow, current)
    }

    private static func copyFocusedWindow(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

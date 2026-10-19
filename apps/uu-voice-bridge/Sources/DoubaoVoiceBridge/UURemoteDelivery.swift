import AppKit
import ApplicationServices
import os.log

enum DeliveryError: LocalizedError, Equatable {
    case emptyText
    case accessibilityMissing
    case targetAppMissing
    case pasteboardUnavailable
    case clipboardChanged
    case targetChanged
    case keyboardEventFailed
    case modifierKeysActive

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "没有可发送的文字"
        case .accessibilityMissing:
            return "尚未开启辅助功能权限"
        case .targetAppMissing:
            return "UU 远控已经关闭"
        case .pasteboardUnavailable:
            return "无法写入系统剪贴板"
        case .clipboardChanged:
            return "发送前剪贴板内容发生变化，已取消自动粘贴"
        case .targetChanged:
            return "发送前焦点发生变化，已取消自动粘贴"
        case .keyboardEventFailed:
            return "无法发送 Command-V"
        case .modifierKeysActive:
            return "请先松开 Command、Shift、Option 或 Control 键"
        }
    }
}

final class UURemoteDelivery {
    static let defaultPasteDelay: TimeInterval = 0.50
    static let minimumPasteDelay: TimeInterval = 0.45
    static let maximumPasteDelay: TimeInterval = 3.0

    private let pasteboard = NSPasteboard.general
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge.Fn", category: "delivery")

    func deliver(
        text: String,
        to target: UURemoteTarget,
        panelWillHide: @escaping () -> Void,
        completion: @escaping (Result<Void, Error>) -> Void,
        cleanupCompletion: @escaping () -> Void
    ) {
        precondition(Thread.isMainThread)

        guard !text.isEmpty else {
            completion(.failure(DeliveryError.emptyText))
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.failure(DeliveryError.accessibilityMissing))
            return
        }
        guard !target.isTerminated else {
            cleanupCompletion()
            completion(.failure(DeliveryError.targetAppMissing))
            return
        }

        // Leave this transcript on the clipboard. Restoring old contents can
        // trigger another UU/Continuity synchronization and race the paste.
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            completion(.failure(DeliveryError.pasteboardUnavailable))
            return
        }
        let bridgeChangeCount = pasteboard.changeCount
        let lengthBucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
        logger.notice(
            "Transcript staged for UU lengthBucket=\(lengthBucket, privacy: .public) pasteboardGeneration=\(bridgeChangeCount, privacy: .private)"
        )
        let configuredDelay = UserDefaults.standard.double(forKey: "pasteDelay")
        let syncDelay = min(
            max(configuredDelay, Self.minimumPasteDelay),
            Self.maximumPasteDelay
        )

        // Activate UU immediately so its clipboard bridge has the full delay
        // to synchronize before the paste shortcut is sent.
        panelWillHide()
        target.activateOriginalWindow()
        logger.notice("Original UU window activation requested; waiting for clipboard synchronization")

        DispatchQueue.main.asyncAfter(deadline: .now() + syncDelay) { [weak self] in
            guard let self else { return }
            guard !target.isTerminated else {
                completion(.failure(DeliveryError.targetAppMissing))
                cleanupCompletion()
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  target.stillMatchesFocusedWindow() else {
                completion(.failure(DeliveryError.targetChanged))
                cleanupCompletion()
                return
            }
            guard DeliveryClipboardPolicy.permitsPaste(
                from: self.pasteboard,
                expectedText: text,
                originalChangeCount: bridgeChangeCount
            ) else {
                completion(.failure(DeliveryError.clipboardChanged))
                cleanupCompletion()
                return
            }

            ClipboardKeyboardPaster.postCommandV { result in
                switch result {
                case .success:
                    self.logger.notice("Complete Command-V key sequence posted to UU")
                    // This acknowledges local key posting only. UU exposes no
                    // acknowledgement of this transcript reaching the remote Mac.
                    completion(.success(()))
                    cleanupCompletion()
                case .failure(let error):
                    completion(.failure(error))
                    cleanupCompletion()
                }
            }
        }
    }

    func restoreClipboardForTermination() {
        precondition(Thread.isMainThread)
        // Kept as the coordinator's termination hook. Never rewrite old data,
        // including when a previous installation saved restoreClipboard=true.
    }
}

enum ClipboardKeyboardPaster {
    private static let leftCommandKeyCode: CGKeyCode = 55
    private static let vKeyCode: CGKeyCode = 9
    private static let interEventDelay: TimeInterval = 0.025
    private static let eventQueue = DispatchQueue(
        label: "com.lyp.DoubaoVoiceBridge.command-v",
        qos: .userInteractive
    )

    static func makeCommandVEvents() throws -> [CGEvent] {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let commandDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: leftCommandKeyCode,
                keyDown: true
              ),
              let vDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: vKeyCode,
                keyDown: true
              ),
              let vUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: vKeyCode,
                keyDown: false
              ),
              let commandUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: leftCommandKeyCode,
                keyDown: false
              ) else {
            throw DeliveryError.keyboardEventFailed
        }

        // Keep the constructor-generated left-Command device flag. UU Remote
        // tracks modifier down/up events separately and otherwise forwards a
        // plain "V" to the remote Mac.
        vDown.flags = commandDown.flags
        vUp.flags = commandDown.flags

        let events = [commandDown, vDown, vUp, commandUp]
        for event in events {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: TriggerHoldMonitor.syntheticEventMarker
            )
        }
        return events
    }

    static func postCommandV(completion: @escaping (Result<Void, Error>) -> Void) {
        let conflictingFlags: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskSecondaryFn
        ]
        guard CGEventSource.flagsState(.combinedSessionState)
            .intersection(conflictingFlags).isEmpty else {
            completion(.failure(DeliveryError.modifierKeysActive))
            return
        }

        let events: [CGEvent]
        do {
            // Construct all four first, so allocation failure can never leave
            // a synthetic Command key held down.
            events = try makeCommandVEvents()
        } catch {
            completion(.failure(error))
            return
        }

        eventQueue.async {
            for (index, event) in events.enumerated() {
                // Eligibility and modifier state are validated immediately
                // before this queue starts. Once Command-down is posted, the
                // remaining events run unconditionally so neither V nor
                // Command can be left held by a blocking AX/focus check.
                event.post(tap: .cghidEventTap)
                if index < events.count - 1 {
                    Thread.sleep(forTimeInterval: interEventDelay)
                }
            }
            DispatchQueue.main.async {
                completion(.success(()))
            }
        }
    }

    static func finishPendingEventsBeforeTermination() {
        precondition(Thread.isMainThread)
        // The serial event queue never calls back synchronously to main while
        // a modifier is held. A barrier here therefore guarantees any posted
        // Command-down has matching V-up and Command-up before process exit.
        eventQueue.sync {}
    }
}

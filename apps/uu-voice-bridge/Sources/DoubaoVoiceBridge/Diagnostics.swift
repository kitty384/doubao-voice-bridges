import AppKit
import ApplicationServices
import Carbon

enum PrivacySafeTextMetrics {
    static func lengthBucket(_ length: Int) -> String {
        switch length {
        case ..<1: return "empty"
        case 1...4: return "1-4"
        case 5...16: return "5-16"
        case 17...64: return "17-64"
        default: return "65+"
        }
    }
}

enum Diagnostics {
    static func printReport() {
        let workspace = NSWorkspace.shared
        let uuRemote = workspace.runningApplications.first {
            $0.bundleIdentifier == AppDelegate.uuRemoteBundleIdentifier
        }
        let doubaoPath = "/Library/Input Methods/DoubaoIme.app"
        let values: [(String, String)] = [
            ("diagnostic_scope", "calling_process_only_gui_permissions_may_differ"),
            ("trigger", "fn"),
            ("doubao_required_shortcut", "fn"),
            ("local_event_keycode", "63"),
            ("local_event_modifier", "maskSecondaryFn"),
            ("secure_input", IsSecureEventInputEnabled() ? "enabled" : "disabled"),
            ("remote_acknowledgement", "not_available"),
            ("bundle", Bundle.main.bundleIdentifier ?? "unknown"),
            ("version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
            ("accessibility", AXIsProcessTrusted() ? "granted" : "missing"),
            ("input_monitoring", CGPreflightListenEventAccess() ? "granted" : "missing"),
            ("hid_event_tap", "not_probed"),
            ("startup_state", "paused"),
            ("input_callback_thread", "dedicated"),
            ("automatic_tap_reinstall", "bounded_foreground_transition"),
            ("automatic_timeout_restart", "disabled"),
            ("doubao", FileManager.default.fileExists(atPath: doubaoPath) ? "installed" : "missing"),
            ("uuremote", uuRemote == nil ? "not_running" : "running"),
            ("frontmost", workspace.frontmostApplication?.bundleIdentifier ?? "unknown")
        ]
        if let data = try? Data(contentsOf: GUIRuntimeStatus.url),
           let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = snapshot["pid"] as? Int,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           app.bundleIdentifier == "com.lyp.DoubaoVoiceBridge.Fn" {
            print("gui_process_snapshot=\(String(data: data, encoding: .utf8) ?? "unreadable")")
        } else { print("gui_process_snapshot=not_available") }
        for (key, value) in values {
            print("\(key)=\(value)")
        }
    }
}

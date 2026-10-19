import ApplicationServices
import Foundation

struct PermissionStatus {
    let accessibility: Bool
    let inputMonitoring: Bool

    static func current() -> PermissionStatus {
        // Evaluate independently: a missing AX grant must not hide the input grant.
        let ax = AXIsProcessTrusted()
        let input = CGPreflightListenEventAccess()
        return PermissionStatus(accessibility: ax, inputMonitoring: input)
    }
    var ready: Bool { accessibility && inputMonitoring }
    var missingDescription: String {
        if !accessibility && !inputMonitoring { return "辅助功能和输入监控尚未生效" }
        if !accessibility { return "辅助功能尚未生效" }
        if !inputMonitoring { return "输入监控尚未生效" }
        return "权限已具备"
    }
}

enum GUIRuntimeStatus {
    static let url = FileManager.default.temporaryDirectory.appendingPathComponent("com.lyp.DoubaoVoiceBridge.Fn.gui-status.json")
    static func write(permissions: PermissionStatus, state: String, message: String) {
        let data: [String: Any] = [
            "source": "gui_process", "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "accessibility": permissions.accessibility, "input_monitoring": permissions.inputMonitoring,
            "state": state, "message": message,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            try? encoded.write(to: url, options: .atomic)
        }
    }
    static func removeOwnSnapshot() {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

import AppKit

struct ComposerOpenRequest {
    let id: String
    let targetPID: pid_t
    let sentAt: TimeInterval
    func isFresh(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let age = now - sentAt
        return age.isFinite && age >= -0.1 && age <= 0.8
    }
    static func decode(_ info: [AnyHashable: Any], now: TimeInterval) -> ComposerOpenRequest? {
        guard let id = info["requestID"] as? String, UUID(uuidString: id) != nil,
              let pid = info["targetPID"] as? NSNumber, pid.int64Value > 0,
              pid.int64Value <= Int64(Int32.max),
              let sent = info["sentAt"] as? NSNumber else { return nil }
        let age = now - sent.doubleValue
        guard age.isFinite, age >= -0.1, age <= 0.8 else { return nil }
        return ComposerOpenRequest(id: id, targetPID: pid.int32Value, sentAt: sent.doubleValue)
    }
}

struct ComposerRequestLedger {
    private var entries: [String: (expires: TimeInterval, result: String?)] = [:]
    mutating func accept(_ id: String, now: TimeInterval) -> Bool {
        entries = entries.filter { $0.value.expires > now }
        guard entries[id] == nil else { return false }
        if entries.count >= 64, let oldest = entries.min(by: { $0.value.expires < $1.value.expires }) {
            entries.removeValue(forKey: oldest.key)
        }
        entries[id] = (now + 2, nil)
        return true
    }
    func result(for id: String) -> String? { entries[id]?.result }
    mutating func finish(_ id: String, status: String) {
        guard let entry = entries[id] else { return }
        entries[id] = (entry.expires, status)
    }
}

/// Local control messages only; contains neither audio nor text to paste.
final class ComposerRequestServer: NSObject {
    static let requestName = Notification.Name("com.doubao.voicebridges.openComposer.v1")
    static let replyName = Notification.Name("com.doubao.voicebridges.openComposerReply.v1")
    static let object = "com.doubao.voicebridges.local"
    var onRequest: ((ComposerOpenRequest, @escaping (String) -> Void) -> Void)?
    private var ledger = ComposerRequestLedger()
    func start() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
            name: Self.requestName, object: Self.object, suspensionBehavior: .deliverImmediately)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    @objc private func receive(_ note: Notification) {
        let info = note.userInfo ?? [:]
        DispatchQueue.main.async { [weak self] in self?.handle(info) }
    }
    private func handle(_ info: [AnyHashable: Any]) {
        guard let request = ComposerOpenRequest.decode(info, now: Date().timeIntervalSince1970) else { return }
        guard ledger.accept(request.id, now: ProcessInfo.processInfo.systemUptime) else {
            if let result = ledger.result(for: request.id) { reply(request.id, status: result) }
            return
        }
        guard let onRequest else { complete(request.id, status: "unavailable"); return }
        onRequest(request) { [weak self] result in self?.complete(request.id, status: result) }
    }
    private func complete(_ id: String, status: String) {
        ledger.finish(id, status: status)
        reply(id, status: status)
    }
    private func reply(_ id: String, status: String) {
        DistributedNotificationCenter.default().postNotificationName(Self.replyName,
            object: Self.object, userInfo: ["requestID": id, "status": status], deliverImmediately: true)
    }
}

enum ComposerResumePolicy {
    static func permits(sameProcess: Bool, sameWindow: Bool, delivering: Bool) -> Bool {
        sameProcess && sameWindow && !delivering
    }
}

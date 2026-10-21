import Foundation

enum CooperativeRoutingTests {
    static func run() -> (failures: [String], count: Int) {
        var failures: [String] = []
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1
            if !condition { failures.append("cooperative: \(label)") }
        }
        let id = UUID().uuidString
        let valid: [AnyHashable: Any] = ["requestID": id, "targetPID": 123, "sentAt": 100.0]
        check(ComposerOpenRequest.decode(valid, now: 100.1)?.targetPID == 123, "matching fresh request")
        let decoded = ComposerOpenRequest.decode(valid, now: 100.1)!
        check(!decoded.isFresh(now: 100.81), "recheck request after delayed AX query")
        check(ComposerOpenRequest.decode(valid, now: 100.81) == nil, "expired request cannot open panel")
        check(ComposerOpenRequest.decode(valid, now: 99) == nil, "future request rejected")
        var malformed = valid
        malformed["requestID"] = "invalid"
        check(ComposerOpenRequest.decode(malformed, now: 100) == nil, "invalid identifier")
        malformed = valid; malformed["targetPID"] = Int64.max
        check(ComposerOpenRequest.decode(malformed, now: 100) == nil, "invalid process identifier")
        malformed = valid; malformed["sentAt"] = Double.nan
        check(ComposerOpenRequest.decode(malformed, now: 100) == nil, "invalid timestamp")
        var ledger = ComposerRequestLedger()
        check(ledger.accept(id, now: 0), "first request admitted")
        check(!ledger.accept(id, now: 0.1), "duplicate pending request does not open twice")
        check(ledger.result(for: id) == nil, "no premature acknowledgement before panel ready")
        ledger.finish(id, status: "opened")
        check(!ledger.accept(id, now: 0.2) && ledger.result(for: id) == "opened", "completed duplicate only repeats acknowledgement")
        check(ledger.accept(UUID().uuidString, now: 3), "expired ledger purged for later request")
        check(ledger.result(for: id) == nil, "expired old acknowledgement not reused")
        check(ComposerResumePolicy.permits(sameProcess: true, sameWindow: true, delivering: false), "resume original draft")
        check(!ComposerResumePolicy.permits(sameProcess: true, sameWindow: false, delivering: false), "do not retarget old text to other UU window")
        check(!ComposerResumePolicy.permits(sameProcess: false, sameWindow: true, delivering: false), "do not retarget old text after UU restart")
        check(!ComposerResumePolicy.permits(sameProcess: true, sameWindow: true, delivering: true), "do not enter during delivery")
        return (failures, count)
    }
}

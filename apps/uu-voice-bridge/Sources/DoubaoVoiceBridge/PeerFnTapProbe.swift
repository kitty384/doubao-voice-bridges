import CoreGraphics
import Darwin

/// Metadata only. No event callbacks, order assumptions, or key contents.
enum PeerFnTapProbe {
    static func activePeerIDs(excluding ownPID: pid_t) -> Set<PeerFnTapRecoveryPolicy.Identity>? {
        // One query per sample. Reject a filled buffer rather than comparing
        // two possibly truncated lists and manufacturing a peer change.
        let capacity: UInt32 = 256
        let entries = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(capacity))
        defer { entries.deallocate() }
        var count: UInt32 = 0
        guard CGGetEventTapList(capacity, entries, &count) == .success, count < capacity else { return nil }
        let flagsChanged = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        var peers: Set<PeerFnTapRecoveryPolicy.Identity> = []
        for i in 0..<Int(count) {
            let tap = entries[i]
            guard tap.enabled, tap.tapPoint == .cghidEventTap, tap.options == .defaultTap,
                  tap.processBeingTapped == 0, tap.tappingProcess > 0, tap.tappingProcess != ownPID,
                  (tap.eventsOfInterest & flagsChanged) != 0 else { continue }
            peers.insert(.init(process: tap.tappingProcess, tapID: tap.eventTapID))
        }
        return peers
    }
}

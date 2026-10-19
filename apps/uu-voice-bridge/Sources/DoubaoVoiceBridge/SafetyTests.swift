import Foundation

/// No global event tap, GUI, synthetic key posting or microphone is used.
enum SafetyTests {
    static func run() -> (failures: [String], count: Int) {
        var failures: [String] = []
        var count = 0
        func check(_ value: Bool, _ label: String) {
            count += 1
            if !value { failures.append("safety: \(label)") }
        }
        var state = FnFilterState()
        check(!state.down(eligible: false), "outside UU passes Fn")
        let outsideUp = state.up()
        check(!outsideUp.suppress && !outsideUp.release, "unowned release passes through")
        check(state.down(eligible: true), "eligible press captured")
        check(state.phase == .pending, "press pending")
        check(state.down(eligible: false) && state.phase == .pending, "duplicate down does not reset gesture")
        check(state.beginDictation(), "pending can activate")
        let up = state.up()
        check(up.suppress && up.release && state.phase == .idle, "dictation release is paired")
        let duplicateUp = state.up()
        check(!duplicateUp.suppress && !duplicateUp.release, "duplicate up does not submit")
        _ = state.down(eligible: true)
        check(state.up().release, "quick release reaches coordinator for cancellation")
        check(!state.beginDictation(), "released press cannot activate")
        _ = state.down(eligible: true)
        check(state.chord(), "chord detected before threshold")
        check(!state.beginDictation(), "chord cannot activate recording")
        let chordUp = state.up()
        check(!chordUp.suppress && !chordUp.release, "replayed chord gets real release")
        _ = state.down(eligible: true)
        state.cancel()
        check(state.phase == .cancelled, "fault cancels pending gesture")
        check(state.down(eligible: true) && state.phase == .cancelled, "cancelled held key cannot restart")
        state.recoverIfReleased(false)
        check(state.phase == .cancelled, "held key stays cancelled")
        let cancelUp = state.up()
        check(cancelUp.suppress && !cancelUp.release, "cancelled release never submits")
        _ = state.down(eligible: true)
        _ = state.beginDictation()
        state.cancel()
        check(!state.beginDictation(), "cancelled recording cannot reactivate")
        state.recoverIfReleased(true)
        check(state.phase == .idle, "lost release recovery")

        var tap = HoldGestureState()
        _ = tap.handle(.triggerDown(targetAvailable: true))
        check(FnReleasePolicy.action(phase: tap.phase, hasSyntheticDown: false) == .openComposer, "tap opens composer without Fn synthesis")
        _ = tap.handle(.thresholdReached)
        check(FnReleasePolicy.action(phase: tap.phase, hasSyntheticDown: true) == .finishVoice, "held Fn preserves speech release")
        check(FnReleasePolicy.action(phase: tap.phase, hasSyntheticDown: false) == .openComposer, "release before synthetic down leaves typing composer")
        tap.reset()
        check(FnReleasePolicy.action(phase: tap.phase, hasSyntheticDown: false) == .ignore, "unowned release never opens composer")
        _ = tap.handle(.triggerDown(targetAvailable: true))
        _ = tap.handle(.otherInput)
        check(FnReleasePolicy.action(phase: tap.phase, hasSyntheticDown: false) == .ignore, "Fn chord never opens composer on release")
        var queuedRelease = FnFilterState()
        _ = queuedRelease.down(eligible: true)
        _ = queuedRelease.up()
        check(!queuedRelease.beginDictation() && FnReleasePolicy.action(phase: .pending, hasSyntheticDown: false) == .openComposer,
              "queued release survives expired activation timer")
        check(FnKeyPolicy.source(marker: 0x444F5542414F) == .headset, "installed headset marker recognized")
        check(!FnKeyPolicy.schedulesVoiceHold(source: .headset), "headset pulse never schedules synthetic voice hold")
        check(FnKeyPolicy.schedulesVoiceHold(source: .keyboard), "keyboard long hold still schedules voice")
        check(FnKeyPolicy.headsetEventMarker != TriggerHoldMonitor.syntheticEventMarker, "headset Fn is not mistaken for own event")
        check(FnKeyPolicy.transition(type: .flagsChanged, keyCode: 115, flags: []) == nil, "physical Home is not hijacked")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doubao-guard-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = SingleInstanceGuard()
        check(first.acquire(at: url), "first instance owns lock")
        func childStatus() -> Int32 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            task.arguments = ["--check-instance-lock", url.path]
            do { try task.run(); task.waitUntilExit(); return task.terminationStatus }
            catch { return -1 }
        }
        check(childStatus() == 2, "second process cannot acquire held lock")
        first.release()
        check(childStatus() == 0, "new process can acquire released lock")
        check(first.acquire(at: url), "guard can reacquire without unlinking")
        first.release()
        return (failures, count)
    }
}

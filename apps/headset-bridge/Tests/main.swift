import Foundation

func button(_ key: Int = 16, down: Bool = true, repeated: Bool = false) -> MediaButton {
    MediaButton(key: key, down: down, repeated: repeated)
}
var state = MappingState()
func check(_ b: MediaButton, eligible: Bool = true, held: Bool = false,
           time: Double, swallow: Bool, trigger: Bool) {
    let result = state.handle(b, eligible: eligible, modifiersHeld: held, now: time)
    precondition(result.swallow == swallow && result.trigger == trigger, "Unexpected mapping at \(time)")
}
check(button(), time: 1, swallow: true, trigger: true)
check(button(repeated: true), time: 1.05, swallow: true, trigger: false)
check(button(down: false), time: 1.08, swallow: true, trigger: false)
check(button(down: false), time: 1.1, swallow: false, trigger: false)
check(button(), time: 2, swallow: true, trigger: true)
// A toggle/unplug between down and up still consumes the paired up.
check(button(down: false), eligible: false, time: 2.1, swallow: true, trigger: false)
check(button(), eligible: false, time: 3, swallow: false, trigger: false)
check(button(down: false), time: 3.1, swallow: false, trigger: false)
// A modifier suppresses the shortcut but cannot leak play/pause to the system.
check(button(), held: true, time: 4, swallow: true, trigger: false)
check(button(), held: false, time: 4.05, swallow: true, trigger: false)
check(button(down: false), time: 4.1, swallow: true, trigger: false)
check(button(down: false), time: 4.2, swallow: false, trigger: false)
check(button(0), time: 5, swallow: false, trigger: false)
check(button(17), time: 5.1, swallow: false, trigger: false)
check(button(), time: 6, swallow: true, trigger: true)
check(button(down: false), time: 6.01, swallow: true, trigger: false)
check(button(), time: 6.05, swallow: true, trigger: false)
check(button(down: false), time: 6.06, swallow: true, trigger: false)
check(button(), time: 6.3, swallow: true, trigger: true)
// Duplicate down values must not start another shortcut, with or without the
// legacy repeat bit, or after eligibility changes before the release arrives.
check(button(), time: 7, swallow: true, trigger: false)
check(button(repeated: true), eligible: false, time: 7.1, swallow: true, trigger: false)
check(button(), eligible: false, time: 7.2, swallow: true, trigger: false)
check(button(down: false), eligible: false, time: 7.3, swallow: true, trigger: false)
check(button(repeated: true), eligible: false, time: 7.4, swallow: false, trigger: false)
// A repeat delivered before the original down still consumes a complete pair.
check(button(repeated: true), time: 8, swallow: true, trigger: false)
check(button(), time: 8.1, swallow: true, trigger: false)
check(button(down: false), time: 8.2, swallow: true, trigger: false)
check(button(), time: 9, swallow: true, trigger: true)
state.reset()
// Reset must discard both an unfinished pair and the debounce timestamp.
check(button(down: false), time: 9.01, swallow: false, trigger: false)
check(button(), time: 9.02, swallow: true, trigger: true)
check(button(0, down: false), time: 9.03, swallow: false, trigger: false)
check(button(1), time: 9.04, swallow: false, trigger: false)
check(button(down: false), time: 9.05, swallow: true, trigger: false)
check(button(), eligible: false, held: true, time: 10, swallow: false, trigger: false)
check(button(down: false), eligible: false, time: 10.1, swallow: false, trigger: false)
precondition(MediaButton.decode(subtype: 8, data1: (16 << 16) | 0x0a00)?.down == true)
precondition(MediaButton.decode(subtype: 8, data1: (16 << 16) | 0x0b00)?.down == false)
precondition(MediaButton.decode(subtype: 8, data1: (16 << 16) | 0x0a01)?.repeated == true)
precondition(MediaButton.decode(subtype: 7, data1: 0) == nil)
precondition(MediaButton.decode(subtype: 8, data1: 0) == nil)
let hidPlayDown = MediaButton.decodeHID(usagePage: 0x0c, usage: 0xcd, value: 1)
precondition(hidPlayDown?.key == 16 && hidPlayDown?.down == true && hidPlayDown?.repeated == false)
let hidPlayUp = MediaButton.decodeHID(usagePage: 0x0c, usage: 0xcd, value: 0)
precondition(hidPlayUp?.key == 16 && hidPlayUp?.down == false)
precondition(MediaButton.decodeHID(usagePage: 0x0c, usage: 0xcd, value: -1)?.down == true)
let hidVolumeUp = MediaButton.decodeHID(usagePage: 0x0c, usage: 0xe9, value: 1)
precondition(hidVolumeUp?.key == 0 && hidVolumeUp?.down == true)
let hidVolumeDown = MediaButton.decodeHID(usagePage: 0x0c, usage: 0xea, value: 0)
precondition(hidVolumeDown?.key == 1 && hidVolumeDown?.down == false)
precondition(MediaButton.decodeHID(usagePage: 0x01, usage: 0xcd, value: 1) == nil)
precondition(MediaButton.decodeHID(usagePage: 0x0c, usage: 0x01, value: 1) == nil)
precondition(MediaButton.decodeHID(usagePage: 0x0c, usage: 0xb0, value: 1) == nil)
precondition(isHeadsetRemote(product: "Headset", transport: "Audio", usagePage: 0x0c, usage: 1))
precondition(!isHeadsetRemote(product: "Keyboard", transport: "Audio", usagePage: 0x0c, usage: 1))
precondition(!isHeadsetRemote(product: "Headset", transport: "USB", usagePage: 0x0c, usage: 1))
precondition(!isHeadsetRemote(product: "Headset", transport: "Audio", usagePage: 0x01, usage: 1))
precondition(!isHeadsetRemote(product: "Headset", transport: "Audio", usagePage: 0x0c, usage: 2))
precondition(isHeadphoneName("External Headphones"))
precondition(isHeadphoneName("外置耳机"))
precondition(!isHeadphoneName("MacBook Pro Speakers"))
print("PASS: legacy/HID parsing, headset selection, one trigger per press, repeats, paired releases, eligibility, modifier capture, debounce/reset, non-target keys")


// These routing checks intentionally use no AppKit, HID or notification center.
// They cover where a physical click goes, including late/wrong replies and
// cancellation; none of these tests sends a real Fn or opens a window.
var routing = ComposerRoutingState()
var routeAssertions = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    routeAssertions += 1
}
let uu = ComposerProtocol.uuBundleID
let composer = ComposerProtocol.bridgeBundleID
expect(routing.route(frontmostBundleID: "com.apple.TextEdit", bridgeRunning: false,
                     requestID: "unused", now: 0) == .localFn, "local works without receiver")
expect(routing.route(frontmostBundleID: composer, bridgeRunning: true,
                     requestID: "unused", now: 1) == .localFn, "composer uses native Doubao Fn")
expect(routing.route(frontmostBundleID: nil, bridgeRunning: true,
                     requestID: "unused", now: 2) == .noForeground, "unknown focus does not inject")
expect(routing.route(frontmostBundleID: "", bridgeRunning: true,
                     requestID: "unused", now: 3) == .noForeground, "empty focus does not inject")
expect(routing.route(frontmostBundleID: uu, bridgeRunning: false,
                     requestID: "unused", now: 4) == .bridgeUnavailable, "no receiver never falls back to Fn")
expect(routing.pendingID == nil, "unavailable is not pending")
expect(routing.route(frontmostBundleID: uu, bridgeRunning: true,
                     requestID: "first", now: 5) == .openComposer("first"), "UU sends message")
expect(routing.route(frontmostBundleID: uu, bridgeRunning: true,
                     requestID: "duplicate", now: 5.2) == .waiting, "duplicate click suppressed")
expect(routing.route(frontmostBundleID: composer, bridgeRunning: true,
                     requestID: "focused", now: 5.3) == .waiting, "pending blocks premature Fn after focus moves")
expect(routing.acknowledge(requestID: "wrong", status: "opened", now: 5.4) == nil,
       "wrong nonce ignored")
expect(routing.pendingID == "first", "wrong nonce preserves request")
expect(routing.acknowledge(requestID: "first", status: "unknown", now: 5.4) == nil,
       "unknown reply ignored")
expect(routing.acknowledge(requestID: "first", status: "opened", now: 5.5) == .opened,
       "successful reply accepted")
expect(routing.pendingID == nil, "success clears pending")
expect(routing.route(frontmostBundleID: composer, bridgeRunning: true,
                     requestID: "next", now: 5.6) == .localFn, "second click in composer uses Fn")
expect(routing.acknowledge(requestID: "first", status: "opened", now: 5.7) == nil,
       "duplicate reply ignored")
for status in ComposerReplyStatus.allCases {
    _ = routing.route(frontmostBundleID: uu, bridgeRunning: true,
                      requestID: status.rawValue, now: 10)
    expect(routing.acknowledge(requestID: status.rawValue, status: status.rawValue, now: 10.1) == status,
           "recognized status \(status.rawValue)")
    expect(routing.pendingID == nil, "every recognized reply clears pending")
}
_ = routing.route(frontmostBundleID: uu, bridgeRunning: true, requestID: "timeout", now: 20)
expect(!routing.expire(requestID: "wrong", now: 21), "stale timer cannot expire another request")
expect(!routing.expire(requestID: "timeout", now: 20.7), "early timeout ignored")
expect(routing.expire(requestID: "timeout", now: 20.8), "deadline clears request")
expect(routing.acknowledge(requestID: "timeout", status: "opened", now: 20.9) == nil,
       "late reply after timeout ignored")
_ = routing.route(frontmostBundleID: uu, bridgeRunning: true, requestID: "late", now: 30)
expect(routing.acknowledge(requestID: "late", status: "opened", now: 30.8) == nil,
       "late reply rejected even before timeout callback")
expect(routing.pendingID == nil, "expired acknowledgement clears state")
_ = routing.route(frontmostBundleID: uu, bridgeRunning: true, requestID: "cancelled", now: 40)
routing.cancel()
expect(routing.pendingID == nil, "pause or device change cancels request")
expect(routing.acknowledge(requestID: "cancelled", status: "opened", now: 40.1) == nil,
       "reply after cancellation ignored")
expect(!routing.expire(requestID: "cancelled", now: 41), "cancelled timer has no effect")
_ = routing.route(frontmostBundleID: uu, bridgeRunning: true, requestID: "old", now: 50)
expect(routing.route(frontmostBundleID: uu, bridgeRunning: true,
                     requestID: "retry", now: 51) == .openComposer("retry"), "new user click can retry after timeout")
expect(!routing.expire(requestID: "old", now: 51.1), "old timer cannot cancel retry")
expect(routing.acknowledge(requestID: "old", status: "opened", now: 51.1) == nil,
       "old reply cannot complete retry")
expect(routing.acknowledge(requestID: "retry", status: "restored", now: 51.2) == .restored,
       "retry can complete")
print("PASS: \(routeAssertions) cooperative routing / acknowledgement assertions")

import Foundation

struct MediaButton {
    let key: Int
    let down: Bool
    let repeated: Bool

    static func decode(subtype: Int, data1: Int) -> MediaButton? {
        guard subtype == 8 else { return nil }
        let state = (data1 >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        return MediaButton(key: (data1 >> 16) & 0xffff,
                           down: state == 0x0a, repeated: (data1 & 1) != 0)
    }

    static func decodeHID(usagePage: Int, usage: Int, value: Int) -> MediaButton? {
        guard usagePage == 0x0c else { return nil }
        let key: Int
        switch usage {
        case 0xcd: key = 16
        case 0xe9: key = 0
        case 0xea: key = 1
        default: return nil
        }
        return MediaButton(key: key, down: value != 0, repeated: false)
    }
}

struct MappingDecision {
    let swallow: Bool
    let trigger: Bool
}

/// The headset is seized before values reach the media-key system. This state
/// decides whether a captured play/pause value starts the shortcut. One physical
/// down/up pair produces at most one shortcut; modifiers suppress the shortcut
/// while still consuming the media button and its matching release.
struct MappingState {
    private var captured = false
    private var lastTrigger = -Double.infinity

    mutating func reset() {
        captured = false
        lastTrigger = -Double.infinity
    }

    mutating func handle(_ button: MediaButton, eligible: Bool,
                         modifiersHeld: Bool, now: Double) -> MappingDecision {
        guard button.key == 16 else {
            return MappingDecision(swallow: false, trigger: false)
        }
        if !button.down {
            let wasCaptured = captured
            captured = false
            return MappingDecision(swallow: wasCaptured, trigger: false)
        }
        // HID may deliver duplicate downs without a repeat bit. Keep the same
        // physical press captured until its up, even if eligibility changes.
        if captured { return MappingDecision(swallow: true, trigger: false) }
        guard eligible else { return MappingDecision(swallow: false, trigger: false) }
        captured = true
        guard !button.repeated, !modifiersHeld else {
            return MappingDecision(swallow: true, trigger: false)
        }
        // Reject duplicate hardware notifications, but allow deliberate clicks.
        guard now - lastTrigger >= 0.18 else {
            return MappingDecision(swallow: true, trigger: false)
        }
        lastTrigger = now
        return MappingDecision(swallow: true, trigger: true)
    }
}

func isHeadsetRemote(product: String, transport: String,
                     usagePage: Int, usage: Int) -> Bool {
    product == "Headset" && transport == "Audio" && usagePage == 0x0c && usage == 1
}

func isHeadphoneName(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.contains("headphone") || lower.contains("headset") || name.contains("耳机")
}

import CoreGraphics

/// Both the physical trigger and the local Doubao event are Fn / Globe.
/// No preference or mapping can select a Control trigger in this build.
enum FnTriggerSource: Hashable { case keyboard, headset }

enum FnKeyPolicy {
    // DoubaoHeadsetBridge 1.1+ local Fn pulse marker (HID flagsChanged, 60ms).
    static let headsetEventMarker: Int64 = 0x444F5542414F
    static func source(marker: Int64) -> FnTriggerSource {
        marker == headsetEventMarker ? .headset : .keyboard
    }
    static func schedulesVoiceHold(source: FnTriggerSource) -> Bool { source == .keyboard }

    static let keyCode: Int64 = 63
    static let title = "Fn / 🌐"
    static let conflictingFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskControl]

    static func transition(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool? {
        guard type == .flagsChanged, keyCode == Self.keyCode else { return nil }
        return flags.contains(.maskSecondaryFn)
    }
}

enum LocalFnEventPolicy {
    static func flags(down: Bool, current: CGEventFlags) -> CGEventFlags {
        var flags = current
        if down { flags.insert(.maskSecondaryFn) }
        else { flags.remove(.maskSecondaryFn) }
        return flags
    }
}

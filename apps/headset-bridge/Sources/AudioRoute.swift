import CoreAudio
import Foundation

struct AudioRoute {
    let headphoneConnected: Bool
    let summary: String

    static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                   mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func name(_ object: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return "未知设备" }
        return value.takeRetainedValue() as String
    }

    static func devices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                            &address, 0, nil, &size) == noErr else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !result.isEmpty else { return [] }
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? result : []
    }

    static func inspect() -> AudioRoute {
        var connected = false
        var rows: [String] = []
        for device in devices() {
            let deviceName = name(device)
            let transport = uint(device, kAudioDevicePropertyTransportType)
            let alive = uint(device, kAudioDevicePropertyDeviceIsAlive) == 1
            let jack = uint(device, kAudioDevicePropertyJackIsConnected,
                            scope: kAudioObjectPropertyScopeOutput)
            let source = uint(device, kAudioDevicePropertyDataSource,
                              scope: kAudioObjectPropertyScopeOutput)
            // 'hdpn' is the built-in output data source used by many Macs.
            // Newer Macs expose an alive "External Headphones" audio device.
            let builtIn = transport == kAudioDeviceTransportTypeBuiltIn
            let headphone = builtIn && alive &&
                (source == 0x6864706e || isHeadphoneName(deviceName)) && jack != 0
            connected = connected || headphone
            rows.append("\(deviceName)：内置=\(builtIn)，可用=\(alive)，耳机插孔=\(jack.map(String.init) ?? "未提供")，输出源=\(source.map { String(format: "%08x", $0) } ?? "未提供")")
        }
        return AudioRoute(headphoneConnected: connected,
                          summary: rows.isEmpty ? "系统未返回音频设备；可暂时关闭“仅耳机连接时”。" : rows.joined(separator: "\n"))
    }
}

import Foundation
import IOKit.hid

/// Own only the Mac's audio-jack remote, never a keyboard or an audio stream.
/// Seizing prevents the original consumer report from reaching media players.
final class HeadsetCapture {
    private var manager: IOHIDManager?
    private var sessions = [ObjectIdentifier: HeadsetSession]()
    private var active = false
    private(set) var lastError: IOReturn?
    var onButton: ((MediaButton, inout MappingState) -> Void)?
    var onChange: (() -> Void)?

    var deviceCount: Int { sessions.count }
    var capturedCount: Int { sessions.values.filter { $0.opened }.count }

    func start() {
        guard manager == nil else { return }
        // The manager discovers devices; only individual sessions open them.
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault,
                                          IOHIDManagerOptions.independentDevices.rawValue)
        manager = newManager
        let matching: [String: Any] = [
            kIOHIDProductKey: "Headset", kIOHIDTransportKey: "Audio",
            kIOHIDPrimaryUsagePageKey: 0x0c, kIOHIDPrimaryUsageKey: 1
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HeadsetCapture>.fromOpaque(context).takeUnretainedValue().add(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, _, _, device in
            guard let context else { return }
            let capture = Unmanaged<HeadsetCapture>.fromOpaque(context).takeUnretainedValue()
            capture.sessions.removeValue(forKey: ObjectIdentifier(device))?.close()
            capture.onChange?()
        }, context)
        IOHIDManagerSetDeviceMatching(newManager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { lastError = result }
        if let devices = IOHIDManagerCopyDevices(newManager) as? Set<IOHIDDevice> {
            for device in devices { add(device) }
        }
    }

    private func add(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        guard isHeadsetRemote(product: product, transport: transport, usagePage: page, usage: usage),
              sessions[ObjectIdentifier(device)] == nil else { return }
        let session = HeadsetSession(device: device)
        session.onButton = { [weak self] button, state in self?.onButton?(button, &state) }
        sessions[ObjectIdentifier(device)] = session
        if active { open(session) }
        onChange?()
    }

    private func open(_ session: HeadsetSession) {
        let result = session.open()
        if result != kIOReturnSuccess { lastError = result }
    }

    func update(active: Bool) {
        self.active = active
        lastError = nil
        let previous = capturedCount
        for session in sessions.values {
            if active { open(session) } else { session.close() }
        }
        if previous != capturedCount { onChange?() }
    }

    func stop() {
        active = false
        for session in sessions.values { session.close() }
        sessions.removeAll()
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        lastError = nil
    }
}

private final class HeadsetSession {
    let device: IOHIDDevice
    private(set) var opened = false
    private var state = MappingState()
    var onButton: ((MediaButton, inout MappingState) -> Void)?

    init(device: IOHIDDevice) { self.device = device }

    func open() -> IOReturn {
        guard !opened else { return kIOReturnSuccess }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            // ExclusiveAccess can leave a non-seizing open client registered.
            // Balance it before a retry, or a later seize may reuse that open.
            if result == kIOReturnExclusiveAccess {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            return result
        }
        opened = true
        state.reset()
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            let session = Unmanaged<HeadsetSession>.fromOpaque(context).takeUnretainedValue()
            guard session.opened else { return }
            let element = IOHIDValueGetElement(value)
            guard let button = MediaButton.decodeHID(
                usagePage: Int(IOHIDElementGetUsagePage(element)),
                usage: Int(IOHIDElementGetUsage(element)), value: IOHIDValueGetIntegerValue(value)) else { return }
            session.onButton?(button, &session.state)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return result
    }

    func close() {
        guard opened else { return }
        opened = false
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        state.reset()
    }
}

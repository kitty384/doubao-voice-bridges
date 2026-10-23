import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hidsystem

final class Bridge: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let capture = HeadsetCapture()
    private var timer: Timer?
    private var route = AudioRoute.inspect()
    private var window: NSWindow?
    private var textView: NSTextView?
    private var enabled = true
    private var onlyHeadphones = true
    private var volumeTimers = [Int: Timer]()
    private var heldVolumeKeys = Set<Int>()
    private var pendingFnUp: CGEvent?
    private var shortcutGeneration = 0
    private var composerRouting = ComposerRoutingState()
    private var composerTimeout: DispatchWorkItem?
    private var replyObserver: NSObjectProtocol?
    private var cooperativeStatus: String?
    private let marker: Int64 = 0x444f5542414f

    private var inputAllowed: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    private var mappingRequested: Bool {
        enabled && AXIsProcessTrusted() && (!onlyHeadphones || route.headphoneConnected)
    }
    private var captureRequested: Bool { enabled && AXIsProcessTrusted() }
    private var status: String {
        if !enabled { return "映射已暂停" }
        if !AXIsProcessTrusted() { return "请允许辅助功能权限" }
        if onlyHeadphones && !route.headphoneConnected { return "等待连接外置耳机" }
        if capture.capturedCount > 0 { return cooperativeStatus ?? "已启用：本地 Fn / UU 开框；音乐控制已拦截" }
        if capture.lastError != nil {
            return inputAllowed ? "线控接管未就绪，请重新检测或退出其他映射工具" : "线控接管未就绪，请允许输入监控并重新打开"
        }
        return "等待耳机线控设备"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["mappingEnabled": true, "onlyHeadphones": true])
        enabled = defaults.bool(forKey: "mappingEnabled")
        onlyHeadphones = defaults.bool(forKey: "onlyHeadphones")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        replyObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(ComposerProtocol.replyName),
            object: ComposerProtocol.object, queue: .main
        ) { [weak self] notification in
            self?.receiveComposerReply(notification)
        }
        capture.onButton = { [weak self] button, state in self?.handle(button, state: &state) }
        capture.onChange = { [weak self] in
            guard let self else { return }
            self.shortcutGeneration += 1
            self.cancelComposerRequest()
            self.releaseFn()
            if self.capture.capturedCount == 0 {
                self.releaseVolumeKeys()
            }
            self.refreshText()
        }
        updateCapture()
        let refreshTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateCapture()
        }
        timer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
        // Normal launches stay quietly in the menu bar. Setup needs a window.
        if !AXIsProcessTrusted() || capture.lastError != nil { showWindow() }
    }

    private func updateRoute() {
        let next = AudioRoute.inspect()
        if next.headphoneConnected != route.headphoneConnected || next.summary != route.summary {
            shortcutGeneration += 1
            cancelComposerRequest()
            releaseFn()
        }
        route = next
    }

    private func updateCapture() {
        updateRoute()
        capture.start()
        // The Headset interface is permanent. Keep it captured across plug-in
        // so the first click cannot reach Music before a route polling tick.
        let requested = captureRequested
        if !mappingRequested { cancelComposerRequest() }
        if !requested {
            shortcutGeneration += 1
            releaseFn()
            releaseVolumeKeys()
        }
        capture.update(active: requested)
        refreshText()
    }

    private func handle(_ button: MediaButton, state: inout MappingState) {
        guard captureRequested else { return }
        updateRoute()
        if button.key == 0 || button.key == 1 {
            handleVolume(button)
            return
        }
        let held = CGEventSource.flagsState(.combinedSessionState)
        let modifiersHeld = !held.intersection([.maskCommand, .maskControl, .maskAlternate,
                                               .maskShift, .maskSecondaryFn]).isEmpty
        let decision = state.handle(button, eligible: mappingRequested, modifiersHeld: modifiersHeld,
                                    now: ProcessInfo.processInfo.systemUptime)
        if decision.trigger {
            let generation = shortcutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.shortcutGeneration, self.mappingRequested else { return }
                self.routeShortcut()
            }
        }
        // The exclusive open already consumes the original report. Never
        // re-post play/pause, including when another modifier is held.
    }

    private func routeShortcut() {
        guard mappingRequested else { cancelComposerRequest(); return }
        let foregroundApp = NSWorkspace.shared.frontmostApplication
        let foreground = foregroundApp?.bundleIdentifier
        let bridgeRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: ComposerProtocol.bridgeBundleID).isEmpty
        let action = composerRouting.route(frontmostBundleID: foreground,
            bridgeRunning: bridgeRunning, requestID: UUID().uuidString,
            now: ProcessInfo.processInfo.systemUptime)
        switch action {
        case .localFn:
            cooperativeStatus = nil
            sendFn()
        case .openComposer(let requestID):
            guard let targetPID = foregroundApp?.processIdentifier else {
                cancelComposerRequest()
                return
            }
            composerTimeout?.cancel()
            cooperativeStatus = "等待远控听写打开发送框…"
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.composerRouting.expire(requestID: requestID,
                    now: ProcessInfo.processInfo.systemUptime) else { return }
                self.composerTimeout = nil
                self.cooperativeStatus = "远控听写未回应；请检查是否启用或更新到协作版本"
                self.refreshText()
            }
            composerTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + ComposerProtocol.timeout, execute: timeout)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(ComposerProtocol.requestName), object: ComposerProtocol.object,
                userInfo: ["requestID": requestID,
                           "targetPID": Int(targetPID),
                           "sentAt": Date().timeIntervalSince1970], deliverImmediately: true)
        case .waiting:
            break
        case .bridgeUnavailable:
            cooperativeStatus = "请先启动远控听写，再按线控打开发送框"
        case .noForeground:
            cooperativeStatus = "未确定当前应用；请选中输入框后重试"
        }
        refreshText()
    }

    private func receiveComposerReply(_ notification: Notification) {
        let now = ProcessInfo.processInfo.systemUptime
        if let pending = composerRouting.pendingID,
           composerRouting.expire(requestID: pending, now: now) {
            composerTimeout?.cancel()
            composerTimeout = nil
            cooperativeStatus = "远控听写未及时回应；请检查状态后重试"
            refreshText()
            return
        }
        guard let requestID = notification.userInfo?["requestID"] as? String,
              let status = notification.userInfo?["status"] as? String,
              let reply = composerRouting.acknowledge(requestID: requestID, status: status, now: now) else { return }
        composerTimeout?.cancel()
        composerTimeout = nil
        switch reply {
        case .opened, .restored:
            cooperativeStatus = "发送框已打开；再按线控启动豆包，转写后按 Return 发送"
        case .busy:
            cooperativeStatus = "远控听写正在处理上一轮；请完成后再试"
        case .paused:
            cooperativeStatus = "远控听写已暂停；请先启用 Fn 听写"
        case .blocked:
            cooperativeStatus = "远控听写暂时阻止开框；请检查其菜单状态"
        case .focusChanged:
            cooperativeStatus = "焦点已切换；请回到 UU 后重试"
        case .unavailable:
            cooperativeStatus = "远控听写暂不可用；请检查其菜单状态"
        }
        refreshText()
    }

    private func cancelComposerRequest() {
        composerTimeout?.cancel()
        composerTimeout = nil
        composerRouting.cancel()
        cooperativeStatus = nil
    }

    private func sendFn() {
        // Recheck immediately before event synthesis: focus may have changed
        // since the captured HID press was queued on the main thread.
        guard let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              !foreground.isEmpty else { return }
        if foreground == ComposerProtocol.uuBundleID { routeShortcut(); return }

        guard AXIsProcessTrusted(), pendingFnUp == nil else { return }
        let current = CGEventSource.flagsState(.combinedSessionState)
        guard current.intersection([.maskCommand, .maskControl, .maskAlternate,
                                    .maskShift, .maskSecondaryFn]).isEmpty else { return }
        guard let pair = FnPulseEvents.makePair() else { return }
        let down = pair.down
        let up = pair.up
        let latestForeground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if latestForeground == ComposerProtocol.uuBundleID { routeShortcut(); return }
        guard latestForeground == foreground, mappingRequested else { return }
        pendingFnUp = up
        FnPulseEvents.prepare(down, down: true, currentFlags: current)
        down.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + FnPulseEvents.duration) { [weak self] in
            guard let self, self.pendingFnUp === up else { return }
            self.releaseFn()
        }
    }

    private func releaseFn() {
        guard let up = pendingFnUp else { return }
        pendingFnUp = nil
        FnPulseEvents.prepare(up, down: false,
                              currentFlags: CGEventSource.flagsState(.combinedSessionState))
        up.post(tap: .cghidEventTap)
    }

    private func handleVolume(_ button: MediaButton) {
        if button.down {
            guard heldVolumeKeys.insert(button.key).inserted else { return }
            postVolume(key: button.key, down: true)
            let repeatTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.captureRequested, self.heldVolumeKeys.contains(button.key) else { return }
                self.postVolume(key: button.key, down: true, repeated: true)
            }
            repeatTimer.fireDate = Date().addingTimeInterval(0.4)
            volumeTimers[button.key] = repeatTimer
            RunLoop.main.add(repeatTimer, forMode: .common)
        } else {
            volumeTimers.removeValue(forKey: button.key)?.invalidate()
            if heldVolumeKeys.remove(button.key) != nil { postVolume(key: button.key, down: false) }
        }
    }

    private func postVolume(key: Int, down: Bool, repeated: Bool = false) {
        // Only the two volume usages are re-posted; never NX_KEYTYPE_PLAY.
        guard key == 0 || key == 1 else { return }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0x0a00 : 0x0b00))
        guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 8,
            data1: (key << 16) | (down ? 0x0a00 : 0x0b00) | (repeated ? 1 : 0), data2: -1)?.cgEvent else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    private func releaseVolumeKeys() {
        for timer in volumeTimers.values { timer.invalidate() }
        volumeTimers.removeAll()
        for key in heldVolumeKeys { postVolume(key: key, down: false) }
        heldVolumeKeys.removeAll()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        item(menu, status, nil)
        item(menu, "外置耳机：\(route.headphoneConnected ? "已连接" : "未连接")", nil)
        menu.addItem(.separator())
        item(menu, enabled ? "暂停线控桥接" : "启用线控：本地 Fn / UU 开框", #selector(toggleEnabled))
        item(menu, "仅外置耳机连接时启用", #selector(toggleGate), checked: onlyHeadphones)
        menu.addItem(.separator())
        item(menu, "设置与使用说明…", #selector(showWindow))
        item(menu, "打开辅助功能设置…", #selector(openAccessibility))
        item(menu, "打开输入监控设置…", #selector(openInputMonitoring))
        item(menu, "重新检测", #selector(retry))
        menu.addItem(.separator())
        item(menu, "退出", #selector(quit))
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector?, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "mappingEnabled")
        updateCapture()
        if enabled && (!AXIsProcessTrusted() || capture.lastError != nil) { showWindow() }
    }
    @objc private func toggleGate() {
        onlyHeadphones.toggle()
        UserDefaults.standard.set(onlyHeadphones, forKey: "onlyHeadphones")
        updateCapture()
    }
    @objc private func retry() {
        cancelComposerRequest()
        shortcutGeneration += 1
        releaseFn()
        releaseVolumeKeys()
        capture.stop()
        updateCapture()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    @objc private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "豆包耳机语音桥接 — 设置"
            w.minSize = NSSize(width: 620, height: 400)
            w.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: NSRect(x: 20, y: 80, width: 650, height: 360))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.font = NSFont.systemFont(ofSize: 14)
            text.textContainerInset = NSSize(width: 10, height: 10)
            text.autoresizingMask = [.width]
            scroll.documentView = text
            w.contentView?.addSubview(scroll)
            let buttons: [(String, Selector, CGFloat, CGFloat)] = [
                ("辅助功能权限", #selector(openAccessibility), 20, 150),
                ("输入监控权限", #selector(openInputMonitoring), 180, 150),
                ("重新检测", #selector(retry), 340, 120),
                ("在访达中显示", #selector(revealApp), 470, 150)
            ]
            for (title, action, x, width) in buttons {
                let button = NSButton(title: title, target: self, action: action)
                button.frame = NSRect(x: x, y: 25, width: width, height: 32)
                w.contentView?.addSubview(button)
            }
            window = w
            textView = text
            w.center()
        }
        refreshText()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshText() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2"
        statusItem?.button?.title = mappingRequested && capture.capturedCount > 0 ? "🎧Fn" : "🎧"
        statusItem?.button?.toolTip = status
        textView?.string = """
        豆包耳机语音桥接 \(version)

        \(status)
        外置耳机：\(route.headphoneConnected ? "已连接" : "未连接")
        辅助功能：\(AXIsProcessTrusted() ? "已允许" : "未允许")    输入监控：\(inputAllowed ? "已允许" : "未允许")

        使用方法
        1. 豆包保留“免按模式：Fn”。
        2. 在系统设置中允许本程序的“辅助功能”。
           更新后若权限失效，请移除旧条目，重新添加当前程序并重新打开。
        3. 连接 3.5 mm 耳机；出现“音乐控制已拦截”后即可使用。
           如果线控未就绪，请允许“输入监控”并重新打开本程序。
        4. 本地输入框：单击中间键开始豆包语音，再单击结束。
        5. UU 前台：第一次单击通知远控听写打开发送框。
           框内再单击中间键开始豆包语音，结束后按 Return 发送。
           需搭配支持协作消息的新版远控听写。

        本地中间键发送一次 Fn；UU 前台只发送开框请求。
        请求未回应时会提示，不补发 Fn、不自动重试。
        不发送音乐播放或暂停。
        按住其他修饰键时，中间键不触发 Fn，也不会控制音乐。
        耳机音量加减继续可用；键盘上的 Fn 和媒体键保持原功能。
        麦克风由豆包选择。本程序不录音、不联网、不记录按键日志或次数。

        映射默认启用并记住设置，正常启动只驻留菜单栏。
        暂停线控桥接或退出本程序后，耳机恢复系统原有功能。
        若耳机已连接但未检测到，可取消菜单中的“仅外置耳机连接时启用”。
        """
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        cancelComposerRequest()
        if let replyObserver { DistributedNotificationCenter.default().removeObserver(replyObserver) }
        replyObserver = nil
        shortcutGeneration += 1
        releaseFn()
        releaseVolumeKeys()
        capture.stop()
    }
}

if CommandLine.arguments.contains("--audio-diagnostics") {
    let route = AudioRoute.inspect()
    print("headphoneConnected=\(route.headphoneConnected)\n\(route.summary)")
} else {
    let app = NSApplication.shared
    let delegate = Bridge()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}

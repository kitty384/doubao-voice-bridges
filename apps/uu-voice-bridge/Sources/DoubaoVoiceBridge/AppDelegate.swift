import AppKit
import Carbon
import ApplicationServices
import os.log

enum LatencyDefaultsMigration {
    static let legacyPasteDelay: TimeInterval = 0.9

    static func replacementPasteDelay(for storedValue: Any?) -> TimeInterval? {
        guard let storedValue else { return UURemoteDelivery.defaultPasteDelay }

        let numericValue: Double?
        if let number = storedValue as? NSNumber {
            numericValue = number.doubleValue
        } else if let string = storedValue as? String {
            numericValue = Double(string)
        } else {
            numericValue = nil
        }

        guard let numericValue,
              abs(numericValue - legacyPasteDelay) < 0.000_1 else {
            return nil
        }
        return UURemoteDelivery.defaultPasteDelay
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let uuRemoteBundleIdentifier = "com.netease.uuremote"
    private static let latencyDefaultsMigrationKey = "didMigrateLatencyDefaultsV23"

    private enum MonitoringState {
        case paused
        case starting
        case active
    }

    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge.Fn", category: "app")
    private let coordinator = SessionCoordinator()
    private let requestServer = ComposerRequestServer()
    private var workspaceObserver: NSObjectProtocol?
    private var healthTimer: Timer?
    private var monitor: TriggerHoldMonitor?
    private var statusItem: NSStatusItem?
    private var statusText = "已暂停 · 点击菜单启用 Fn 听写"
    private var statusIsError = false
    private var monitoringState: MonitoringState = .paused
    private var startGeneration: UInt64 = 0
    private var accessibilityItem: NSMenuItem?
    private var inputMonitoringItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "pasteDelay": UURemoteDelivery.defaultPasteDelay,
            "autoPasteUU": true,
            "fnHoldThreshold": 0.18,
            "legacyHoldToTalk": false
        ])
        UserDefaults.standard.set(true, forKey: "autoPasteUU")
        migrateLatencyDefaultsIfNeeded()

        configureStatusItem()
        coordinator.onStatusChange = { [weak self] text, isError in
            guard let self, self.monitoringState == .active else { return }
            self.setStatus(text, isError: isError)
        }
        configureMonitor()
        requestServer.onRequest = { [weak self] request, reply in
            guard let self else { reply("unavailable"); return }
            self.handleHeadsetRequest(request, reply: reply)
        }
        requestServer.start()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.monitor?.refreshForForegroundTransition(isUU: app?.bundleIdentifier == Self.uuRemoteBundleIdentifier)
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updatePermissionDisplay() }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        // Permission changes never install an event tap. Every launch remains
        // paused until the user explicitly chooses Enable from the menu.
        setStatus("已暂停 · 点击菜单启用 Fn 听写", isError: false)
        if CommandLine.arguments.contains("--paused-startup-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { exit(1) }
                var count: UInt32 = 0
                guard CGGetEventTapList(0, nil, &count) == .success else { exit(1) }
                let capacity = max(count + 32, 64)
                let buffer = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(capacity))
                defer { buffer.deallocate() }
                var filled: UInt32 = 0
                guard CGGetEventTapList(capacity, buffer, &filled) == .success else { exit(1) }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownCount = (0..<min(Int(filled), Int(capacity))).filter { buffer[$0].tappingProcess == ownPID }.count
                guard self.monitoringState == .paused, self.monitor?.activeTapLocation == nil, ownCount == 0 else { exit(1) }
                print("PAUSED_STARTUP_OK own_event_taps=0")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    private func configureMonitor() {
        let monitor = TriggerHoldMonitor(
            holdThreshold: UserDefaults.standard.double(forKey: "fnHoldThreshold"),
            voiceHoldEnabled: UserDefaults.standard.bool(forKey: "legacyHoldToTalk"),
            targetProvider: { [weak self] in
                guard let self, self.monitoringState == .active,
                      self.coordinator.canRequestComposer else { return nil }
                return self.currentUURemoteTarget()
            },
            localComposerReady: { [weak self] in
                self?.coordinator.isLocalComposerReady ?? false
            },
            onBegin: { [weak self] target, mode in
                guard let self else { return false }
                return self.coordinator.begin(target: target, mode: mode, activationAllowed: {
                    self.monitoringState == .active && !IsSecureEventInputEnabled() &&
                    self.currentUURemoteTarget()?.processIdentifier == target.processIdentifier
                })
            },
            onRelease: { [weak self] in self?.coordinator.fnReleased() },
            onCancel: { [weak self] in self?.coordinator.cancel(restoreFocus: false) }
        )
        monitor.onFault = { [weak self] reason in
            // TriggerHoldMonitor delivers this on main after validating its generation.
            // Do not enqueue another turn that could pause a newer activation.
            guard let self, self.monitoringState != .paused else { return }
            self.pauseMonitoring(status: "已暂停 · \(reason)", isError: true)
        }
        self.monitor = monitor
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        startGeneration &+= 1
        monitoringState = .paused
        monitor?.stop()
        coordinator.prepareForTermination()
        GUIRuntimeStatus.removeOwnSnapshot()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: "远控听写 Fn")
            button.toolTip = "远控听写 Fn · 已暂停"
        }
        statusItem = item
        rebuildMenu()
    }

    private func migrateLatencyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.latencyDefaultsMigrationKey) else { return }
        if let replacement = LatencyDefaultsMigration.replacementPasteDelay(
            for: defaults.object(forKey: "pasteDelay")
        ) {
            defaults.set(replacement, forKey: "pasteDelay")
        }
        defaults.set(true, forKey: Self.latencyDefaultsMigrationKey)
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
        statusItem?.button?.toolTip = "远控听写 Fn · \(text)"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let versionItem = NSMenuItem(title: "远控听写 Fn \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if statusIsError {
            status.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(status)
        menu.addItem(.separator())

        let enable = NSMenuItem(title: "启用 Fn 听写", action: #selector(enableMonitoring), keyEquivalent: "")
        enable.target = self
        enable.isEnabled = monitoringState == .paused
        menu.addItem(enable)
        let pause = NSMenuItem(title: "暂停 Fn 听写", action: #selector(pauseMonitoringFromMenu), keyEquivalent: "")
        pause.target = self
        pause.isEnabled = monitoringState != .paused
        menu.addItem(pause)
        menu.addItem(.separator())

        let instruction = NSMenuItem(title: "UU 中第一次 Fn / 线控开框，框内再听写", action: nil, keyEquivalent: "")
        instruction.isEnabled = false
        menu.addItem(instruction)
        let doubaoHint = NSMenuItem(title: "豆包保留原生 Fn 设置；回车发送", action: nil, keyEquivalent: "")
        doubaoHint.isEnabled = false
        menu.addItem(doubaoHint)
        let legacy = NSMenuItem(title: "兼容模式：长按 Fn 直接听写", action: #selector(toggleLegacyHold), keyEquivalent: "")
        legacy.target = self
        legacy.state = UserDefaults.standard.bool(forKey: "legacyHoldToTalk") ? .on : .off
        menu.addItem(legacy)
        menu.addItem(.separator())

        let ax = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        ax.target = self
        accessibilityItem = ax
        menu.addItem(ax)
        let input = NSMenuItem(title: "", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        input.target = self
        inputMonitoringItem = input
        menu.addItem(input)
        updatePermissionDisplay()
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出远控听写", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // Preserve the explicit enabled states above instead of asking AppKit
        // to infer availability from the presence of action selectors.
        menu.autoenablesItems = false
        statusItem?.menu = menu
    }

    private func currentUURemoteTarget() -> UURemoteTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == Self.uuRemoteBundleIdentifier,
              !frontmost.isTerminated else { return nil }
        return UURemoteTarget(application: frontmost)
    }

    @objc private func enableMonitoring() {
        guard monitoringState == .paused, let monitor else { return }
        let permissions = PermissionStatus.current()
        guard permissions.ready else {
            setStatus("已暂停 · \(permissions.missingDescription)；开启后退出并重新打开本应用", isError: true)
            return
        }
        startGeneration &+= 1
        let requestedGeneration = startGeneration
        monitoringState = .starting
        setStatus("正在启用 Fn 听写…", isError: false)
        monitor.start { [weak self] result in
            guard let self, self.startGeneration == requestedGeneration,
                  self.monitoringState == .starting else { return }
            switch result {
            case .success:
                self.monitoringState = .active
                monitor.refreshEligibility()
                self.setStatus("监听已启用 · UU 首次开框，框内 Fn / 线控听写", isError: false)
            case .failure(let error):
                self.logger.error("Fn monitor start failed: \(error.localizedDescription, privacy: .public)")
                self.pauseMonitoring(status: "已暂停 · \(error.localizedDescription)", isError: true)
            }
        }
    }

    @objc private func pauseMonitoringFromMenu() {
        pauseMonitoring(status: "已暂停 · 点击菜单启用 Fn 听写", isError: false)
    }

    private func pauseMonitoring(status: String, isError: Bool) {
        startGeneration &+= 1
        monitoringState = .paused
        monitor?.stop()
        coordinator.cancel(restoreFocus: false)
        setStatus(status, isError: isError)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updatePermissionDisplay() }

    func applicationDidBecomeActive(_ notification: Notification) { updatePermissionDisplay() }

    private func updatePermissionDisplay() {
        let permissions = PermissionStatus.current()
        accessibilityItem?.title = "辅助功能：\(permissions.accessibility ? "已生效" : "未生效") · 打开设置…"
        inputMonitoringItem?.title = "输入监控：\(permissions.inputMonitoring ? "已生效" : "未生效") · 打开设置…"
        let state: String
        switch monitoringState {
        case .paused: state = "paused"
        case .starting: state = "starting"
        case .active: state = "active"
        }
        var details = monitor?.diagnosticSnapshot ?? [:]
        details.merge(coordinator.diagnosticSnapshot) { _, new in new }
        details["frontmost_is_uu"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.uuRemoteBundleIdentifier
        GUIRuntimeStatus.write(permissions: permissions, state: state, message: statusText, details: details)
    }

    @objc private func toggleLegacyHold() {
        pauseMonitoring(status: "已暂停 · 模式已切换，请重新启用", isError: false)
        let enabled = !UserDefaults.standard.bool(forKey: "legacyHoldToTalk")
        UserDefaults.standard.set(enabled, forKey: "legacyHoldToTalk")
        monitor?.voiceHoldEnabled = enabled
        rebuildMenu()
    }

    private func handleHeadsetRequest(_ request: ComposerOpenRequest, reply: @escaping (String) -> Void) {
        guard monitoringState == .active, let monitor else { reply("paused"); return }
        guard !IsSecureEventInputEnabled(), PermissionStatus.current().ready else { reply("blocked"); return }
        guard let target = currentUURemoteTarget(), target.processIdentifier == request.targetPID else { reply("focusChanged"); return }
        guard monitor.isGestureIdle, coordinator.canRequestComposer else { reply("busy"); return }
        guard target.captureFocusedWindow() else { reply("unavailable"); return }
        guard request.isFresh(), currentUURemoteTarget()?.processIdentifier == request.targetPID,
              !IsSecureEventInputEnabled() else { reply("focusChanged"); return }
        let restoring = coordinator.state == .listening || coordinator.state == .failed
        // Disable interception BEFORE activating the local panel. Its next Fn
        // belongs to Doubao even if the foreground polling tick has not run.
        monitor.suspendEligibilityForComposer()
        guard coordinator.begin(target: target, mode: .tapToCompose, activationAllowed: {
            request.isFresh() && self.monitoringState == .active && !IsSecureEventInputEnabled() &&
            self.currentUURemoteTarget()?.processIdentifier == request.targetPID
        }) else { reply("busy"); return }
        confirmComposerReady(generation: startGeneration, deadline: ProcessInfo.processInfo.systemUptime + 0.35,
                             success: restoring ? "restored" : "opened", reply: reply)
    }

    private func confirmComposerReady(generation: UInt64, deadline: TimeInterval, success: String,
                                      reply: @escaping (String) -> Void) {
        guard monitoringState == .active, startGeneration == generation else { reply("paused"); return }
        if coordinator.isLocalComposerReady { reply(success); return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front == Self.uuRemoteBundleIdentifier || front == Bundle.main.bundleIdentifier else { reply("focusChanged"); return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { reply("unavailable"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { reply("unavailable"); return }
            self.confirmComposerReady(generation: generation, deadline: deadline, success: success, reply: reply)
        }
    }

    @objc private func openAccessibilitySettings() {
        pauseMonitoring(status: "已暂停 · 辅助功能授权后请退出并重新打开本应用", isError: false)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openSystemSettings(anchor: "Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettings() {
        pauseMonitoring(status: "已暂停 · 输入监控授权后请退出并重新打开本应用", isError: false)
        _ = CGRequestListenEventAccess()
        openSystemSettings(anchor: "Privacy_ListenEvent")
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

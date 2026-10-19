import AppKit

final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case listening
        case finalizing
        case delivering
        case failed
    }

    var onStatusChange: ((String, Bool) -> Void)?

    private let panel = ComposerPanelController()
    private let delivery = UURemoteDelivery()
    private(set) var state: State = .idle
    private var target: UURemoteTarget?
    private var deliveryAwaitingCleanup = false

    var canBegin: Bool {
        (state == .idle || state == .failed) && !deliveryAwaitingCleanup
    }

    var isLocalComposerReady: Bool {
        state == .listening && panel.isReadyForLocalDictation
    }

    init() {
        panel.onCommit = { [weak self] text in self?.send(text: text) }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onTranscriptTimeout = { [weak self] in self?.handleTranscriptTimeout() }
    }

    func begin(target: UURemoteTarget, mode: ComposerEntryMode = .holdToTalk) {
        if state == .listening, mode == .tapToCompose, self.target === target {
            panel.switchToCompose()
            onStatusChange?("发送框已打开 · 输入后回车发送，Esc 取消", false)
            return
        }
        guard (state == .idle || state == .failed), !deliveryAwaitingCleanup else {
            onStatusChange?("正在完成上一轮发送，请稍候…", false)
            return
        }
        self.target = target
        state = .listening
        panel.begin(targetDescription: "发送到远端 Mac · UU 远控", mode: mode)
        onStatusChange?(mode == .tapToCompose
            ? "发送框已打开 · 输入后回车发送，Esc 取消"
            : "正在听写…松开 \(FnKeyPolicy.title) 后提交", false)
    }

    func fnReleased() {
        guard state == .listening else { return }
        state = .finalizing
        panel.waitForFinalTranscript()
        onStatusChange?("正在完成识别…", false)
    }

    func cancel(restoreFocus: Bool = true) {
        guard state != .idle, state != .delivering else { return }
        let target = self.target
        self.target = nil
        state = .idle
        panel.hide()
        if restoreFocus { target?.activateOriginalWindow() }
        onStatusChange?("就绪 · UU 中轻按开框，长按听写 · \(FnKeyPolicy.title)", false)
    }

    func prepareForTermination() {
        ClipboardKeyboardPaster.finishPendingEventsBeforeTermination()
        delivery.restoreClipboardForTermination()
    }

    private func send(text: String) {
        guard state == .listening || state == .finalizing || state == .failed,
              let target else { return }
        state = .delivering
        deliveryAwaitingCleanup = true
        panel.showSending()
        onStatusChange?("正在同步并自动粘贴…", false)

        delivery.deliver(
            text: text,
            to: target,
            panelWillHide: { [weak self] in self?.panel.hide() },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.target = nil
                    self.onStatusChange?("已发送粘贴指令，远端结果请核对", false)
                case .failure(let error):
                    self.deliveryAwaitingCleanup = false
                    self.state = .failed
                    let message = error.localizedDescription
                    self.panel.showError("\(message)。文字仍保留，可按回车重试")
                    self.onStatusChange?(message, true)
                }
            },
            cleanupCompletion: { [weak self] in
                guard let self else { return }
                self.deliveryAwaitingCleanup = false
                if self.state == .delivering {
                    self.state = .idle
                    self.onStatusChange?("就绪 · UU 中轻按开框，长按听写 · \(FnKeyPolicy.title)", false)
                }
            }
        )
    }

    private func handleTranscriptTimeout() {
        state = .failed
        if panel.currentText().isEmpty {
            panel.showError("没有识别到文字。按 Esc 返回 UU 后可重试")
            onStatusChange?("没有识别到文字，请重试", true)
        } else {
            panel.showError("豆包语音输入法尚未完成识别，确认文字后按回车发送，或按 Esc 取消")
            onStatusChange?("识别超时，等待手动确认", true)
        }
    }
}

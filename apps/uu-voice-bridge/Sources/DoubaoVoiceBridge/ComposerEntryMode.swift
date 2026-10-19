import Foundation

enum ComposerEntryMode {
    case holdToTalk
    case tapToCompose
}

enum FnReleaseAction {
    case openComposer
    case finishVoice
    case ignore
}

enum FnReleasePolicy {
    static func action(phase: HoldGesturePhase, hasSyntheticDown: Bool) -> FnReleaseAction {
        switch phase {
        case .pending: return .openComposer
        case .dictating: return hasSyntheticDown ? .finishVoice : .openComposer
        case .idle, .passthrough: return .ignore
        }
    }
}

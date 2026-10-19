import Foundation

enum HoldGesturePhase: Equatable {
    case idle
    case pending
    case dictating
    case passthrough
}

enum HoldGestureInput {
    case triggerDown(targetAvailable: Bool)
    case triggerUp
    case otherInput
    case thresholdReached
}

enum HoldGestureEffect: Equatable {
    case suppress
    case passThrough
    case scheduleThreshold
    case synthesizeTriggerDown
    case beginDictation
    case finishDictation
}

struct HoldGestureState {
    private(set) var phase: HoldGesturePhase = .idle

    mutating func reset() {
        phase = .idle
    }

    mutating func handle(_ input: HoldGestureInput) -> [HoldGestureEffect] {
        switch (phase, input) {
        case (.idle, .triggerDown(let targetAvailable)):
            guard targetAvailable else { return [.passThrough] }
            phase = .pending
            return [.suppress, .scheduleThreshold]

        case (.pending, .thresholdReached):
            phase = .dictating
            return [.beginDictation]

        case (.pending, .otherInput):
            phase = .passthrough
            return [.synthesizeTriggerDown, .passThrough]

        case (.pending, .triggerUp):
            phase = .idle
            return [.suppress]

        case (.dictating, .triggerUp):
            return [.suppress, .finishDictation]

        case (.passthrough, .triggerUp):
            phase = .idle
            return [.passThrough]

        case (.dictating, .otherInput), (.passthrough, .otherInput), (.idle, .otherInput):
            return [.passThrough]

        case (.idle, .triggerUp), (.idle, .thresholdReached),
             (.pending, .triggerDown), (.dictating, .triggerDown),
             (.dictating, .thresholdReached), (.passthrough, .triggerDown),
             (.passthrough, .thresholdReached):
            return phase == .dictating ? [.suppress] : [.passThrough]
        }
    }
}

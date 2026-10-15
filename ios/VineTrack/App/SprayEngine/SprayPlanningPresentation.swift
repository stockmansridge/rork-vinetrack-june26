import Foundation

/// Local intent and authoritative admission are distinct. A local draft is never labelled saved/ready.
nonisolated enum SprayPlanningPresentation: String, Sendable {
    case draft = "Local draft — not server saved"
    case saveRequested = "Save requested — confirmation pending"
    case saveConfirmed = "Save receipt confirmed"
    case savedUnbound = "Saved — work area not selected"
    case bindingRequested = "Route selected — binding confirmation pending"
    case bound = "Route binding confirmed"
    case ready = "Ready to Start"
    case active = "Active spray operation"
    case held = "Reconciliation required — original evidence retained"
    case repairRequired = "Receipt verified — local repair required"

    @MainActor static func state(_ attempt: SprayPlanningAttemptJournal.Attempt?) -> Self {
        guard let attempt else { return .draft }
        if [.held, .quarantined].contains(attempt.stage) { return .held }
        guard let receipt = attempt.receipt else { return attempt.request.kind == .bind ? .bindingRequested : .saveRequested }
        guard attempt.stage == .complete else { return .repairRequired }
        switch receipt.result.phase {
        case .savedUnbound: return .savedUnbound
        case .bound: return .bound
        case .ready: return receipt.result.routeRevisionId == nil ? .held : .ready
        case .active: return receipt.result.routeRevisionId == nil ? .held : .active
        }
    }
}

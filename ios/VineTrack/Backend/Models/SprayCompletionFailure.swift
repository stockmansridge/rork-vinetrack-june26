import Foundation

nonisolated enum SprayCompletionFailure: Error, LocalizedError {
    case unconfirmed
    var errorDescription: String? { "Completion was not confirmed. Sync and try again." }

    static func message(_ code: String) -> String {
        switch code {
        case "ACTIVE_TRIP": return "This spray still has an active Trip. End the Trip to complete the spray."
        case "UNLINKED_CONFIRMATION_REQUIRED": return "No linked Trip is available. Mark this spray complete now?"
        case "MANUAL_SPRAY_WORKFLOW_REQUIRED": return "Manual spray records must be managed through the manual spray workflow."
        default: return "Unable to complete this spray. Check your connection and permissions, sync and try again."
        }
    }
}

import Foundation

nonisolated enum ButtonConfigSyncError: LocalizedError {
    case reviewRequired
    case scopeChanged

    var errorDescription: String? {
        switch self {
        case .reviewRequired:
            "Button configuration changed or could not be verified. Your local edit is retained. Review the other device's configuration before retrying."
        case .scopeChanged:
            "Account or vineyard changed. The saved button edit remains pending."
        }
    }
}

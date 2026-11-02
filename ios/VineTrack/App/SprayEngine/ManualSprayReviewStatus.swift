import Foundation

/// A manual-spray review does not imply a completed application.
/// Locally queued evidence is not a verified backend acknowledgement.
nonisolated enum ManualSprayReviewStatus: Sendable, Hashable {
    case reviewOnly
    case locallySavedAwaitingServer
    case serverConfirmed

    var label: String {
        switch self {
        case .reviewOnly: "Review only — not yet saved"
        case .locallySavedAwaitingServer: "Saved on device — awaiting server confirmation"
        case .serverConfirmed: "Completed — server confirmed"
        }
    }
}

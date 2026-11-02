import Foundation

/// Manual-spray presentation evidence. A disappeared local operation does NOT
/// prove upload success: background replay can clear the queue before this
/// screen sees the server-readback record.
nonisolated enum ManualSprayReviewStatus: Sendable, Hashable {
    case reviewOnly
    case submitting
    case locallySavedAwaitingServer
    case verificationRequired
    case serverConfirmed

    static func resolve(serverConfirmed: Bool, hasRetainedSave: Bool,
                        hasSubmissionMarker: Bool, isSaving: Bool = false) -> Self {
        if serverConfirmed { return .serverConfirmed }
        if isSaving { return .submitting }
        if hasRetainedSave { return .locallySavedAwaitingServer }
        if hasSubmissionMarker { return .verificationRequired }
        return .reviewOnly
    }

    var canOfferSave: Bool { self == .reviewOnly }

    var label: String {
        switch self {
        case .reviewOnly: "Review only — not yet saved"
        case .submitting: "Saving original manual spray — do not close"
        case .locallySavedAwaitingServer: "Saved on device — awaiting server confirmation"
        case .verificationRequired: "Submission status unknown — verification required"
        case .serverConfirmed: "Completed — server confirmed"
        }
    }
}

/// Local-only, owner/vineyard-scoped submission intent. This is NOT a sync
/// receipt and MUST NOT mutate, replay or acknowledge retained operations.
/// Persisted intent prevents a stale draft reopening as a new application
/// after asynchronous background ACK removes the original queue item.
@MainActor
struct ManualSpraySubmissionGuard {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(ownerId: UUID, vineyardId: UUID) -> String {
        "vinetrack_manual_spray_submission_guard_v1_\(ownerId.uuidString.lowercased())_\(vineyardId.uuidString.lowercased())"
    }

    func submittedId(ownerId: UUID, vineyardId: UUID) -> UUID? {
        guard let raw = defaults.string(forKey: key(ownerId: ownerId, vineyardId: vineyardId)) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Fail closed if a different unsafely unresolved spray has already been
    /// submitted in this owner's single-draft vineyard workflow.
    @discardableResult
    func mark(ownerId: UUID, vineyardId: UUID, manualEntryId: UUID) -> Bool {
        if let existing = submittedId(ownerId: ownerId, vineyardId: vineyardId),
           existing != manualEntryId { return false }
        let name = key(ownerId: ownerId, vineyardId: vineyardId)
        defaults.set(manualEntryId.uuidString, forKey: name)
        return defaults.synchronize() && defaults.string(forKey: name) == manualEntryId.uuidString
    }

    func clearIfMatching(ownerId: UUID, vineyardId: UUID, manualEntryId: UUID) {
        guard submittedId(ownerId: ownerId, vineyardId: vineyardId) == manualEntryId else { return }
        defaults.removeObject(forKey: key(ownerId: ownerId, vineyardId: vineyardId))
    }
}

import Foundation

nonisolated enum AttachmentReferenceWriteError: LocalizedError, Sendable {
    case unresolved
    case recordDeleted
    case unexpectedRecord

    var errorDescription: String? {
        switch self {
        case .unresolved: "The photo reference could not be confirmed. It will be reconciled on the next sync."
        case .recordDeleted: "The record was deleted while its photo was saving."
        case .unexpectedRecord: "The server returned a different photo record."
        }
    }
}

nonisolated struct AttachmentReferenceConfirmation: Equatable, Sendable {
    let recordId: UUID
    let vineyardId: UUID
    let photoPath: String?
    let photoPaths: [String]?
}

protocol PinSyncRepositoryProtocol: Sendable {
    func fetchPins(vineyardId: UUID, since: Date?) async throws -> [BackendPin]
    func fetchAllPins(vineyardId: UUID) async throws -> [BackendPin]
    func upsertPin(_ pin: BackendPinUpsert) async throws
    func upsertPins(_ pins: [BackendPinUpsert]) async throws
    func updatePhotoPath(pinId: UUID, vineyardId: UUID, path: String?) async throws -> AttachmentReferenceConfirmation
    func softDeletePin(id: UUID) async throws
}

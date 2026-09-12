import Foundation
import Supabase

final class SupabasePinSyncRepository: PinSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchPins(vineyardId: UUID, since: Date?) async throws -> [BackendPin] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // Embed the structured row selection (sql/171 placement contract) so
        // row-scope pins carry their canonical location in the normal delta
        // sync — no per-pin round trips.
        let query = provider.client
            .from("pins")
            .select("*, pin_row_segments(row_number, segment_number)")
            .eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await query
                .gte("updated_at", value: ISO8601DateFormatter().string(from: since))
                .order("updated_at", ascending: true)
                .execute()
                .value
        } else {
            return try await query
                .order("updated_at", ascending: true)
                .execute()
                .value
        }
    }

    func fetchAllPins(vineyardId: UUID) async throws -> [BackendPin] {
        try await fetchPins(vineyardId: vineyardId, since: nil)
    }

    func upsertPin(_ pin: BackendPinUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("pins")
            .upsert(pin, onConflict: "id")
            .execute()
    }

    func upsertPins(_ pins: [BackendPinUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !pins.isEmpty else { return }
        try await provider.client
            .from("pins")
            .upsert(pins, onConflict: "id")
            .execute()
    }

    func upsertPinCaptureEvidence(_ evidence: PinCaptureEvidenceUpload) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("pin_capture_evidence")
            .upsert(evidence, onConflict: "pin_id,evidence_revision")
            .execute()
    }

    func updatePhotoPath(pinId: UUID, vineyardId: UUID, path: String?) async throws -> AttachmentReferenceConfirmation {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let updated: [BackendPin] = try await provider.client
            .from("pins")
            .update(PinPhotoPathPatch(photoPath: path, clientUpdatedAt: Date()))
            .eq("id", value: pinId.uuidString)
            .eq("vineyard_id", value: vineyardId.uuidString)
            .is("deleted_at", value: nil)
            .select()
            .execute()
            .value
        if let row = updated.first {
            guard updated.count == 1,
                  row.id == pinId,
                  row.vineyardId == vineyardId,
                  row.deletedAt == nil,
                  row.photoPath == path else { throw AttachmentReferenceWriteError.unexpectedRecord }
            return AttachmentReferenceConfirmation(
                recordId: row.id,
                vineyardId: row.vineyardId,
                photoPath: row.photoPath,
                photoPaths: nil
            )
        }
        let existing: [BackendPin] = try await provider.client
            .from("pins")
            .select()
            .eq("id", value: pinId.uuidString)
            .eq("vineyard_id", value: vineyardId.uuidString)
            .limit(1)
            .execute()
            .value
        if existing.first?.deletedAt != nil { throw AttachmentReferenceWriteError.recordDeleted }
        throw AttachmentReferenceWriteError.unresolved
    }

    func softDeletePin(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_pin", params: SoftDeletePinRequest(pinId: id))
            .execute()
    }
}

nonisolated private struct PinPhotoPathPatch: Encodable, Sendable {
    let photoPath: String?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case photoPath = "photo_path"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated private struct SoftDeletePinRequest: Encodable, Sendable {
    let pinId: UUID

    enum CodingKeys: String, CodingKey {
        case pinId = "p_pin_id"
    }
}

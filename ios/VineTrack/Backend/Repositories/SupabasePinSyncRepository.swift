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
        let outcome: String = try await provider.client
            .rpc("insert_pin_capture_evidence", params: PinEvidenceInsertRequest(payload: evidence))
            .execute()
            .value
        guard outcome == "inserted" || outcome == "identical" else {
            throw PinCaptureEvidenceDeliveryError.immutableConflict
        }
    }

    func confirmSavedPinLocation(_ operation: PendingPinLocationConfirmation) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let _: String = try await provider.client
            .rpc("confirm_saved_pin_location_v2", params: PinLocationConfirmationRequest(operation: operation))
            .execute()
            .value
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

nonisolated private struct PinLocationConfirmationRequest: Encodable, Sendable {
    let operation: PendingPinLocationConfirmation

    enum CodingKeys: String, CodingKey {
        case operationId = "p_operation_id", pinId = "p_pin_id", evidenceRevision = "p_evidence_revision"
        case expectedSyncVersion = "p_expected_sync_version", paddockId = "p_paddock_id", drivingRow = "p_driving_row"
        case pinRow = "p_pin_row", pinSide = "p_pin_side", snappedLatitude = "p_snapped_latitude"
        case snappedLongitude = "p_snapped_longitude", alongRowDistanceM = "p_along_row_distance_m"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operation.id, forKey: .operationId); try c.encode(operation.pinId, forKey: .pinId)
        try c.encode(operation.evidenceRevision, forKey: .evidenceRevision); try c.encodeIfPresent(operation.expectedSyncVersion, forKey: .expectedSyncVersion)
        try c.encode(operation.paddockId, forKey: .paddockId); try c.encode(operation.drivingRow, forKey: .drivingRow)
        try c.encode(operation.pinRow, forKey: .pinRow); try c.encode(operation.pinSide, forKey: .pinSide)
        try c.encode(operation.snappedLatitude, forKey: .snappedLatitude); try c.encode(operation.snappedLongitude, forKey: .snappedLongitude)
        try c.encode(operation.alongRowDistanceM, forKey: .alongRowDistanceM)
    }
}

nonisolated private struct PinEvidenceInsertRequest: Encodable, Sendable {
    let payload: PinCaptureEvidenceUpload
    enum CodingKeys: String, CodingKey { case payload = "p_payload" }
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

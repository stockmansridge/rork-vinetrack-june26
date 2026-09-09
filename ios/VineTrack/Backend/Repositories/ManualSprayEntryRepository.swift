import Foundation
import Supabase

protocol ManualSprayEntryRepositoryProtocol: Sendable {
    func save(operationId: UUID, payload: ManualSprayPayload, expectedVersion: Int?) async throws -> ManualSpraySaveResponse
    func delete(operationId: UUID, payload: ManualSprayPayload) async throws
}

final class ManualSprayEntryRepository: ManualSprayEntryRepositoryProtocol, @unchecked Sendable {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func save(operationId: UUID, payload: ManualSprayPayload, expectedVersion: Int?) async throws -> ManualSpraySaveResponse {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let response: ManualSpraySaveResponse = try await provider.client
            .rpc("save_manual_spray_v1", params: SaveRequest(operationId: operationId, payload: payload, expectedVersion: expectedVersion))
            .execute()
            .value
        return response
    }

    func delete(operationId: UUID, payload: ManualSprayPayload) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("delete_manual_spray_v1", params: DeleteRequest(operationId: operationId, payload: payload))
            .execute()
    }
}

nonisolated private struct SaveRequest: Encodable, Sendable {
    let operationId: UUID
    let payload: ManualSprayPayload
    let expectedVersion: Int?

    enum CodingKeys: String, CodingKey {
        case operationId = "p_operation_id"
        case payload = "p_payload"
        case expectedVersion = "p_expected_version"
    }
}

nonisolated private struct DeleteRequest: Encodable, Sendable {
    let operationId: UUID
    let vineyardId: UUID
    let manualEntryId: UUID
    let sprayRecordId: UUID
    let tripId: UUID

    init(operationId: UUID, payload: ManualSprayPayload) {
        self.operationId = operationId
        vineyardId = payload.vineyardId
        manualEntryId = payload.manualEntryId
        sprayRecordId = payload.sprayRecordId
        tripId = payload.tripId
    }

    enum CodingKeys: String, CodingKey {
        case operationId = "p_operation_id"
        case vineyardId = "p_vineyard_id"
        case manualEntryId = "p_manual_entry_id"
        case sprayRecordId = "p_spray_record_id"
        case tripId = "p_trip_id"
    }
}

import Foundation
import Supabase

/// Server-authoritative access to the sql/170 unified pin composer RPCs:
/// the vineyard-shared custom pin type catalogue, the simplified Custom pin
/// create, and the generic row-segment persistence used by Repair/Growth
/// pins saved with a ROW location. Mirrors `CustomPinTypeRepository.kt`.
final class CustomPinTypeRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// Idempotent create keyed by the client-generated id; a duplicate active
    /// name (trimmed, case-insensitive) returns the existing shared entry.
    func createType(_ params: CustomPinTypeCreateParams) async throws -> CustomPinTypeRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("create_vineyard_custom_pin_type", params: params)
            .execute()
            .value
    }

    /// Active items by default (what the composer offers).
    func listTypes(vineyardId: UUID, includeInactive: Bool = false) async throws -> [CustomPinTypeRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "list_vineyard_custom_pin_types",
                params: ListTypesParams(vineyardId: vineyardId, includeInactive: includeInactive)
            )
            .execute()
            .value
    }

    /// Deactivating hides an item from new selection; historical pins keep
    /// their meaning.
    func setTypeActive(id: UUID, isActive: Bool) async throws -> CustomPinTypeRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "set_vineyard_custom_pin_type_active",
                params: SetActiveParams(id: id, isActive: isActive)
            )
            .execute()
            .value
    }

    /// Simplified Custom-tab save — returns the canonical manual-issue JSON.
    func createCustomPin(_ params: CustomPinCreateParams) async throws -> ManualIssueRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("create_custom_pin", params: params)
            .execute()
            .value
    }

    /// Persist the structured ROW selection for a Repair/Growth pin created
    /// through the existing direct pin write path. Raises PIN_NOT_FOUND while
    /// the parent pin hasn't reached the server yet — callers treat that as
    /// retryable.
    func setPinRowSegments(pinId: UUID, segments: [ManualIssueSegment]) async throws -> [ManualIssueSegment] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "set_pin_row_segments",
                params: SegmentsParams(pinId: pinId, segments: segments)
            )
            .execute()
            .value
    }
}

nonisolated private struct ListTypesParams: Encodable, Sendable {
    let vineyardId: UUID
    let includeInactive: Bool

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case includeInactive = "p_include_inactive"
    }
}

nonisolated private struct SetActiveParams: Encodable, Sendable {
    let id: UUID
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case isActive = "p_is_active"
    }
}

nonisolated private struct SegmentsParams: Encodable, Sendable {
    let pinId: UUID
    let segments: [ManualIssueSegment]

    enum CodingKeys: String, CodingKey {
        case pinId = "p_pin_id"
        case segments = "p_segments"
    }
}

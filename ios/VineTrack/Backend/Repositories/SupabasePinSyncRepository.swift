import Foundation
import Supabase

final class SupabasePinSyncRepository: PinSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchPins(vineyardId: UUID, since: Date?) async throws -> [BackendPin] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("pins")
            .select()
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

    func softDeletePin(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_pin", params: SoftDeletePinRequest(pinId: id))
            .execute()
    }
}

nonisolated private struct SoftDeletePinRequest: Encodable, Sendable {
    let pinId: UUID

    enum CodingKeys: String, CodingKey {
        case pinId = "p_pin_id"
    }
}

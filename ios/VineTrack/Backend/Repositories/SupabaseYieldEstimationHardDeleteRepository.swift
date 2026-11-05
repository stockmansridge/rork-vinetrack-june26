import Foundation
import Supabase

/// Issue #54. Physical removal is server-authorised. No local deletion
/// or success banner is permitted until both RPC and receipt readback succeed.
@MainActor
final class SupabaseYieldEstimationHardDeleteRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private nonisolated struct DeleteArgs: Encodable, Sendable {
        let p_id: UUID
        let p_vineyard_id: UUID
        let p_expected_completed: Bool
    }
    private nonisolated struct DeletionReceipt: Decodable, Sendable {
        let session_id: UUID
        let vineyard_id: UUID
        let was_completed: Bool
    }

    func hardDelete(_ session: YieldEstimationSession) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let acknowledged: Bool = try await provider.client.rpc(
            "hard_delete_yield_estimation_session",
            params: DeleteArgs(
                p_id: session.id,
                p_vineyard_id: session.vineyardId,
                p_expected_completed: session.isCompleted
            )
        ).execute().value
        guard acknowledged else { throw CocoaError(.fileWriteNoPermission) }
        let rows: [DeletionReceipt] = try await provider.client
            .from("yield_estimation_session_deletion_receipts")
            .select("session_id,vineyard_id,was_completed")
            .eq("session_id", value: session.id.uuidString)
            .eq("vineyard_id", value: session.vineyardId.uuidString)
            .execute().value
        guard rows.count == 1, rows[0].session_id == session.id,
              rows[0].vineyard_id == session.vineyardId else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func deletedIds(vineyardId: UUID) async throws -> Set<UUID> {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [DeletionReceipt] = try await provider.client
            .from("yield_estimation_session_deletion_receipts")
            .select("session_id,vineyard_id,was_completed")
            .eq("vineyard_id", value: vineyardId.uuidString)
            .execute().value
        return Set(rows.filter { $0.vineyard_id == vineyardId }.map(\.session_id))
    }
}

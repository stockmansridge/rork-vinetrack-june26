import Foundation
import Supabase

/// Reads the caller's VineTrack entitlement from the draft Supabase RPC
/// `get_my_vinetrack_access()`.
///
/// ⚠️ DRAFT / ADDITIVE ONLY. This repository does not change app access today;
/// it only surfaces the backend entitlement so `VineTrackAccessResolver` can
/// prepare for the July 2026 pricing model. The RPC is SECURITY DEFINER and
/// only ever reports the authenticated caller's own access.
nonisolated struct VineTrackAccessRepository: Sendable {
    static let rpcName = "get_my_vinetrack_access"

    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// Fetch the current user's backend access, or `nil` when the RPC returns
    /// no row. Throws on configuration/auth/transport failure so the caller can
    /// fall back to RevenueCat without treating "no row" as an error.
    func fetchMyAccess() async throws -> BackendVineTrackAccess? {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }

        // Require an authenticated Supabase user; the RPC raises 42501 without
        // one, but failing fast avoids a needless round trip.
        let session = try await provider.client.auth.session
        _ = session.user.id

        // The RPC `returns table (...)`, so decode an array and take the first.
        let rows: [BackendVineTrackAccess] = try await provider.client
            .rpc(Self.rpcName)
            .execute()
            .value

        return rows.first
    }
}

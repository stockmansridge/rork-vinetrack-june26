import Foundation
import Supabase

/// Reads the caller's VineTrack entitlement from the Supabase RPC
/// `get_my_vinetrack_access()` (hardened in sql/132) and reports
/// entitlement mismatch diagnostics.
///
/// Phase 2A: this is the shared access source enforced by `EntitlementGate`
/// when the rollout flag covers the caller. The RPC is SECURITY DEFINER and
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

    /// Report a "RevenueCat grants access but Supabase does not" diagnostic
    /// (sql/132 `report_entitlement_mismatch`; server-throttled per platform
    /// per 24 h). Never sends receipts or provider payloads.
    func reportMismatch(platform: String, appVersion: String?) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        struct Params: Encodable {
            let p_platform: String
            let p_app_version: String?
        }
        _ = try await provider.client
            .rpc("report_entitlement_mismatch",
                 params: Params(p_platform: platform, p_app_version: appVersion))
            .execute()
    }
}

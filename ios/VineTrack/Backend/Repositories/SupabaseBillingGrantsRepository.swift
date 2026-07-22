import Foundation
import Supabase

// MARK: - Model

/// One manual / internal unlimited-access grant, as returned by
/// `admin_list_manual_unlimited_grants()`. Reporting + management only; this is
/// never used for client-side entitlement enforcement.
nonisolated struct ManualUnlimitedGrant: Identifiable, Sendable, Hashable {
    let subscriptionId: UUID
    let ownerUserId: UUID
    let ownerEmail: String?
    let ownerFullName: String?
    let primaryVineyardId: UUID?
    let vineyardName: String?
    let status: String
    let unlimitedLicences: Bool
    let manualGrantReason: String?
    let manualGrantExpiresAt: Date?
    let manualGrantRevokedAt: Date?
    let activeLicences: Int
    let isActive: Bool
    let createdAt: Date?
    let updatedAt: Date?

    var id: UUID { subscriptionId }

    /// Best owner label: full name, else email, else short id.
    var ownerDisplay: String {
        if let n = ownerFullName, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        if let e = ownerEmail, !e.isEmpty { return e }
        return String(ownerUserId.uuidString.prefix(8))
    }

    /// True when the grant has an expiry that has already passed.
    var isExpired: Bool {
        guard let expiry = manualGrantExpiresAt else { return false }
        return expiry <= Date()
    }
}

// MARK: - DTOs

nonisolated private struct ManualUnlimitedGrantDTO: Decodable, Sendable {
    let subscriptionId: UUID
    let ownerUserId: UUID
    let ownerEmail: String?
    let ownerFullName: String?
    let primaryVineyardId: UUID?
    let vineyardName: String?
    let status: String?
    let unlimitedLicences: Bool?
    let manualGrantReason: String?
    let manualGrantExpiresAt: Date?
    let manualGrantRevokedAt: Date?
    let activeLicences: Int?
    let isActive: Bool?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case subscriptionId       = "subscription_id"
        case ownerUserId          = "owner_user_id"
        case ownerEmail           = "owner_email"
        case ownerFullName        = "owner_full_name"
        case primaryVineyardId    = "primary_vineyard_id"
        case vineyardName         = "vineyard_name"
        case status
        case unlimitedLicences    = "unlimited_licences"
        case manualGrantReason    = "manual_grant_reason"
        case manualGrantExpiresAt = "manual_grant_expires_at"
        case manualGrantRevokedAt = "manual_grant_revoked_at"
        case activeLicences       = "active_licences"
        case isActive             = "is_active"
        case createdAt            = "created_at"
        case updatedAt            = "updated_at"
    }

    func toModel() -> ManualUnlimitedGrant {
        ManualUnlimitedGrant(
            subscriptionId: subscriptionId,
            ownerUserId: ownerUserId,
            ownerEmail: ownerEmail,
            ownerFullName: ownerFullName,
            primaryVineyardId: primaryVineyardId,
            vineyardName: vineyardName,
            status: status ?? "manual",
            unlimitedLicences: unlimitedLicences ?? false,
            manualGrantReason: manualGrantReason,
            manualGrantExpiresAt: manualGrantExpiresAt,
            manualGrantRevokedAt: manualGrantRevokedAt,
            activeLicences: activeLicences ?? 0,
            isActive: isActive ?? false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

nonisolated private struct GrantParams: Encodable, Sendable {
    let ownerUserId: UUID
    let vineyardId: UUID?
    let reason: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case ownerUserId = "p_owner_user_id"
        case vineyardId  = "p_vineyard_id"
        case reason      = "p_reason"
        case expiresAt   = "p_expires_at"
    }
}

nonisolated private struct RevokeParams: Encodable, Sendable {
    let subscriptionId: UUID
    let revokeLicences: Bool

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "p_subscription_id"
        case revokeLicences = "p_revoke_licences"
    }
}

// MARK: - Repository

/// System-admin-only access to manual / internal unlimited licensing grants.
/// All RPCs enforce `public.is_system_admin()` server-side; this repository is
/// a thin transport layer. No Stripe / Apple / RevenueCat involvement.
final class SupabaseBillingGrantsRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// All current and historical manual unlimited grants.
    func listGrants() async throws -> [ManualUnlimitedGrant] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [ManualUnlimitedGrantDTO] = try await provider.client
            .rpc("admin_list_manual_unlimited_grants")
            .execute()
            .value
        return rows.map { $0.toModel() }
    }

    /// Grant or reactivate unlimited access for an owner. Returns the
    /// subscription id created/updated.
    @discardableResult
    func grantUnlimited(
        ownerUserId: UUID,
        vineyardId: UUID?,
        reason: String?,
        expiresAt: Date?
    ) async throws -> UUID {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: UUID = try await provider.client
            .rpc("admin_grant_unlimited_access", params: GrantParams(
                ownerUserId: ownerUserId,
                vineyardId: vineyardId,
                reason: (trimmedReason?.isEmpty == false) ? trimmedReason : nil,
                expiresAt: expiresAt
            ))
            .execute()
            .value
        return id
    }

    /// Revoke an existing grant by subscription id.
    @discardableResult
    func revokeUnlimited(subscriptionId: UUID, revokeLicences: Bool = true) async throws -> UUID {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let id: UUID = try await provider.client
            .rpc("admin_revoke_unlimited_access", params: RevokeParams(
                subscriptionId: subscriptionId,
                revokeLicences: revokeLicences
            ))
            .execute()
            .value
        return id
    }
}

import Foundation
import Supabase

// MARK: - Models

/// One vineyard row from `get_my_vineyard_access_matrix()` (sql/156).
nonisolated struct VineyardAccessEntry: Decodable, Sendable, Equatable {
    let vineyardId: UUID
    let vineyardName: String?
    let membershipRole: String?
    let hasVineyardAccess: Bool
    let vineyardAccessReason: String?
    let vineyardAccessSource: String?
    let planCode: String?
    let subscriptionStatus: String?
    let expiresAt: Date?
    let isTrial: Bool?
    let isVineyardWide: Bool?
    let isBillingOwner: Bool?
    let canManageBilling: Bool?
    let requiresBillingAttention: Bool?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case vineyardName = "vineyard_name"
        case membershipRole = "membership_role"
        case hasVineyardAccess = "has_vineyard_access"
        case vineyardAccessReason = "vineyard_access_reason"
        case vineyardAccessSource = "vineyard_access_source"
        case planCode = "plan_code"
        case subscriptionStatus = "subscription_status"
        case expiresAt = "expires_at"
        case isTrial = "is_trial"
        case isVineyardWide = "is_vineyard_wide"
        case isBillingOwner = "is_billing_owner"
        case canManageBilling = "can_manage_billing"
        case requiresBillingAttention = "requires_billing_attention"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        vineyardName = try? c.decodeIfPresent(String.self, forKey: .vineyardName)
        membershipRole = try? c.decodeIfPresent(String.self, forKey: .membershipRole)
        hasVineyardAccess = (try? c.decodeIfPresent(Bool.self, forKey: .hasVineyardAccess)) ?? false
        vineyardAccessReason = try? c.decodeIfPresent(String.self, forKey: .vineyardAccessReason)
        vineyardAccessSource = try? c.decodeIfPresent(String.self, forKey: .vineyardAccessSource)
        planCode = try? c.decodeIfPresent(String.self, forKey: .planCode)
        subscriptionStatus = try? c.decodeIfPresent(String.self, forKey: .subscriptionStatus)
        expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
        isTrial = try? c.decodeIfPresent(Bool.self, forKey: .isTrial)
        isVineyardWide = try? c.decodeIfPresent(Bool.self, forKey: .isVineyardWide)
        isBillingOwner = try? c.decodeIfPresent(Bool.self, forKey: .isBillingOwner)
        canManageBilling = try? c.decodeIfPresent(Bool.self, forKey: .canManageBilling)
        requiresBillingAttention = try? c.decodeIfPresent(Bool.self, forKey: .requiresBillingAttention)
    }
}

/// Account summary from `get_my_vineyard_access_matrix()`.
nonisolated struct VineyardAccessAccountSummary: Decodable, Sendable, Equatable {
    /// full | vineyard_only | restricted | no_vineyards
    let accountAccessState: String?
    let hasAccountEntitlement: Bool?
    let accountReasonCode: String?
    let hasAnyAccessibleVineyard: Bool?
    let accessibleVineyardCount: Int?
    let vineyardCount: Int?
    let pendingInvitationCount: Int?
    let canCreateVineyard: Bool?

    enum CodingKeys: String, CodingKey {
        case accountAccessState = "account_access_state"
        case hasAccountEntitlement = "has_account_entitlement"
        case accountReasonCode = "account_reason_code"
        case hasAnyAccessibleVineyard = "has_any_accessible_vineyard"
        case accessibleVineyardCount = "accessible_vineyard_count"
        case vineyardCount = "vineyard_count"
        case pendingInvitationCount = "pending_invitation_count"
        case canCreateVineyard = "can_create_vineyard"
    }
}

/// Server-authoritative per-vineyard access matrix (sql/156). One call, one
/// decision source — clients never re-derive entitlement precedence locally.
nonisolated struct VineyardAccessMatrix: Decodable, Sendable, Equatable {
    let account: VineyardAccessAccountSummary?
    let vineyards: [VineyardAccessEntry]

    enum CodingKeys: String, CodingKey {
        case account
        case vineyards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try? c.decodeIfPresent(VineyardAccessAccountSummary.self, forKey: .account)
        vineyards = (try? c.decodeIfPresent([VineyardAccessEntry].self, forKey: .vineyards)) ?? []
    }

    init(account: VineyardAccessAccountSummary?, vineyards: [VineyardAccessEntry]) {
        self.account = account
        self.vineyards = vineyards
    }

    func entry(for vineyardId: UUID) -> VineyardAccessEntry? {
        vineyards.first { $0.vineyardId == vineyardId }
    }

    var accessibleVineyardIds: [UUID] {
        vineyards.filter { $0.hasVineyardAccess }.map { $0.vineyardId }
    }

    var hasAnyAccessibleVineyard: Bool {
        account?.hasAnyAccessibleVineyard ?? !accessibleVineyardIds.isEmpty
    }
}

// MARK: - Repository

/// Fetches the per-vineyard access matrix. SECURITY DEFINER RPC — only ever
/// reports the authenticated caller's own memberships.
nonisolated struct VineyardAccessMatrixRepository: Sendable {
    static let rpcName = "get_my_vineyard_access_matrix"

    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchMatrix() async throws -> VineyardAccessMatrix {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let matrix: VineyardAccessMatrix = try await provider.client
            .rpc(Self.rpcName)
            .execute()
            .value
        return matrix
    }
}

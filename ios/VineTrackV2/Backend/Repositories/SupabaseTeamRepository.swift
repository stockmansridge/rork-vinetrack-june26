import Foundation
import Supabase

final class SupabaseTeamRepository: TeamRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func listMembers(vineyardId: UUID) async throws -> [BackendVineyardMember] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // Use SECURITY DEFINER RPC so we can resolve email / full_name / avatar
        // for fellow vineyard members without weakening profiles RLS.
        // See sql/022_vineyard_team_members_rpc.sql + sql/082_team_members_with_operator_category.sql.
        return try await provider.client
            .rpc("get_vineyard_team_members", params: ListTeamMembersRequest(vineyardId: vineyardId))
            .execute()
            .value
    }

    func updateMemberRole(vineyardId: UUID, userId: UUID, role: BackendRole) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // Shared SQL 79 RPC. Validates caller is owner/manager, blocks owner
        // role assignment (use transfer_vineyard_ownership), runs as definer.
        try await provider.client
            .rpc("update_member_role", params: UpdateMemberRoleRequest(
                vineyardId: vineyardId,
                userId: userId,
                role: role.rawValue
            ))
            .execute()
    }

    func updateMemberOperatorCategory(vineyardId: UUID, userId: UUID, operatorCategoryId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // Shared SQL 106 RPC. Owner/manager only; validates the worker type
        // belongs to the vineyard and is not soft-deleted.
        try await provider.client
            .rpc("update_member_worker_type", params: UpdateMemberOperatorCategoryRequest(
                vineyardId: vineyardId,
                userId: userId,
                operatorCategoryId: operatorCategoryId
            ))
            .execute()
    }

    func removeMember(vineyardId: UUID, userId: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // Shared SQL 79 RPC. Honors prevent_last_owner_loss trigger and blocks
        // owner removal (use transfer_vineyard_ownership first).
        try await provider.client
            .rpc("remove_member", params: RemoveMemberRequest(
                vineyardId: vineyardId,
                userId: userId
            ))
            .execute()
    }

    func inviteMember(vineyardId: UUID, email: String, role: BackendRole) async throws -> BackendInvitation {
        // Back-compat: call through to the operator-category-aware overload
        // with no default category.
        try await inviteMember(
            vineyardId: vineyardId,
            email: email,
            role: role,
            operatorCategoryId: nil,
            expiresAt: nil
        )
    }

    func inviteMember(
        vineyardId: UUID,
        email: String,
        role: BackendRole,
        operatorCategoryId: UUID?,
        expiresAt: Date?
    ) async throws -> BackendInvitation {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Shared SQL 79 RPC. Cancels any existing pending row for the same
        // vineyard/email, validates operator category belongs to the vineyard,
        // and blocks inviting 'owner'.
        let rows: [BackendInvitation] = try await provider.client
            .rpc("create_invitation", params: CreateInvitationRequest(
                vineyardId: vineyardId,
                email: normalizedEmail,
                role: role.rawValue,
                operatorCategoryId: operatorCategoryId,
                expiresAt: expiresAt
            ))
            .execute()
            .value
        guard let invitation = rows.first else {
            throw BackendRepositoryError.missingAuthenticatedUser
        }
        return invitation
    }

    func listPendingInvitations() async throws -> [BackendInvitation] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("invitations")
            .select("*, vineyards(name)")
            .eq("status", value: "pending")
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func acceptInvitation(invitationId: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await ensureCurrentUserProfileExists()
        try await provider.client
            .rpc("accept_invitation", params: AcceptInvitationRequest(invitationId: invitationId))
            .execute()
    }

    private func ensureCurrentUserProfileExists() async throws {
        guard let user = provider.client.auth.currentUser else { throw BackendRepositoryError.missingAuthenticatedUser }
        try await provider.client
            .from("profiles")
            .upsert(InvitationAcceptanceProfileUpsert(id: user.id, email: user.email ?? ""))
            .execute()
    }

    func declineInvitation(invitationId: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("decline_invitation", params: DeclineInvitationRequest(invitationId: invitationId))
            .execute()
    }

    func transferOwnership(vineyardId: UUID, newOwnerId: UUID, removeOldOwner: Bool) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("transfer_vineyard_ownership", params: TransferOwnershipRequest(
                vineyardId: vineyardId,
                newOwnerId: newOwnerId,
                removeOldOwner: removeOldOwner
            ))
            .execute()
    }
}

nonisolated private struct ListTeamMembersRequest: Encodable, Sendable {
    let vineyardId: UUID

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
    }
}

nonisolated private struct UpdateMemberRoleRequest: Encodable, Sendable {
    let vineyardId: UUID
    let userId: UUID
    let role: String

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case userId = "p_user_id"
        case role = "p_role"
    }
}

nonisolated private struct UpdateMemberOperatorCategoryRequest: Encodable, Sendable {
    let vineyardId: UUID
    let userId: UUID
    let operatorCategoryId: UUID?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case userId = "p_user_id"
        case operatorCategoryId = "p_worker_type_id"
    }

    // Explicit encode so a nil worker type is sent as JSON `null` (PostgREST
    // treats it as "argument present, value SQL NULL") and clears the
    // assignment. Mirrors the fix applied to grape-variety / vineyard-
    // location RPCs.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(userId, forKey: .userId)
        try c.encode(operatorCategoryId, forKey: .operatorCategoryId)
    }
}

nonisolated private struct RemoveMemberRequest: Encodable, Sendable {
    let vineyardId: UUID
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case userId = "p_user_id"
    }
}

nonisolated private struct CreateInvitationRequest: Encodable, Sendable {
    let vineyardId: UUID
    let email: String
    let role: String
    let operatorCategoryId: UUID?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case email = "p_email"
        case role = "p_role"
        case operatorCategoryId = "p_operator_category_id"
        case expiresAt = "p_expires_at"
    }

    // Explicit encode so optional params are sent as JSON `null` rather than
    // omitted — PostgREST needs all five arguments to resolve the overload.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(email, forKey: .email)
        try c.encode(role, forKey: .role)
        try c.encode(operatorCategoryId, forKey: .operatorCategoryId)
        try c.encode(expiresAt, forKey: .expiresAt)
    }
}

nonisolated private struct TransferOwnershipRequest: Encodable, Sendable {
    let vineyardId: UUID
    let newOwnerId: UUID
    let removeOldOwner: Bool

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case newOwnerId = "p_new_owner_id"
        case removeOldOwner = "p_remove_old_owner"
    }
}

nonisolated private struct DeclineInvitationRequest: Encodable, Sendable {
    let invitationId: UUID

    enum CodingKeys: String, CodingKey {
        case invitationId = "p_invitation_id"
    }
}

nonisolated private struct InvitationAcceptanceProfileUpsert: Encodable, Sendable {
    let id: UUID
    let email: String
}

nonisolated private struct AcceptInvitationRequest: Encodable, Sendable {
    let invitationId: UUID

    enum CodingKeys: String, CodingKey {
        case invitationId = "p_invitation_id"
    }
}

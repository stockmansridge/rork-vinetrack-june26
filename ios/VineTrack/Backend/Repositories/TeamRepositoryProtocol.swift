import Foundation

protocol TeamRepositoryProtocol: Sendable {
    func listMembers(vineyardId: UUID) async throws -> [BackendVineyardMember]
    func updateMemberRole(vineyardId: UUID, userId: UUID, role: BackendRole) async throws
    /// Owner/manager-only: assigns or clears a member's default operator category.
    /// Used by trip costing as a fallback when `trips.operator_category_id` is null.
    func updateMemberOperatorCategory(vineyardId: UUID, userId: UUID, operatorCategoryId: UUID?) async throws
    func removeMember(vineyardId: UUID, userId: UUID) async throws
    func inviteMember(vineyardId: UUID, email: String, role: BackendRole) async throws -> BackendInvitation
    /// Owner/manager-only invite with an optional default operator category and
    /// optional expiry. Mirrors the shared SQL 79 `create_invitation` RPC.
    func inviteMember(
        vineyardId: UUID,
        email: String,
        role: BackendRole,
        operatorCategoryId: UUID?,
        expiresAt: Date?
    ) async throws -> BackendInvitation
    func listPendingInvitations() async throws -> [BackendInvitation]
    func acceptInvitation(invitationId: UUID) async throws
    func declineInvitation(invitationId: UUID) async throws
    func transferOwnership(vineyardId: UUID, newOwnerId: UUID, removeOldOwner: Bool) async throws
}

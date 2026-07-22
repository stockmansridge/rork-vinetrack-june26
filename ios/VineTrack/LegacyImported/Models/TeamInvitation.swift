import Foundation

nonisolated struct TeamInvitation: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyard_id: String
    var vineyard_name: String?
    var email: String
    var role: String
    var invited_by: String?
    var invited_by_name: String?
    var status: String
    var created_at: String?

    init(
        id: UUID = UUID(),
        vineyard_id: String,
        vineyard_name: String? = nil,
        email: String,
        role: String = "Operator",
        invited_by: String? = nil,
        invited_by_name: String? = nil,
        status: String = "pending",
        created_at: String? = nil
    ) {
        self.id = id
        self.vineyard_id = vineyard_id
        self.vineyard_name = vineyard_name
        self.email = email
        self.role = role
        self.invited_by = invited_by
        self.invited_by_name = invited_by_name
        self.status = status
        self.created_at = created_at
    }
}

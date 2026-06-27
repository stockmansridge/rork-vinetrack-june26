import Foundation

nonisolated struct BackendVineyardMember: Identifiable, Codable, Sendable {
    let id: UUID?
    let vineyardId: UUID
    let userId: UUID
    let role: BackendRole
    let displayName: String?
    let joinedAt: Date?
    /// Default operator category assigned to this member. Used as a fallback
    /// for trip cost calculations when `trips.operator_category_id` is null.
    /// Synced as `vineyard_members.operator_category_id` (see
    /// `sql/057_trips_costing_links.sql`).
    let operatorCategoryId: UUID?

    // Profile-derived display data populated by the
    // `get_vineyard_team_members` RPC (sql/022 + sql/082). Optional so direct
    // table selects still decode cleanly.
    let email: String?
    let fullName: String?
    let avatarUrl: String?
    /// Resolved operator category name. NULL when no category is assigned or
    /// the category has been soft-deleted.
    let operatorCategoryName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case membershipId = "membership_id"
        case vineyardId = "vineyard_id"
        case userId = "user_id"
        case role
        case displayName = "display_name"
        case joinedAt = "joined_at"
        case operatorCategoryId = "operator_category_id"
        case email
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case operatorCategoryName = "operator_category_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // RPC returns `membership_id`; direct table selects return `id`.
        let directId = try c.decodeIfPresent(UUID.self, forKey: .id)
        let membershipId = try c.decodeIfPresent(UUID.self, forKey: .membershipId)
        self.id = directId ?? membershipId
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.userId = try c.decode(UUID.self, forKey: .userId)
        self.role = try c.decode(BackendRole.self, forKey: .role)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
        self.operatorCategoryId = try c.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
        self.fullName = try c.decodeIfPresent(String.self, forKey: .fullName)
        self.avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        self.operatorCategoryName = try c.decodeIfPresent(String.self, forKey: .operatorCategoryName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(userId, forKey: .userId)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(joinedAt, forKey: .joinedAt)
        try c.encodeIfPresent(operatorCategoryId, forKey: .operatorCategoryId)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(fullName, forKey: .fullName)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encodeIfPresent(operatorCategoryName, forKey: .operatorCategoryName)
    }

    init(
        id: UUID?,
        vineyardId: UUID,
        userId: UUID,
        role: BackendRole,
        displayName: String? = nil,
        joinedAt: Date? = nil,
        operatorCategoryId: UUID? = nil,
        email: String? = nil,
        fullName: String? = nil,
        avatarUrl: String? = nil,
        operatorCategoryName: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.userId = userId
        self.role = role
        self.displayName = displayName
        self.joinedAt = joinedAt
        self.operatorCategoryId = operatorCategoryId
        self.email = email
        self.fullName = fullName
        self.avatarUrl = avatarUrl
        self.operatorCategoryName = operatorCategoryName
    }
}

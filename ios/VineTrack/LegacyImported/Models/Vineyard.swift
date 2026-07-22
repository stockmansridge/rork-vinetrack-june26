import Foundation

nonisolated struct Vineyard: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var users: [VineyardUser]
    let createdAt: Date
    var logoData: Data?
    var country: String
    /// Storage path (within the `vineyard-logos` bucket) for the synced logo.
    /// `nil` means no synced logo. Local-only logos can also exist (e.g. while
    /// an upload is in flight) — those have `logoData != nil` and `logoPath == nil`.
    var logoPath: String?
    /// Timestamp the synced logo was last updated, as reported by the backend.
    /// Used to decide when to refetch the cached `logoData`.
    var logoUpdatedAt: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        users: [VineyardUser] = [],
        createdAt: Date = Date(),
        logoData: Data? = nil,
        country: String = "",
        logoPath: String? = nil,
        logoUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.users = users
        self.createdAt = createdAt
        self.logoData = logoData
        self.country = country
        self.logoPath = logoPath
        self.logoUpdatedAt = logoUpdatedAt
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, name, users, createdAt, logoData, country, logoPath, logoUpdatedAt
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        users = try container.decodeIfPresent([VineyardUser].self, forKey: .users) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        logoData = try container.decodeIfPresent(Data.self, forKey: .logoData)
        country = try container.decodeIfPresent(String.self, forKey: .country) ?? ""
        logoPath = try container.decodeIfPresent(String.self, forKey: .logoPath)
        logoUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .logoUpdatedAt)
    }
}

nonisolated struct VineyardUser: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var role: VineyardRole
    var operatorCategoryId: UUID?

    init(
        id: UUID = UUID(),
        name: String = "",
        email: String = "",
        role: VineyardRole = .operator_,
        operatorCategoryId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.operatorCategoryId = operatorCategoryId
    }

    /// Best human-readable label: display name if set, otherwise email,
    /// otherwise a short form of the UUID. Never returns an empty string,
    /// so the Team & Access list never renders blank rows.
    var displayLabel: String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        if !trimmedEmail.isEmpty { return trimmedEmail }
        return "User " + String(id.uuidString.prefix(8))
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, name, email, role, operatorCategoryId
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        role = try container.decodeIfPresent(VineyardRole.self, forKey: .role) ?? .operator_
        operatorCategoryId = try container.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
    }
}

nonisolated enum VineyardRole: String, Codable, Sendable, Hashable, CaseIterable {
    case owner = "Owner"
    case manager = "Manager"
    case supervisor = "Supervisor"
    case operator_ = "Operator"

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "Owner": self = .owner
        case "Manager": self = .manager
        case "Supervisor": self = .supervisor
        case "Operator", "Member": self = .operator_
        default: self = .operator_
        }
    }

    var displayName: String { rawValue }

    /// Highest privilege level: full access including financial data, user management, settings.
    var isManager: Bool { self == .owner || self == .manager }

    /// Supervisors and above can delete operational records and manage day-to-day data.
    var canDelete: Bool { self == .owner || self == .manager || self == .supervisor }

    /// Only Managers can view financial data (costs, prices, revenue).
    var canViewFinancials: Bool { isManager }

    /// Only Managers can export PDFs containing financial data.
    var canExportFinancialPDF: Bool { isManager }

    /// Operational PDF exports (spray records, trip summaries without cost) — Supervisors and above.
    var canExport: Bool { isManager || self == .supervisor }

    /// Only Managers can change settings & manage users.
    var canManageUsers: Bool { isManager }
    var canChangeSettings: Bool { isManager }

    /// Supervisors and above can reopen finalised records.
    var canReopenRecords: Bool { canDelete }

    /// Supervisors and above can finalise/lock records.
    var canFinalizeRecords: Bool { canDelete }
}

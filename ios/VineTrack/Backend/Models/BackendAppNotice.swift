import Foundation

nonisolated enum AppNoticeType: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case success
    case critical

    var displayName: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .success: "Success"
        case .critical: "Critical"
        }
    }
}

nonisolated struct BackendAppNotice: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var title: String
    var message: String
    var noticeType: String
    var priority: Int
    var startsAt: Date?
    var endsAt: Date?
    var isActive: Bool
    var createdBy: UUID?
    var updatedBy: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
    var clientUpdatedAt: Date?
    var syncVersion: Int64?

    var typedNoticeType: AppNoticeType {
        AppNoticeType(rawValue: noticeType) ?? .info
    }

    /// Whether the notice should currently be visible based on the active
    /// flag, soft-delete state, and optional start/end windows.
    func isCurrentlyVisible(now: Date = Date()) -> Bool {
        guard isActive, deletedAt == nil else { return false }
        if let starts = startsAt, now < starts { return false }
        if let ends = endsAt, now > ends { return false }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case message
        case noticeType = "notice_type"
        case priority
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isActive = "is_active"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
    }
}

nonisolated struct AppNoticeUpsert: Encodable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let noticeType: String
    let priority: Int
    let startsAt: Date?
    let endsAt: Date?
    let isActive: Bool
    let createdBy: UUID?
    let updatedBy: UUID?
    let deletedAt: Date?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case message
        case noticeType = "notice_type"
        case priority
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isActive = "is_active"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

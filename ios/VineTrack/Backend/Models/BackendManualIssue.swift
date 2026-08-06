import Foundation

/// Canonical manual issue as returned by the sql/169 RPCs
/// (`manual_issue_json`). All timestamps stay ISO-8601 strings so the record
/// round-trips through the offline outbox without decoder-strategy drift.
nonisolated struct ManualIssueRecord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let title: String
    let description: String?
    let category: String
    let priority: String
    let status: String
    let locationScope: String
    let latitude: Double?
    let longitude: Double?
    let snappedLatitude: Double?
    let snappedLongitude: Double?
    let drivingRowNumber: Double?
    let pinRowNumber: Double?
    let pinSide: String?
    let alongRowDistanceM: Double?
    let snappedToRow: Bool?
    let assignedUserId: UUID?
    let dueDate: String?
    let linkedWorkTaskId: UUID?
    let photoPath: String?
    let createdBy: UUID?
    let createdAt: String?
    let updatedAt: String?
    let clientUpdatedAt: String?
    let deletedAt: String?
    let completedAt: String?
    let completedByUserId: UUID?
    let completedBy: String?
    /// Structured row selection — present (possibly empty) for row scope,
    /// nil otherwise. Authoritative over the marker coordinate.
    let segments: [ManualIssueSegment]?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case title
        case description
        case category
        case priority
        case status
        case locationScope = "location_scope"
        case latitude
        case longitude
        case snappedLatitude = "snapped_latitude"
        case snappedLongitude = "snapped_longitude"
        case drivingRowNumber = "driving_row_number"
        case pinRowNumber = "pin_row_number"
        case pinSide = "pin_side"
        case alongRowDistanceM = "along_row_distance_m"
        case snappedToRow = "snapped_to_row"
        case assignedUserId = "assigned_user_id"
        case dueDate = "due_date"
        case linkedWorkTaskId = "linked_work_task_id"
        case photoPath = "photo_path"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case clientUpdatedAt = "client_updated_at"
        case deletedAt = "deleted_at"
        case completedAt = "completed_at"
        case completedByUserId = "completed_by_user_id"
        case completedBy = "completed_by"
        case segments
    }

    var categoryValue: ManualIssueCategory { ManualIssueCategory(rawValue: category) ?? .general }
    var priorityValue: ManualIssuePriority { ManualIssuePriority(rawValue: priority) ?? .normal }
    var statusValue: ManualIssueStatus { ManualIssueStatus(rawValue: status) ?? .open }
    var scopeValue: ManualIssueLocationScope { ManualIssueLocationScope(rawValue: locationScope) ?? .point }
    var isActive: Bool { statusValue.isActive && deletedAt == nil }

    /// Customer-facing location line: row summary for row scope, "Whole
    /// block" for block scope, attached-row wording for a snapped point.
    var locationSummary: String {
        switch scopeValue {
        case .row:
            let summary = ManualIssueContract.rowSelectionSummary(segments ?? [])
            return summary.isEmpty ? "Rows" : summary
        case .block:
            return "Whole block"
        case .point:
            return ManualIssueContract.attachedRowLabel(
                drivingRowNumber: drivingRowNumber,
                pinRowNumber: pinRowNumber,
                side: pinSide
            ) ?? "Point on map"
        }
    }
}

/// Arguments for `create_manual_issue`. Field names match the RPC argument
/// names exactly. Codable so a queued offline create replays byte-identically.
nonisolated struct ManualIssueCreateParams: Codable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let title: String
    let locationScope: String
    var paddockId: UUID?
    var description: String?
    var category: String = ManualIssueContract.defaultCategory.rawValue
    var priority: String = ManualIssueContract.defaultPriority.rawValue
    var latitude: Double?
    var longitude: Double?
    var snappedLatitude: Double?
    var snappedLongitude: Double?
    var drivingRowNumber: Double?
    var pinRowNumber: Double?
    var pinSide: String?
    var alongRowDistanceM: Double?
    var snappedToRow: Bool = false
    var assignedUserId: UUID?
    var dueDate: String?
    var clientUpdatedAt: String
    var segments: [ManualIssueSegment]?

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case title = "p_title"
        case locationScope = "p_location_scope"
        case paddockId = "p_paddock_id"
        case description = "p_description"
        case category = "p_category"
        case priority = "p_priority"
        case latitude = "p_latitude"
        case longitude = "p_longitude"
        case snappedLatitude = "p_snapped_latitude"
        case snappedLongitude = "p_snapped_longitude"
        case drivingRowNumber = "p_driving_row_number"
        case pinRowNumber = "p_pin_row_number"
        case pinSide = "p_pin_side"
        case alongRowDistanceM = "p_along_row_distance_m"
        case snappedToRow = "p_snapped_to_row"
        case assignedUserId = "p_assigned_user_id"
        case dueDate = "p_due_date"
        case clientUpdatedAt = "p_client_updated_at"
        case segments = "p_segments"
    }
}

/// Arguments for `update_manual_issue` — same shape minus the vineyard id
/// (the server derives it from the existing row).
nonisolated struct ManualIssueUpdateParams: Codable, Sendable {
    let id: UUID
    let title: String
    let locationScope: String
    var paddockId: UUID?
    var description: String?
    var category: String
    var priority: String
    var latitude: Double?
    var longitude: Double?
    var snappedLatitude: Double?
    var snappedLongitude: Double?
    var drivingRowNumber: Double?
    var pinRowNumber: Double?
    var pinSide: String?
    var alongRowDistanceM: Double?
    var snappedToRow: Bool = false
    var assignedUserId: UUID?
    var dueDate: String?
    var clientUpdatedAt: String
    var segments: [ManualIssueSegment]?

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case title = "p_title"
        case locationScope = "p_location_scope"
        case paddockId = "p_paddock_id"
        case description = "p_description"
        case category = "p_category"
        case priority = "p_priority"
        case latitude = "p_latitude"
        case longitude = "p_longitude"
        case snappedLatitude = "p_snapped_latitude"
        case snappedLongitude = "p_snapped_longitude"
        case drivingRowNumber = "p_driving_row_number"
        case pinRowNumber = "p_pin_row_number"
        case pinSide = "p_pin_side"
        case alongRowDistanceM = "p_along_row_distance_m"
        case snappedToRow = "p_snapped_to_row"
        case assignedUserId = "p_assigned_user_id"
        case dueDate = "p_due_date"
        case clientUpdatedAt = "p_client_updated_at"
        case segments = "p_segments"
    }
}

nonisolated enum ManualIssueTimestamp {
    /// ISO-8601 with fractional seconds — the client_updated_at format both
    /// platforms send so last-write-wins comparisons agree.
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

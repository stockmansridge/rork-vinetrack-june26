import Foundation

/// Vineyard-shared custom pin type (sql/170 `vineyard_custom_pin_types`).
/// Shared by every authorised user of the vineyard on iOS / Android / portal —
/// never device- or user-specific. Inactive items stay on historical pins but
/// are hidden from new selection.
nonisolated struct CustomPinTypeRecord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let color: String?
    let icon: String?
    let isActive: Bool
    let createdBy: UUID?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case color
        case icon
        case isActive = "is_active"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Arguments for `create_vineyard_custom_pin_type`. The client-generated id
/// makes an offline replay idempotent; a duplicate active NAME (trimmed,
/// case-insensitive) converges on the existing shared entry server-side.
nonisolated struct CustomPinTypeCreateParams: Codable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    var color: String?
    var icon: String?

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case name = "p_name"
        case color = "p_color"
        case icon = "p_icon"
    }
}

/// Arguments for `create_custom_pin` (sql/170) — the simplified Custom-tab
/// save. Deliberately has no category / priority / assignee / due-date / side:
/// safe backend defaults apply (general / normal / open, pin_side null) and
/// the creation UI never shows those fields.
nonisolated struct CustomPinCreateParams: Codable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let title: String
    let locationScope: String
    var customTypeId: UUID?
    var paddockId: UUID?
    var notes: String?
    var latitude: Double?
    var longitude: Double?
    var snappedLatitude: Double?
    var snappedLongitude: Double?
    var drivingRowNumber: Double?
    var pinRowNumber: Double?
    var alongRowDistanceM: Double?
    var snappedToRow: Bool = false
    var clientUpdatedAt: String
    var segments: [ManualIssueSegment]?

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case title = "p_title"
        case locationScope = "p_location_scope"
        case customTypeId = "p_custom_type_id"
        case paddockId = "p_paddock_id"
        case notes = "p_notes"
        case latitude = "p_latitude"
        case longitude = "p_longitude"
        case snappedLatitude = "p_snapped_latitude"
        case snappedLongitude = "p_snapped_longitude"
        case drivingRowNumber = "p_driving_row_number"
        case pinRowNumber = "p_pin_row_number"
        case alongRowDistanceM = "p_along_row_distance_m"
        case snappedToRow = "p_snapped_to_row"
        case clientUpdatedAt = "p_client_updated_at"
        case segments = "p_segments"
    }
}

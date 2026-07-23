import Foundation

nonisolated struct BackendPin: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let tripId: UUID?
    let mode: String?
    let category: String?
    let priority: String?
    let status: String?
    let buttonName: String?
    let buttonColor: String?
    let title: String?
    let notes: String?
    let latitude: Double?
    let longitude: Double?
    let heading: Double?
    let rowNumber: Int?
    let side: String?
    let growthStageCode: String?
    let isCompleted: Bool
    let completedBy: String?
    let completedByUserId: UUID?
    let completedAt: Date?
    let photoPath: String?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?
    let syncVersion: Int?
    // Attachment geometry (added in 041; nullable on legacy rows).
    let drivingRowNumber: Double?
    let pinRowNumber: Double?
    let pinSide: String?
    let alongRowDistanceM: Double?
    let snappedLatitude: Double?
    let snappedLongitude: Double?
    let snappedToRow: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case tripId = "trip_id"
        case mode
        case category
        case priority
        case status
        case buttonName = "button_name"
        case buttonColor = "button_color"
        case title
        case notes
        case latitude
        case longitude
        case heading
        case rowNumber = "row_number"
        case side
        case growthStageCode = "growth_stage_code"
        case isCompleted = "is_completed"
        case completedBy = "completed_by"
        case completedByUserId = "completed_by_user_id"
        case completedAt = "completed_at"
        case photoPath = "photo_path"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
        case drivingRowNumber = "driving_row_number"
        case pinRowNumber = "pin_row_number"
        case pinSide = "pin_side"
        case alongRowDistanceM = "along_row_distance_m"
        case snappedLatitude = "snapped_latitude"
        case snappedLongitude = "snapped_longitude"
        case snappedToRow = "snapped_to_row"
    }
}

/// Encodable payload used when upserting a pin from the client. Fields that
/// the server fills in (created_at, updated_at, deleted_at, sync_version,
/// updated_by) are intentionally omitted so the client cannot spoof them.
nonisolated struct BackendPinUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let tripId: UUID?
    let mode: String?
    let buttonName: String?
    let buttonColor: String?
    let notes: String?
    let latitude: Double?
    let longitude: Double?
    let heading: Double?
    let rowNumber: Int?
    let side: String?
    let growthStageCode: String?
    let isCompleted: Bool
    let completedBy: String?
    let completedByUserId: UUID?
    let completedAt: Date?
    let photoPath: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date
    // Attachment geometry (added in 041).
    let drivingRowNumber: Double?
    let pinRowNumber: Double?
    let pinSide: String?
    let alongRowDistanceM: Double?
    let snappedLatitude: Double?
    let snappedLongitude: Double?
    let snappedToRow: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case tripId = "trip_id"
        case mode
        case buttonName = "button_name"
        case buttonColor = "button_color"
        case notes
        case latitude
        case longitude
        case heading
        case rowNumber = "row_number"
        case side
        case growthStageCode = "growth_stage_code"
        case isCompleted = "is_completed"
        case completedBy = "completed_by"
        case completedByUserId = "completed_by_user_id"
        case completedAt = "completed_at"
        case photoPath = "photo_path"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
        case drivingRowNumber = "driving_row_number"
        case pinRowNumber = "pin_row_number"
        case pinSide = "pin_side"
        case alongRowDistanceM = "along_row_distance_m"
        case snappedLatitude = "snapped_latitude"
        case snappedLongitude = "snapped_longitude"
        case snappedToRow = "snapped_to_row"
    }
}

private extension Optional where Wrapped == String {
    /// The wrapped string trimmed of whitespace, or nil when absent/empty —
    /// lets `??` chains skip empty-string values coming from Android rows.
    var nonEmptyTrimmed: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension BackendPin {
    /// Map a local VinePin into a BackendPin upsert payload.
    /// `photoPath` is the Supabase Storage path; raw photo bytes are uploaded
    /// separately to the `vineyard-pin-photos` bucket before upsert.
    static func upsert(from pin: VinePin, clientUpdatedAt: Date) -> BackendPinUpsert {
        BackendPinUpsert(
            id: pin.id,
            vineyardId: pin.vineyardId,
            paddockId: pin.paddockId,
            tripId: pin.tripId,
            mode: pin.mode.rawValue,
            buttonName: pin.buttonName,
            buttonColor: pin.buttonColor,
            notes: pin.notes,
            latitude: pin.latitude,
            longitude: pin.longitude,
            heading: pin.heading,
            rowNumber: pin.rowNumber,
            side: pin.side.rawValue,
            growthStageCode: pin.growthStageCode,
            isCompleted: pin.isCompleted,
            completedBy: pin.completedBy,
            completedByUserId: pin.completedByUserId,
            completedAt: pin.completedAt,
            photoPath: pin.photoPath,
            createdBy: pin.createdByUserId,
            clientUpdatedAt: clientUpdatedAt,
            drivingRowNumber: pin.drivingRowNumber,
            pinRowNumber: pin.pinRowNumber.map(Double.init),
            pinSide: pin.pinSide?.rawValue,
            alongRowDistanceM: pin.alongRowDistanceM,
            snappedLatitude: pin.snappedLatitude,
            snappedLongitude: pin.snappedLongitude,
            snappedToRow: pin.snappedToRow
        )
    }

    /// Map a remote BackendPin into a local VinePin. Returns nil if the remote
    /// row is missing critical coordinates.
    /// - Parameter nameColorMap: button-name → colour-token map from the
    ///   vineyard's launcher configuration, used when the row has no stored
    ///   colour (Android parity — old Android pins saved neither name nor colour
    ///   in the button columns).
    func toVinePin(
        preservingPhoto existingPhoto: Data? = nil,
        preservingCreatedByText existingCreatedByText: String? = nil,
        nameColorMap: [String: String] = [:]
    ) -> VinePin? {
        guard let latitude, let longitude else { return nil }
        let resolvedSide = PinSide(rawValue: side ?? "") ?? .left
        let pinMode = PinMode(rawValue: mode ?? "") ?? .repairs
        // Android historically saved the pin's name only in `title` (and often
        // an empty string — not NULL — in `button_name`), so treat empty as
        // missing and fall back through title, then category.
        let resolvedName = buttonName.nonEmptyTrimmed ?? title.nonEmptyTrimmed ?? category.nonEmptyTrimmed ?? ""
        // Colour: the stored token wins; otherwise resolve from the vineyard's
        // button configuration by name (matching Android), then a mode accent —
        // never a hardcoded blue.
        let resolvedColor = buttonColor.nonEmptyTrimmed
            ?? nameColorMap[resolvedName].nonEmptyTrimmed
            ?? (pinMode == .growth ? "darkgreen" : "red")
        return VinePin(
            id: id,
            vineyardId: vineyardId,
            latitude: latitude,
            longitude: longitude,
            // Preserve a genuinely-missing heading as nil so the UI can show
            // "—" instead of a misleading North (0°).
            heading: heading,
            buttonName: resolvedName,
            buttonColor: resolvedColor,
            side: resolvedSide,
            mode: pinMode,
            paddockId: paddockId,
            rowNumber: rowNumber,
            timestamp: createdAt ?? Date(),
            createdBy: existingCreatedByText,
            createdByUserId: createdBy,
            isCompleted: isCompleted,
            completedBy: completedBy,
            completedByUserId: completedByUserId,
            completedAt: completedAt,
            photoData: existingPhoto,
            photoPath: photoPath,
            tripId: tripId,
            growthStageCode: growthStageCode,
            notes: notes,
            drivingRowNumber: drivingRowNumber,
            pinRowNumber: pinRowNumber.map { Int($0.rounded()) },
            pinSide: pinSide.flatMap { PinSide(rawValue: $0) },
            alongRowDistanceM: alongRowDistanceM,
            snappedLatitude: snappedLatitude,
            snappedLongitude: snappedLongitude,
            snappedToRow: snappedToRow ?? false
        )
    }
}

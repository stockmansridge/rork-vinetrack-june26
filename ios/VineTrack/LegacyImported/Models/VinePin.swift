import Foundation
import CoreLocation

nonisolated struct VinePin: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    let latitude: Double
    let longitude: Double
    /// Compass direction at drop time (degrees, 0–360). Nil when the device
    /// had no heading fix — shown honestly as "—" instead of a fake North.
    let heading: Double?
    let buttonName: String
    let buttonColor: String
    let side: PinSide
    let mode: PinMode
    var paddockId: UUID?
    /// Legacy field. Stores the integer floor of the driving path/mid-row
    /// the tractor was on (e.g. 14 for path 14.5). Kept for backward
    /// compatibility — new code should prefer `drivingRowNumber` and
    /// `pinRowNumber` when present.
    let rowNumber: Int?
    let timestamp: Date
    var createdBy: String?
    var createdByUserId: UUID?
    var isCompleted: Bool
    var completedBy: String?
    var completedByUserId: UUID?
    var completedAt: Date?
    var photoData: Data?
    var photoPath: String?
    var tripId: UUID?
    var growthStageCode: String?
    var notes: String?

    // MARK: - Attachment geometry (additive, optional)
    /// Driving path / mid-row the operator was on, e.g. 14.5.
    var drivingRowNumber: Double?
    /// Actual vine row the pin/issue is attached to, e.g. 14 or 15.
    var pinRowNumber: Int?
    /// Side of the operator the pin was attached to (operator's POV).
    var pinSide: PinSide?
    /// Distance along `pinRowNumber` (metres) from the row's start point to
    /// the snapped pin location. Used for along-row duplicate detection.
    var alongRowDistanceM: Double?
    /// Snapped latitude after projecting the pin onto the row line.
    var snappedLatitude: Double?
    /// Snapped longitude after projecting the pin onto the row line.
    var snappedLongitude: Double?
    /// True when iOS had a confident row lock and successfully snapped the
    /// pin to the row geometry. Only confident snaps populate the
    /// attachment fields above.
    var snappedToRow: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Best-known attached coordinate: snapped point when available,
    /// otherwise the raw saved coordinate.
    var attachedCoordinate: CLLocationCoordinate2D {
        if snappedToRow, let lat = snappedLatitude, let lon = snappedLongitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return coordinate
    }

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        heading: Double?,
        buttonName: String,
        buttonColor: String,
        side: PinSide,
        mode: PinMode,
        paddockId: UUID? = nil,
        rowNumber: Int? = nil,
        timestamp: Date = Date(),
        createdBy: String? = nil,
        createdByUserId: UUID? = nil,
        isCompleted: Bool = false,
        completedBy: String? = nil,
        completedByUserId: UUID? = nil,
        completedAt: Date? = nil,
        photoData: Data? = nil,
        photoPath: String? = nil,
        tripId: UUID? = nil,
        growthStageCode: String? = nil,
        notes: String? = nil,
        drivingRowNumber: Double? = nil,
        pinRowNumber: Int? = nil,
        pinSide: PinSide? = nil,
        alongRowDistanceM: Double? = nil,
        snappedLatitude: Double? = nil,
        snappedLongitude: Double? = nil,
        snappedToRow: Bool = false
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.buttonName = buttonName
        self.buttonColor = buttonColor
        self.side = side
        self.mode = mode
        self.paddockId = paddockId
        self.rowNumber = rowNumber
        self.timestamp = timestamp
        self.createdBy = createdBy
        self.createdByUserId = createdByUserId
        self.isCompleted = isCompleted
        self.completedBy = completedBy
        self.completedByUserId = completedByUserId
        self.completedAt = completedAt
        self.photoData = photoData
        self.photoPath = photoPath
        self.tripId = tripId
        self.growthStageCode = growthStageCode
        self.notes = notes
        self.drivingRowNumber = drivingRowNumber
        self.pinRowNumber = pinRowNumber
        self.pinSide = pinSide
        self.alongRowDistanceM = alongRowDistanceM
        self.snappedLatitude = snappedLatitude
        self.snappedLongitude = snappedLongitude
        self.snappedToRow = snappedToRow
    }

    // Custom Codable so older persisted JSON (without the new fields) still
    // decodes cleanly with safe defaults.
    private enum CodingKeys: String, CodingKey {
        case id, vineyardId, latitude, longitude, heading
        case buttonName, buttonColor, side, mode, paddockId, rowNumber
        case timestamp, createdBy, createdByUserId
        case isCompleted, completedBy, completedByUserId, completedAt
        case photoData, photoPath, tripId, growthStageCode, notes
        case drivingRowNumber, pinRowNumber, pinSide, alongRowDistanceM
        case snappedLatitude, snappedLongitude, snappedToRow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        heading = try c.decodeIfPresent(Double.self, forKey: .heading)
        buttonName = try c.decode(String.self, forKey: .buttonName)
        buttonColor = try c.decode(String.self, forKey: .buttonColor)
        side = try c.decode(PinSide.self, forKey: .side)
        mode = try c.decode(PinMode.self, forKey: .mode)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId)
        rowNumber = try c.decodeIfPresent(Int.self, forKey: .rowNumber)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        createdByUserId = try c.decodeIfPresent(UUID.self, forKey: .createdByUserId)
        isCompleted = try c.decode(Bool.self, forKey: .isCompleted)
        completedBy = try c.decodeIfPresent(String.self, forKey: .completedBy)
        completedByUserId = try c.decodeIfPresent(UUID.self, forKey: .completedByUserId)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        photoData = try c.decodeIfPresent(Data.self, forKey: .photoData)
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        tripId = try c.decodeIfPresent(UUID.self, forKey: .tripId)
        growthStageCode = try c.decodeIfPresent(String.self, forKey: .growthStageCode)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        drivingRowNumber = try c.decodeIfPresent(Double.self, forKey: .drivingRowNumber)
        pinRowNumber = try c.decodeIfPresent(Int.self, forKey: .pinRowNumber)
        pinSide = try c.decodeIfPresent(PinSide.self, forKey: .pinSide)
        alongRowDistanceM = try c.decodeIfPresent(Double.self, forKey: .alongRowDistanceM)
        snappedLatitude = try c.decodeIfPresent(Double.self, forKey: .snappedLatitude)
        snappedLongitude = try c.decodeIfPresent(Double.self, forKey: .snappedLongitude)
        snappedToRow = try c.decodeIfPresent(Bool.self, forKey: .snappedToRow) ?? false
    }
}

nonisolated enum PinSide: String, Codable, Sendable, Hashable {
    case left = "Left"
    case right = "Right"
}

nonisolated enum PinMode: String, Codable, Sendable, Hashable, CaseIterable {
    case repairs = "Repairs"
    case growth = "Growth"
}

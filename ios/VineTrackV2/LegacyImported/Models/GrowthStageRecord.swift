import Foundation

/// Local representation of a growth-stage observation that mirrors the
/// `public.growth_stage_records` Supabase table.
///
/// This is the dedicated store for E-L growth-stage observations. The
/// existing pin-based growth observations (see `VinePin.growthStageCode`)
/// remain readable for backwards compatibility. When a growth-stage pin
/// is added, the sync service mirrors it into a `GrowthStageRecord` via
/// `pinId` so updates/soft-deletes can be reconciled.
nonisolated struct GrowthStageRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var paddockId: UUID?
    /// Source pin for back-compat mirroring. nil for records created
    /// directly via the new growth-stage flow.
    var pinId: UUID?

    var stageCode: String
    var stageLabel: String?

    /// Snapshot of the variety name at the time of observation. Important
    /// for reporting — historical records remain readable even if the
    /// block's variety allocation changes later.
    var variety: String?
    /// Optional id pointer into `grape_varieties` when available.
    var varietyId: UUID?

    var observedAt: Date
    var latitude: Double?
    var longitude: Double?
    var rowNumber: Int?
    var side: String?
    var notes: String?

    /// Storage paths into the `growth-stage-photos` bucket. May be empty.
    var photoPaths: [String]

    /// Friendly observer/operator name (for legacy/imported records and
    /// for reporting when an auth profile lookup is unavailable).
    var recordedByName: String?

    var createdBy: UUID?
    var updatedBy: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        paddockId: UUID? = nil,
        pinId: UUID? = nil,
        stageCode: String,
        stageLabel: String? = nil,
        variety: String? = nil,
        varietyId: UUID? = nil,
        observedAt: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        rowNumber: Int? = nil,
        side: String? = nil,
        notes: String? = nil,
        photoPaths: [String] = [],
        recordedByName: String? = nil,
        createdBy: UUID? = nil,
        updatedBy: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.pinId = pinId
        self.stageCode = stageCode
        self.stageLabel = stageLabel
        self.variety = variety
        self.varietyId = varietyId
        self.observedAt = observedAt
        self.latitude = latitude
        self.longitude = longitude
        self.rowNumber = rowNumber
        self.side = side
        self.notes = notes
        self.photoPaths = photoPaths
        self.recordedByName = recordedByName
        self.createdBy = createdBy
        self.updatedBy = updatedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension GrowthStageRecord {
    /// Build a mirrored record from a freshly added growth-stage pin.
    /// Caller is responsible for filling in `variety` / `varietyId` from
    /// the paddock allocation if available.
    static func mirroring(
        _ pin: VinePin,
        stageLabel: String? = nil,
        variety: String? = nil,
        varietyId: UUID? = nil
    ) -> GrowthStageRecord? {
        guard let code = pin.growthStageCode, !code.isEmpty else { return nil }
        return GrowthStageRecord(
            id: UUID(),
            vineyardId: pin.vineyardId,
            paddockId: pin.paddockId,
            pinId: pin.id,
            stageCode: code,
            stageLabel: stageLabel,
            variety: variety,
            varietyId: varietyId,
            observedAt: pin.timestamp,
            latitude: pin.latitude,
            longitude: pin.longitude,
            rowNumber: pin.rowNumber,
            side: pin.side.rawValue,
            notes: pin.notes,
            photoPaths: pin.photoPath.map { [$0] } ?? [],
            recordedByName: pin.createdBy,
            createdBy: pin.createdByUserId,
            updatedBy: pin.createdByUserId,
            createdAt: pin.timestamp,
            updatedAt: pin.timestamp
        )
    }
}

import Foundation

/// The Scout capture domain — pure data and pure rules, no UI, no network.
///
/// Mirrors the Android `ScoutModels.kt`. Both platforms capture the same shapes
/// so a visit recorded on a phone in the rows reads identically on the other
/// platform and, later, in a report.

/// Lifecycle of a Scout visit.
nonisolated enum ScoutStatus: String, Sendable, CaseIterable {
    case draft
    case completed

    var code: String { rawValue }

    var label: String {
        switch self {
        case .draft: return "Draft"
        case .completed: return "Completed"
        }
    }

    static func byCode(_ code: String?) -> ScoutStatus {
        guard let code, let value = ScoutStatus(rawValue: code) else { return .draft }
        return value
    }
}

/// Completion state of one block's assessment.
nonisolated enum ScoutAssessmentStatus: String, Sendable {
    case inProgress = "in_progress"
    case complete

    var code: String { rawValue }

    var label: String {
        switch self {
        case .inProgress: return "In progress"
        case .complete: return "Complete"
        }
    }
}

/// How honestly a photo's coordinates are known.
///
/// This exists because the alternative — a nullable latitude — cannot tell the
/// difference between "we did not try", "we tried and failed" and "this is
/// where it was". A scouting photo is evidence; a photo silently carrying the
/// shed's coordinates, or the block centroid, is worse than a photo with no
/// coordinates at all, because it looks precise.
nonisolated enum PhotoLocationStatus: String, Sendable {
    /// A fresh fix passing the existing strict validation was attached.
    case gpsConfirmed = "gps_confirmed"
    /// No qualifying fix was available. The photo is associated with the BLOCK
    /// only and carries no coordinates whatsoever — not a stale fix, not a
    /// last-known position, not a centroid.
    case unavailable = "location_unavailable"

    var code: String { rawValue }

    var label: String {
        switch self {
        case .gpsConfirmed: return "GPS confirmed"
        case .unavailable: return "Location unavailable — block association only"
        }
    }

    static func byCode(_ code: String?) -> PhotoLocationStatus {
        guard let code, let value = PhotoLocationStatus(rawValue: code) else { return .unavailable }
        return value
    }
}

/// A photo attached to one observation.
///
/// Coordinates are only ever populated together with `.gpsConfirmed`;
/// `.unavailable` is the only other legal shape. The initialiser is private so
/// no caller can construct the dishonest combination — the two factories below
/// are the only way in.
nonisolated struct ScoutPhoto: Identifiable, Equatable, Sendable {
    let id: UUID
    let observationID: UUID
    /// App-private file path, written BEFORE any upload is attempted.
    ///
    /// This is what makes the photograph survive a crash, a restart and a
    /// vineyard switch. The bytes live on disk from the moment of capture; the
    /// upload is a later reconciliation, never the place the evidence lives.
    let localPath: String?
    /// Server storage path once uploaded; nil while local-only.
    ///
    /// Mutable because reconciliation fills it in after the bytes land in the
    /// `scout-photos` bucket. Keyed by this photo's own id, so a late upload
    /// callback can only ever complete ITS OWN photograph and can never
    /// overwrite or remove a newer one.
    var storagePath: String?
    /// True when the last upload attempt failed. The local file is retained and
    /// the operator is offered Retry — a failed upload must never look like a
    /// lost photograph.
    var uploadFailed: Bool
    let capturedAt: Date
    let capturedByUserID: UUID?
    let latitude: Double?
    let longitude: Double?
    let accuracyMetres: Double?
    let locationStatus: PhotoLocationStatus

    /// True once the bytes are known to be in the bucket.
    var isUploaded: Bool { storagePath != nil }

    private init(
        id: UUID,
        observationID: UUID,
        localPath: String?,
        storagePath: String?,
        uploadFailed: Bool,
        capturedAt: Date,
        capturedByUserID: UUID?,
        latitude: Double?,
        longitude: Double?,
        accuracyMetres: Double?,
        locationStatus: PhotoLocationStatus
    ) {
        self.id = id
        self.observationID = observationID
        self.localPath = localPath
        self.storagePath = storagePath
        self.uploadFailed = uploadFailed
        self.capturedAt = capturedAt
        self.capturedByUserID = capturedByUserID
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMetres = accuracyMetres
        self.locationStatus = locationStatus
    }

    /// A photo whose position came from a fix that passed validation.
    static func gpsConfirmed(
        observationID: UUID,
        localPath: String?,
        capturedAt: Date,
        capturedByUserID: UUID?,
        latitude: Double,
        longitude: Double,
        accuracyMetres: Double,
        id: UUID = UUID(),
        storagePath: String? = nil,
        uploadFailed: Bool = false
    ) -> ScoutPhoto {
        ScoutPhoto(
            id: id,
            observationID: observationID,
            localPath: localPath,
            storagePath: storagePath,
            uploadFailed: uploadFailed,
            capturedAt: capturedAt,
            capturedByUserID: capturedByUserID,
            latitude: latitude,
            longitude: longitude,
            accuracyMetres: accuracyMetres,
            locationStatus: .gpsConfirmed
        )
    }

    /// A photo with no trustworthy position. The caller cannot pass coordinates
    /// here even by mistake — that is the entire point of the separate factory.
    static func blockOnly(
        observationID: UUID,
        localPath: String?,
        capturedAt: Date,
        capturedByUserID: UUID?,
        id: UUID = UUID(),
        storagePath: String? = nil,
        uploadFailed: Bool = false
    ) -> ScoutPhoto {
        ScoutPhoto(
            id: id,
            observationID: observationID,
            localPath: localPath,
            storagePath: storagePath,
            uploadFailed: uploadFailed,
            capturedAt: capturedAt,
            capturedByUserID: capturedByUserID,
            latitude: nil,
            longitude: nil,
            accuracyMetres: nil,
            locationStatus: .unavailable
        )
    }
}

/// One captured assessment item for one block.
///
/// `valueCode` and `valueLabel` are stored together deliberately: the code is
/// the queryable truth and the label is what the operator actually read on the
/// day. A future relabelling changes new captures only.
nonisolated struct ScoutObservation: Identifiable, Equatable, Sendable {
    let id: UUID
    let assessmentID: UUID
    let item: ScoutItem
    var valueCode: String?
    var valueLabel: String?
    var notes: String?
    var photos: [ScoutPhoto]
    /// Nullable linkage reserved for the later reviewed-action workflow.
    var linkedPinID: UUID?
    /// Canonical `growth_stage_records.id` when `item == .growthStage`.
    var linkedGrowthStageRecordID: UUID?

    init(
        id: UUID = UUID(),
        assessmentID: UUID,
        item: ScoutItem,
        valueCode: String? = nil,
        valueLabel: String? = nil,
        notes: String? = nil,
        photos: [ScoutPhoto] = [],
        linkedPinID: UUID? = nil,
        linkedGrowthStageRecordID: UUID? = nil
    ) {
        self.id = id
        self.assessmentID = assessmentID
        self.item = item
        self.valueCode = valueCode
        self.valueLabel = valueLabel
        self.notes = notes
        self.photos = photos
        self.linkedPinID = linkedPinID
        self.linkedGrowthStageRecordID = linkedGrowthStageRecordID
    }

    /// True when this row carries anything at all worth keeping.
    var hasContent: Bool {
        VineyardInsightsCatalog.isAssessed(item: item, code: valueCode)
            || !(notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !photos.isEmpty
            || linkedGrowthStageRecordID != nil
    }

    var needsAttention: Bool {
        VineyardInsightsCatalog.needsAttention(item: item, code: valueCode)
    }

    /// An empty, defaulted observation for `item`.
    static func empty(assessmentID: UUID, item: ScoutItem) -> ScoutObservation {
        let defaultCode: String? = (item.isFreeText || item == .growthStage)
            ? nil
            : VineyardInsightsCatalog.notAssessedCode
        return ScoutObservation(
            assessmentID: assessmentID,
            item: item,
            valueCode: defaultCode,
            valueLabel: defaultCode == nil ? nil : VineyardInsightsCatalog.notAssessedLabel
        )
    }
}

/// One block's assessment within a visit.
nonisolated struct ScoutBlockAssessment: Identifiable, Equatable, Sendable {
    let id: UUID
    let visitID: UUID
    let vineyardID: UUID
    let paddockID: UUID
    var status: ScoutAssessmentStatus
    var observations: [ScoutObservation]

    init(
        id: UUID = UUID(),
        visitID: UUID,
        vineyardID: UUID,
        paddockID: UUID,
        status: ScoutAssessmentStatus = .inProgress,
        observations: [ScoutObservation] = []
    ) {
        self.id = id
        self.visitID = visitID
        self.vineyardID = vineyardID
        self.paddockID = paddockID
        self.status = status
        self.observations = observations
    }

    func observation(_ item: ScoutItem) -> ScoutObservation? {
        observations.first { $0.item == item }
    }

    /// Observations carrying real content — what the review and report count.
    var recordedObservations: [ScoutObservation] { observations.filter(\.hasContent) }

    var photoCount: Int { observations.reduce(0) { $0 + $1.photos.count } }

    var attentionItems: [ScoutObservation] { observations.filter(\.needsAttention) }

    /// Completion rule for ONE block.
    ///
    /// Deliberately not "every dropdown answered": a scout who walks a block
    /// and finds nothing worth noting has done their job, and forcing six
    /// selections to record that would train people to click through defaults.
    /// What IS required is evidence the block was actually visited — at least
    /// one observation, issue or recommendation.
    var isComplete: Bool { !recordedObservations.isEmpty }

    mutating func setObservation(_ updated: ScoutObservation) {
        if let index = observations.firstIndex(where: { $0.item == updated.item }) {
            observations[index] = updated
        } else {
            observations.append(updated)
        }
        status = isComplete ? .complete : .inProgress
    }

    /// A fresh assessment with every item present and defaulted.
    static func create(visitID: UUID, vineyardID: UUID, paddockID: UUID) -> ScoutBlockAssessment {
        let id = UUID()
        return ScoutBlockAssessment(
            id: id,
            visitID: visitID,
            vineyardID: vineyardID,
            paddockID: paddockID,
            observations: ScoutItem.allCases.map { ScoutObservation.empty(assessmentID: id, item: $0) }
        )
    }
}

/// A current-weather snapshot captured alongside a visit.
///
/// Every field is optional and `isStale` / `isUnavailable` are explicit,
/// because the honest answer "we could not reach the weather service" must
/// survive into the record. A report that silently omits a missing reading
/// invites the reader to assume conditions were unremarkable.
nonisolated struct ScoutWeatherSnapshot: Equatable, Sendable {
    let observedAt: Date?
    let capturedAt: Date
    let source: String?
    let temperatureCelsius: Double?
    let humidityPercent: Double?
    let windSpeedKph: Double?
    let windGustKph: Double?
    let recentRainfallMm: Double?
    let isStale: Bool
    let isUnavailable: Bool

    init(
        observedAt: Date?,
        capturedAt: Date,
        source: String?,
        temperatureCelsius: Double?,
        humidityPercent: Double?,
        windSpeedKph: Double?,
        windGustKph: Double?,
        recentRainfallMm: Double?,
        isStale: Bool = false,
        isUnavailable: Bool = false
    ) {
        self.observedAt = observedAt
        self.capturedAt = capturedAt
        self.source = source
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.windSpeedKph = windSpeedKph
        self.windGustKph = windGustKph
        self.recentRainfallMm = recentRainfallMm
        self.isStale = isStale
        self.isUnavailable = isUnavailable
    }

    /// The recorded absence of weather — never an invented reading.
    static func unavailable(capturedAt: Date, source: String? = nil) -> ScoutWeatherSnapshot {
        ScoutWeatherSnapshot(
            observedAt: nil,
            capturedAt: capturedAt,
            source: source,
            temperatureCelsius: nil,
            humidityPercent: nil,
            windSpeedKph: nil,
            windGustKph: nil,
            recentRainfallMm: nil,
            isUnavailable: true
        )
    }
}

/// A Scout visit: the unit an operator starts, saves and completes.
nonisolated struct ScoutVisit: Identifiable, Equatable, Sendable {
    /// Client-generated UUID — the offline idempotency key.
    let id: UUID
    let vineyardID: UUID
    /// Server-resolved; the client value is display-only until sync returns.
    var vintageYear: Int
    var scoutDate: Date
    var status: ScoutStatus
    var visitSummary: String?
    var weather: ScoutWeatherSnapshot?
    let scoutUserID: UUID?
    let scoutNameSnapshot: String?
    var assessments: [ScoutBlockAssessment]
    var clientUpdatedAt: Date
    var syncVersion: Int

    init(
        id: UUID = UUID(),
        vineyardID: UUID,
        vintageYear: Int,
        scoutDate: Date,
        status: ScoutStatus = .draft,
        visitSummary: String? = nil,
        weather: ScoutWeatherSnapshot? = nil,
        scoutUserID: UUID?,
        scoutNameSnapshot: String?,
        assessments: [ScoutBlockAssessment] = [],
        clientUpdatedAt: Date = Date(),
        syncVersion: Int = 0
    ) {
        self.id = id
        self.vineyardID = vineyardID
        self.vintageYear = vintageYear
        self.scoutDate = scoutDate
        self.status = status
        self.visitSummary = visitSummary
        self.weather = weather
        self.scoutUserID = scoutUserID
        self.scoutNameSnapshot = scoutNameSnapshot
        self.assessments = assessments
        self.clientUpdatedAt = clientUpdatedAt
        self.syncVersion = syncVersion
    }

    var isEditable: Bool { status == .draft }

    func assessment(paddockID: UUID) -> ScoutBlockAssessment? {
        assessments.first { $0.paddockID == paddockID }
    }

    /// Add a block, or do nothing if it is already assessed.
    ///
    /// The uniqueness of one assessment per visit and block is a domain rule,
    /// not only a database constraint: two partially-filled assessments for the
    /// same block would make "what did the scout find in Block 4?" ambiguous.
    mutating func addBlock(paddockID: UUID) {
        guard assessment(paddockID: paddockID) == nil else { return }
        assessments.append(
            ScoutBlockAssessment.create(visitID: id, vineyardID: vineyardID, paddockID: paddockID)
        )
    }

    mutating func removeBlock(paddockID: UUID) {
        assessments.removeAll { $0.paddockID == paddockID }
    }

    mutating func setAssessment(_ updated: ScoutBlockAssessment) {
        guard let index = assessments.firstIndex(where: { $0.id == updated.id }) else { return }
        assessments[index] = updated
    }
}

/// Vineyard-scoped, deterministic Scout history used by list and navigation.
nonisolated enum ScoutHistoryPolicy {
    static func select(
        _ visits: [ScoutVisit],
        vineyardID: UUID,
        vintageYear: Int?
    ) -> [ScoutVisit] {
        visits
            .filter { $0.vineyardID == vineyardID }
            .filter { vintageYear == nil || $0.vintageYear == vintageYear }
            .sorted { lhs, rhs in
                if lhs.scoutDate != rhs.scoutDate { return lhs.scoutDate > rhs.scoutDate }
                if lhs.clientUpdatedAt != rhs.clientUpdatedAt { return lhs.clientUpdatedAt > rhs.clientUpdatedAt }
                return lhs.id.uuidString > rhs.id.uuidString
            }
    }
}

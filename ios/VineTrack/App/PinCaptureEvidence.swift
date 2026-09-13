import CryptoKit
import Foundation

/// Immutable sensor observation retained with an automatic pin capture.
nonisolated struct PinCaptureObservation: Codable, Sendable, Equatable {
    let observedAt: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyM: Double?
    let courseDegrees: Double?
    let speedMps: Double?
}

/// Frozen aisle-lock evidence. It is advisory until the server verifies it
/// against the capture-time geometry and bounded observations.
nonisolated struct PinCaptureAisleLock: Codable, Sendable, Equatable {
    let paddockId: UUID
    let aisleNumber: Double
    let supportingObservations: Int
    let confirmedAt: Date
}

/// Immutable, durable evidence captured with an automatic pin. Derived server
/// placement may change; this observation never does.
nonisolated struct PinCaptureEvidence: Codable, Sendable, Identifiable {
    let pinId: UUID
    let vineyardId: UUID
    let evidenceRevision: Int
    let resolverVersion: String
    let capturedAt: Date
    let locationObservedAt: Date
    let rawLatitude: Double
    let rawLongitude: Double
    let horizontalAccuracyM: Double?
    let headingDegrees: Double?
    let headingSource: String?
    let headingObservedAt: Date?
    let pressedSide: String?
    let tripId: UUID?
    let captureUserId: UUID?
    let captureButtonName: String
    let captureMode: String
    let supportedPaddockId: UUID?
    let supportedDrivingRow: Double?
    let supportedPinRow: Double?
    let supportedPinSide: String?
    let supportedSnappedLatitude: Double?
    let supportedSnappedLongitude: Double?
    let supportedAlongRowDistanceM: Double?
    let aisleLock: PinCaptureAisleLock?
    let observations: [PinCaptureObservation]
    let captureProvenance: [String: String]
    let geometryRevision: String?
    let geometryHash: String?
    var isUploaded: Bool

    var id: String { "\(pinId.uuidString.lowercased())#\(evidenceRevision)" }

    enum CodingKeys: String, CodingKey {
        case pinId = "pin_id"
        case vineyardId = "vineyard_id"
        case evidenceRevision = "evidence_revision"
        case resolverVersion = "resolver_version"
        case capturedAt = "captured_at"
        case locationObservedAt = "location_observed_at"
        case rawLatitude = "raw_latitude"
        case rawLongitude = "raw_longitude"
        case horizontalAccuracyM = "horizontal_accuracy_m"
        case headingDegrees = "heading_degrees"
        case headingSource = "heading_source"
        case headingObservedAt = "heading_observed_at"
        case pressedSide = "pressed_side"
        case tripId = "trip_id"
        case captureUserId = "capture_user_id"
        case captureButtonName = "capture_button_name"
        case captureMode = "capture_mode"
        case supportedPaddockId = "supported_paddock_id"
        case supportedDrivingRow = "supported_driving_row"
        case supportedPinRow = "supported_pin_row"
        case supportedPinSide = "supported_pin_side"
        case supportedSnappedLatitude = "supported_snapped_latitude"
        case supportedSnappedLongitude = "supported_snapped_longitude"
        case supportedAlongRowDistanceM = "supported_along_row_distance_m"
        case aisleLock = "aisle_lock"
        case observations
        case captureProvenance = "capture_provenance"
        case geometryRevision = "geometry_revision"
        case geometryHash = "geometry_hash"
        case isUploaded
    }

    func uploadPayload() -> PinCaptureEvidenceUpload { PinCaptureEvidenceUpload(evidence: self) }

    /// Versioned geometry identity shared with Android and SQL. Only ordered
    /// polygon coordinates and row number/endpoints participate.
    static func geometryIdentity(for paddock: Paddock?) -> (revision: String?, hash: String?) {
        guard let paddock else { return (nil, nil) }
        func number(_ value: Double) -> String {
            String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let polygon = paddock.polygonPoints.map { "\(number($0.latitude)),\(number($0.longitude))" }.joined(separator: ";")
        let rows = paddock.rows.sorted { $0.number < $1.number }.map {
            "\($0.number):\(number($0.startPoint.latitude)),\(number($0.startPoint.longitude))>\(number($0.endPoint.latitude)),\(number($0.endPoint.longitude))"
        }.joined(separator: ";")
        let canonical = "pin-geometry-v1|p=\(polygon)|r=\(rows)"
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return ("pin-geometry-v1", "pin-geometry-v1:\(digest)")
    }
}

/// Server payload deliberately excludes local upload state.
nonisolated struct PinCaptureEvidenceUpload: Encodable, Sendable {
    private let evidence: PinCaptureEvidence
    init(evidence: PinCaptureEvidence) { self.evidence = evidence }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PinCaptureEvidence.CodingKeys.self)
        try container.encode(evidence.pinId, forKey: .pinId)
        try container.encode(evidence.vineyardId, forKey: .vineyardId)
        try container.encode(evidence.evidenceRevision, forKey: .evidenceRevision)
        try container.encode(evidence.resolverVersion, forKey: .resolverVersion)
        try container.encode(evidence.capturedAt, forKey: .capturedAt)
        try container.encode(evidence.locationObservedAt, forKey: .locationObservedAt)
        try container.encode(evidence.rawLatitude, forKey: .rawLatitude)
        try container.encode(evidence.rawLongitude, forKey: .rawLongitude)
        try container.encodeIfPresent(evidence.horizontalAccuracyM, forKey: .horizontalAccuracyM)
        try container.encodeIfPresent(evidence.headingDegrees, forKey: .headingDegrees)
        try container.encodeIfPresent(evidence.headingSource, forKey: .headingSource)
        try container.encodeIfPresent(evidence.headingObservedAt, forKey: .headingObservedAt)
        try container.encodeIfPresent(evidence.pressedSide, forKey: .pressedSide)
        try container.encodeIfPresent(evidence.tripId, forKey: .tripId)
        try container.encodeIfPresent(evidence.captureUserId, forKey: .captureUserId)
        try container.encode(evidence.captureButtonName, forKey: .captureButtonName)
        try container.encode(evidence.captureMode, forKey: .captureMode)
        try container.encodeIfPresent(evidence.supportedPaddockId, forKey: .supportedPaddockId)
        try container.encodeIfPresent(evidence.supportedDrivingRow, forKey: .supportedDrivingRow)
        try container.encodeIfPresent(evidence.supportedPinRow, forKey: .supportedPinRow)
        try container.encodeIfPresent(evidence.supportedPinSide, forKey: .supportedPinSide)
        try container.encodeIfPresent(evidence.supportedSnappedLatitude, forKey: .supportedSnappedLatitude)
        try container.encodeIfPresent(evidence.supportedSnappedLongitude, forKey: .supportedSnappedLongitude)
        try container.encodeIfPresent(evidence.supportedAlongRowDistanceM, forKey: .supportedAlongRowDistanceM)
        try container.encodeIfPresent(evidence.aisleLock, forKey: .aisleLock)
        try container.encode(Array(evidence.observations.suffix(16)), forKey: .observations)
        try container.encode(evidence.captureProvenance, forKey: .captureProvenance)
        try container.encodeIfPresent(evidence.geometryRevision, forKey: .geometryRevision)
        try container.encodeIfPresent(evidence.geometryHash, forKey: .geometryHash)
    }
}

nonisolated enum PinCaptureEvidenceDeliveryError: LocalizedError, Sendable {
    case immutableConflict
    var errorDescription: String? { "Capture evidence conflicts with the immutable server copy and remains queued for review." }
}

@MainActor
final class PinCaptureEvidenceStore {
    static let shared = PinCaptureEvidenceStore()
    private let persistence: PersistenceStore
    private let key = "vinetrack_pin_capture_evidence_v2"
    private let recoveryKey = "vinetrack_pin_capture_evidence_recovery_v2"
    private(set) var records: [PinCaptureEvidence]

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        let primary: [PinCaptureEvidence] = persistence.load(key: key) ?? []
        let recovery: [PinCaptureEvidence] = Self.loadRecovery(key: recoveryKey)
        self.records = Dictionary((primary + recovery).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.capturedAt < $1.capturedAt }
    }

    func save(_ evidence: PinCaptureEvidence) throws {
        var next = records.filter { $0.id != evidence.id }
        next.append(evidence)
        do {
            try persistence.saveOrThrow(next, key: key)
            Self.clearRecovery(key: recoveryKey)
        } catch {
            try Self.saveRecovery(next, key: recoveryKey)
        }
        records = next
    }

    func markUploaded(_ ids: Set<String>) throws {
        let next = records.map { record -> PinCaptureEvidence in
            guard ids.contains(record.id) else { return record }
            var copy = record
            copy.isUploaded = true
            return copy
        }
        try persistence.saveOrThrow(next, key: key)
        Self.clearRecovery(key: recoveryKey)
        records = next
    }

    func evidence(pinId: UUID) -> PinCaptureEvidence? {
        records.filter { $0.pinId == pinId }.max { $0.evidenceRevision < $1.evidenceRevision }
    }

    var pending: [PinCaptureEvidence] { records.filter { !$0.isUploaded } }

    private nonisolated static func saveRecovery(_ records: [PinCaptureEvidence], key: String) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try encoder.encode(records), forKey: key)
        guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }

    private nonisolated static func loadRecovery(key: String) -> [PinCaptureEvidence] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PinCaptureEvidence].self, from: data)) ?? []
    }

    private nonisolated static func clearRecovery(key: String) { UserDefaults.standard.removeObject(forKey: key) }
}

/// Identity-specific, durable optional confirmation operation.
nonisolated struct PendingPinLocationConfirmation: Codable, Sendable, Identifiable {
    let id: UUID
    let pinId: UUID
    let vineyardId: UUID
    let evidenceRevision: Int
    let expectedSyncVersion: Int?
    let paddockId: UUID
    let drivingRow: Double
    let pinRow: Double
    let pinSide: String
    let snappedLatitude: Double
    let snappedLongitude: Double
    let alongRowDistanceM: Double
}

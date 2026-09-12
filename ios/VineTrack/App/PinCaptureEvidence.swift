import CryptoKit
import Foundation

/// Immutable, durable evidence captured with an automatic pin. Derived server
/// placement may change; this observation never does.
nonisolated struct PinCaptureEvidence: Codable, Sendable, Identifiable {
    nonisolated struct Observation: Codable, Sendable {
        let observedAt: Date
        let latitude: Double
        let longitude: Double
        let horizontalAccuracyM: Double
    }

    let pinId: UUID
    let vineyardId: UUID
    let evidenceRevision: Int
    let resolverVersion: String
    let capturedAt: Date
    let locationObservedAt: Date
    let rawLatitude: Double
    let rawLongitude: Double
    let horizontalAccuracyM: Double
    let headingDegrees: Double?
    let headingSource: String?
    let headingObservedAt: Date?
    let pressedSide: String?
    let tripId: UUID?
    let supportedPaddockId: UUID?
    let supportedDrivingRow: Double?
    let supportedPinRow: Double?
    let supportedPinSide: String?
    let supportedSnappedLatitude: Double?
    let supportedSnappedLongitude: Double?
    let supportedAlongRowDistanceM: Double?
    let observations: [Observation]
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
        case supportedPaddockId = "supported_paddock_id"
        case supportedDrivingRow = "supported_driving_row"
        case supportedPinRow = "supported_pin_row"
        case supportedPinSide = "supported_pin_side"
        case supportedSnappedLatitude = "supported_snapped_latitude"
        case supportedSnappedLongitude = "supported_snapped_longitude"
        case supportedAlongRowDistanceM = "supported_along_row_distance_m"
        case observations
        case captureProvenance = "capture_provenance"
        case geometryRevision = "geometry_revision"
        case geometryHash = "geometry_hash"
        case isUploaded
    }

    func uploadPayload() -> PinCaptureEvidenceUpload {
        PinCaptureEvidenceUpload(evidence: self)
    }

    static func geometryIdentity(for paddock: Paddock?) -> (revision: String?, hash: String?) {
        guard let paddock,
              let data = try? JSONEncoder().encode(paddock) else { return (nil, nil) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (digest, digest)
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
        try container.encode(evidence.horizontalAccuracyM, forKey: .horizontalAccuracyM)
        try container.encodeIfPresent(evidence.headingDegrees, forKey: .headingDegrees)
        try container.encodeIfPresent(evidence.headingSource, forKey: .headingSource)
        try container.encodeIfPresent(evidence.headingObservedAt, forKey: .headingObservedAt)
        try container.encodeIfPresent(evidence.pressedSide, forKey: .pressedSide)
        try container.encodeIfPresent(evidence.tripId, forKey: .tripId)
        try container.encodeIfPresent(evidence.supportedPaddockId, forKey: .supportedPaddockId)
        try container.encodeIfPresent(evidence.supportedDrivingRow, forKey: .supportedDrivingRow)
        try container.encodeIfPresent(evidence.supportedPinRow, forKey: .supportedPinRow)
        try container.encodeIfPresent(evidence.supportedPinSide, forKey: .supportedPinSide)
        try container.encodeIfPresent(evidence.supportedSnappedLatitude, forKey: .supportedSnappedLatitude)
        try container.encodeIfPresent(evidence.supportedSnappedLongitude, forKey: .supportedSnappedLongitude)
        try container.encodeIfPresent(evidence.supportedAlongRowDistanceM, forKey: .supportedAlongRowDistanceM)
        try container.encode(Array(evidence.observations.suffix(16)), forKey: .observations)
        try container.encode(evidence.captureProvenance, forKey: .captureProvenance)
        try container.encodeIfPresent(evidence.geometryRevision, forKey: .geometryRevision)
        try container.encodeIfPresent(evidence.geometryHash, forKey: .geometryHash)
    }
}

@MainActor
final class PinCaptureEvidenceStore {
    static let shared = PinCaptureEvidenceStore()
    private let persistence: PersistenceStore
    private let key = "vinetrack_pin_capture_evidence_v1"
    private(set) var records: [PinCaptureEvidence]

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.records = persistence.load(key: key) ?? []
    }

    func save(_ evidence: PinCaptureEvidence) throws {
        var next = records.filter { $0.id != evidence.id }
        next.append(evidence)
        try persistence.saveOrThrow(next, key: key)
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
        records = next
    }

    var pending: [PinCaptureEvidence] { records.filter { !$0.isUploaded } }
}

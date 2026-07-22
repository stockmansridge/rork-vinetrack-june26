import Foundation
import CoreLocation

nonisolated struct SampleSite: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var paddockId: UUID
    var paddockName: String
    var rowNumber: Int
    var latitude: Double
    var longitude: Double
    var siteIndex: Int
    var bunchCountEntry: BunchCountEntry?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isRecorded: Bool {
        bunchCountEntry != nil
    }

    init(
        id: UUID = UUID(),
        paddockId: UUID,
        paddockName: String = "",
        rowNumber: Int,
        latitude: Double,
        longitude: Double,
        siteIndex: Int,
        bunchCountEntry: BunchCountEntry? = nil
    ) {
        self.id = id
        self.paddockId = paddockId
        self.paddockName = paddockName
        self.rowNumber = rowNumber
        self.latitude = latitude
        self.longitude = longitude
        self.siteIndex = siteIndex
        self.bunchCountEntry = bunchCountEntry
    }
}

nonisolated struct BunchCountEntry: Codable, Sendable, Hashable {
    var bunchesPerVine: Double
    var recordedAt: Date
    var recordedBy: String

    init(
        bunchesPerVine: Double,
        recordedAt: Date = Date(),
        recordedBy: String = ""
    ) {
        self.bunchesPerVine = bunchesPerVine
        self.recordedAt = recordedAt
        self.recordedBy = recordedBy
    }
}

nonisolated struct YieldEstimationSession: Codable, Identifiable, Sendable {
    let id: UUID
    var vineyardId: UUID
    var createdAt: Date
    var selectedPaddockIds: [UUID]
    var samplesPerHectare: Int
    var sampleSites: [SampleSite]
    var blockBunchWeightsKg: [UUID: Double]
    var previousBunchWeights: [BunchWeightRecord]
    var pathWaypoints: [CoordinatePoint]
    var isCompleted: Bool
    var completedAt: Date?

    var averageBunchWeightKg: Double {
        guard !blockBunchWeightsKg.isEmpty else { return 0.15 }
        return blockBunchWeightsKg.values.reduce(0, +) / Double(blockBunchWeightsKg.count)
    }

    func bunchWeightKg(for paddockId: UUID) -> Double {
        blockBunchWeightsKg[paddockId] ?? 0.15
    }

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        createdAt: Date = Date(),
        selectedPaddockIds: [UUID] = [],
        samplesPerHectare: Int = 20,
        sampleSites: [SampleSite] = [],
        blockBunchWeightsKg: [UUID: Double] = [:],
        previousBunchWeights: [BunchWeightRecord] = [],
        pathWaypoints: [CoordinatePoint] = [],
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.createdAt = createdAt
        self.selectedPaddockIds = selectedPaddockIds
        self.samplesPerHectare = samplesPerHectare
        self.sampleSites = sampleSites
        self.blockBunchWeightsKg = blockBunchWeightsKg
        self.previousBunchWeights = previousBunchWeights
        self.pathWaypoints = pathWaypoints
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, createdAt, selectedPaddockIds, samplesPerHectare
        case sampleSites, blockBunchWeightsKg, averageBunchWeightKg
        case previousBunchWeights, pathWaypoints, isCompleted, completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        selectedPaddockIds = try container.decodeIfPresent([UUID].self, forKey: .selectedPaddockIds) ?? []
        samplesPerHectare = try container.decodeIfPresent(Int.self, forKey: .samplesPerHectare) ?? 20
        sampleSites = try container.decodeIfPresent([SampleSite].self, forKey: .sampleSites) ?? []
        previousBunchWeights = try container.decodeIfPresent([BunchWeightRecord].self, forKey: .previousBunchWeights) ?? []
        pathWaypoints = try container.decodeIfPresent([CoordinatePoint].self, forKey: .pathWaypoints) ?? []
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)

        if let perBlock = try? container.decode([UUID: Double].self, forKey: .blockBunchWeightsKg) {
            blockBunchWeightsKg = perBlock
        } else if let legacy = try? container.decode(Double.self, forKey: .averageBunchWeightKg) {
            var weights: [UUID: Double] = [:]
            for pid in selectedPaddockIds {
                weights[pid] = legacy
            }
            blockBunchWeightsKg = weights
        } else {
            blockBunchWeightsKg = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(vineyardId, forKey: .vineyardId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(selectedPaddockIds, forKey: .selectedPaddockIds)
        try container.encode(samplesPerHectare, forKey: .samplesPerHectare)
        try container.encode(sampleSites, forKey: .sampleSites)
        try container.encode(blockBunchWeightsKg, forKey: .blockBunchWeightsKg)
        try container.encode(previousBunchWeights, forKey: .previousBunchWeights)
        try container.encode(pathWaypoints, forKey: .pathWaypoints)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

nonisolated struct BunchWeightRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var date: Date
    var weightKg: Double

    init(id: UUID = UUID(), date: Date = Date(), weightKg: Double = 0.15) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
    }
}

nonisolated struct BlockYieldEstimate: Sendable {
    let paddockId: UUID
    let paddockName: String
    let areaHectares: Double
    let totalVines: Int
    let averageBunchesPerVine: Double
    let totalBunches: Double
    let averageBunchWeightKg: Double
    let damageFactor: Double
    let estimatedYieldKg: Double
    let estimatedYieldTonnes: Double
    let samplesRecorded: Int
    let samplesTotal: Int
    let damageRecords: [DamageRecord]
}

nonisolated enum DamageType: String, Codable, Sendable, CaseIterable, Hashable {
    case frost = "Frost"
    case hail = "Hail"
    case wind = "Wind"
    case heat = "Heat"
    case disease = "Disease"
    case pest = "Pest"
    case other = "Other"

    var icon: String {
        switch self {
        case .frost: "snowflake"
        case .hail: "cloud.hail.fill"
        case .wind: "wind"
        case .heat: "sun.max.fill"
        case .disease: "allergens"
        case .pest: "ladybug.fill"
        case .other: "exclamationmark.triangle.fill"
        }
    }
}

nonisolated struct DamageRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var paddockId: UUID
    var polygonPoints: [CoordinatePoint]
    var date: Date
    var damageType: DamageType
    var damagePercent: Double
    var notes: String

    // Portal-facing fields (Phase 048 — additive). These are populated by the
    // Lovable web portal and round-tripped through sync. iOS does not edit them
    // yet, so they remain optional and are only encoded when set.
    var rowNumber: Int?
    var side: String?
    var severity: String?
    var status: String?
    var dateObserved: Date?
    var operatorName: String?
    var latitude: Double?
    var longitude: Double?
    var pinId: UUID?
    var tripId: UUID?
    var photoUrls: [String]?

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        paddockId: UUID,
        polygonPoints: [CoordinatePoint] = [],
        date: Date = Date(),
        damageType: DamageType = .frost,
        damagePercent: Double = 20,
        notes: String = "",
        rowNumber: Int? = nil,
        side: String? = nil,
        severity: String? = nil,
        status: String? = nil,
        dateObserved: Date? = nil,
        operatorName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        pinId: UUID? = nil,
        tripId: UUID? = nil,
        photoUrls: [String]? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.polygonPoints = polygonPoints
        self.date = date
        self.damageType = damageType
        self.damagePercent = damagePercent
        self.notes = notes
        self.rowNumber = rowNumber
        self.side = side
        self.severity = severity
        self.status = status
        self.dateObserved = dateObserved
        self.operatorName = operatorName
        self.latitude = latitude
        self.longitude = longitude
        self.pinId = pinId
        self.tripId = tripId
        self.photoUrls = photoUrls
    }

    var areaHectares: Double {
        let points = polygonPoints
        guard points.count >= 3 else { return 0 }
        let centroidLat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        var area = 0.0
        let n = points.count
        for i in 0..<n {
            let j = (i + 1) % n
            let xi = points[i].longitude * mPerDegLon
            let yi = points[i].latitude * mPerDegLat
            let xj = points[j].longitude * mPerDegLon
            let yj = points[j].latitude * mPerDegLat
            area += xi * yj - xj * yi
        }
        area = abs(area) / 2.0
        return area / 10_000.0
    }
}

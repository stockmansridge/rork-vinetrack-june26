import Foundation
import CoreLocation

nonisolated struct Paddock: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var polygonPoints: [CoordinatePoint]
    var rows: [PaddockRow]
    var rowDirection: Double
    var rowWidth: Double
    var rowOffset: Double
    var vineSpacing: Double
    var vineCountOverride: Int?
    var rowLengthOverride: Double?
    var flowPerEmitter: Double?
    var emitterSpacing: Double?
    var intermediatePostSpacing: Double?
    var varietyAllocations: [PaddockVarietyAllocation]
    var budburstDate: Date?
    var floweringDate: Date?
    var veraisonDate: Date?
    var harvestDate: Date?
    var plantingYear: Int?
    var calculationModeOverride: GDDCalculationMode?
    var resetModeOverride: GDDResetMode?

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        polygonPoints: [CoordinatePoint] = [],
        rows: [PaddockRow] = [],
        rowDirection: Double = 0,
        rowWidth: Double = 2.5,
        rowOffset: Double = 0,
        vineSpacing: Double = 1.0,
        vineCountOverride: Int? = nil,
        rowLengthOverride: Double? = nil,
        flowPerEmitter: Double? = nil,
        emitterSpacing: Double? = nil,
        intermediatePostSpacing: Double? = nil,
        varietyAllocations: [PaddockVarietyAllocation] = [],
        budburstDate: Date? = nil,
        floweringDate: Date? = nil,
        veraisonDate: Date? = nil,
        harvestDate: Date? = nil,
        plantingYear: Int? = nil,
        calculationModeOverride: GDDCalculationMode? = nil,
        resetModeOverride: GDDResetMode? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.polygonPoints = polygonPoints
        self.rows = rows
        self.rowDirection = rowDirection
        self.rowWidth = rowWidth
        self.rowOffset = rowOffset
        self.vineSpacing = vineSpacing
        self.vineCountOverride = vineCountOverride
        self.rowLengthOverride = rowLengthOverride
        self.flowPerEmitter = flowPerEmitter
        self.emitterSpacing = emitterSpacing
        self.intermediatePostSpacing = intermediatePostSpacing
        self.varietyAllocations = varietyAllocations
        self.budburstDate = budburstDate
        self.floweringDate = floweringDate
        self.veraisonDate = veraisonDate
        self.harvestDate = harvestDate
        self.plantingYear = plantingYear
        self.calculationModeOverride = calculationModeOverride
        self.resetModeOverride = resetModeOverride
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, polygonPoints, rows, rowDirection, rowWidth, rowOffset, vineSpacing, vineCountOverride, rowLengthOverride, flowPerEmitter, emitterSpacing, intermediatePostSpacing, varietyAllocations, budburstDate, floweringDate, veraisonDate, harvestDate, plantingYear, calculationModeOverride, resetModeOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = try container.decode(String.self, forKey: .name)
        polygonPoints = try container.decode([CoordinatePoint].self, forKey: .polygonPoints)
        rows = try container.decode([PaddockRow].self, forKey: .rows)
        rowDirection = try container.decode(Double.self, forKey: .rowDirection)
        rowWidth = try container.decodeIfPresent(Double.self, forKey: .rowWidth) ?? 2.5
        rowOffset = try container.decodeIfPresent(Double.self, forKey: .rowOffset) ?? 0
        vineSpacing = try container.decodeIfPresent(Double.self, forKey: .vineSpacing) ?? 1.0
        vineCountOverride = try container.decodeIfPresent(Int.self, forKey: .vineCountOverride)
        rowLengthOverride = try container.decodeIfPresent(Double.self, forKey: .rowLengthOverride)
        flowPerEmitter = try container.decodeIfPresent(Double.self, forKey: .flowPerEmitter)
        emitterSpacing = try container.decodeIfPresent(Double.self, forKey: .emitterSpacing)
        intermediatePostSpacing = try container.decodeIfPresent(Double.self, forKey: .intermediatePostSpacing)
        varietyAllocations = try container.decodeIfPresent([PaddockVarietyAllocation].self, forKey: .varietyAllocations) ?? []
        budburstDate = try container.decodeIfPresent(Date.self, forKey: .budburstDate)
        floweringDate = try container.decodeIfPresent(Date.self, forKey: .floweringDate)
        veraisonDate = try container.decodeIfPresent(Date.self, forKey: .veraisonDate)
        harvestDate = try container.decodeIfPresent(Date.self, forKey: .harvestDate)
        plantingYear = try container.decodeIfPresent(Int.self, forKey: .plantingYear)
        calculationModeOverride = try container.decodeIfPresent(GDDCalculationMode.self, forKey: .calculationModeOverride)
        resetModeOverride = try container.decodeIfPresent(GDDResetMode.self, forKey: .resetModeOverride)
    }
}

nonisolated struct CoordinatePoint: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(id: UUID = UUID(), latitude: Double, longitude: Double) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
    }

    init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    enum CodingKeys: String, CodingKey { case id, latitude, longitude }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate polygon points written by external systems (e.g. the
        // Lovable web portal) that omit the synthetic `id` field.
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.latitude = try c.decode(Double.self, forKey: .latitude)
        self.longitude = try c.decode(Double.self, forKey: .longitude)
    }
}

extension Paddock {
    func effectiveCalculationMode(defaultMode: GDDCalculationMode) -> GDDCalculationMode {
        calculationModeOverride ?? defaultMode
    }

    func effectiveResetMode(defaultMode: GDDResetMode) -> GDDResetMode {
        resetModeOverride ?? defaultMode
    }

    func resetDate(for mode: GDDResetMode, seasonStart: Date) -> Date? {
        switch mode {
        case .seasonStart: return seasonStart
        case .budburst: return budburstDate
        case .flowering: return floweringDate
        case .veraison: return veraisonDate
        }
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

    var rowSpacingMetres: Double { rowWidth }

    var totalRowLengthMetres: Double {
        let mPerDegLat = 111_320.0
        let centroidLat = polygonPoints.isEmpty ? 0 : polygonPoints.map(\.latitude).reduce(0, +) / Double(polygonPoints.count)
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        return rows.reduce(0.0) { total, row in
            let dLat = (row.endPoint.latitude - row.startPoint.latitude) * mPerDegLat
            let dLon = (row.endPoint.longitude - row.startPoint.longitude) * mPerDegLon
            return total + sqrt(dLat * dLat + dLon * dLon)
        }
    }

    var effectiveTotalRowLength: Double {
        rowLengthOverride ?? totalRowLengthMetres
    }

    var estimatedVineCount: Int {
        guard vineSpacing > 0 else { return 0 }
        return Int(effectiveTotalRowLength / vineSpacing)
    }

    var effectiveVineCount: Int {
        vineCountOverride ?? estimatedVineCount
    }

    var emittersPerHectare: Double? {
        guard let emitterSpacing, emitterSpacing > 0, rowWidth > 0 else { return nil }
        return 10_000.0 / (rowWidth * emitterSpacing)
    }

    var litresPerHaPerHour: Double? {
        guard let flowPerEmitter, let emittersPerHa = emittersPerHectare else { return nil }
        return emittersPerHa * flowPerEmitter
    }

    var mlPerHaPerHour: Double? {
        guard let litres = litresPerHaPerHour else { return nil }
        return litres / 1_000_000.0
    }

    var mmPerHour: Double? {
        guard let ml = mlPerHaPerHour else { return nil }
        return ml * 100.0
    }

    var litresPerHour: Double? {
        guard let emitterSpacing, emitterSpacing > 0,
              let flowPerEmitter, flowPerEmitter > 0,
              !rows.isEmpty else { return nil }
        return (effectiveTotalRowLength / emitterSpacing) * flowPerEmitter
    }

    var totalEmitters: Int? {
        guard let emitterSpacing, emitterSpacing > 0 else { return nil }
        return Int(effectiveTotalRowLength / emitterSpacing)
    }

    var intermediatePostCount: Int? {
        guard let spacing = intermediatePostSpacing, spacing > 0 else { return nil }
        let total = effectiveTotalRowLength
        guard total > 0 else { return nil }
        let rawPosts = Int(total / spacing)
        let endPosts = 2 * rows.count
        return max(0, rawPosts - endPosts)
    }

    var litresPerVinePerHour: Double? {
        guard let flowPerEmitter, let emitterSpacing, emitterSpacing > 0, vineSpacing > 0 else { return nil }
        let emittersPerVine = vineSpacing / emitterSpacing
        return emittersPerVine * flowPerEmitter
    }
}

nonisolated struct PaddockRow: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var number: Int
    var startPoint: CoordinatePoint
    var endPoint: CoordinatePoint

    init(
        id: UUID = UUID(),
        number: Int,
        startPoint: CoordinatePoint,
        endPoint: CoordinatePoint
    ) {
        self.id = id
        self.number = number
        self.startPoint = startPoint
        self.endPoint = endPoint
    }
}

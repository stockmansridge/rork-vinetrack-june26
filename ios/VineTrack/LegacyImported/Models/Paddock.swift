import CoreLocation
import CryptoKit
import Foundation

nonisolated struct Paddock: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var polygonPoints: [CoordinatePoint]
    var rows: [PaddockRow]
    var rowDirection: Double
    /// Raw stored row spacing. `nil` means NO row spacing has ever been
    /// entered for this block — which is NOT the same as 2.5 m.
    ///
    /// Prefer `authoritativeRowSpacingMetres` for anything that doses a tank,
    /// derives L/ha or computes a treated area. Use `rowWidth` for legacy
    /// spatial work (row guidance, trip corridors, map previews) where a
    /// nominal fallback is harmless.
    var rowWidthRaw: Double?
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
        rowWidth: Double? = Paddock.nominalRowSpacingMetres,
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
        self.rowWidthRaw = rowWidth
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
        case id, vineyardId, name, polygonPoints, rows, rowDirection, rowOffset, vineSpacing, vineCountOverride, rowLengthOverride, flowPerEmitter, emitterSpacing, intermediatePostSpacing, varietyAllocations, budburstDate, floweringDate, veraisonDate, harvestDate, plantingYear, calculationModeOverride, resetModeOverride
        // Persisted under its historical key so stored JSON is unchanged.
        case rowWidthRaw = "rowWidth"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = try container.decode(String.self, forKey: .name)
        polygonPoints = try container.decode([CoordinatePoint].self, forKey: .polygonPoints)
        rows = try container.decode([PaddockRow].self, forKey: .rows)
        rowDirection = try container.decode(Double.self, forKey: .rowDirection)
        // NO `?? 2.5` — absence is preserved so calculation-critical callers can
        // tell "never entered" from "deliberately 2.5 m".
        rowWidthRaw = try container.decodeIfPresent(Double.self, forKey: .rowWidthRaw)
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

    /// Nominal row spacing used ONLY as a legacy display/spatial fallback.
    /// Never used by spray, carrier-volume or treated-area arithmetic.
    static let nominalRowSpacingMetres: Double = 2.5

    /// Legacy row spacing accessor. Always returns a number, falling back to
    /// `nominalRowSpacingMetres` when none was ever entered.
    ///
    /// Preserved verbatim so existing spatial consumers (row guidance, trip
    /// corridor tolerances, map previews, pin de-duplication) keep their
    /// current behaviour. Writing through it records an explicit value.
    var rowWidth: Double {
        get { rowWidthRaw ?? Paddock.nominalRowSpacingMetres }
        set { rowWidthRaw = newValue }
    }

    /// Row spacing ONLY when it is genuinely known, otherwise `nil`.
    ///
    /// This is the accessor every calculation-critical path must use. A block
    /// with no spacing entered returns `nil` here while `rowWidth` would
    /// silently answer 2.5 m.
    var authoritativeRowSpacingMetres: Double? {
        guard let value = rowWidthRaw, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// True when the operator has explicitly entered a row spacing.
    var hasAuthoritativeRowSpacing: Bool { authoritativeRowSpacingMetres != nil }

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

    /// Legacy effective row length: operator override wins over mapped rows.
    ///
    /// This precedence is INTENTIONAL and is now the canonical one — see
    /// `SprayGeometryResolver`, which agrees with it. Retained as the
    /// convenience accessor for irrigation, vine counts and pruning; spray
    /// goes through the canonical resolver so it also gets the derived and
    /// incomplete tiers this property cannot express (it returns 0).
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

    // MARK: - Per-row vine counts (sql/188)

    /// Length of ONE row in metres, using the same equirectangular
    /// approximation as `totalRowLengthMetres`.
    func rowLengthMetres(_ row: PaddockRow) -> Double {
        let mPerDegLat = 111_320.0
        let centroidLat = polygonPoints.isEmpty
            ? row.startPoint.latitude
            : polygonPoints.map(\.latitude).reduce(0, +) / Double(polygonPoints.count)
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let dLat = (row.endPoint.latitude - row.startPoint.latitude) * mPerDegLat
        let dLon = (row.endPoint.longitude - row.startPoint.longitude) * mPerDegLon
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// The AUTOMATIC calculation for one row, carrying its reason when the
    /// block can't produce a number yet. Never reads any override.
    func vineCountCalculation(for row: PaddockRow) -> PaddockRowVineCount.Calculation {
        PaddockRowVineCount.calculation(
            rowLengthMetres: rowLengthMetres(row),
            vineSpacing: vineSpacing
        )
    }

    /// The AUTOMATICALLY calculated vine count for one row: this row's own
    /// length ÷ the block's vine spacing, rounded. Nil when the block has no
    /// usable vine spacing or the row has no usable geometry — never 0.
    func calculatedVineCount(for row: PaddockRow) -> Int? {
        vineCountCalculation(for: row).value
    }

    /// THE vine count to use for this row: the manual override when set,
    /// otherwise the calculated estimate (sql/188). Nil only when neither
    /// exists.
    func effectiveVineCount(for row: PaddockRow) -> Int? {
        PaddockRowVineCount.effective(
            override: row.vineCountOverride,
            rowLengthMetres: rowLengthMetres(row),
            vineSpacing: vineSpacing
        )
    }

    /// Σ of every row's effective vine count. This is the row-driven total used
    /// by piece-rate costing — NOT a replacement for the block-level
    /// `vineCountOverride`, which keeps its existing meaning and consumers.
    /// Rows with no calculable count contribute nothing rather than a guess.
    var rowsEffectiveVineCount: Int {
        rows.reduce(0) { $0 + (effectiveVineCount(for: $1) ?? 0) }
    }

    /// True when at least one row carries a manual per-row count.
    var hasRowVineCountOverrides: Bool {
        rows.contains { $0.vineCountOverride != nil }
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
    /// MANUAL vine count for THIS row (sql/188). Optional by contract: rows
    /// written before the field existed, and rows the operator never overrode,
    /// simply omit the key and keep using the calculated estimate.
    ///
    /// Independent of the BLOCK-level `Paddock.vineCountOverride`, which stays
    /// the block total used by water / spray / fertiliser / yield estimates.
    /// Read this through `Paddock.effectiveVineCount(for:)`, never directly.
    var vineCountOverride: Int?

    init(
        id: UUID = UUID(),
        number: Int,
        startPoint: CoordinatePoint,
        endPoint: CoordinatePoint,
        vineCountOverride: Int? = nil
    ) {
        self.id = id
        self.number = number
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.vineCountOverride = vineCountOverride
    }

    enum CodingKeys: String, CodingKey { case id, number, startPoint, endPoint, vineCountOverride }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        startPoint = try c.decode(CoordinatePoint.self, forKey: .startPoint)
        endPoint = try c.decode(CoordinatePoint.self, forKey: .endPoint)
        // Tolerate rows written without an `id` (older Android builds and
        // external systems stripped it). The fallback is DETERMINISTIC from
        // the row's content, so every device derives the identical id and
        // pruning progress keyed on it stays consistent across platforms.
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id))
            ?? PaddockRowIdentity.derive(number: number, startPoint: startPoint, endPoint: endPoint)
        // Only a whole POSITIVE count is a real override — 0, negatives and
        // junk decode as "no override" rather than poisoning the estimate.
        vineCountOverride = PaddockRowVineCount.sanitiseOverride(
            try? c.decodeIfPresent(Int.self, forKey: .vineCountOverride)
        )
    }

    /// Encodes the override ONLY when set, so untouched rows keep the exact
    /// JSON shape older clients and the portal already parse.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(number, forKey: .number)
        try c.encode(startPoint, forKey: .startPoint)
        try c.encode(endPoint, forKey: .endPoint)
        try c.encodeIfPresent(vineCountOverride, forKey: .vineCountOverride)
    }
}

/// Deterministic fallback identity for paddock rows stored without an `id`.
/// Matches Java's `UUID.nameUUIDFromBytes` (MD5, version 3) so the Kotlin app
/// derives byte-identical ids from the same row content.
nonisolated enum PaddockRowIdentity {
    static func derive(number: Int, startPoint: CoordinatePoint?, endPoint: CoordinatePoint?) -> UUID {
        func fmt(_ value: Double?) -> String {
            guard let value else { return "" }
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let name = "vinetrack-paddock-row|\(number)|\(fmt(startPoint?.latitude))|\(fmt(startPoint?.longitude))|\(fmt(endPoint?.latitude))|\(fmt(endPoint?.longitude))"
        var bytes = Array(Insecure.MD5.hash(data: Data(name.utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

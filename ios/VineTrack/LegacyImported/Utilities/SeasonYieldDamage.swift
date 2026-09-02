import Foundation

/// Area-weighted seasonal damage engine — the shared cross-platform contract
/// documented in `docs/season-yield-damage-parity-fixtures.md` and mirrored by
/// `SeasonYieldDamage.kt` on Android.
///
/// This REPLACES the old multiplicative `MigratedDataStore.damageFactor(for:)`,
/// which compounded every record's percentage over the whole block and so
/// turned "20% intensity over 10% of the block" into a 20% block loss instead
/// of the correct 2%.
///
/// The contract, per block:
///
/// ```text
/// effective_loss_ha          = mapped_area_ha × pct ÷ 100      (per record)
/// block_effective_loss_ha    = Σ effective_loss_ha
/// damage_loss_fraction       = min(1, block_effective_loss_ha ÷ block_area_ha)
/// remaining_yield_multiplier = 1 − damage_loss_fraction
/// adjusted_estimate_t        = base_t × remaining_yield_multiplier
/// ```
///
/// Naming matters: the retired `damageFactor` was a REMAINING-yield number
/// (0.8 = 80% survives) while ``BlockDamage/damageLossFraction`` is the LOSS
/// (0.02 = 2% lost). The two are complements, so reading one under the other's
/// name inverts the answer. Both are named explicitly here and no
/// `damageFactor` is exposed.
nonisolated enum SeasonYieldDamage {

    // MARK: - Warning codes (shared with Android and the SQL contract)

    /// A damage record was excluded because its polygon is missing or invalid.
    static let warningRecordWithoutPolygon = "damage_record_without_polygon"
    /// The block has no usable area, so no loss fraction can be computed.
    static let warningBlockAreaUnavailable = "block_area_unavailable"

    // MARK: - Inputs

    nonisolated struct Point: Sendable, Hashable {
        let latitude: Double
        let longitude: Double

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// A damage record reduced to just what the engine needs. Callers filter
    /// by vineyard AND vintage before building these.
    nonisolated struct Record: Sendable, Identifiable, Hashable {
        let id: UUID
        let paddockId: UUID
        /// Intensity WITHIN the mapped polygon, 0...100.
        let damagePercent: Double
        let polygon: [Point]

        init(id: UUID, paddockId: UUID, damagePercent: Double, polygon: [Point]) {
            self.id = id
            self.paddockId = paddockId
            self.damagePercent = damagePercent
            self.polygon = polygon
        }
    }

    // MARK: - Outputs

    /// One block's damage verdict. `damageLossFraction` and
    /// `remainingYieldMultiplier` are complements and always both present.
    nonisolated struct BlockDamage: Sendable, Equatable {
        let paddockId: UUID
        /// nil when the block has no usable area (never assume 0% or 100%).
        let blockAreaHectares: Double?
        let eligibleRecordCount: Int
        let excludedRecordCount: Int
        let mappedAreaHectares: Double
        let effectiveLossHectares: Double
        /// 0...1, the share of the block's crop lost.
        let damageLossFraction: Double
        /// 0...1, the share that survives. Always `1 − damageLossFraction`.
        let remainingYieldMultiplier: Double
        let warnings: [String]

        /// True when the engine could not compute a loss for this block, so
        /// callers must show base figures only.
        var isAreaUnavailable: Bool { blockAreaHectares == nil }

        /// Tonnes lost from a base estimate.
        func reductionTonnes(base: Double) -> Double { base * damageLossFraction }

        /// Base tonnes after damage. Never negative.
        func adjustedTonnes(base: Double) -> Double { base * remainingYieldMultiplier }

        static func undamaged(paddockId: UUID, blockAreaHectares: Double?, warnings: [String] = []) -> BlockDamage {
            BlockDamage(
                paddockId: paddockId,
                blockAreaHectares: blockAreaHectares,
                eligibleRecordCount: 0,
                excludedRecordCount: 0,
                mappedAreaHectares: 0,
                effectiveLossHectares: 0,
                damageLossFraction: 0,
                remainingYieldMultiplier: 1,
                warnings: warnings
            )
        }
    }

    // MARK: - Polygon validity

    /// A polygon contributes area only when it encloses one and every vertex is
    /// a real coordinate. Validated BEFORE any area maths so a bad shape can
    /// never produce a nonsense hectare figure.
    ///
    /// Requires: at least 3 points; every latitude and longitude finite;
    /// latitude within −90...90; longitude within −180...180.
    static func isValidPolygon(_ polygon: [Point]) -> Bool {
        guard polygon.count >= 3 else { return false }
        for point in polygon {
            guard point.latitude.isFinite, point.longitude.isFinite else { return false }
            guard point.latitude >= -90, point.latitude <= 90 else { return false }
            guard point.longitude >= -180, point.longitude <= 180 else { return false }
        }
        return true
    }

    /// Polygon area in hectares — the same local equirectangular projection as
    /// `Paddock.areaHectares`, `RowInfrastructureCalculator.areaHectares` and
    /// the SQL `_paddock_polygon_area_hectares` (sql/095). Invalid polygons
    /// return 0; callers must check ``isValidPolygon(_:)`` first so an
    /// exclusion is reported rather than silently counted as zero loss.
    static func areaHectares(polygon: [Point]) -> Double {
        guard isValidPolygon(polygon) else { return 0 }
        let count = Double(polygon.count)
        let centroidLatitude = polygon.reduce(0.0) { $0 + $1.latitude } / count
        let metresPerDegreeLatitude = 111_320.0
        let metresPerDegreeLongitude = 111_320.0 * cos(centroidLatitude * .pi / 180.0)
        var doubleArea = 0.0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            let xi = polygon[i].longitude * metresPerDegreeLongitude
            let yi = polygon[i].latitude * metresPerDegreeLatitude
            let xj = polygon[j].longitude * metresPerDegreeLongitude
            let yj = polygon[j].latitude * metresPerDegreeLatitude
            doubleArea += xi * yj - xj * yi
        }
        return abs(doubleArea) / 2.0 / 10_000.0
    }

    // MARK: - The engine

    /// One eligible record reduced to the two numbers the arithmetic needs.
    nonisolated struct MappedRecord: Sendable, Equatable {
        let areaHectares: Double
        let damagePercent: Double

        init(areaHectares: Double, damagePercent: Double) {
            self.areaHectares = areaHectares
            self.damagePercent = damagePercent
        }
    }

    /// Damage for ONE block. `records` must already be filtered to this block,
    /// this vineyard and this vintage.
    ///
    /// - Parameter blockAreaHectares: the block's own area. A non-positive or
    ///   non-finite value means "unknown": the result carries
    ///   ``warningBlockAreaUnavailable`` and a zero loss fraction so callers
    ///   show base figures rather than inventing a 0% or 100% loss.
    static func blockDamage(
        paddockId: UUID,
        blockAreaHectares: Double,
        records: [Record]
    ) -> BlockDamage {
        var mapped: [MappedRecord] = []
        var excluded = 0

        for record in records where record.paddockId == paddockId {
            // Validity is checked BEFORE any area maths, so a bad shape can
            // never contribute a nonsense hectare figure.
            guard isValidPolygon(record.polygon) else {
                excluded += 1
                continue
            }
            let area = areaHectares(polygon: record.polygon)
            guard area.isFinite, area > 0 else {
                excluded += 1
                continue
            }
            mapped.append(MappedRecord(areaHectares: area, damagePercent: record.damagePercent))
        }

        return blockDamage(
            paddockId: paddockId,
            blockAreaHectares: blockAreaHectares,
            mappedRecords: mapped,
            excludedRecordCount: excluded
        )
    }

    /// The pure arithmetic core, taking mapped areas directly.
    ///
    /// Separated from the polygon path on purpose: with areas supplied this is
    /// exact arithmetic that every platform must reproduce to `1e-9`, whereas
    /// polygon→hectares conversion only agrees to a practical tolerance. A
    /// failing test then names its own cause.
    static func blockDamage(
        paddockId: UUID,
        blockAreaHectares: Double,
        mappedRecords: [MappedRecord],
        excludedRecordCount: Int = 0
    ) -> BlockDamage {
        var warnings: [String] = []
        var mappedArea = 0.0
        var effectiveLoss = 0.0
        var eligible = 0
        let excluded = excludedRecordCount

        for record in mappedRecords {
            guard record.areaHectares.isFinite, record.areaHectares > 0 else { continue }
            let percent = record.damagePercent.isFinite
                ? min(100, max(0, record.damagePercent))
                : 0
            eligible += 1
            mappedArea += record.areaHectares
            effectiveLoss += record.areaHectares * percent / 100.0
        }

        if excluded > 0 { warnings.append(warningRecordWithoutPolygon) }

        guard blockAreaHectares.isFinite, blockAreaHectares > 0 else {
            warnings.append(warningBlockAreaUnavailable)
            return BlockDamage(
                paddockId: paddockId,
                blockAreaHectares: nil,
                eligibleRecordCount: eligible,
                excludedRecordCount: excluded,
                mappedAreaHectares: mappedArea,
                effectiveLossHectares: effectiveLoss,
                damageLossFraction: 0,
                remainingYieldMultiplier: 1,
                warnings: warnings
            )
        }

        // Cap at 100%: a block can never lose more than its whole crop, so the
        // remaining multiplier never goes below 0 and adjusted tonnes never
        // go negative.
        let lossFraction = min(1.0, max(0.0, effectiveLoss / blockAreaHectares))

        return BlockDamage(
            paddockId: paddockId,
            blockAreaHectares: blockAreaHectares,
            eligibleRecordCount: eligible,
            excludedRecordCount: excluded,
            mappedAreaHectares: mappedArea,
            effectiveLossHectares: effectiveLoss,
            damageLossFraction: lossFraction,
            remainingYieldMultiplier: 1.0 - lossFraction,
            warnings: warnings
        )
    }

    /// Damage for every block in one pass, keyed by paddock id.
    ///
    /// Each block is calculated independently — a vineyard-wide loss fraction
    /// is never computed, and block fractions are never blended.
    static func blockDamage(
        blockAreas: [UUID: Double],
        records: [Record]
    ) -> [UUID: BlockDamage] {
        let byBlock = Dictionary(grouping: records, by: \.paddockId)
        var result: [UUID: BlockDamage] = [:]
        result.reserveCapacity(blockAreas.count)
        for (paddockId, area) in blockAreas {
            result[paddockId] = blockDamage(
                paddockId: paddockId,
                blockAreaHectares: area,
                records: byBlock[paddockId] ?? []
            )
        }
        return result
    }
}

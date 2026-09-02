package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.Paddock
import kotlin.math.abs
import kotlin.math.cos

/**
 * Area-weighted seasonal damage engine — the shared cross-platform contract in
 * `docs/season-yield-damage-parity-fixtures.md`, mirrored by
 * `SeasonYieldDamage.swift` on iOS.
 *
 * This REPLACES the old multiplicative `List<DamageRecord>.damageFactor(...)`,
 * which compounded every record's percentage over the whole block and so turned
 * "20% intensity over 10% of the block" into a 20% block loss instead of the
 * correct 2%.
 *
 * Per block:
 * ```text
 * effective_loss_ha          = mapped_area_ha × pct ÷ 100      (per record)
 * block_effective_loss_ha    = Σ effective_loss_ha
 * damage_loss_fraction       = min(1, block_effective_loss_ha ÷ block_area_ha)
 * remaining_yield_multiplier = 1 − damage_loss_fraction
 * adjusted_estimate_t        = base_t × remaining_yield_multiplier
 * ```
 *
 * Naming matters: the retired `damageFactor` was a REMAINING-yield number
 * (0.8 = 80% survives) while [BlockDamage.damageLossFraction] is the LOSS
 * (0.02 = 2% lost). They are complements, so reading one under the other's name
 * inverts the answer. Both are named explicitly and no `damageFactor` survives.
 */
object SeasonYieldDamage {

    /** A damage record was excluded because its polygon is missing or invalid. */
    const val WARNING_RECORD_WITHOUT_POLYGON = "damage_record_without_polygon"

    /** The block has no usable area, so no loss fraction can be computed. */
    const val WARNING_BLOCK_AREA_UNAVAILABLE = "block_area_unavailable"

    private const val METRES_PER_DEGREE_LATITUDE = 111_320.0

    /** One eligible record reduced to the two numbers the arithmetic needs. */
    data class MappedRecord(
        val areaHectares: Double,
        val damagePercent: Double,
    )

    /**
     * One block's damage verdict. [damageLossFraction] and
     * [remainingYieldMultiplier] are complements and always both present.
     */
    data class BlockDamage(
        val paddockId: String,
        /** null when the block has no usable area — never assume 0% or 100%. */
        val blockAreaHectares: Double?,
        val eligibleRecordCount: Int,
        val excludedRecordCount: Int,
        val mappedAreaHectares: Double,
        val effectiveLossHectares: Double,
        /** 0..1, the share of the block's crop lost. */
        val damageLossFraction: Double,
        /** 0..1, the share that survives. Always `1 − damageLossFraction`. */
        val remainingYieldMultiplier: Double,
        val warnings: List<String>,
    ) {
        /** True when no loss could be computed, so callers show base figures. */
        val isAreaUnavailable: Boolean get() = blockAreaHectares == null

        /** Tonnes removed from a base estimate. */
        fun reductionTonnes(base: Double): Double = base * damageLossFraction

        /** Base tonnes after damage. Never negative. */
        fun adjustedTonnes(base: Double): Double = base * remainingYieldMultiplier

        companion object {
            fun undamaged(paddockId: String, blockAreaHectares: Double?): BlockDamage =
                BlockDamage(
                    paddockId = paddockId,
                    blockAreaHectares = blockAreaHectares,
                    eligibleRecordCount = 0,
                    excludedRecordCount = 0,
                    mappedAreaHectares = 0.0,
                    effectiveLossHectares = 0.0,
                    damageLossFraction = 0.0,
                    remainingYieldMultiplier = 1.0,
                    warnings = emptyList(),
                )
        }
    }

    /**
     * A polygon contributes area only when it encloses one and every vertex is a
     * real coordinate. Validated BEFORE any area maths so a bad shape can never
     * produce a nonsense hectare figure.
     *
     * Requires: at least 3 points; every latitude and longitude finite; latitude
     * within −90..90; longitude within −180..180.
     */
    fun isValidPolygon(polygon: List<CoordinatePoint>?): Boolean {
        if (polygon == null || polygon.size < 3) return false
        return polygon.all { point ->
            point.latitude.isFinite() &&
                point.longitude.isFinite() &&
                point.latitude >= -90.0 && point.latitude <= 90.0 &&
                point.longitude >= -180.0 && point.longitude <= 180.0
        }
    }

    /**
     * Polygon area in hectares — the same local equirectangular projection as
     * `Paddock.areaHectares` and the SQL `_paddock_polygon_area_hectares`
     * (sql/095). Invalid polygons return 0; callers must check [isValidPolygon]
     * first so an exclusion is reported rather than silently counted as zero.
     */
    fun areaHectares(polygon: List<CoordinatePoint>?): Double {
        if (!isValidPolygon(polygon)) return 0.0
        val points = polygon ?: return 0.0
        val centroidLatitude = points.sumOf { it.latitude } / points.size
        val metresPerDegreeLongitude =
            METRES_PER_DEGREE_LATITUDE * cos(centroidLatitude * Math.PI / 180.0)
        var doubleArea = 0.0
        val n = points.size
        for (i in 0 until n) {
            val j = (i + 1) % n
            val xi = points[i].longitude * metresPerDegreeLongitude
            val yi = points[i].latitude * METRES_PER_DEGREE_LATITUDE
            val xj = points[j].longitude * metresPerDegreeLongitude
            val yj = points[j].latitude * METRES_PER_DEGREE_LATITUDE
            doubleArea += xi * yj - xj * yi
        }
        return abs(doubleArea) / 2.0 / 10_000.0
    }

    /**
     * Damage for ONE block from its damage records. [records] must already be
     * filtered to this block, this vineyard and this vintage.
     *
     * A non-positive or non-finite [blockAreaHectares] means "unknown": the
     * result carries [WARNING_BLOCK_AREA_UNAVAILABLE] and a zero loss fraction
     * so callers show base figures rather than inventing a 0% or 100% loss.
     */
    fun blockDamage(
        paddockId: String,
        blockAreaHectares: Double,
        records: List<DamageRecord>,
    ): BlockDamage {
        val mapped = mutableListOf<MappedRecord>()
        var excluded = 0

        for (record in records) {
            if (!record.paddockId.equals(paddockId, ignoreCase = true)) continue
            // Validity is checked BEFORE any area maths, so a bad shape can
            // never contribute a nonsense hectare figure.
            if (!isValidPolygon(record.polygonPoints)) {
                excluded++
                continue
            }
            val area = areaHectares(record.polygonPoints)
            if (!area.isFinite() || area <= 0.0) {
                excluded++
                continue
            }
            mapped += MappedRecord(areaHectares = area, damagePercent = record.damagePercent)
        }

        return blockDamage(
            paddockId = paddockId,
            blockAreaHectares = blockAreaHectares,
            mappedRecords = mapped,
            excludedRecordCount = excluded,
        )
    }

    /**
     * The pure arithmetic core, taking mapped areas directly.
     *
     * Separated from the polygon path on purpose: with areas supplied this is
     * exact arithmetic every platform must reproduce to `1e-9`, whereas
     * polygon→hectares conversion only agrees to a practical tolerance. A
     * failing test then names its own cause.
     */
    fun blockDamage(
        paddockId: String,
        blockAreaHectares: Double,
        mappedRecords: List<MappedRecord>,
        excludedRecordCount: Int = 0,
    ): BlockDamage {
        val warnings = mutableListOf<String>()
        var mappedArea = 0.0
        var effectiveLoss = 0.0
        var eligible = 0

        for (record in mappedRecords) {
            if (!record.areaHectares.isFinite() || record.areaHectares <= 0.0) continue
            val percent = if (record.damagePercent.isFinite()) {
                record.damagePercent.coerceIn(0.0, 100.0)
            } else {
                0.0
            }
            eligible++
            mappedArea += record.areaHectares
            effectiveLoss += record.areaHectares * percent / 100.0
        }

        if (excludedRecordCount > 0) warnings += WARNING_RECORD_WITHOUT_POLYGON

        if (!blockAreaHectares.isFinite() || blockAreaHectares <= 0.0) {
            warnings += WARNING_BLOCK_AREA_UNAVAILABLE
            return BlockDamage(
                paddockId = paddockId,
                blockAreaHectares = null,
                eligibleRecordCount = eligible,
                excludedRecordCount = excludedRecordCount,
                mappedAreaHectares = mappedArea,
                effectiveLossHectares = effectiveLoss,
                damageLossFraction = 0.0,
                remainingYieldMultiplier = 1.0,
                warnings = warnings,
            )
        }

        // Cap at 100%: a block can never lose more than its whole crop, so the
        // remaining multiplier never goes below 0 and adjusted tonnes never go
        // negative.
        val lossFraction = (effectiveLoss / blockAreaHectares).coerceIn(0.0, 1.0)

        return BlockDamage(
            paddockId = paddockId,
            blockAreaHectares = blockAreaHectares,
            eligibleRecordCount = eligible,
            excludedRecordCount = excludedRecordCount,
            mappedAreaHectares = mappedArea,
            effectiveLossHectares = effectiveLoss,
            damageLossFraction = lossFraction,
            remainingYieldMultiplier = 1.0 - lossFraction,
            warnings = warnings,
        )
    }
}

/**
 * Share of a block's crop that SURVIVES recorded damage (0..1), where 1.0 means
 * undamaged.
 *
 * Deliberately not called `damageFactor`: the retired name was read by some
 * callers as the loss and by others as the remainder, and the two are
 * complements. Records must already be scoped to the block's vintage.
 */
fun List<DamageRecord>.remainingYieldMultiplier(
    paddockId: String,
    blockAreaHectares: Double,
): Double = SeasonYieldDamage.blockDamage(
    paddockId = paddockId,
    blockAreaHectares = blockAreaHectares,
    records = this,
).remainingYieldMultiplier

/**
 * Surviving share for a block in ONE vintage, resolving the block's own area
 * from [blocks].
 *
 * The convenience the screens need: damage must be scoped to the vintage being
 * displayed (an older season's frost must never reduce this season's estimate)
 * and weighted by the block's area (a mapped 0.2 ha at 20% is a 2% loss on a
 * 2 ha block, not a 20% one).
 */
fun List<DamageRecord>.remainingYieldMultiplierForVintage(
    paddockId: String,
    blocks: List<Paddock>,
    vintage: Int,
    seasonStartMonth: Int,
    seasonStartDay: Int,
): Double = blockDamageForVintage(
    paddockId = paddockId,
    blocks = blocks,
    vintage = vintage,
    seasonStartMonth = seasonStartMonth,
    seasonStartDay = seasonStartDay,
).remainingYieldMultiplier

/** Full damage verdict for a block in ONE vintage. */
fun List<DamageRecord>.blockDamageForVintage(
    paddockId: String,
    blocks: List<Paddock>,
    vintage: Int,
    seasonStartMonth: Int,
    seasonStartDay: Int,
): SeasonYieldDamage.BlockDamage {
    val area = blocks
        .firstOrNull { it.id.equals(paddockId, ignoreCase = true) }
        ?.areaHectares
        ?: 0.0
    val scoped = filter { record ->
        record.paddockId.equals(paddockId, ignoreCase = true) &&
            record.resolvedVintage(seasonStartMonth, seasonStartDay) == vintage
    }
    return SeasonYieldDamage.blockDamage(
        paddockId = paddockId,
        blockAreaHectares = area,
        records = scoped,
    )
}

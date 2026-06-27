package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.cos

/**
 * Seasonal block-damage event (frost, hail, wind, etc.), mirroring the iOS
 * `DamageRecord` and the `damage_records` backend table. A polygon drawn on the
 * block map captures the affected zone; `damagePercent` is the operator's
 * estimate of crop loss within that zone. Used by the Yields hub to surface
 * per-block viability and overall yield impact.
 *
 * JSON keys mirror the Supabase columns so rows round-trip with iOS/portal. The
 * portal-only additive columns (row number, side, severity, …) are decoded so we
 * never lose them, but Android does not edit them yet.
 */
@Serializable
data class DamageRecord(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String,
    /** ISO-8601 timestamp the damage occurred / was observed. */
    val date: String? = null,
    @SerialName("damage_type") val damageType: String = "Frost",
    @SerialName("damage_percent") val damagePercent: Double = 0.0,
    @SerialName("polygon_points") val polygonPoints: List<CoordinatePoint>? = null,
    val notes: String = "",
    // Portal extension (sql/048) — additive optional columns, preserved on read.
    @SerialName("row_number") val rowNumber: Int? = null,
    val side: String? = null,
    val severity: String? = null,
    val status: String? = null,
    @SerialName("date_observed") val dateObserved: String? = null,
    @SerialName("operator_name") val operatorName: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    @SerialName("pin_id") val pinId: String? = null,
    @SerialName("trip_id") val tripId: String? = null,
    @SerialName("photo_urls") val photoUrls: List<String>? = null,
) {
    /** Resolved damage type, tolerant of portal label variants (matches iOS). */
    val type: DamageType get() = DamageType.normalize(damageType)

    /** Polygon area in hectares (equirectangular projection — matches iOS). */
    val areaHectares: Double
        get() {
            val points = polygonPoints ?: return 0.0
            if (points.size < 3) return 0.0
            val centroidLat = points.map { it.latitude }.average()
            val mPerDegLat = 111_320.0
            val mPerDegLon = 111_320.0 * cos(centroidLat * Math.PI / 180.0)
            var area = 0.0
            val n = points.size
            for (i in 0 until n) {
                val j = (i + 1) % n
                val xi = points[i].longitude * mPerDegLon
                val yi = points[i].latitude * mPerDegLat
                val xj = points[j].longitude * mPerDegLon
                val yj = points[j].latitude * mPerDegLat
                area += xi * yj - xj * yi
            }
            return abs(area) / 2.0 / 10_000.0
        }
}

/**
 * Categories of crop damage, mirroring the iOS `DamageType`. `label` is the
 * canonical string persisted to `damage_records.damage_type` (capitalised, as
 * iOS writes it).
 */
enum class DamageType(val label: String) {
    Frost("Frost"),
    Hail("Hail"),
    Wind("Wind"),
    Heat("Heat"),
    Disease("Disease"),
    Pest("Pest"),
    Other("Other");

    companion object {
        /** Map any case / portal label to the closest type so a row always renders. */
        fun normalize(raw: String?): DamageType {
            if (raw.isNullOrBlank()) return Other
            entries.firstOrNull { it.label.equals(raw, ignoreCase = false) }?.let { return it }
            return when (raw.lowercase().trim()) {
                "frost" -> Frost
                "hail" -> Hail
                "wind" -> Wind
                "heat", "sunburn", "heat / sunburn", "heat/sunburn" -> Heat
                "disease" -> Disease
                "pest", "animal / bird damage", "animal/bird damage", "animal damage", "bird damage" -> Pest
                else -> Other
            }
        }
    }
}

/**
 * Cumulative viability factor (0..1) for a block based on its damage records.
 * Each record compounds the remaining viability by its damage percent
 * (matches iOS `damageFactor(for:)`).
 */
fun List<DamageRecord>.damageFactor(paddockId: String): Double {
    val records = filter { it.paddockId == paddockId }
    if (records.isEmpty()) return 1.0
    var factor = 1.0
    for (record in records) {
        val pct = record.damagePercent.coerceIn(0.0, 100.0) / 100.0
        factor *= (1.0 - pct)
    }
    return factor.coerceIn(0.0, 1.0)
}

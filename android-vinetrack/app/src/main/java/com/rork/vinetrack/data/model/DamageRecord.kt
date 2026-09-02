package com.rork.vinetrack.data.model

import com.rork.vinetrack.data.VintageResolver
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.LocalDate
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
    /**
     * Vineyard-local season this damage belongs to, resolved SERVER-side
     * (`damage_records.vintage`, sql/221) from `date_observed ?: date` in the
     * vineyard's own timezone.
     *
     * Clients must filter damage by this value rather than by a locally
     * recomputed season — see [resolvedVintage] for the offline fallback used
     * before a newly created record has synced.
     */
    val vintage: Int? = null,
) {
    /** Resolved damage type, tolerant of portal label variants (matches iOS). */
    val type: DamageType get() = DamageType.normalize(damageType)

    /**
     * The vintage this record must be filtered by.
     *
     * Prefers the server-resolved [vintage]. Only when that is absent (a record
     * created offline that has not synced yet) does it fall back to the local
     * season resolver over `dateObserved ?: date` — the same input the server
     * uses.
     */
    fun resolvedVintage(seasonStartMonth: Int, seasonStartDay: Int): Int {
        vintage?.let { return it }
        val iso = (dateObserved ?: date)?.take(10)
        return if (iso.isNullOrBlank()) {
            VintageResolver.vintageYear(LocalDate.now(), seasonStartMonth, seasonStartDay)
        } else {
            VintageResolver.vintageYearForIsoDate(iso, seasonStartMonth, seasonStartDay)
        }
    }

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

// The old multiplicative `List<DamageRecord>.damageFactor(paddockId)` lived
// here. It compounded every record's percentage over the WHOLE block, turning
// "20% intensity over 10% of the block" into a 20% block loss instead of the
// correct 2%, and its name meant the opposite of what half its callers assumed.
//
// It is replaced by the area-weighted contract in
// `com.rork.vinetrack.data.SeasonYieldDamage` — use
// `SeasonYieldDamage.blockDamage(...)` for the full verdict, or the
// `List<DamageRecord>.remainingYieldMultiplier(paddockId, blockAreaHectares)`
// extension for just the surviving share. Both need the block's own area, which
// is the input the old function was missing.

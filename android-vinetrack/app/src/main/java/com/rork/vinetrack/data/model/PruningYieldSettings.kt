package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.Locale

/**
 * Shared per-block Pruning Yield Calculator configuration — backs
 * `public.pruning_yield_settings` (sql/181). ONE record per vineyard block,
 * upserted on the (vineyard_id, paddock_id) unique key so two devices that
 * minted different row ids for the same block converge on a single record.
 *
 * Only the INPUT ASSUMPTIONS are persisted. Every calculated output
 * (buds/vine, bunches/ha, yield kg/ha, yield t/ha, block total tonnes) is
 * derived with [PruningYieldFormula] so results can never go stale.
 */
@Serializable
data class PruningYieldSettings(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String,
    /** Canonical lowercase `spur` | `cane` (matches the SQL contract). */
    @SerialName("prune_method") val pruneMethod: String = PruningYieldDefaults.PRUNE_METHOD,
    @SerialName("bunches_per_bud") val bunchesPerBud: Double = PruningYieldDefaults.BUNCHES_PER_BUD,
    @SerialName("buds_per_spur") val budsPerSpur: Double = PruningYieldDefaults.BUDS_PER_SPUR,
    @SerialName("spurs_per_vine") val spursPerVine: Double = PruningYieldDefaults.SPURS_PER_VINE,
    @SerialName("buds_per_cane") val budsPerCane: Double = PruningYieldDefaults.BUDS_PER_CANE,
    @SerialName("canes_per_vine") val canesPerVine: Double = PruningYieldDefaults.CANES_PER_VINE,
    /** Null = not set; clients seed it from the block's vine count ÷ area. */
    @SerialName("vines_per_ha") val vinesPerHa: Double? = null,
    @SerialName("bunch_weight_grams") val bunchWeightGrams: Double = PruningYieldDefaults.BUNCH_WEIGHT_GRAMS,
    @SerialName("deleted_at") val deletedAt: String? = null,
    /**
     * Server-issued revision (sql/198). SERVER STATE, not an editable input — which is why
     * [inputsEqual] ignores it: a revision change is not an edit and must never make an
     * autosave look dirty.
     *
     * Null means the server has never issued one for this block: created offline, or a row
     * that predates revisions. Legitimate state, never treated as corruption, and never
     * filled with a fabricated number.
     */
    @SerialName("server_revision") val serverRevision: Long? = null,
) {
    /**
     * Value equality on the user-editable inputs only (identity/timestamps
     * ignored). Used to skip no-op autosaves.
     */
    fun inputsEqual(other: PruningYieldSettings): Boolean =
        pruneMethod == other.pruneMethod &&
            bunchesPerBud == other.bunchesPerBud &&
            budsPerSpur == other.budsPerSpur &&
            spursPerVine == other.spursPerVine &&
            budsPerCane == other.budsPerCane &&
            canesPerVine == other.canesPerVine &&
            vinesPerHa == other.vinesPerHa &&
            bunchWeightGrams == other.bunchWeightGrams
}

/**
 * Canonical defaults for an unsaved block — identical on iOS, Android and
 * the SQL column defaults (sql/181).
 */
object PruningYieldDefaults {
    const val PRUNE_METHOD = "spur"
    const val BUNCHES_PER_BUD = 1.5
    const val BUDS_PER_SPUR = 2.0
    const val SPURS_PER_VINE = 6.0
    const val BUDS_PER_CANE = 10.0
    const val CANES_PER_VINE = 4.0
    const val BUNCH_WEIGHT_GRAMS = 120.0
}

/**
 * The shared Pruning Yield Calculator formula — byte-identical to the iOS
 * `YieldDeterminationFormula` so the same inputs return the same result on
 * both platforms (asserted by the shared parity test vectors).
 */
object PruningYieldFormula {
    /** Spur: buds/spur × spurs/vine. Cane: buds/cane × canes/vine. */
    fun budsPerVine(
        pruneMethod: String,
        budsPerSpur: Double,
        spursPerVine: Double,
        budsPerCane: Double,
        canesPerVine: Double,
    ): Double = if (pruneMethod == "cane") budsPerCane * canesPerVine else budsPerSpur * spursPerVine

    /** bunches/ha = bunches/bud × buds/vine × vines/ha. */
    fun bunchesPerHectare(bunchesPerBud: Double, budsPerVine: Double, vinesPerHa: Double): Double =
        bunchesPerBud * budsPerVine * vinesPerHa

    /** kg/ha = bunches/ha × bunch weight (g) ÷ 1000. */
    fun yieldKgPerHectare(bunchesPerHa: Double, bunchWeightGrams: Double): Double =
        bunchesPerHa * bunchWeightGrams / 1000.0

    /** t/ha = kg/ha ÷ 1000. */
    fun yieldTonnesPerHectare(yieldKgPerHa: Double): Double = yieldKgPerHa / 1000.0

    /** Block total tonnes = t/ha × area (ha); null when area ≤ 0. */
    fun totalYieldTonnes(yieldTonnesPerHa: Double, areaHectares: Double): Double? =
        if (areaHectares > 0) yieldTonnesPerHa * areaHectares else null
}

/**
 * Text <-> number conversion shared by the calculator UI and the legacy
 * migration — same convention as iOS `PruningYieldInputFormat` so "1.5",
 * "2" and "120" round-trip identically (dot decimal, trailing zeros trimmed,
 * "," accepted as a decimal separator on parse).
 */
object PruningYieldInputFormat {
    fun parse(text: String): Double = text.replace(',', '.').toDoubleOrNull() ?: 0.0

    fun parseOptional(text: String): Double? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        return trimmed.replace(',', '.').toDoubleOrNull()
    }

    fun text(value: Double?): String {
        if (value == null) return ""
        return if (value == kotlin.math.floor(value) && kotlin.math.abs(value) < 1_000_000_000) {
            String.format(Locale.US, "%.0f", value)
        } else {
            String.format(Locale.US, "%.4f", value).trimEnd('0').trimEnd('.')
        }
    }
}

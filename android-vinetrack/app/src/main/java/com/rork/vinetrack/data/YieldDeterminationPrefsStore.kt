package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Per-block inputs for the Yield Determination calculator, mirroring the iOS
 * `YieldDeterminationCalculatorView` UserDefaults persistence. Inputs are saved
 * per paddock so each block remembers its pruning configuration, and the most
 * recent computed t/ha is stored vineyard-wide so the Yields hub can surface a
 * "Latest" detail just like iOS. Device-local only — never synced.
 */
data class YieldDeterminationInputs(
    val pruneMethod: String = "Spur",
    val bunchesPerBud: String = "1.5",
    val budsPerSpur: String = "2",
    val spursPerVine: String = "6",
    val budsPerCane: String = "10",
    val canesPerVine: String = "4",
    val vinesPerHa: String = "",
    val bunchWeight: String = "120",
)

class YieldDeterminationPrefsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_yield_determination", Context.MODE_PRIVATE)

    fun loadInputs(paddockId: String?): YieldDeterminationInputs? {
        val id = paddockId ?: return null
        if (!prefs.contains("$id$KEY_PRUNE")) return null
        return YieldDeterminationInputs(
            pruneMethod = prefs.getString("$id$KEY_PRUNE", "Spur") ?: "Spur",
            bunchesPerBud = prefs.getString("$id$KEY_BPB", "1.5") ?: "1.5",
            budsPerSpur = prefs.getString("$id$KEY_BPS", "2") ?: "2",
            spursPerVine = prefs.getString("$id$KEY_SPV", "6") ?: "6",
            budsPerCane = prefs.getString("$id$KEY_BPC", "10") ?: "10",
            canesPerVine = prefs.getString("$id$KEY_CPV", "4") ?: "4",
            vinesPerHa = prefs.getString("$id$KEY_VPH", "") ?: "",
            bunchWeight = prefs.getString("$id$KEY_BW", "120") ?: "120",
        )
    }

    fun saveInputs(paddockId: String?, inputs: YieldDeterminationInputs) {
        val id = paddockId ?: return
        prefs.edit {
            putString("$id$KEY_PRUNE", inputs.pruneMethod)
            putString("$id$KEY_BPB", inputs.bunchesPerBud)
            putString("$id$KEY_BPS", inputs.budsPerSpur)
            putString("$id$KEY_SPV", inputs.spursPerVine)
            putString("$id$KEY_BPC", inputs.budsPerCane)
            putString("$id$KEY_CPV", inputs.canesPerVine)
            putString("$id$KEY_VPH", inputs.vinesPerHa)
            putString("$id$KEY_BW", inputs.bunchWeight)
        }
    }

    /** Most recently saved determination yield (t/ha), surfaced on the hub. */
    fun latestTonnesPerHa(): Double? {
        if (!prefs.contains(KEY_LATEST_TPH)) return null
        return prefs.getFloat(KEY_LATEST_TPH, 0f).toDouble()
    }

    fun saveLatestResult(tonnesPerHa: Double) {
        prefs.edit {
            putFloat(KEY_LATEST_TPH, tonnesPerHa.toFloat())
            putLong(KEY_LATEST_AT, System.currentTimeMillis())
        }
    }

    fun latestSavedAtMs(): Long? = prefs.getLong(KEY_LATEST_AT, 0L).takeIf { it > 0L }

    private companion object {
        const val KEY_PRUNE = "_prune"
        const val KEY_BPB = "_bpb"
        const val KEY_BPS = "_bps"
        const val KEY_SPV = "_spv"
        const val KEY_BPC = "_bpc"
        const val KEY_CPV = "_cpv"
        const val KEY_VPH = "_vph"
        const val KEY_BW = "_bw"
        const val KEY_LATEST_TPH = "latest_tonnes_per_ha"
        const val KEY_LATEST_AT = "latest_saved_at"
    }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.spray.SprayProgramCalculatorInputs
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray

/** Cache-only envelope: Program metadata must never become spray_records REST columns. */
@Serializable
internal data class SprayProgramTemplateCache(
    val record: SprayRecord,
    val inputs: SprayProgramCalculatorInputs? = null,
    val growthStageCode: String? = null,
    val chemicalLines: JsonArray? = null,
) {
    fun restored(): SprayRecord = record.copy(programCalculatorInputs = inputs, prefillCanopy = inputs?.canopy,
        templateGrowthStageCode = growthStageCode, templateChemicalLines = chemicalLines)

    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        fun encode(records: List<SprayRecord>): String = json.encodeToString(records.map {
            SprayProgramTemplateCache(it, it.programCalculatorInputs, it.templateGrowthStageCode, it.templateChemicalLines)
        })
        fun decode(raw: String): List<SprayRecord> = runCatching {
            json.decodeFromString<List<SprayProgramTemplateCache>>(raw).map { it.restored() }
        }.getOrElse {
            // Previous caches contained record arrays; no missing inputs are invented on upgrade.
            json.decodeFromString<List<SprayRecord>>(raw)
        }
    }
}

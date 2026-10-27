package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.YieldEstimationSession
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Server resolution only; historical trip weights and device preferences are never authority. */
@Serializable
data class YieldMasterWeight(
    @SerialName("bunch_weight_grams") val bunchWeightGrams: Double? = null,
    val source: String,
    @SerialName("record_id") val recordId: String? = null,
    @SerialName("variety_key") val varietyKey: String? = null,
) {
    val kg: Double? get() = bunchWeightGrams?.takeIf {
        it.isFinite() && it > 0 && recordId != null && source in listOf("block_override", "variety_default")
    }?.div(1000)
    val sourceLabel: String get() = when (source) {
        "block_override" -> "Block override"
        "variety_default" -> "Vineyard variety master"
        else -> "Not configured"
    }
}

object CurrentYieldEstimate {
    data class Planting(val key: String, val name: String, val share: Double)
    data class Block(
        val paddockId: String, val name: String, val varieties: String,
        val samplesRecorded: Int, val samplesTotal: Int, val averageBunches: Double?,
        val vines: Int, val sampledAreaHa: Double, val weightKg: Double?,
        val weightSources: List<String>, val historicalWeightKg: Double?,
        val baseTonnes: Double?, val adjustedTonnes: Double?, val displayTonnes: Double?,
    ) {
        val tonnesPerHa: Double? get() = displayTonnes?.takeIf { sampledAreaHa > 0 }?.div(sampledAreaHa)
    }
    data class Trip(val blocks: List<Block>, val sampledAreaHa: Double, val totalTonnes: Double?) {
        val tonnesPerHa: Double? get() = totalTonnes?.takeIf { sampledAreaHa > 0 }?.div(sampledAreaHa)
    }
    fun key(blockId: String, varietyKey: String) = blockId.lowercase() + "|" + varietyKey.trim().lowercase()
    fun plantings(paddock: Paddock): List<Planting> = paddock.varietyAllocations.orEmpty()
        .filter { (it.displayPercent ?: 0.0) > 0 && it.displayPercent?.isFinite() == true }.map {
            val name = it.displayName ?: "Unknown variety"
            // Only absent stored keys permit a legacy name-derived key.
            val canonical = it.varietyKey?.trim()?.takeIf(String::isNotEmpty)?.lowercase()
            Planting(canonical ?: name.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter(String::isNotEmpty).joinToString("_"), name, it.displayPercent ?: 0.0)
        }
    fun block(session: YieldEstimationSession, paddock: Paddock, weights: Map<String, YieldMasterWeight>, remaining: Double = 1.0): Block {
        val sites = session.sitesIn(paddock.id)
        val counts = sites.mapNotNull { it.bunchCountEntry?.bunchesPerVine }
        val average = counts.takeIf { it.isNotEmpty() && it.all { count -> count.isFinite() && count >= 0 } }?.average()
        val plantings = plantings(paddock)
        val share = plantings.sumOf { it.share }
        val resolved = plantings.map { weights[key(paddock.id, it.key)] }
        val complete = plantings.isNotEmpty() && share > 0 && resolved.all { it?.kg != null }
        val weight = if (complete) plantings.zip(resolved).sumOf { (p, w) -> p.share / share * (w?.kg ?: 0.0) } else null
        val vines = paddock.authoritativeVineCount
        val base = average?.let { avg -> weight?.let { avg * vines * it / 1000 } }
        val adjusted = base?.times((remaining.takeIf(Double::isFinite) ?: 1.0).coerceIn(0.0, 1.0))
        return Block(paddock.id, paddock.name, plantings.joinToString(", ") { it.name }, counts.size, sites.size, average,
            vines, if (counts.isEmpty()) 0.0 else paddock.areaHectares.coerceAtLeast(0.0), weight,
            plantings.zip(resolved).map { (p, w) -> "${p.name}: ${w?.sourceLabel ?: "Not confirmed"}" },
            session.blockBunchWeightsKg.entries.firstOrNull { it.key.equals(paddock.id, true) }?.value,
            base, adjusted, if (session.applyDamage) adjusted else base)
    }
    fun trip(session: YieldEstimationSession, paddocks: List<Paddock>, weights: Map<String, YieldMasterWeight>, remaining: (String) -> Double = { 1.0 }): Trip {
        val blocks = paddocks.filter { session.isPaddockSelected(it.id) }.map { block(session, it, weights, remaining(it.id)) }
        val sampled = blocks.filter { it.samplesRecorded > 0 }
        val total = if (sampled.isEmpty() || sampled.any { it.displayTonnes == null }) null else sampled.sumOf { it.displayTonnes ?: 0.0 }
        return Trip(blocks, sampled.sumOf { it.sampledAreaHa }, total)
    }
}

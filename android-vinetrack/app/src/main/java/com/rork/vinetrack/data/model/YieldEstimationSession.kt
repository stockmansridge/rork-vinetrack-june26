package com.rork.vinetrack.data.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * A single recorded bunch-count reading for one sample site, mirroring the iOS
 * `BunchCountEntry`. Dates are carried as ISO-8601 strings to match the JSONB
 * `payload` representation written/read by iOS and the web portal.
 */
@Serializable
data class BunchCountEntry(
    val bunchesPerVine: Double,
    val recordedAt: String,
    val recordedBy: String = "",
)

/**
 * One generated vine-row sample site, mirroring the iOS `SampleSite`. A site
 * becomes "recorded" once a [bunchCountEntry] is attached. `paddockId` may be
 * an uppercase UUID when authored on iOS, so all id comparisons against Android
 * paddocks must be case-insensitive.
 */
@Serializable
data class SampleSite(
    val id: String,
    val paddockId: String,
    val paddockName: String = "",
    val rowNumber: Int,
    val latitude: Double,
    val longitude: Double,
    val siteIndex: Int,
    val bunchCountEntry: BunchCountEntry? = null,
) {
    val isRecorded: Boolean get() = bunchCountEntry != null
}

/** A previously-used average bunch weight, offered as a quick-fill (iOS parity). */
@Serializable
data class BunchWeightRecord(
    val id: String,
    val date: String,
    val weightKg: Double = 0.15,
)

/**
 * Swift encodes `[UUID: Double]` dictionaries as a FLAT JSON array of alternating
 * key/value entries (`["UUID", 0.15, "UUID", 0.20]`) because the key type is not
 * `String`/`Int`. To round-trip the `blockBunchWeightsKg` field with iOS we must
 * read/write that same array shape. We also tolerate a plain JSON object form in
 * case the web portal ever writes one.
 */
object BlockBunchWeightsSerializer : KSerializer<Map<String, Double>> {
    private val delegate = ListSerializer(JsonElement.serializer())
    override val descriptor: SerialDescriptor = delegate.descriptor

    override fun serialize(encoder: Encoder, value: Map<String, Double>) {
        val arr = buildList {
            value.forEach { (k, v) ->
                add(JsonPrimitive(k))
                add(JsonPrimitive(v))
            }
        }
        encoder.encodeSerializableValue(delegate, arr)
    }

    override fun deserialize(decoder: Decoder): Map<String, Double> {
        val jsonDecoder = decoder as? JsonDecoder ?: return emptyMap()
        return when (val element = jsonDecoder.decodeJsonElement()) {
            is JsonArray -> {
                val map = LinkedHashMap<String, Double>()
                var i = 0
                while (i + 1 < element.size) {
                    val key = element[i].jsonPrimitive.content
                    val v = element[i + 1].jsonPrimitive.doubleOrNull ?: 0.15
                    map[key] = v
                    i += 2
                }
                map
            }
            is JsonObject -> element.mapValues { it.value.jsonPrimitive.doubleOrNull ?: 0.15 }
            else -> emptyMap()
        }
    }
}

/**
 * A single working yield-estimation job for a vineyard, mirroring the iOS
 * `YieldEstimationSession`. This is the JSONB `payload` stored in the
 * `yield_estimation_sessions` table — field names are camelCase to match the
 * iOS Codable keys exactly so a session authored on either platform round-trips.
 *
 * Sample sites and their bunch counts live inline (no separate child table).
 * Ids may arrive uppercase from iOS, so [bunchWeightKg], [sitesIn] and
 * [isPaddockSelected] all compare case-insensitively.
 */
@Serializable
data class YieldEstimationSession(
    val id: String,
    val vineyardId: String,
    val createdAt: String,
    val selectedPaddockIds: List<String> = emptyList(),
    val samplesPerHectare: Int = 20,
    val sampleSites: List<SampleSite> = emptyList(),
    @Serializable(with = BlockBunchWeightsSerializer::class)
    val blockBunchWeightsKg: Map<String, Double> = emptyMap(),
    val previousBunchWeights: List<BunchWeightRecord> = emptyList(),
    val pathWaypoints: List<CoordinatePoint> = emptyList(),
    val isCompleted: Boolean = false,
    val completedAt: String? = null,
) {
    fun bunchWeightKg(paddockId: String): Double =
        blockBunchWeightsKg.entries.firstOrNull { it.key.equals(paddockId, ignoreCase = true) }?.value
            ?: 0.15

    fun sitesIn(paddockId: String): List<SampleSite> =
        sampleSites.filter { it.paddockId.equals(paddockId, ignoreCase = true) }

    fun isPaddockSelected(paddockId: String): Boolean =
        selectedPaddockIds.any { it.equals(paddockId, ignoreCase = true) }

    val recordedSiteCount: Int get() = sampleSites.count { it.isRecorded }
    val totalSiteCount: Int get() = sampleSites.size
    val hasSites: Boolean get() = sampleSites.isNotEmpty()
}

/**
 * Computed per-block estimate produced from a session's recorded samples — the
 * UI/report model (never persisted), mirroring the iOS `BlockYieldEstimate`.
 */
data class BlockYieldEstimate(
    val paddockId: String,
    val paddockName: String,
    val areaHectares: Double,
    val totalVines: Int,
    val averageBunchesPerVine: Double,
    val totalBunches: Double,
    val averageBunchWeightKg: Double,
    val damageFactor: Double,
    val estimatedYieldKg: Double,
    val estimatedYieldTonnes: Double,
    val samplesRecorded: Int,
    val samplesTotal: Int,
)

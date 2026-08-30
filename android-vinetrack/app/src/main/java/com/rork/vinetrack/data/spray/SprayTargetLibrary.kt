package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SprayRecord
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * One row of the vineyard's reusable spray-target vocabulary
 * (sql/204 `vineyard_spray_targets`). Mirrors iOS `VineyardSprayTargetRecord`.
 *
 * Built-in targets are never stored here — they are compiled into the apps.
 */
@Serializable
data class VineyardSprayTarget(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val identifier: String,
    val label: String,
    @SerialName("is_active") val isActive: Boolean = true,
) {
    val tag: SprayTargetTag get() = SprayTargetTag(identifier = identifier, label = label)
}

/**
 * Arguments for the idempotent sql/204 `create_vineyard_spray_target` RPC.
 * Keyed by a client-generated id so an offline replay returns the existing
 * canonical row instead of duplicating.
 */
@Serializable
data class VineyardSprayTargetCreateParams(
    @SerialName("p_id") val id: String,
    @SerialName("p_vineyard_id") val vineyardId: String,
    @SerialName("p_identifier") val identifier: String,
    @SerialName("p_label") val label: String,
)

/**
 * Pure scoping and merge rules for the vineyard spray-target library — the
 * Android mirror of the iOS `SprayTargetLibraryService` statics.
 *
 * Pure, because "a target created for Vineyard A is never offered in
 * Vineyard B" is the rule most worth proving, and it should not need a
 * network, a cache or a running app to prove.
 */
object SprayTargetLibrary {

    /** identifier -> wording for one vineyard, for resolving stored tags. */
    fun labels(entries: List<VineyardSprayTarget>, vineyardId: String?): Map<String, String> {
        if (vineyardId == null) return emptyMap()
        val map = mutableMapOf<String, String>()
        for (entry in entries) {
            if (entry.vineyardId == vineyardId && entry.isActive) map[entry.identifier] = entry.label
        }
        return map
    }

    /**
     * This vineyard's custom targets, sorted by wording.
     *
     * [observed] lets the caller fold in identifiers already used on the
     * vineyard's own Program Steps, so the chooser offers what the vineyard
     * demonstrably sprays for rather than only what has been formally added.
     * A real library entry's wording wins over a de-slugged approximation of
     * the same identifier.
     */
    fun customTags(
        entries: List<VineyardSprayTarget>,
        vineyardId: String?,
        observed: List<SprayTargetTag> = emptyList(),
    ): List<SprayTargetTag> {
        if (vineyardId == null) return emptyList()
        val byIdentifier = mutableMapOf<String, SprayTargetTag>()
        for (tag in observed) {
            if (tag.isCustom) byIdentifier[tag.identifier] = tag
        }
        for (entry in entries) {
            if (entry.vineyardId == vineyardId && entry.isActive) byIdentifier[entry.identifier] = entry.tag
        }
        return byIdentifier.values.sortedBy { it.label.lowercase() }
    }

    /**
     * Every custom target this vineyard's Program Steps already use — the
     * reason the chooser is useful on day one. A vineyard that has been
     * writing "Phomopsis" into its program for three seasons should not have
     * to re-type it into a library before it can reuse it.
     */
    fun observedCustomTags(
        steps: List<SprayRecord>,
        labels: Map<String, String> = emptyMap(),
    ): List<SprayTargetTag> {
        val all = steps.flatMap { record ->
            SprayTargetVocabulary.tags(
                identifiers = record.targets.orEmpty(),
                wording = null,
                labels = labels,
            )
        }
        return SprayTargetVocabulary.customs(all)
            .distinctBy { it.identifier }
            .sortedBy { it.label.lowercase() }
    }
}

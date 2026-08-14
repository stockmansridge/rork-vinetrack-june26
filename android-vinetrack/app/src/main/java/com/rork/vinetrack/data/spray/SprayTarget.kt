package com.rork.vinetrack.data.spray

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * What a spray is aimed at — the pest, disease or agronomic purpose. The Kotlin
 * twin of the Swift `SprayTarget`.
 *
 * Stored as a STABLE INTERNAL IDENTIFIER, never as display text, so the label can
 * be reworded (or localised) without orphaning historical records and without
 * breaking the future Resistance Check, which will match on these identifiers
 * rather than on strings a user typed.
 *
 * Multiple targets per spray are supported by design: a single tank commonly
 * addresses powdery and downy in one pass.
 */
@Serializable
enum class SprayTarget(val raw: String, val label: String) {
    @SerialName("powdery_mildew")
    POWDERY_MILDEW("powdery_mildew", "Powdery Mildew"),

    @SerialName("downy_mildew")
    DOWNY_MILDEW("downy_mildew", "Downy Mildew"),

    @SerialName("botrytis")
    BOTRYTIS("botrytis", "Botrytis"),

    @SerialName("weeds")
    WEEDS("weeds", "Weeds"),

    @SerialName("nutrition_biostimulant")
    NUTRITION_BIOSTIMULANT("nutrition_biostimulant", "Nutrition / Biostimulant"),

    @SerialName("other")
    OTHER("other", "Other"),
    ;

    /**
     * True for targets a fungicide resistance strategy applies to.
     *
     * This is the hook the Resistance Check will read. It deliberately lives on
     * the target rather than in the UI so the future rules engine and this flow
     * cannot disagree about which targets are resistance-relevant.
     */
    val isFungicideResistanceRelevant: Boolean
        get() = when (this) {
            POWDERY_MILDEW, DOWNY_MILDEW, BOTRYTIS -> true
            WEEDS, NUTRITION_BIOSTIMULANT, OTHER -> false
        }

    companion object {
        /**
         * Tolerant decode from stored text, so an unknown or legacy value degrades
         * to null instead of failing the record.
         */
        fun from(raw: String?): SprayTarget? {
            val value = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            entries.firstOrNull { it.raw == value }?.let { return it }
            return when (value) {
                "powdery", "pm", "powdery mildew" -> POWDERY_MILDEW
                "downy", "dm", "downy mildew" -> DOWNY_MILDEW
                "nutrition", "biostimulant", "foliar nutrition" -> NUTRITION_BIOSTIMULANT
                "weed", "herbicide" -> WEEDS
                else -> null
            }
        }

        /**
         * Stable display order for pickers on both platforms, so iOS and Android
         * present the same decisions in the same sequence.
         */
        val presentationOrder: List<SprayTarget> = listOf(
            POWDERY_MILDEW, DOWNY_MILDEW, BOTRYTIS, WEEDS, NUTRITION_BIOSTIMULANT, OTHER,
        )
    }
}

/**
 * Where the spray head is aimed for a foliar application.
 *
 * Extensible on purpose: other Australian and New Zealand terminology will be
 * added without changing the persisted shape, because this is stored as a stable
 * identifier too.
 */
@Serializable
enum class SprayHeadTarget(val raw: String, val label: String, val detail: String) {
    @SerialName("full_canopy")
    FULL_CANOPY("full_canopy", "Full Canopy", "Whole canopy, top to bottom"),

    @SerialName("bunch_line")
    BUNCH_LINE("bunch_line", "Bunch Line", "Fruit zone only"),

    @SerialName("leaf_zone")
    LEAF_ZONE("leaf_zone", "Leaf Zone", "Foliage above the fruit zone"),
    ;

    companion object {
        fun from(raw: String?): SprayHeadTarget? {
            val value = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            entries.firstOrNull { it.raw == value }?.let { return it }
            return when (value) {
                "full canopy", "canopy", "whole canopy" -> FULL_CANOPY
                "bunch line", "bunchline", "fruit zone" -> BUNCH_LINE
                "leaf zone", "leafzone", "foliage" -> LEAF_ZONE
                else -> null
            }
        }
    }
}

/**
 * The operator-facing application method. Raw values match the iOS
 * `OperationType` enum and the existing `sprayOperationTypes` strings, so the
 * stored `operation_type` column is unchanged.
 */
enum class SprayOperationType(val raw: String) {
    FOLIAR_SPRAY("Foliar Spray"),
    BANDED_SPRAY("Banded Spray"),
    SPREADER("Spreader"),
    ;

    companion object {
        fun from(raw: String?): SprayOperationType? {
            val value = raw?.trim() ?: return null
            return entries.firstOrNull { it.raw.equals(value, ignoreCase = true) }
        }
    }
}

package com.rork.vinetrack.data.insights

/**
 * The seeded Vintage Note type catalogue.
 *
 * Mirrored exactly by iOS `VintageNoteCatalog.swift` and seeded into
 * `public.vintage_note_types` by SQL 236. All three must agree on code, group,
 * label and sort order.
 *
 * ## Why the label is snapshotted onto each note
 *
 * A note type is a living record: it can be renamed, re-sorted or retired. A
 * note is a historical claim about a season and must not change meaning
 * afterwards. So every saved note stores BOTH the type id (for grouping,
 * filtering and future reporting) and a snapshot of the label as it read on
 * the day it was written. Renaming "Frost" to "Frost event" updates the
 * dropdown for new notes and leaves the 2024 vintage saying exactly what the
 * observer chose.
 */

/** A grouping heading in the note-type dropdown. */
enum class VintageNoteGroup(
    /** Stored `vintage_note_types.group_code`. */
    val code: String,
    /** Section heading shown in the picker. */
    val label: String,
    /** Group ordering. Weather leads because it is what gets recorded most. */
    val sortOrder: Int,
) {
    WEATHER("weather", "Weather and hazards", 10),
    PHENOLOGY("phenology", "Phenology and crop development", 20),
    DISEASE("disease", "Disease and pest pressure", 30),
    ACTIVITY("activity", "Major vineyard activity", 40),
    OTHER("other", "Other", 50),
    ;

    companion object {
        fun byCode(code: String?): VintageNoteGroup? = entries.firstOrNull { it.code == code }
    }
}

/** One selectable note type. */
data class VintageNoteType(
    /** Database UUID. Codes are catalogue keys, never database identities. */
    val databaseId: String? = null,
    /** Stable stored code. Null-safe identity across platforms and renames. */
    val code: String,
    val group: VintageNoteGroup,
    val label: String,
    val sortOrder: Int,
    /**
     * True for a vineyard-authored type. Custom types are scoped to a single
     * vineyard and never leak into another's dropdown.
     */
    val isCustom: Boolean = false,
    /**
     * Retired types stay readable on historical notes but are not offered for
     * new ones — retiring is never a deletion.
     */
    val isActive: Boolean = true,
    val vineyardId: String? = null,
    val isSystem: Boolean = false,
) {
    /** UUID when reconciled; stable catalogue code during first-use offline bootstrap. */
    val persistedIdentity: String get() = databaseId ?: code
}

object VintageNoteCatalog {

    /** Sentinel for the free-form entry at the end of the list. */
    const val OTHER_CUSTOM_CODE: String = "other_custom"

    /**
     * The seeded system types, in display order.
     *
     * Sort orders are spaced by 10 within each group so a later migration can
     * insert a type between two existing ones without renumbering the rest —
     * and therefore without a client and a server briefly disagreeing on order.
     */
    val systemTypes: List<VintageNoteType> = buildList {
        fun add(group: VintageNoteGroup, code: String, label: String, order: Int) {
            add(VintageNoteType(code = code, group = group, label = label, sortOrder = order, isSystem = true))
        }

        // Weather and hazards — the most commonly recorded events lead.
        add(VintageNoteGroup.WEATHER, "frost", "Frost", 10)
        add(VintageNoteGroup.WEATHER, "low_temperature", "Low temperature / cold spell", 20)
        add(VintageNoteGroup.WEATHER, "extended_dry", "Extended dry period", 30)
        add(VintageNoteGroup.WEATHER, "excessive_heat", "Excessive heat / heatwave", 40)
        add(VintageNoteGroup.WEATHER, "high_winds", "High winds", 50)
        add(VintageNoteGroup.WEATHER, "heavy_rain", "Heavy rain", 60)
        add(VintageNoteGroup.WEATHER, "extended_wet", "Extended wet period", 70)
        add(VintageNoteGroup.WEATHER, "flooding", "Flooding / waterlogging", 80)
        add(VintageNoteGroup.WEATHER, "hail", "Hail", 90)
        add(VintageNoteGroup.WEATHER, "smoke_exposure", "Smoke / bushfire exposure", 100)
        add(VintageNoteGroup.WEATHER, "high_humidity", "High humidity / persistent fog", 110)

        // Phenology and crop development.
        add(VintageNoteGroup.PHENOLOGY, "early_budburst", "Early budburst", 10)
        add(VintageNoteGroup.PHENOLOGY, "delayed_budburst", "Delayed budburst", 20)
        add(VintageNoteGroup.PHENOLOGY, "flowering_started", "Flowering started", 30)
        add(VintageNoteGroup.PHENOLOGY, "flowering_completed", "Flowering completed", 40)
        add(VintageNoteGroup.PHENOLOGY, "poor_fruit_set", "Poor or variable fruit set", 50)
        add(VintageNoteGroup.PHENOLOGY, "veraison_started", "Veraison started", 60)
        add(VintageNoteGroup.PHENOLOGY, "slow_ripening", "Slow or delayed ripening", 70)
        add(VintageNoteGroup.PHENOLOGY, "rapid_ripening", "Rapid or early ripening", 80)
        add(VintageNoteGroup.PHENOLOGY, "harvest_started", "Harvest started", 90)
        add(VintageNoteGroup.PHENOLOGY, "harvest_completed", "Harvest completed", 100)
        add(VintageNoteGroup.PHENOLOGY, "lower_yield", "Lower than expected yield", 110)
        add(VintageNoteGroup.PHENOLOGY, "higher_yield", "Higher than expected yield", 120)

        // Disease and pest pressure.
        add(VintageNoteGroup.DISEASE, "increased_disease_pressure", "Increased disease pressure", 10)
        add(VintageNoteGroup.DISEASE, "powdery_mildew", "Powdery mildew", 20)
        add(VintageNoteGroup.DISEASE, "downy_mildew", "Downy mildew", 30)
        add(VintageNoteGroup.DISEASE, "botrytis", "Botrytis", 40)
        add(VintageNoteGroup.DISEASE, "pest_bird_pressure", "Pest or bird pressure", 50)

        // Major vineyard activity.
        add(VintageNoteGroup.ACTIVITY, "pruning_started", "Pruning started", 10)
        add(VintageNoteGroup.ACTIVITY, "pruning_completed", "Pruning completed", 20)
        add(VintageNoteGroup.ACTIVITY, "shoot_thinning", "Shoot thinning", 30)
        add(VintageNoteGroup.ACTIVITY, "desuckering", "Desuckering", 40)
        add(VintageNoteGroup.ACTIVITY, "wire_lifting", "Wire lifting", 50)
        add(VintageNoteGroup.ACTIVITY, "leaf_plucking", "Leaf plucking", 60)
        add(VintageNoteGroup.ACTIVITY, "canopy_trimming", "Canopy trimming", 70)
        add(VintageNoteGroup.ACTIVITY, "fruit_thinning", "Fruit thinning", 80)
        add(VintageNoteGroup.ACTIVITY, "significant_irrigation", "Significant irrigation", 90)
        add(VintageNoteGroup.ACTIVITY, "cover_crop_activity", "Cover crop activity", 100)

        // Other.
        add(VintageNoteGroup.OTHER, OTHER_CUSTOM_CODE, "Other / custom event", 10)
    }

    fun systemType(code: String?): VintageNoteType? =
        systemTypes.firstOrNull { it.code == code }

    /**
     * The picker's contents: seeded types plus this vineyard's custom types,
     * grouped and ordered identically on both platforms.
     *
     * Retired types are excluded from NEW selection but remain resolvable by
     * code for display of existing notes.
     */
    fun selectable(customTypes: List<VintageNoteType>): List<VintageNoteType> =
        ((if (customTypes.any { it.isSystem }) emptyList() else systemTypes) + customTypes)
            .filter { it.isActive }
            .sortedWith(compareBy({ it.group.sortOrder }, { it.sortOrder }, { it.label }))

    /** Groups in display order, each with its selectable types. */
    fun grouped(customTypes: List<VintageNoteType>): List<Pair<VintageNoteGroup, List<VintageNoteType>>> =
        selectable(customTypes)
            .groupBy { it.group }
            .toList()
            .sortedBy { it.first.sortOrder }

    /**
     * Case-insensitive substring search over labels, preserving group order.
     * A blank query returns everything rather than nothing.
     */
    fun search(query: String, customTypes: List<VintageNoteType>): List<VintageNoteType> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return selectable(customTypes)
        return selectable(customTypes).filter { it.label.contains(trimmed, ignoreCase = true) }
    }
}

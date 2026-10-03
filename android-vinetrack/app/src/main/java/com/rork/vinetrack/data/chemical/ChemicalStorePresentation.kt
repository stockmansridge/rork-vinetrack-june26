package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Store-only projections; retain full rows for historical ID resolution. */
internal object ChemicalStorePresentation {
    enum class EditorKind { CATALOGUE, MANUAL, LEGACY_REPAIR }
    fun editorKind(chemical: SavedChemical?): EditorKind = when {
        chemical == null -> EditorKind.MANUAL
        chemical.chemicalV3RevisionId != null -> EditorKind.CATALOGUE
        chemical.entrySource in listOf("customer_entered", "manual", "manual_v2") &&
            (chemical.defaultRates?.perHectare?.entryMethod == "manual" || chemical.defaultRates?.per100Litres?.entryMethod == "manual") -> EditorKind.MANUAL
        else -> EditorKind.LEGACY_REPAIR
    }
    fun safeLegacyGroup(text: String): String = if (text.trim().uppercase(java.util.Locale.ROOT) in listOf("NOT_APPLICABLE", "UNRESOLVED", "CLASSIFIED")) "" else text
    fun active(chemicals: List<SavedChemical>): List<SavedChemical> = chemicals.filter { it.isActive && it.deletedAt == null }
    fun archived(chemical: SavedChemical): SavedChemical = chemical.copy(isActive = false)
    fun preservingUnchangedResistance(patch: JsonObject, intelligenceChanged: Boolean): JsonObject =
        if (intelligenceChanged) patch else JsonObject(patch - "resistance_classification_state")
    fun notesPatch(notes: String): JsonObject = buildJsonObject { put("notes", notes) }
}

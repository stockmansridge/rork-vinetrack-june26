package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.CatalogueRow
import com.rork.vinetrack.data.chemical.ChemicalStorePresentation
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChemicalStorePresentationTest {
    @Test fun archiveHidesImmediatelyAndRetainsHistoryAcrossCacheReloadAndRemoteMerge() {
        val original = SavedChemical(id = "history", vineyardId = "vineyard", name = "Historical product", purchase = ChemicalPurchase(costDollars = 200.0, containerSizeML = 20.0, containerUnit = "Litres"))
        val local = object : SavedChemicalLocalStoring {
            var saved = listOf(original)
            override fun load(userId: String, vineyardId: String) = saved
            override fun save(userId: String, vineyardId: String, rows: List<SavedChemical>): Boolean { saved = rows; return true }
        }
        val sync = SavedChemicalCreateSync(SavedChemicalRepository(), PendingWriteRepository(InMemoryPendingWriteStore()), local, { "owner" })
        assertEquals(listOf(original), ChemicalStorePresentation.active(sync.rows("owner", "vineyard")))
        sync.archiveLocal("owner", "vineyard", original.id)
        val reloaded = sync.rows("owner", "vineyard")
        assertTrue(ChemicalStorePresentation.active(reloaded).isEmpty())
        assertEquals(original.copy(isActive = false), reloaded.single { it.id == original.id })
        assertEquals(original.purchase, reloaded.single().purchase)
        assertEquals(original.costPerUnit, reloaded.single().costPerUnit)
        assertEquals(reloaded, sync.mergeRemote("owner", "vineyard", emptyList()))
    }

    @Test fun eitherArchiveRepresentationIsExcludedFromEveryStoreProjection() {
        val active = SavedChemical(id = "active", vineyardId = "vineyard", name = "Active")
        val rows = listOf(active, active.copy(id = "inactive", isActive = false), active.copy(id = "deleted", deletedAt = "2026-10-03T00:00:00Z"))
        assertEquals(listOf(active), ChemicalStorePresentation.active(rows))
        assertEquals(3, rows.size)
    }

    @Test fun rawResistanceSchemesAndLegacyEnumsNeverDisplay() {
        for (scheme in listOf("NOT_APPLICABLE", "not_applicable", "UNRESOLVED", "CLASSIFIED")) {
            assertEquals("", CatalogueRow.resistanceText(scheme, listOf("CLASSIFIED")))
            assertEquals("", ChemicalStorePresentation.safeLegacyGroup(scheme))
        }
        assertEquals("FRAC 3 + 11", CatalogueRow.resistanceText("frac", listOf("3", "11")))
        assertEquals("HRAC 10", CatalogueRow.resistanceText("hrac", listOf("10")))
        val unresolved = CatalogueRow(Json.parseToJsonElement("""{"resistance_classification_state":"UNRESOLVED"}""").jsonObject)
        assertEquals("", unresolved.groupText)
        assertEquals("Resistance group unknown", unresolved.resistanceWarning)
    }

    @Test fun registeredRangesKeepBothBoundsBasisAndConditions() {
        val row = CatalogueRow(Json.parseToJsonElement("""{"default_rate_options":{"per_hectare":[{"min_value":560,"max_value":700,"unit":"g/ha","condition":"Early growth"}],"per_100_litres":[{"value":100,"unit":"mL/100L"}]}}""").jsonObject)
        assertEquals(listOf("560–700 g/ha · Early growth"), row.registeredRateLines("per_hectare"))
        assertEquals(listOf("100 mL/100L"), row.registeredRateLines("per_100_litres"))
        assertEquals(560.0, row.rateRows("per_hectare").single().number("min_value")!!, 0.0)
        assertEquals(700.0, row.rateRows("per_hectare").single().number("max_value")!!, 0.0)
    }

    @Test fun notesPayloadCannotOverwriteLegacyOrCatalogueOrCostingFields() {
        val patch = ChemicalStorePresentation.notesPatch("Operator notes")
        assertEquals(setOf("notes"), patch.keys)
        assertFalse(patch.containsKey("purchase"))
        assertFalse(patch.containsKey("rates"))
        assertFalse(patch.containsKey("resistance_classification_state"))
        assertFalse(patch.containsKey("chemical_v3_revision_id"))
    }

    @Test fun unrelatedLegacyMetadataEditDoesNotResetStoredResistance() {
        val patch = Json.parseToJsonElement("""{"name":"Repaired name","resistance_classification_state":"unresolved"}""").jsonObject
        val untouched = ChemicalStorePresentation.preservingUnchangedResistance(patch, intelligenceChanged = false)
        assertEquals(setOf("name"), untouched.keys)
        assertEquals(patch, ChemicalStorePresentation.preservingUnchangedResistance(patch, intelligenceChanged = true))
    }

    @Test fun catalogueAndLegacyAndNewManualHaveSeparateEditorRoutes() {
        val old = SavedChemical(id = "old", vineyardId = "vineyard", name = "Legacy", activeIngredient = "Old text")
        assertEquals(ChemicalStorePresentation.EditorKind.LEGACY_REPAIR, ChemicalStorePresentation.editorKind(old))
        assertEquals(ChemicalStorePresentation.EditorKind.CATALOGUE, ChemicalStorePresentation.editorKind(old.copy(chemicalV3RevisionId = "exact")))
        assertEquals(ChemicalStorePresentation.EditorKind.MANUAL, ChemicalStorePresentation.editorKind(null))
    }
}

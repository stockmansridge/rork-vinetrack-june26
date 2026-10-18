package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TargetNutrientTest {
    private fun draft(pct: String = "16") = TargetNutrient.Draft(percent = pct, target = "2")
    @Test fun portalSolidExamplesAndTotals() {
        val n = TargetNutrient.calculate(draft(), false, 1000, 1.0)
        assertEquals(12.5, n.rate!!, 0.0); assertEquals(12.5, n.totalProduct!!, 0.0); assertEquals(2.0, n.totalNutrientKg!!, 0.0); assertTrue(n.issues.isEmpty())
        assertEquals(10.0, TargetNutrient.calculate(draft("20").selectNutrient("Ca").copy(analysisBasis = "elemental"), false, 1000, 1.0).rate!!, 0.0)
    }
    @Test fun liquidWeightVolumeNeedsNoDensity() {
        val r = TargetNutrient.calculate(draft().copy(concentrationBasis = "w/v"), true, 1000, 1.0)
        assertEquals(12.5, r.rate!!, 0.0); assertEquals("mL/vine", r.rateUnit); assertEquals(12.5, r.totalProduct!!, 0.0); assertEquals("L", r.productUnit); assertTrue(r.issues.isEmpty())
    }
    @Test fun liquidWeightWeightNeedsDocumentedDensity() {
        val d = draft().copy(concentrationBasis = "w/w")
        val mass = TargetNutrient.calculate(d, true, 1000, 1.0)
        assertNull(mass.rate); assertEquals(12.5, mass.totalProduct!!, 0.0); assertEquals("kg", mass.productUnit)
        assertNull(TargetNutrient.calculate(d.copy(density = "1.25"), true, 1000, 1.0).rate)
        val volume = TargetNutrient.calculate(d.copy(density = "1.25", densityReference = "Synthetic sheet"), true, 1000, 1.0)
        assertEquals(10.0, volume.rate!!, 0.0); assertEquals(10.0, volume.totalProduct!!, 0.0); assertEquals("L", volume.productUnit)
        listOf("0", "-1", "NaN", "Infinity").forEach { assertNull(TargetNutrient.calculate(d.copy(density = it, densityReference = "Sheet"), true, 1000, 1.0).rate) }
    }
    @Test fun hectareAndRegionalManualArea() {
        val d = draft().copy(perVine = false)
        val r = TargetNutrient.calculate(d, false, null, 2.5)
        assertEquals(12.5, r.rate!!, 0.0); assertEquals("kg/ha", r.rateUnit); assertEquals(31.25, r.totalProduct!!, 0.0); assertEquals(5.0, r.totalNutrientKg!!, 0.0)
        val f = RegionFormatter(RegionSettings(areaUnit = "acres"))
        assertEquals(31.25, TargetNutrient.calculate(d, false, null, f.areaToCanonical(f.areaValue(2.5))).totalProduct!!, 0.0)
    }
    @Test fun switchingNutrientsRetainsTypedPercentAndTargetNotOxideIdentity() {
        var d = draft("20,5")
        TargetNutrient.nutrients.forEach { (key, _) ->
            d = d.selectNutrient(key); assertEquals("20,5", d.percent); assertEquals("2", d.target)
            if (key in TargetNutrient.oxideKeys) assertEquals("unknown", d.analysisBasis)
        }
    }
    @Test fun oxideUnknownAndSolidWeightVolumeNeverBecomeElemental() {
        listOf("oxide", "unknown").forEach {
            val r = TargetNutrient.calculate(draft().copy(analysisBasis = it), false, 1000, 1.0)
            assertNull(r.rate); assertNull(r.totalProduct); assertNull(r.totalNutrientKg)
        }
        assertNull(TargetNutrient.calculate(draft(), true, 1000, 1.0).totalProduct)
        assertNull(TargetNutrient.calculate(draft().copy(concentrationBasis = "w/v"), false, 1000, 1.0).rate)
    }
    @Test fun invalidInputsMissingQuantityAndOtherName() {
        listOf("", "0", "-1", "101", "NaN", "Infinity", "1,2.3").forEach { assertNull(TargetNutrient.calculate(draft(it), false, 1000, 1.0).rate) }
        val r = TargetNutrient.calculate(draft(), false, null, null)
        assertEquals(12.5, r.rate!!, 0.0); assertNull(r.totalProduct)
        val other = draft().selectNutrient("other").copy(analysisBasis = "elemental")
        assertNull(TargetNutrient.calculate(other, false, 1000, 1.0).rate)
        assertEquals(12.5, TargetNutrient.calculate(other.copy(otherName = "Custom"), false, 1000, 1.0).rate!!, 0.0)
    }
    @Test fun existingBlockCountAuthorityDrivesLiveTotals() {
        val blocks = listOf(Paddock(id = "a", vineyardId = "v", name = "A", vineSpacing = 2.0, vineCountOverride = 4200, rowLengthOverride = 10000.0), Paddock(id = "b", vineyardId = "v", name = "B", vineSpacing = 2.0, vineCountOverride = 3600, rowLengthOverride = 8000.0))
        val actual = TargetNutrient.calculate(draft(), false, FertiliserVineCounts.total(blocks, "actual"), null)
        val assumed = TargetNutrient.calculate(draft(), false, FertiliserVineCounts.total(blocks, "assumed_full"), null)
        assertEquals(97.5, actual.totalProduct!!, 0.0); assertEquals(15.6, actual.totalNutrientKg!!, 0.0)
        assertEquals(112.5, assumed.totalProduct!!, 0.0); assertEquals(18.0, assumed.totalNutrientKg!!, 0.0)
    }
    @Test fun adminAccessAndSavingAreIndependent() {
        assertTrue(TargetNutrient.canPreview(true)); assertFalse(TargetNutrient.canPreview(false))
        listOf("nutrientTarget", "fertigation", "future", "").forEach { assertFalse(TargetNutrient.canSave(it)) }
        assertTrue(TargetNutrient.canSave("perVine")); assertTrue(TargetNutrient.canSave("perHectare"))
    }
    @Test fun unsupportedRemoteAndOfflineSnapshotRemainReadOnly() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        listOf("nutrientTarget", "fertigation", "future").forEach { mode ->
            val raw = Json.parseToJsonElement("""{"id":"r","vineyard_id":"v","calculation_mode":"$mode","application_rate":12.5,"application_rate_unit":"g/vine","product_unit":"kg","nutrient_key":"Ca","nutrient_percent":20,"analysis_basis":"oxide","product_analysis_snapshot":{"schema_version":1,"nutrients":[{"percent":20,"analysis_basis":"oxide"}]}}""").jsonObject
            val row = json.decodeFromJsonElement<FertiliserSyncRepository.RecordRow>(raw).copy(rawSnapshot = raw)
            val record = row.toModel(emptyList())
            assertEquals(mode, record.mode); assertFalse(record.isSupportedMode); assertEquals("g/vine", record.rateUnit)
            val restored = json.decodeFromString<FertiliserRecord>(json.encodeToString(record))
            assertEquals(record, restored); assertEquals(raw, restored.unsupportedSnapshot)
        }
    }
}

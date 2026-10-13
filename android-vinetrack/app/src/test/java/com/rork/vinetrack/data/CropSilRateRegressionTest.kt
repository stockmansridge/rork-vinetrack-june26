package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.SprayRecord
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonArray
import com.rork.vinetrack.data.model.chemicalUnitToBase
import com.rork.vinetrack.data.spray.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import org.junit.Assert.*
import org.junit.Test

class CropSilRateRegressionTest {
    // Exact user-supplied rate fields, with a synthetic REST envelope/use target.
    // This is not a captured full live registered_uses payload.
    private val payload = """{"id":"ae9a8166-a052-41d4-af07-d7bc4de01c9a","vineyard_id":"11111111-1111-4111-8111-111111111111","name":"Crop Sil","unit":"Litres","registered_uses":[{"crop":"Grapevines (viticulture)","target_raw":"","rates":[{"basis":"range_per_hectare","min_value":3,"max_value":5,"unit":"L/ha","condition":"Monthly as required","raw_text":"3-5L"},{"basis":"range_per_100_litres","min_value":500,"max_value":1000,"unit":"mL/100 L water","condition":"If using high volumes of water for foliar sprays","raw_text":"500-1000mls/100L water"}]}]}"""
    private fun chemical(): SavedChemical = Json.decodeFromString(payload)

    @Test fun `both bases retain correct display and deliberate presets`() {
        val chemical = chemical()
        assertFalse(SprayRegisteredUseRates.hasInvalidStructuredRates(chemical))
        val rates = SprayRegisteredUseRates.vineyardRates(chemical)
        assertEquals(8, rates.size)
        val area = rates.filter { it.basis == SprayCalculator.RateBasis.PER_HECTARE && it.preset != null }
        val volume = rates.filter { it.basis == SprayCalculator.RateBasis.PER_100L && it.preset != null }
        assertEquals(listOf("3 L/ha", "4 L/ha", "5 L/ha"), area.map { it.displayText })
        assertEquals(listOf(3.0, 4.0, 5.0), area.map { it.appliedValue })
        assertEquals(listOf("500 mL/100 L", "750 mL/100 L", "1000 mL/100 L"), volume.map { it.displayText })
        assertTrue(volume.all { it.menuText.contains("If using high volumes of water for foliar sprays") })
        assertEquals(rates.size, rates.map { it.id }.toSet().size)
        for (basis in listOf(SprayCalculator.RateBasis.PER_HECTARE, SprayCalculator.RateBasis.PER_100L)) {
            val first = SprayRegisteredUseRates.firstOffered(chemical, basis)!!
            assertTrue(first.requiresManualRate)
            assertNull(first.appliedValue)
            assertNull(first.preset)
        }
    }

    @Test fun `manual and chosen quantities are correct on separate bases`() {
        val rates = SprayRegisteredUseRates.vineyardRates(chemical())
        val area = rates.first { it.basis == SprayCalculator.RateBasis.PER_HECTARE && it.requiresManualRate }
        val volume = rates.first { it.basis == SprayCalculator.RateBasis.PER_100L && it.requiresManualRate }
        val context = SprayQuantityContext(grossAreaHectares = 6.0, carrierLitres = 1200.0)
        val chosenArea = SprayRegisteredUseRates.validateManual("4", area)!!
        val chosenVolume = SprayRegisteredUseRates.validateManual("750", volume)!!
        val areaTotal = SprayProductQuantityCalculator.totalQuantity(chosenArea, SprayProductRateBasis.WHOLE_BLOCK_AREA, context)!!
        assertEquals(24.0, areaTotal, 0.0)
        assertEquals(24000.0, chemicalUnitToBase("Litres", areaTotal), 0.0)
        assertEquals(9000.0, SprayProductQuantityCalculator.totalQuantity(chosenVolume, SprayProductRateBasis.PER_100_LITRES, context)!!, 0.0)
        assertEquals(chosenArea, rates.first { it.basis == area.basis && it.preset == SprayRatePreset.MIDPOINT }.appliedValue!!, 0.0)
        assertEquals(chosenVolume, rates.first { it.basis == volume.basis && it.preset == SprayRatePreset.MIDPOINT }.appliedValue!!, 0.0)
        assertNull(SprayConfirmedRateSeeding.seedFor(chemical()))
        for (text in listOf("", "0", "2.99", "5.01", "NaN")) assertNull(SprayRegisteredUseRates.validateManual(text, area))
        for (text in listOf("499", "1001")) assertNull(SprayRegisteredUseRates.validateManual(text, volume))
        assertEquals(4.5, SprayRegisteredUseRates.validateManual("4,5", area)!!, 0.0)
        assertEquals(3.0, SprayRegisteredUseRates.validateManual("3", area)!!, 0.0)
        assertEquals(1000.0, SprayRegisteredUseRates.validateManual("1000", volume)!!, 0.0)
    }

    @Test fun `normalization keeps evidence and rejects contradictory stored data`() {
        val chemical = chemical()
        val originals = chemical.registeredUses!!.first().rates
        for (rate in originals) {
            val normalized = ChemicalLabelRateNormalizer.normalize(rate)!!
            assertEquals(rate.rawText, normalized.rawText)
            assertEquals(rate.label, normalized.label)
            assertEquals(rate.condition, normalized.condition)
            assertEquals(rate.basis, normalized.basis)
            assertEquals(rate.rateId, normalized.rateId)
            assertEquals(rate.conditionAmbiguous, normalized.conditionAmbiguous)
        }
        assertEquals(listOf("L/ha", "mL/100 L water"), originals.map { it.unit })
        assertNull(ChemicalLabelRateNormalizer.normalize(originals[1].copy(unit = "mL/ha")))
        assertNull(ChemicalLabelRateNormalizer.normalize(originals[1].copy(maxValue = 400.0)))
        val bad = originals[1].copy(unit = "mL/100 L water or per ha")
        assertNull(ChemicalLabelRateNormalizer.normalize(bad))
        assertTrue(SprayRegisteredUseRates.hasInvalidStructuredRates(chemical.copy(registeredUses = listOf(chemical.registeredUses!!.first().copy(rates = listOf(bad))))))
    }

    @Test fun `REST decoding cache codecs edit and outbound projection preserve rate evidence`() {
        val original = chemical()
        val uses = original.registeredUses!!
        assertEquals(listOf("Monthly as required", "If using high volumes of water for foliar sprays"), uses[0].rates.map { it.condition })
        assertEquals(listOf("3-5L", "500-1000mls/100L water"), uses[0].rates.map { it.rawText })
        val draft = ChemicalManualEntry.draft(original, "NZ").copy(productName = "Edited display name")
        val proposed = ChemicalManualEntry.intelligenceForManualSave(draft)
        assertEquals(uses, proposed.registeredUses)
        assertEquals(uses, ChemicalLabelRateNormalizer.normalize(proposed)!!.registeredUses)
        val cacheJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val reopened = cacheJson.decodeFromString<SavedChemical>(cacheJson.encodeToString(original.copy(notes = "Unrelated note")))
        assertEquals(uses, reopened.registeredUses)
        assertEquals(SprayRegisteredUseRates.vineyardRates(original).map { it.id }, SprayRegisteredUseRates.vineyardRates(reopened).map { it.id })
        val outbound = Json.parseToJsonElement(cacheJson.encodeToString(reopened)).jsonObject["registered_uses"]!!
        assertEquals(uses, cacheJson.decodeFromString<List<ChemicalRegisteredUse>>(outbound.toString()))
    }

    @Test fun `old labels separate conditions and unrecognized evidence round trip`() {
        val text = """[{"crop":"Grapes","target_raw":"Powdery mildew","target":"future_target","withholding_statement":"Original historical wording","future_use":{"a":[1,null,true]},"rates":[{"basis":"per_hectare","value":2,"unit":"L/ha","label":"Description","condition":"Only before flowering","raw_text":"  2 L/ha  ","rate_id":"unchanged-server-id","future_rate":{"evidence":"original"}},{"basis":"per_100_litres","value":100,"unit":"mL","label":"Legacy condition"}]}]"""
        val compatibleJson = Json { ignoreUnknownKeys = true }
        assertTrue(runCatching { Json.decodeFromString<List<ChemicalRegisteredUse>>(text) }.isFailure)
        val uses = compatibleJson.decodeFromString<List<ChemicalRegisteredUse>>(text)
        val reloaded = compatibleJson.decodeFromString<List<ChemicalRegisteredUse>>(compatibleJson.encodeToString(uses))
        assertEquals(uses, reloaded)
        assertEquals("Description", reloaded[0].rates[0].label)
        assertEquals("Only before flowering", reloaded[0].rates[0].applicationCondition)
        assertEquals("Legacy condition", reloaded[0].rates[1].applicationCondition)
        assertNotNull(reloaded[0].unknownFields["future_use"])
        assertEquals("\"future_target\"", reloaded[0].unknownFields["target"].toString())
        assertNotNull(reloaded[0].rates[0].unknownFields["future_rate"])
        val unsupported = compatibleJson.decodeFromString<ChemicalLabelRate>("""{"basis":"per_vine_future","value":2,"unit":"L","raw_text":"2 L/ha"}""")
        assertNull(ChemicalLabelRateNormalizer.normalize(unsupported))
        assertEquals("per_vine_future", compatibleJson.decodeFromString<ChemicalLabelRate>(compatibleJson.encodeToString(unsupported)).unsupportedBasis)
    }

    @Test fun `chosen rate quantity and condition remain frozen in spray record`() {
        val chemical = chemical()
        val rates = SprayRegisteredUseRates.vineyardRates(chemical)
        val context = SprayQuantityContext(grossAreaHectares = 6.0, carrierLitres = 1200.0, concentrationFactor = 1.0)
        for ((basis, expectedLitres) in listOf(SprayCalculator.RateBasis.PER_HECTARE to 24.0, SprayCalculator.RateBasis.PER_100L to 9.0)) {
            val chosen = rates.first { it.basis == basis && it.preset == SprayRatePreset.MIDPOINT }
            val productBasis = if (basis == SprayCalculator.RateBasis.PER_HECTARE) SprayProductRateBasis.WHOLE_BLOCK_AREA else SprayProductRateBasis.PER_100_LITRES
            val quantity = SprayProductQuantityCalculator.totalQuantity(chosen.appliedValue!!, productBasis, context)!!
            val litres = if (basis == SprayCalculator.RateBasis.PER_100L) quantity / 1000 else quantity
            assertEquals(expectedLitres, litres, 0.0)
            val frozen = ChemicalLineSnapshot().recordingApplied(chosen.appliedValue!!, chosen.unit,
                if (basis == SprayCalculator.RateBasis.PER_HECTARE) ChemicalDefaultRateBasis.PER_HECTARE else ChemicalDefaultRateBasis.PER_100_LITRES,
                StoredChemicalDefaultRate.ENTRY_CANONICAL, selectedRate = chosen)
            val record = SprayRecord(id = "synthetic-record", vineyardId = chemical.vineyardId,
                tanks = listOf(SprayTank(id = "synthetic-tank", waterVolume = 1200.0, concentrationFactor = 1.0,
                    chemicals = listOf(SprayChemical(id = "synthetic-line", name = chemical.name, volumePerTank = litres, chemicalSnapshot = frozen)))))
            val reopened = Json.decodeFromString<SprayRecord>(Json.encodeToString(record))
            val saved = reopened.tanks!!.first().chemicals.first()
            assertEquals(expectedLitres, saved.volumePerTank, 0.0)
            assertEquals(frozen, saved.chemicalSnapshot)
            assertEquals(chosen.condition, saved.chemicalSnapshot!!.rateCondition)
            assertEquals(chosen.registeredRate!!.rawText, saved.chemicalSnapshot!!.registeredRate!!.rawText)
        }
    }

    private fun captured(): List<SavedChemical> = SupabaseClient.json.decodeFromString(
        java.io.File("src/androidTest/assets/production_chemical_registered_uses.json").readText())

    @Test fun `unresolved captured concentration units must not be discarded or inferred`() {
        val chemical = captured()[0]
        val encoded = SupabaseClient.json.parseToJsonElement(SupabaseClient.json.encodeToString(chemical)).jsonObject
        val actives = encoded["active_ingredients"]!!.jsonArray
        assertEquals("% (±1%)", actives[0].jsonObject["concentration_unit"]?.toString()?.trim('"'))
        assertEquals("%", actives[1].jsonObject["concentration_unit"]?.toString()?.trim('"'))
        assertNull(chemical.activeIngredients!![0].concentrationUnit)
        assertNull(chemical.activeIngredients!![1].concentrationUnit)
    }

    @Test fun `captured competing fixed rates never choose on basis alone`() {
        val chemical = captured()[1]
        val rates = SprayRegisteredUseRates.vineyardRates(chemical)
        assertEquals(listOf("40 mL/100 L", "60 mL/100 L"), rates.map { it.displayText })
        assertEquals(listOf(40.0, 60.0), rates.map { it.appliedValue })
        assertEquals(2, rates.map { it.id }.toSet().size)
        assertTrue(rates.all { it.menuText.contains(it.registeredRate!!.condition!!) })
        assertNull(SprayConfirmedRateSeeding.seedFor(chemical))
        assertNull(SprayRegisteredUseRates.firstOffered(chemical, SprayCalculator.RateBasis.PER_100L))
    }

    @Test fun `captured incompatible product unit requires independent review`() {
        val chemical = captured()[2]
        assertEquals("Litres", chemical.unit)
        val original = chemical.registeredUses!!.single().rates
        assertEquals(listOf("kg/ha", "g/100 L", "g/100L"), original.map { it.unit })
        assertEquals(listOf(null, "Dilute Spraying (to the point of run-off)", "Concentrate Spraying"), original.map { it.condition })
        assertTrue(SprayRegisteredUseRates.hasInvalidStructuredRates(chemical))
        val rates = SprayRegisteredUseRates.vineyardRates(chemical)
        assertEquals(3, rates.size)
        assertTrue(rates.all { !it.isSelectable && it.appliedValue == null })
    }

    @Test fun `only explicit equivalent notations are accepted`() {
        for (text in listOf("500–1000 mL/100 L water", "500–1000 mL per 100 litres of water", "500–1000 mL / 100\tL water")) {
            assertEquals(ChemicalLabelRateBasis.RANGE_PER_100_LITRES, ChemicalLabelRateNormalizer.parse(text)?.basis)
        }
        assertEquals("L", ChemicalLabelRateNormalizer.parse("3–5 L per hectare")?.unit)
        for (text in listOf("3–5 L/ha water", "500 mL/100 L or ha", "500 mL/100 L concentrate", "5–3 L/ha", "500 mL/200 L water")) {
            assertNull(ChemicalLabelRateNormalizer.parse(text))
        }
    }
}

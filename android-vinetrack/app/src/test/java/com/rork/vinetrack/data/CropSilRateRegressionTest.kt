package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitToBase
import com.rork.vinetrack.data.spray.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import org.junit.Assert.*
import org.junit.Test

class CropSilRateRegressionTest {
    // Rate fields and conditions supplied from the verified record; no live writes.
    private fun chemical(): SavedChemical {
        val payload = """[{"basis":"range_per_hectare","min_value":3,"max_value":5,"unit":"L/ha","label":"Monthly as required","raw_text":"3–5 L/ha"},{"basis":"range_per_100_litres","min_value":500,"max_value":1000,"unit":"mL/100 L water","label":"If using high volumes of water for foliar sprays","raw_text":"500–1000 mL/100 L water"}]"""
        val rates = Json.decodeFromString<List<ChemicalLabelRate>>(payload)
        return SavedChemical(id = "ae9a8166-a052-41d4-af07-d7bc4de01c9a", vineyardId = "regression", name = "Crop Sil", unit = "Litres",
            registeredUses = listOf(ChemicalRegisteredUse(crop = "Grapevines (viticulture)", targetRaw = "", rates = rates)))
    }

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

package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayCarrierRegionalFormat
import com.rork.vinetrack.data.spray.SprayProductLineResult
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.ui.components.SprayGuidedFormat
import org.junit.Assert.*
import org.junit.Test

class SprayCarrierRegionalFormatTest {
    @Test fun metricCarrierTextRetainsItsValues() {
        val carrier = SprayCarrierRegionalFormat(RegionFormatter(RegionCountry.Australia.recommendedPreset))
        assertEquals("500.00 L/ha", carrier.litresPerHectare(500.0))
        assertEquals("40.00 L/100 m", carrier.litresPer100m(40.0))
        assertEquals("2.50 m", carrier.metres(2.5, 2))
        assertEquals("—", carrier.litresPerHectare(null))
    }

    @Test fun imperialCarrierConvertsBothDimensionsNotJustSuffixes() {
        val fmt = RegionFormatter(RegionCountry.UnitedStates.recommendedPreset)
        val carrier = SprayCarrierRegionalFormat(fmt)
        assertEquals("gal/ac", carrier.carrierBasisLabel(SprayCarrierBasis.LITRES_PER_HECTARE))
        assertEquals("gal/100 ft", carrier.carrierBasisLabel(SprayCarrierBasis.LITRES_PER_100_METRES))
        assertEquals(500.0 * 0.264172052 / 2.471053814672, fmt.volumePerAreaValue(500.0), 1e-8)
        assertEquals(40.0 * 0.264172052 / 3.280839895, fmt.volumePer100LengthValue(40.0), 1e-8)
        assertFalse(carrier.litresPerHectare(500.0).contains("L/ha"))
        assertTrue(carrier.hectares(1.0).contains("2.47 ac"))
    }

    @Test fun customCarrierEditedAndUntouchedValuesRoundTripThroughCache() {
        for (settings in listOf(RegionCountry.Australia.recommendedPreset, RegionCountry.UnitedStates.recommendedPreset)) {
            val carrier = SprayCarrierRegionalFormat(RegionFormatter(settings))
            for (basis in SprayCarrierBasis.entries) {
                val seed = carrier.rateInput(750.123456789, basis)
                assertEquals(750.123456789, carrier.resolveRate(seed.text, basis, seed)!!, 0.0)
                val editedText = carrier.rateInput(500.0, basis).text
                assertEquals(500.0, carrier.resolveRate(editedText, basis, seed)!!, 1e-9)
            }
            val water = carrier.resolveRate(carrier.rateInput(1500.0, SprayCarrierBasis.MANUAL_TOTAL_VOLUME).text, SprayCarrierBasis.MANUAL_TOTAL_VOLUME)!!
            val preset = com.rork.vinetrack.data.model.SavedSprayPreset(id = "p", vineyardId = "v", waterVolume = water, sprayRatePerHa = 500.0, concentrationFactor = 2.5)
            val json = kotlinx.serialization.json.Json
            val replay = json.decodeFromString(com.rork.vinetrack.data.model.SavedSprayPreset.serializer(), json.encodeToString(com.rork.vinetrack.data.model.SavedSprayPreset.serializer(), preset))
            assertEquals(1500.0, replay.waterVolume, 1e-9)
            assertEquals(500.0, replay.sprayRatePerHa, 0.0)
            assertEquals(2.5, replay.concentrationFactor, 0.0)
        }
    }

    @Test fun registeredChemicalRateBasesRemainAuthoritativeBesideRegionalCarrier() {
        val carrier = SprayCarrierRegionalFormat(RegionFormatter(RegionCountry.UnitedStates.recommendedPreset))
        val perHa = SprayProductLineResult("p", "Product", "L", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0, 20.0, 2.0, null, null, basisInput = 10.0)
        val per100L = perHa.copy(basis = SprayProductRateBasis.PER_100_LITRES, rate = 0.15, basisInput = 1000.0)
        assertTrue(SprayGuidedFormat.productRate(perHa).contains("/ha"))
        assertTrue(SprayGuidedFormat.productRate(per100L).contains("/100 L"))
        assertTrue(carrier.litresPerHectare(500.0).contains("gal/ac"))
        assertTrue(SprayGuidedFormat.productCalculation(perHa)!!.contains("10.00 ha"))
        assertEquals(2.0, perHa.rate, 0.0)
        assertEquals(0.15, per100L.rate, 0.0)
    }

    @Test fun independentLandSprayFuelAndCurrencySettingsStayIndependent() {
        val settings = RegionCountry.UnitedKingdom.recommendedPreset.copy(areaUnit = "acres", sprayRateAreaUnit = "hectare", volumeUnit = "gallons", fuelUnit = "gallons")
        val fmt = RegionFormatter(settings)
        assertEquals("gal/ha", fmt.volumePerAreaUnit)
        assertTrue(fmt.formatFuelCostPerUnit(1.5).contains("£"))
        assertTrue(fmt.formatFuelCostPerUnit(1.5).endsWith("/gal"))
        assertTrue(fmt.formatFuelRatePerHour(10.0).endsWith("gal/hr"))
        assertEquals(1.5, fmt.fuelCostToCanonical(fmt.fuelCostValue(1.5)), 1e-9)
        assertTrue(fmt.formatYieldPerArea(24.71053814672, "kg").contains("10.00 kg/ac"))
        assertEquals(40.0, fmt.volumePer100LengthToCanonical(fmt.volumePer100LengthValue(40.0)), 1e-9)
    }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.reporting.SprayApplicationReportFields
import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.ui.components.SprayGuidedFormat
import org.junit.Assert.*
import org.junit.Test

class SprayMVPDefectTest {
    @Test fun recordedMultipleTargetsAndFullCanopyRemainReadable() {
        val snapshot = SprayApplicationSnapshot(applicationMode = SprayApplicationMode.WHOLE_BLOCK,
            targets = listOf(SprayTarget.POWDERY_MILDEW, SprayTarget.DOWNY_MILDEW),
            customTargets = listOf("historical_unknown_target"), sprayHeadTarget = SprayHeadTarget.FULL_CANOPY)
        val fields = SprayApplicationReportFields.from(snapshot)
        assertEquals("Powdery Mildew; Downy Mildew; historical_unknown_target", fields.targets)
        assertEquals("Full Canopy", fields.sprayHead)
        assertEquals("Whole block", fields.mode)
        assertEquals(4, fields.values.size)
        assertEquals(snapshot, kotlinx.serialization.json.Json.decodeFromString(SprayApplicationSnapshot.serializer(),
            kotlinx.serialization.json.Json.encodeToString(SprayApplicationSnapshot.serializer(), snapshot)))
    }
    @Test fun actualCsvExporterIncludesRecordedApplicationIntent() {
        val record = com.rork.vinetrack.data.model.SprayRecord(id = "record", vineyardId = "vineyard",
            targets = listOf("powdery_mildew", "downy_mildew"), sprayHeadTarget = "full_canopy", applicationMode = "whole_block")
        val csv = SprayProgramCsvExporter.buildCsv(listOf(record), emptyList(), false, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyMap(), null)
        assertTrue(csv.contains("Disease/pest targets"))
        assertTrue(csv.contains("Powdery Mildew; Downy Mildew"))
        assertTrue(csv.contains("Full Canopy"))
        assertTrue(csv.contains("Whole block"))
        assertEquals(SprayHeadTarget.FULL_CANOPY, record.applicationGeometry?.sprayHeadTarget)
    }
    @Test fun historicalAndGroundLocationsAreNotInvented() {
        assertTrue(SprayApplicationReportFields.from(null).values.all { it == "Not recorded" })
        val fields = SprayApplicationReportFields.from(SprayApplicationSnapshot(groundTarget = SprayGroundTarget.UNDERVINE))
        assertEquals("Undervine", fields.ground)
        assertEquals("Not recorded", fields.sprayHead)
    }
    @Test fun kilogramsAreDisplayOnlyAtThreshold() {
        assertEquals("999 g", SprayGuidedFormat.quantity(999.0, "g"))
        assertEquals("1.00 kg", SprayGuidedFormat.quantity(1000.0, "g"))
        assertEquals("1.50 kg", SprayGuidedFormat.quantity(1500.0, "g"))
    }
    @Test fun manualWaterUsesExistingCalculatorAndDoesNotDemandCanopy() {
        val inputs = SprayGuidedInputs(carrierBasis = SprayCarrierBasis.MANUAL_TOTAL_VOLUME, manualTotalLitres = 420.0,
            blocks = listOf(SprayBlockInput(blockId = "block", grossAreaHectares = 2.0)))
        val flow = SprayGuidedFlow(inputs)
        assertFalse(flow.requiresCanopyConfirmation)
        assertEquals(420.0, flow.carrier!!.totalLitres, 0.0)
        assertNull(flow.blocker(SprayGuidedStep.CARRIER))
        assertNotNull(SprayGuidedFlow(inputs.copy(manualTotalLitres = 0.0)).blocker(SprayGuidedStep.CARRIER))
        assertNull(SprayGuidedFlow(inputs.copy(manualTotalLitres = Double.NaN)).carrier)
    }
    @Test fun unsupportedPlanningStaysDisabledAndInvalidRateCannotCompleteProducts() {
        assertNotNull(SprayPlanningOperationalGate.blocker(true, 1.0, false))
        val inputs = SprayGuidedInputs(carrierBasis = SprayCarrierBasis.MANUAL_TOTAL_VOLUME, manualTotalLitres = 420.0,
            blocks = listOf(SprayBlockInput(blockId = "block", grossAreaHectares = 2.0)),
            products = listOf(SprayProductLineInput("p", "Product", "g", SprayProductRateBasis.WHOLE_BLOCK_AREA, 0.0)))
        assertNotNull(SprayGuidedFlow(inputs).blocker(SprayGuidedStep.PRODUCTS))
    }
    @Test fun invalidFrozenChemicalRateCannotStartAndCFIsDisclosed() {
        val chemical = com.rork.vinetrack.data.model.SprayChemical(id = "c", name = "Fixture", volumePerTank = 1500.0, ratePerHa = 750.0, unit = "g")
        val tank = com.rork.vinetrack.data.model.SprayTank(id = "t", tankNumber = 1, waterVolume = 420.0, chemicals = listOf(chemical))
        assertNull(SprayStartRecipeValidation.blocker(listOf(tank)))
        assertNotNull(SprayStartRecipeValidation.blocker(emptyList()))
        for (rate in listOf(0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNotNull(SprayStartRecipeValidation.blocker(listOf(tank.copy(chemicals = listOf(chemical.copy(ratePerHa = rate))))))
        }
        val line = SprayProductLineResult("p", "Product", "g", SprayProductRateBasis.PER_100_LITRES, 100.0, 2000.0, 2000.0, null, null, basisInput = 1000.0)
        assertTrue(SprayGuidedFormat.productCalculation(line, 2.0)!!.contains("CF 2"))
        assertFalse(SprayGuidedFormat.productCalculation(line, 1.0)!!.contains("CF"))
    }
    @Test fun regionalEquipmentFuelAndBandDoNotChangeMetricAuthority() {
        for (country in listOf(RegionCountry.Australia, RegionCountry.UnitedStates)) {
            val region = RegionFormatter(country.recommendedPreset)
            assertEquals(420.0, region.volumeToCanonical(region.volumeValue(420.0)), 1e-6)
            assertEquals(20.0, region.volumePer100LengthToCanonical(region.volumePer100LengthValue(20.0)), 1e-6)
            assertTrue(region.formatFuelRatePerHour(10.0).endsWith(if (country == RegionCountry.UnitedStates) "gal/hr" else "L/hr"))
        }
    }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.*
import org.junit.Assert.*
import org.junit.Test

class SprayCarrierProvenanceTest {
    @Test fun `entry provenance survives physical normalisation and server round trip`() {
        for (basis in SprayCarrierBasis.entries) {
            val input = SprayGuidedInputs(
                operationType = if (basis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME) SprayOperationType.BANDED_SPRAY else SprayOperationType.FOLIAR_SPRAY,
                groundTarget = SprayGroundTarget.UNDERVINE, bandWidthTotalMetres = 1.0,
                blocks = listOf(SprayBlockInput(blockId = "block", grossAreaHectares = 10.0, mappedRowLengthMetres = 31250.0, rowSpacingMetres = 3.2)),
                targets = setOf(SprayTarget.POWDERY_MILDEW), sprayHeadTarget = SprayHeadTarget.FULL_CANOPY,
                isGrowthStageAssigned = true, isEquipmentSelected = true, isEquipmentConfirmed = true,
                tankCapacityLitres = 2000.0, carrierBasis = basis, manualTotalLitres = 400.125,
                litresPerHectare = 600.0, appliedLitresPer100Metres = 20.0,
                isCanopyConfirmed = true,
                canopy = if (basis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME) null else SprayCanopySelection(type = SprayCalculator.CanopyType.VSP, size = SprayCalculator.CanopySize.MEDIUM, density = SprayCalculator.CanopyDensity.HIGH),
                sprayVolumeChoice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
                customSprayerBasis = basis, customSprayerRate = if (basis == SprayCarrierBasis.LITRES_PER_HECTARE) 600.0 else 20.0,
                products = listOf(SprayProductLineInput(productId = "product", name = "Product", unit = "mL", basis = SprayProductRateBasis.PER_100_LITRES, rate = 150.0)),
            )
            val flow = SprayGuidedFlow(input)
            assertEquals(basis, flow.effectiveCarrierBasis)
            val carrier = requireNotNull(flow.carrier)
            assertEquals(if (basis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME) SprayCarrierBasis.LITRES_PER_HECTARE else basis, carrier.basis)
            val snapshot = requireNotNull(flow.snapshot)
            assertEquals(basis, snapshot.carrierVolumeBasis)
            assertEquals(carrier.totalLitres, snapshot.totalCarrierLitres!!, 0.0)
            val server = snapshot.carrierVolumeBasis!!.serverValue
            assertEquals(if (basis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME) "manual_actual_total" else basis.raw, server)
            assertEquals(basis, SprayCarrierBasis.from(server))
            assertEquals(carrier.basis, SprayApplicationSnapshot.from(flow.plan).carrierVolumeBasis)
            val reference = SprayCalculationReferenceBuilder.make(flow)
            if (basis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME) {
                assertEquals(400.125, carrier.totalLitres, 0.0)
                assertEquals(600.1875, flow.plan.productLines.first().totalQuantity!!, 0.0)
                assertEquals("Entered directly — not calculated from a rate or an area", reference.water.first { it.id == "totalWater" }.workings)
                assertEquals("Not used", reference.products.first().lines.first { it.id == "cf" }.value)
                assertTrue(reference.canopy.isEmpty() && reference.volume.isEmpty())
            } else {
                assertFalse(reference.water.first { it.id == "totalWater" }.workings.orEmpty().contains("Entered directly"))
                assertNotEquals("Not used", reference.products.first().lines.first { it.id == "cf" }.value)
            }
        }
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, SprayCarrierBasis.from("l_per_ha"))
    }
}

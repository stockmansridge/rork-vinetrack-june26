package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.*
import org.junit.Assert.*
import org.junit.Test

class SprayCalculatorTimingTest {
    @Test fun repeatedPlanReads() {
        val inputs = SprayGuidedInputs(
            operationType = SprayOperationType.SPREADER,
            blocks = (0 until 100).map { SprayBlockInput(blockId = "b$it", blockName = "Synthetic", grossAreaHectares = 1.0, rowSpacingMetres = 2.8) },
            carrierBasis = SprayCarrierBasis.MANUAL_TOTAL_VOLUME, manualTotalLitres = 1500.0, tankCapacityLitres = 1500.0,
            products = (0 until 20).map { SprayProductLineInput(productId = "p$it", name = "Synthetic", unit = "L", basis = SprayProductRateBasis.WHOLE_BLOCK_AREA, rate = 2.0) })
        val flow = SprayGuidedFlow(inputs)
        var checksum = 0.0
        val start = System.nanoTime()
        repeat(300) {
            checksum += flow.plan.carrier.totalLitres
            checksum += flow.geometry.grossAreaHectares
            checksum += flow.plan.productLines[0].totalQuantity ?: 0.0
        }
        println("CALCULATOR_TIMING repeated_plan_300 ms=${(System.nanoTime() - start) / 1e6} checksum=$checksum")
        assertTrue(checksum > 0)
        assertEquals(200.0, flow.plan.productLines[0].totalQuantity!!, 0.0)
    }
}

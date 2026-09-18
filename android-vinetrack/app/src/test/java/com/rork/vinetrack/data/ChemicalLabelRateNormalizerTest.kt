package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLabelRateNormalizer
import com.rork.vinetrack.data.spray.SprayProductQuantityCalculator
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayQuantityContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChemicalLabelRateNormalizerTest {
    @Test fun `per 100 litre range is retained with bare unit`() {
        val rate = ChemicalLabelRateNormalizer.parse("240–320 mL/100 L")!!
        assertEquals(ChemicalLabelRateBasis.RANGE_PER_100_LITRES, rate.basis)
        assertEquals(240.0, rate.minValue!!, 0.0)
        assertEquals(320.0, rate.maxValue!!, 0.0)
        assertEquals("mL", rate.unit)
        assertNull(rate.value)
    }

    @Test fun `per hectare range is retained with bare unit`() {
        val rate = ChemicalLabelRateNormalizer.parse("2.4–3.2 L/ha")!!
        assertEquals(ChemicalLabelRateBasis.RANGE_PER_HECTARE, rate.basis)
        assertEquals(2.4, rate.minValue!!, 0.0)
        assertEquals(3.2, rate.maxValue!!, 0.0)
        assertEquals("L", rate.unit)
    }

    @Test fun `contradictory denominator is rejected`() {
        assertNull(ChemicalLabelRateNormalizer.normalize(ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.PER_100_LITRES, value = 240.0, unit = "L/ha",
        )))
    }

    @Test fun `320 millilitres per 100 litres over 1200 litres is 3840 millilitres`() {
        val total = SprayProductQuantityCalculator.totalQuantity(
            rate = 320.0,
            basis = SprayProductRateBasis.PER_100_LITRES,
            context = SprayQuantityContext(grossAreaHectares = 6.0, carrierLitres = 1200.0),
        )
        assertEquals(3840.0, total!!, 0.0)
    }
}

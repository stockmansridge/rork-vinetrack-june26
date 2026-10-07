package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.IrrigationCalculator
import com.rork.vinetrack.data.model.IrrigationSettings
import com.rork.vinetrack.data.model.SoilProfileInputs
import com.rork.vinetrack.data.model.ForecastDay
import org.junit.Assert.*
import org.junit.Test

class IrrigationRegionalAdviceTest {
    @Test fun regionalAdviceDoesNotChangeCanonicalIrrigation() {
        val soil = SoilProfileInputs("sand_loamy_sand", 70.0, 0.4, 40.0)
        val days = listOf(ForecastDay(0L, 80.0, 0.0))
        val settings = IrrigationSettings(irrigationApplicationRateMmPerHour = 4.0)
        val au = IrrigationCalculator.calculate(days, settings, soil = soil, soilAwareV2Enabled = true)!!
        val formatter = RegionFormatter(RegionCountry.UnitedStates.recommendedPreset)
        val us = IrrigationCalculator.calculate(days, settings, soil = soil, soilAwareV2Enabled = true, formatter = formatter)!!
        assertEquals(au.v2!!.soilAdjustedGrossMm, us.v2!!.soilAdjustedGrossMm, 0.0)
        assertEquals(au.recommendedIrrigationMinutes, us.recommendedIrrigationMinutes)
        assertTrue(us.v2!!.adjustmentReason!!.contains("in"))
        assertFalse(us.v2!!.adjustmentReason!!.contains("mm"))
        assertTrue(us.soilAdviceText!!.contains(formatter.formatRainfall(11.2)))
    }
}

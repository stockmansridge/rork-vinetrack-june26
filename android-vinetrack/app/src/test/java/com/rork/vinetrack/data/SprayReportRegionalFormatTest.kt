package com.rork.vinetrack.data

import org.junit.Assert.*
import org.junit.Test

class SprayReportRegionalFormatTest {
    @Test fun savedTankDetailUsesMetricAndImperialCarrierUnits() {
        val au = SprayReportRegionalFormat(RegionFormatter(RegionCountry.Australia.recommendedPreset))
        val us = SprayReportRegionalFormat(RegionFormatter(RegionCountry.UnitedStates.recommendedPreset))
        assertTrue(au.water(100.0).endsWith(" L"))
        assertEquals("2.10 ha", au.area(2.1))
        assertEquals("5.19 ac", us.area(2.1))
        assertTrue(us.water(100.0).endsWith(" gal"))
        assertTrue(us.water(0.0).endsWith(" gal"))
        assertFalse(us.water(0.0).contains(" L"))
        assertTrue(us.carrier(500.0).endsWith("gal/ac"))
        assertTrue(us.difference(10.0).startsWith("+"))
        assertTrue(us.difference(-10.0).endsWith(" gal"))
    }

    @Test fun pdfMoneyUsesAudUsdAndGbpWithoutFx() {
        for ((country, code, symbol) in listOf(Triple(RegionCountry.Australia, "AUD", "$"), Triple(RegionCountry.UnitedStates, "USD", "$"), Triple(RegionCountry.UnitedKingdom, "GBP", "£"))) {
            val formatter = RegionFormatter(country.recommendedPreset)
            assertEquals(code, formatter.currencyCode)
            val text = SprayReportRegionalFormat(formatter).money(42.5)
            assertTrue(text.contains(symbol))
            assertTrue(text.contains("42.50"))
        }
    }

    @Test fun pdfTimestampsUseVineyardDayFormatAndZone() {
        val settings = RegionCountry.UnitedStates.recommendedPreset.copy(timezone = "America/Los_Angeles", dateFormat = "MM/DD/YYYY")
        val us = SprayReportRegionalFormat(RegionFormatter(settings))
        assertEquals("10/06/2026 18:30", us.dateTime("2026-10-07T01:30:00Z"))
        assertEquals("6:30 PM", us.time("2026-10-07T01:30:00Z"))
        val au = SprayReportRegionalFormat(RegionFormatter(RegionCountry.Australia.recommendedPreset.copy(timezone = "Australia/Sydney", dateFormat = "DD/MM/YYYY")))
        assertEquals("07/10/2026 12:30", au.dateTime("2026-10-07T01:30:00Z"))
        assertNull(us.dateTime(null))
    }
}

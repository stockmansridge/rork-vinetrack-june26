package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.TimeZone

/**
 * Consumer-side regression tests for the central region/unit formatting layer.
 *
 * The pre-existing coverage only proved that saving Region & Units produced the
 * right RPC payload. That is not the same as proving the SAVED settings actually
 * drive what the app renders — the bug this suite exists to prevent was
 * "settings persist correctly but every screen still prints hectares".
 *
 * These tests therefore assert the CONVERTED VALUES AND UNIT LABELS produced for
 * several Region & Units configurations, using the same arithmetic constants as
 * the iOS `RegionFormatter` so the two platforms can never drift.
 */
class RegionFormatterTest {

    private val au = RegionCountry.Australia.recommendedPreset
    private val us = RegionCountry.UnitedStates.recommendedPreset
    private val uk = RegionCountry.UnitedKingdom.recommendedPreset
    private val ca = RegionCountry.Canada.recommendedPreset

    @Before
    fun fixTimeZone() {
        // Date assertions must not depend on the machine's zone.
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    // ---------------------------------------------------------------- area

    @Test
    fun `area stays hectares for australia`() {
        assertEquals("12.50 ha", RegionFormatter(au).formatArea(12.5))
    }

    @Test
    fun `area converts to acres for the united states`() {
        // 12.5 ha x 2.471053814672 = 30.888... -> 30.89 ac
        assertEquals("30.89 ac", RegionFormatter(us).formatArea(12.5))
    }

    @Test
    fun `area unit label follows the vineyard setting`() {
        assertEquals("ha", RegionFormatter(au).areaUnitAbbreviation)
        assertEquals("ac", RegionFormatter(us).areaUnitAbbreviation)
    }

    @Test
    fun `compact area keeps australian output byte for byte`() {
        val fmt = RegionFormatter(au)
        // Mirrors the trimming the screens previously did inline with " ha".
        assertEquals("12 ha", fmt.formatAreaCompact(12.0))
        assertEquals("4.5 ha", fmt.formatAreaCompact(4.5))
    }

    @Test
    fun `compact area converts and re-thresholds on the displayed value`() {
        val fmt = RegionFormatter(us)
        // 4 ha -> 9.88 ac: still below 10, so one decimal is kept.
        assertEquals("9.9 ac", fmt.formatAreaCompact(4.0))
        // 10 ha -> 24.71 ac: at/above 10, so decimals drop.
        assertEquals("24 ac", fmt.formatAreaCompact(10.0))
    }

    @Test
    fun `area conversion never mutates the stored hectare value`() {
        val stored = 12.5
        RegionFormatter(us).formatArea(stored)
        assertEquals("display-only conversion must not touch the record", 12.5, stored, 0.0)
    }

    // ------------------------------------------------------------ distance

    @Test
    fun `distance converts kilometres to miles for imperial`() {
        assertEquals("1.50 km", RegionFormatter(au).formatDistance(1500.0))
        assertEquals("0.93 mi", RegionFormatter(us).formatDistance(1500.0))
    }

    @Test
    fun `short distance uses metres or feet`() {
        assertEquals("337m", RegionFormatter(au).formatShortDistance(337.0))
        // 337 m x 3.280839895 = 1105.64 ft
        assertEquals("1106ft", RegionFormatter(us).formatShortDistance(337.0))
    }

    @Test
    fun `short distance switches to the larger unit past one unit`() {
        assertEquals("1.5km", RegionFormatter(au).formatShortDistance(1500.0))
        // 2 km = 6561 ft, still under a mile (5280 ft is the switch point)
        assertEquals("1.2mi", RegionFormatter(us).formatShortDistance(2000.0))
    }

    @Test
    fun `speed converts to mph for imperial`() {
        assertEquals("10.0 km/h", RegionFormatter(au).formatSpeed(10.0))
        assertEquals("6.2 mph", RegionFormatter(us).formatSpeed(10.0))
    }

    // -------------------------------------------------------------- volume

    @Test
    fun `volume converts litres to us gallons`() {
        assertEquals("1000.0 L", RegionFormatter(au).formatVolume(1000.0))
        // 1000 L x 0.264172052 = 264.17 US gal
        assertEquals("264.2 gal", RegionFormatter(us).formatVolume(1000.0))
    }

    @Test
    fun `united kingdom uses imperial gallons not us gallons`() {
        // The UK preset is metric, so force gallons to isolate the constant.
        val ukGallons = uk.copy(volumeUnit = VolumeUnit.Gallons.raw, fuelUnit = FuelUnit.Gallons.raw)
        // 1000 L x 0.219969157 = 219.97 imperial gal
        assertEquals("220.0 gal", RegionFormatter(ukGallons).formatVolume(1000.0))
        assertNotEquals(
            "imperial and US gallons must not share a constant",
            RegionFormatter(us).formatVolume(1000.0),
            RegionFormatter(ukGallons).formatVolume(1000.0),
        )
    }

    @Test
    fun `fuel rate and cost per unit stay internally consistent`() {
        val fmt = RegionFormatter(us)
        assertEquals("2.6 gal/hr", fmt.formatFuelRatePerHour(10.0))
        // Cost per litre -> cost per gallon must DIVIDE by gallons-per-litre so
        // the rate and its label describe the same quantity.
        assertTrue(fmt.formatFuelCostPerUnit(1.85).endsWith("/gal"))
        assertTrue(RegionFormatter(au).formatFuelCostPerUnit(1.85).endsWith("/L"))
    }

    // --------------------------------------------- spray / application rate

    @Test
    fun `spray rate converts the area denominator`() {
        assertEquals("1000.00 L/ha", RegionFormatter(au).formatSprayRate(1000.0, "L"))
        // 1000 / 2.471053814672 = 404.69 per acre
        assertEquals("404.69 L/ac", RegionFormatter(us).formatSprayRate(1000.0, "L"))
    }

    @Test
    fun `volume per area converts BOTH dimensions`() {
        assertEquals("1000 L/ha", RegionFormatter(au).formatVolumePerArea(1000.0))
        // 1000 L/ha -> 264.17 gal/ha -> 106.91 gal/ac
        assertEquals("107 gal/ac", RegionFormatter(us).formatVolumePerArea(1000.0))
        assertEquals("L/ha", RegionFormatter(au).volumePerAreaUnit)
        assertEquals("gal/ac", RegionFormatter(us).volumePerAreaUnit)
    }

    @Test
    fun `volume per area per hour keeps the hour suffix`() {
        assertEquals("1,200 L/ha/h", RegionFormatter(au).formatVolumePerAreaPerHour(1200.0))
        assertEquals("128 gal/ac/h", RegionFormatter(us).formatVolumePerAreaPerHour(1200.0))
    }

    // ------------------------------------------------------ yield per area

    @Test
    fun `yield per area converts to per acre`() {
        assertEquals("12.50 t/ha", RegionFormatter(au).formatYieldPerArea(12.5))
        // 12.5 / 2.471053814672 = 5.06 t/ac
        assertEquals("5.06 t/ac", RegionFormatter(us).formatYieldPerArea(12.5))
        assertEquals("t/ha", RegionFormatter(au).yieldPerAreaUnit())
        assertEquals("t/ac", RegionFormatter(us).yieldPerAreaUnit())
    }

    // ----------------------------------------------------------- date

    private val march5 = Instant.parse("2026-03-05T12:00:00Z").toEpochMilli()

    @Test
    fun `date format follows the vineyard setting`() {
        assertEquals("5 Mar 2026", RegionFormatter(au).formatDate(march5))
        assertEquals("Mar 5, 2026", RegionFormatter(us).formatDate(march5))
        assertEquals("2026-03-05", RegionFormatter(ca).formatDate(march5))
    }

    // ------------------------------------------------------- temperature

    @Test
    fun `temperature is NOT region converted and matches ios`() {
        // Deliberate: the Region & Units contract (sql/099) has no temperature
        // unit and iOS performs no temperature conversion. GDD/BEDD models and
        // disease-risk thresholds are defined in Celsius. Converting on Android
        // alone would make one vineyard read differently on the two platforms.
        assertEquals("21.5\u00b0C", RegionFormatter(au).formatTemperature(21.5))
        assertEquals("21.5\u00b0C", RegionFormatter(us).formatTemperature(21.5))
        assertEquals("21.5\u00b0C", RegionFormatter(uk).formatTemperature(21.5))
    }

    // ---------------------------------------------------------- currency

    @Test
    fun `currency code follows the vineyard setting`() {
        assertEquals("AUD", RegionFormatter(au).currencyCode)
        assertEquals("USD", RegionFormatter(us).currencyCode)
        assertEquals("GBP", RegionFormatter(uk).currencyCode)
        assertEquals("CAD", RegionFormatter(ca).currencyCode)
    }

    @Test
    fun `currency formatting groups thousands`() {
        assertTrue(RegionFormatter(au).formatCurrency(1250.0).contains("1,250"))
        assertTrue(RegionFormatter(us).formatCurrency(1250.0).contains("1,250"))
    }

    // -------------------------------------------------- duration (neutral)

    @Test
    fun `duration is region independent and never abbreviates minutes to m`() {
        // "min" not "m", so it can't be misread as metres.
        assertEquals("45 min", RegionFormatter.formatDuration(45 * 60L))
        assertEquals("2 h", RegionFormatter.formatDuration(2 * 3600L))
        assertEquals("2 h 30 min", RegionFormatter.formatDuration(2 * 3600L + 30 * 60L))
    }

    // ------------------------------------------------------------ presets

    @Test
    fun `united states preset selects the full imperial set`() {
        assertEquals(AreaUnit.Acres.raw, us.areaUnit)
        assertEquals(VolumeUnit.Gallons.raw, us.volumeUnit)
        assertEquals(DistanceSystem.Imperial.raw, us.distanceUnit)
        assertEquals(FuelUnit.Gallons.raw, us.fuelUnit)
        assertEquals(SprayRateAreaUnit.Acre.raw, us.sprayRateAreaUnit)
        assertEquals(RegionDateFormat.MonthDayYear.raw, us.dateFormat)
        assertEquals("USD", us.currencyCode)
    }

    @Test
    fun `australian defaults perform no conversion at all`() {
        // Guards existing AU/NZ users: the default path must be a pure no-op.
        val fmt = RegionFormatter(RegionSettings.defaults)
        assertEquals(5.0, fmt.areaValue(5.0), 1e-9)
        assertEquals(5.0, fmt.volumeValue(5.0), 1e-9)
        assertEquals(5.0, fmt.fuelValue(5.0), 1e-9)
        assertEquals(5.0, fmt.sprayRateValue(5.0), 1e-9)
        assertEquals(5.0, fmt.perAreaValue(5.0), 1e-9)
    }

    @Test
    fun `unknown or blank raw values fall back to the australian baseline`() {
        // A vineyard row written by an older client, or a partially-populated
        // row, must never produce a broken unit label.
        val junk = RegionSettings(
            areaUnit = "furlongs",
            volumeUnit = "",
            distanceUnit = "warp",
            fuelUnit = "",
            sprayRateAreaUnit = "nope",
            dateFormat = "??",
        )
        val fmt = RegionFormatter(junk)
        assertEquals("12.50 ha", fmt.formatArea(12.5))
        assertEquals("1.50 km", fmt.formatDistance(1500.0))
        assertEquals("5 Mar 2026", fmt.formatDate(march5))
    }
}

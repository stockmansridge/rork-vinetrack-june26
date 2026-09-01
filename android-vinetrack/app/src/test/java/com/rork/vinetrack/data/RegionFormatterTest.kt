package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.Locale
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
    fun `area unit name is the full word for split stat tiles`() {
        // The Home "Vineyard Overview" card shows the number and the unit as two
        // separate lines, so it needs the word rather than the abbreviation.
        assertEquals("Hectares", RegionFormatter(au).areaUnitName)
        assertEquals("Acres", RegionFormatter(us).areaUnitName)
        // Canada's preset is metric (hectares) even though it shares US
        // terminology and Brix — the label follows the AREA unit, not the country.
        assertEquals("Hectares", RegionFormatter(ca).areaUnitName)
    }

    @Test
    fun `headline area keeps australian output byte for byte`() {
        val fmt = RegionFormatter(au)
        // Reproduces the inline rule the Home overview tile used before it was
        // regionalised: one decimal below 100, none at or above it.
        assertEquals("12.5", fmt.formatAreaHeadline(12.5))
        assertEquals("99.9", fmt.formatAreaHeadline(99.9))
        assertEquals("100", fmt.formatAreaHeadline(100.0))
        assertEquals("1234", fmt.formatAreaHeadline(1234.0))
    }

    @Test
    fun `headline area converts and re-thresholds on the displayed value`() {
        val fmt = RegionFormatter(us)
        // 12.5 ha -> 30.89 ac: below 100, so one decimal is kept.
        assertEquals("30.9", fmt.formatAreaHeadline(12.5))
        // 45 ha -> 111.2 ac: the CONVERTED value crosses 100, so decimals drop
        // even though the canonical hectare figure has not.
        assertEquals("111", fmt.formatAreaHeadline(45.0))
    }

    @Test
    fun `headline area is never the raw hectare number for an acres vineyard`() {
        // Regression: the Home overview tile printed canonical hectares under a
        // hardcoded "Hectares" caption, so an acres vineyard saw hectare figures
        // while every other screen converted.
        val hectares = 40.0
        val usFmt = RegionFormatter(us)
        assertNotEquals(usFmt.formatAreaHeadline(hectares), RegionFormatter(au).formatAreaHeadline(hectares))
        assertEquals("98.8", usFmt.formatAreaHeadline(hectares))
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
    fun `numeric date renders the saved vineyard template literally`() {
        // Exact iOS parity: iOS `RegionFormatter.formatDate` renders the numeric
        // `dateFormatTemplate`, so a vineyard set to MM/DD/YYYY must never show a
        // day-first date on Android.
        assertEquals("05/03/2026", RegionFormatter(au).formatDate(march5))
        assertEquals("03/05/2026", RegionFormatter(us).formatDate(march5))
        assertEquals("2026-03-05", RegionFormatter(ca).formatDate(march5))
    }

    @Test
    fun `each supported date format renders the SAME stored instant`() {
        // One canonical instant, three vineyard configurations: the stored value is
        // untouched and only presentation differs.
        val dmy = au.copy(dateFormat = RegionDateFormat.DayMonthYear.raw)
        val mdy = au.copy(dateFormat = RegionDateFormat.MonthDayYear.raw)
        val iso = au.copy(dateFormat = RegionDateFormat.IsoYearMonthDay.raw)
        assertEquals("05/03/2026", RegionFormatter(dmy).formatDate(march5))
        assertEquals("03/05/2026", RegionFormatter(mdy).formatDate(march5))
        assertEquals("2026-03-05", RegionFormatter(iso).formatDate(march5))
    }

    @Test
    fun `medium date keeps month names but follows the vineyard field order`() {
        assertEquals("5 Mar 2026", RegionFormatter(au).formatDateMedium(march5))
        assertEquals("Mar 5, 2026", RegionFormatter(us).formatDateMedium(march5))
        // en-CA abbreviates March as "Mar." (with a period), so the expectation is
        // built from the vineyard locale's own symbol rather than hardcoding one
        // region's spelling. What is being asserted is the FIELD ORDER.
        val caMonth = RegionFormatter(ca).monthAbbreviation(3)
        assertEquals("2026 $caMonth 5", RegionFormatter(ca).formatDateMedium(march5))
        assertTrue("ISO vineyards must lead with the year", RegionFormatter(ca).formatDateMedium(march5).startsWith("2026"))
    }

    @Test
    fun `date time appends a 24h clock to the vineyard template`() {
        assertEquals("05/03/2026 12:00", RegionFormatter(au).formatDateTime(march5))
        assertEquals("03/05/2026 12:00", RegionFormatter(us).formatDateTime(march5))
        assertEquals("05/03/2026 12:00:00", RegionFormatter(au).formatDateTime(march5, includeSeconds = true))
    }

    @Test
    fun `month names come from the vineyard locale not the device`() {
        // The device default is forced to French to prove the formatter ignores it:
        // the vineyard is en_AU, so the month name must stay English.
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("fr-FR"))
            assertEquals("5 Mar 2026", RegionFormatter(au).formatDateMedium(march5))
            assertEquals("Mar", RegionFormatter(au).monthAbbreviation(3))
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun `decimal separator ignores the device locale`() {
        // A comma-decimal device locale must not turn "12.50 ha" into "12,50 ha".
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("12.50 ha", RegionFormatter(au).formatArea(12.5))
            assertEquals("30.89 ac", RegionFormatter(us).formatArea(12.5))
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun `vineyard timezone decides the calendar day, not the device zone`() {
        // 2026-03-05T20:00Z is already 6 March in Adelaide, so a vineyard pinned to
        // Adelaide must show the 6th even while the phone is on UTC.
        val evening = Instant.parse("2026-03-05T20:00:00Z").toEpochMilli()
        assertEquals("05/03/2026", RegionFormatter(au).formatDate(evening))
        val adelaide = au.copy(timezone = "Australia/Adelaide")
        assertEquals("06/03/2026", RegionFormatter(adelaide).formatDate(evening))
    }

    @Test
    fun `an unknown timezone falls back instead of throwing`() {
        val broken = au.copy(timezone = "Mars/Olympus_Mons")
        assertEquals("05/03/2026", RegionFormatter(broken).formatDate(march5))
    }

    // ------------------------------------------------------- cost per unit

    @Test
    fun `cost per area re-bases the money over the displayed area unit`() {
        // $500/ha is $202.34/ac. Relabelling without dividing would overstate an
        // acre vineyard's cost by 2.47x.
        assertTrue(RegionFormatter(au).formatCostPerArea(500.0).endsWith("/ha"))
        assertTrue(RegionFormatter(us).formatCostPerArea(500.0).endsWith("/ac"))
        assertTrue(RegionFormatter(us).formatCostPerArea(500.0).contains("202.3"))
        assertEquals("ha", RegionFormatter(au).costPerAreaUnit)
        assertEquals("ac", RegionFormatter(us).costPerAreaUnit)
    }

    @Test
    fun `cost per volume converts per litre to per gallon`() {
        assertTrue(RegionFormatter(au).formatCostPerVolume(2.0).endsWith("/L"))
        val perGallon = RegionFormatter(us).formatCostPerVolume(2.0)
        assertTrue(perGallon.endsWith("/gal"))
        // $2.00/L x 3.785 L per US gallon = $7.57/gal
        assertTrue(perGallon.contains("7.5"))
    }

    @Test
    fun `mass per area converts only the denominator`() {
        // The contract has no mass unit and iOS converts none, so kg stays kg while
        // the area denominator follows the vineyard.
        assertEquals("kg/ha", RegionFormatter(au).massPerAreaUnit())
        assertEquals("kg/ac", RegionFormatter(us).massPerAreaUnit())
        assertEquals("100.00 kg/ha", RegionFormatter(au).formatSprayRate(100.0, "kg"))
        assertEquals("40.47 kg/ac", RegionFormatter(us).formatSprayRate(100.0, "kg"))
    }

    // --------------------------------------- editable round trip (no corruption)

    @Test
    fun `area round trips canonical to display to canonical`() {
        val fmt = RegionFormatter(us)
        val storedHa = 12.5
        val shown = fmt.areaValue(storedHa)
        assertEquals(30.888, shown, 0.001)
        // Untouched value must save back byte-identical.
        assertEquals(storedHa, fmt.areaToCanonical(shown), 1e-9)
        // User edits 30.89 -> 31.00 ac, which is 12.545 ha.
        assertEquals(12.545, fmt.areaToCanonical(31.0), 0.001)
    }

    @Test
    fun `every inverse converter is an exact mirror of its forward converter`() {
        // Guards the corruption case: display conversion working while the save
        // path writes the displayed number straight into a canonical column.
        listOf(us, uk, ca, au).forEach { settings ->
            val fmt = RegionFormatter(settings)
            val v = 37.25
            assertEquals(v, fmt.areaToCanonical(fmt.areaValue(v)), 1e-9)
            assertEquals(v, fmt.volumeToCanonical(fmt.volumeValue(v)), 1e-9)
            assertEquals(v, fmt.fuelToCanonical(fmt.fuelValue(v)), 1e-9)
            assertEquals(v, fmt.sprayRateToCanonical(fmt.sprayRateValue(v)), 1e-9)
            assertEquals(v, fmt.perAreaToCanonical(fmt.perAreaValue(v)), 1e-9)
        }
    }

    @Test
    fun `australian round trip is a pure identity`() {
        val fmt = RegionFormatter(au)
        assertEquals(9.75, fmt.areaToCanonical(9.75), 1e-9)
        assertEquals(9.75, fmt.sprayRateToCanonical(9.75), 1e-9)
    }

    // ---------------------------------------------------------- rainfall

    @Test
    fun `rainfall stays millimetres for australia byte for byte`() {
        // The historical Rain & Forecast rendering was "%.1f mm" — AU output
        // must not change at all.
        assertEquals("12.5 mm", RegionFormatter(au).formatRainfall(12.5))
        assertEquals("mm", RegionFormatter(au).rainfallUnitAbbreviation)
    }

    @Test
    fun `rainfall converts to inches for the united states`() {
        // 12.5 mm / 25.4 = 0.4921... -> 0.49 in (inches show two decimals
        // because 1 mm is only ~0.04 in).
        assertEquals("0.49 in", RegionFormatter(us).formatRainfall(12.5))
        assertEquals("in", RegionFormatter(us).rainfallUnitAbbreviation)
        assertEquals(1.0, RegionFormatter(us).rainfallValue(25.4), 1e-9)
    }

    @Test
    fun `rainfall 25 point 4 mm reads exactly one inch under imperial`() {
        assertEquals("25.4 mm", RegionFormatter(au).formatRainfall(25.4))
        assertEquals("1.00 in", RegionFormatter(us).formatRainfall(25.4))
    }

    @Test
    fun `rainfall defaults to millimetres when the setting is absent`() {
        // Canada, UK etc. keep mm; default settings (metric distance) also
        // resolve to mm so pre-existing vineyards are unaffected.
        assertEquals("12.5 mm", RegionFormatter(ca).formatRainfall(12.5))
        assertEquals("12.5 mm", RegionFormatter(RegionSettings()).formatRainfall(12.5))
    }

    @Test
    fun `rainfall unit is derived from the distance setting alone`() {
        // There is no independently stored rainfall preference — imperial
        // distance means inches, metric distance means millimetres.
        assertEquals("in", RegionFormatter(RegionSettings(distanceUnit = DistanceSystem.Imperial.raw)).rainfallUnitAbbreviation)
        assertEquals("mm", RegionFormatter(RegionSettings(distanceUnit = DistanceSystem.Metric.raw)).rainfallUnitAbbreviation)
    }

    // ------------------------------------------------------- temperature

    @Test
    fun `temperature stays celsius under metric distance`() {
        // AU and UK presets use metric distance, so weather stays °C — the
        // historical rendering is unchanged for them.
        assertEquals("21.5\u00b0C", RegionFormatter(au).formatTemperature(21.5))
        assertEquals("20.0\u00b0C", RegionFormatter(au).formatTemperature(20.0))
        assertEquals("21.5\u00b0C", RegionFormatter(uk).formatTemperature(21.5))
    }

    @Test
    fun `temperature converts to fahrenheit under imperial distance`() {
        // Weather display follows the shared Metric/Imperial Distance setting
        // (matching the Portal): mi → °F. Raw values remain Celsius — only the
        // display converts, mirroring iOS `formatTemperature`.
        assertEquals("68.0\u00b0F", RegionFormatter(us).formatTemperature(20.0))
        assertEquals("32.0\u00b0F", RegionFormatter(us).formatTemperature(0.0))
        assertEquals("°F", RegionFormatter(us).temperatureUnitAbbreviation)
        assertEquals(68.0, RegionFormatter(us).temperatureValue(20.0), 1e-9)
        assertEquals(20.0, RegionFormatter(au).temperatureValue(20.0), 1e-9)
        assertEquals("70–86°F", RegionFormatter(us).formatTemperatureRange(21.0, 30.0))
        assertEquals("21–30°C", RegionFormatter(au).formatTemperatureRange(21.0, 30.0))
    }

    // ---------------------------------------------------------------- wind

    @Test
    fun `wind speed stays km per hour under metric distance`() {
        assertEquals("10.0 km/h", RegionFormatter(au).formatSpeed(10.0))
        assertEquals("km/h", RegionFormatter(au).speedUnitAbbreviation)
    }

    @Test
    fun `wind speed converts to mph under imperial distance`() {
        // 10 km/h * 0.621371192 = 6.21... → "6.2 mph".
        assertEquals("6.2 mph", RegionFormatter(us).formatSpeed(10.0))
        assertEquals("mph", RegionFormatter(us).speedUnitAbbreviation)
        assertEquals(6.21371192, RegionFormatter(us).speedValue(10.0), 1e-6)
    }

    @Test
    fun `distance setting alone drives all three weather displays`() {
        // Same canonical inputs; ONLY distanceUnit differs. No stored value is
        // rebased — metric value functions are pure identities.
        val metric = RegionSettings(distanceUnit = DistanceSystem.Metric.raw)
        val imperial = metric.copy(distanceUnit = DistanceSystem.Imperial.raw)
        assertEquals("25.4 mm", RegionFormatter(metric).formatRainfall(25.4))
        assertEquals("1.00 in", RegionFormatter(imperial).formatRainfall(25.4))
        assertEquals("20.0\u00b0C", RegionFormatter(metric).formatTemperature(20.0))
        assertEquals("68.0\u00b0F", RegionFormatter(imperial).formatTemperature(20.0))
        assertEquals("10.0 km/h", RegionFormatter(metric).formatSpeed(10.0))
        assertEquals("6.2 mph", RegionFormatter(imperial).formatSpeed(10.0))
        // Canonical passthrough under metric proves conversion is display-only.
        assertEquals(25.4, RegionFormatter(metric).rainfallValue(25.4), 1e-9)
        assertEquals(20.0, RegionFormatter(metric).temperatureValue(20.0), 1e-9)
        assertEquals(10.0, RegionFormatter(metric).speedValue(10.0), 1e-9)
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
        assertEquals("05/03/2026", fmt.formatDate(march5))
    }
}

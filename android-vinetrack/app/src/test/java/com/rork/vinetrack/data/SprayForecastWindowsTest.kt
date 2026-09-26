package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

class SprayForecastWindowsTest {
    private val zone = TimeZone.getTimeZone("Australia/Sydney")
    private val now = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssX", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.parse("2026-09-24T14:00:00Z")!!.time

    private fun period(hour: Int, date: String = "2026-09-25", low: Double? = 11.0,
                       high: Double? = 34.0, wind: Double? = 14.0, rain: Double? = 0.1,
                       humidity: Double? = null) = SprayForecastPeriod(date, hour,
        tempMinC = low, tempMaxC = high, windMaxKmh = wind, rainMm = rain,
        humidityMinPct = humidity, humidityMaxPct = humidity, sampleCount = 4)

    @Test fun exactThresholdsAndMissingMeasurements() {
        assertTrue(SprayForecastWindows.qualifiesOptimal(period(0)))
        assertFalse(SprayForecastWindows.qualifiesHighHumidity(period(0)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, low = 10.0)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, high = 35.0)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, wind = 15.0)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, rain = 0.101)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, low = null)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, high = null)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, wind = null)))
        assertFalse(SprayForecastWindows.qualifiesOptimal(period(0, rain = null)))
        assertTrue(SprayForecastWindows.qualifiesHighHumidity(period(0, humidity = 90.0)))
        assertFalse(SprayForecastWindows.qualifiesHighHumidity(period(0, humidity = 89.9)))
    }

    @Test fun sharedFixtureProducesSameBoundariesAndNonOverlappingBandsAsIos() {
        val fixture = listOf(period(4), period(8, humidity = 90.0), period(12),
            period(16, wind = null), period(20), period(0, date = "2026-09-26"))
        val windows = SprayForecastWindows.windows(fixture, zone, now)
        assertEquals(listOf("4-8:OPTIMAL", "8-12:HIGH_HUMIDITY", "12-16:OPTIMAL", "20-28:OPTIMAL"),
            windows.map { "${(it.start - now) / 3_600_000}-${(it.end - now) / 3_600_000}:${it.kind}" })
        assertTrue(windows[3].label(zone, now).contains("Fri 8:00 PM – Sat 4:00 AM"))
        assertEquals(2, SprayForecastWindows.windows(listOf(period(4), period(8), period(12, humidity = 90.0)), zone, now).size)
        assertEquals(2, SprayForecastWindows.windows(listOf(period(4), period(12)), zone, now).size)
    }

    @Test fun supplementationRetainsPrimaryAndCrossMidnightIsExplicit() {
        val primary = period(4, low = 12.0, wind = null, rain = null)
        val supplemented = SprayForecastWindows.supplement(listOf(primary), listOf(
            period(4, low = 99.0, wind = 8.0, rain = 0.0), period(4, date = "2026-09-26")))
        assertEquals(12.0, supplemented[0].tempMinC)
        assertEquals(8.0, supplemented[0].windMaxKmh)
        assertEquals(0.0, supplemented[0].rainMm)
        assertEquals("2026-09-26", supplemented[1].date)
        val cross = SprayForecastWindow(now + 22 * 3_600_000, now + 30 * 3_600_000, SprayForecastWindow.Kind.OPTIMAL)
        assertTrue(cross.label(zone, now).contains("Fri 10:00 PM – Sat 6:00 AM"))
    }
}

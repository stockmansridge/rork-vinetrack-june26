package com.rork.vinetrack.data

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.TimeZone

class DavisOptimalRipenessParityTest {
    private val zone = TimeZone.getTimeZone("Australia/Sydney")

    @Test
    fun `captured Davis extrema decode to canonical iOS daily and cumulative GDD`() {
        val fixture = SupabaseClient.json.parseToJsonElement(CAPTURED_DAVIS_RESPONSE).jsonObject
        val parsed = parseDavisHistoricTemperatures(requireNotNull(fixture["sensors"]).jsonArray, zone)
        val service = DegreeDayService(timeZone = zone)
        val source = DegreeDayService.davisKey("123345")
        service.installDailyTemps(source, parsed.dailyTemps)
        val points = service.dailyGddSeries(
            sourceKey = source,
            fromMs = Instant.parse("2026-09-15T14:00:00Z").toEpochMilli(),
            toMs = Instant.parse("2026-09-21T14:00:00Z").toEpochMilli(),
            latitude = -33.28,
            useBEDD = false,
        )

        val expected = listOf(8.0, 7.0, 6.0, 6.0, 5.0, 5.0)
        assertEquals(expected.size, points.size)
        expected.zip(points).forEach { (value, point) -> assertEquals(value, point.daily, 0.000_001) }
        assertEquals(37.0, points.sumOf { it.daily }, 0.000_001)
        assertEquals(points.sumOf { it.daily }, points.last().cumulative, 0.000_001)
        assertEquals(6, parsed.records.size)
        assertTrue(parsed.records.all { it.highField == "temp_hi" && it.lowField == "temp_lo" })
    }

    @Test
    fun `missing average current and indoor values are never used as Davis extrema`() {
        val fixture = SupabaseClient.json.parseToJsonElement(CAPTURED_DAVIS_RESPONSE).jsonObject
        val parsed = parseDavisHistoricTemperatures(requireNotNull(fixture["sensors"]).jsonArray, zone)

        assertEquals(6, parsed.dailyTemps.size)
        assertTrue(parsed.records.none { it.sensorType == 27 })
        assertEquals(
            GddCalculationMode.GDD,
            GddSettings(hasExplicitCalculationMode = false).calculationModeForSource("davis:123345"),
        )
        assertEquals(
            GddCalculationMode.BEDD,
            GddSettings(GddCalculationMode.BEDD, hasExplicitCalculationMode = true).calculationModeForSource("davis:123345"),
        )
    }

    companion object {
        private val CAPTURED_DAVIS_RESPONSE = """
            {"sensors":[
              {"sensor_type":23,"data":[
                {"ts":1789480800,"temp_hi":77.0,"temp_lo":51.8},
                {"ts":1789567200,"temp_hi":75.2,"temp_lo":50.0},
                {"ts":1789653600,"temp_hi":73.4,"temp_lo":48.2},
                {"ts":1789740000,"temp_hi":71.6,"temp_lo":50.0},
                {"ts":1789826400,"temp_hi":69.8,"temp_lo":48.2},
                {"ts":1789912800,"temp_hi":68.0,"temp_lo":50.0},
                {"ts":1789916400,"temp_avg":90.0,"temp_last":90.0},
                {"ts":1789917000,"temp_hi":null,"temp_lo":null}
              ]},
              {"sensor_type":27,"data":[{"ts":1789480800,"temp_hi":95.0,"temp_lo":80.0}]}
            ]}
        """.trimIndent()
    }
}

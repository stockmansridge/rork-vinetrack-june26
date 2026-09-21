package com.rork.vinetrack.data

import com.rork.vinetrack.data.insights.BudburstReconciler
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.screens.computeRows
import com.rork.vinetrack.ui.screens.earliestRequiredWeatherDate
import com.rork.vinetrack.ui.screens.seasonStartDate
import com.rork.vinetrack.ui.screens.startOfDayMs
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.TimeZone

class OptimalRipenessParityTest {
    private val utc = TimeZone.getTimeZone("UTC")
    private val start = Instant.parse("2026-09-01T00:00:00Z").toEpochMilli()
    private val end = Instant.parse("2026-09-05T00:00:00Z").toEpochMilli()

    @Test
    fun `shared fixed series has canonical daily contributions cumulative values and total`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, mapOf(
            "20260901" to DailyTemp(20.0, 10.0),
            "20260902" to DailyTemp(24.0, 12.0),
            "20260903" to DailyTemp(18.0, 8.0),
            "20260904" to DailyTemp(30.0, 14.0),
        ))

        val points = service.dailyGddSeries(key, start, end, latitude = null, useBEDD = false)

        assertEquals(listOf(5.0, 8.0, 3.0, 12.0), points.map { it.daily })
        assertEquals(listOf(5.0, 13.0, 16.0, 28.0), points.map { it.cumulative })
        assertEquals(28.0, points.last().cumulative, 0.0001)
        assertTrue(service.hasCompleteData(key, start, end))
    }

    @Test
    fun `daily contributions never go negative and totals use unrounded values`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.davisKey("station-1")
        service.installDailyTemps(key, mapOf(
            "20260901" to DailyTemp(8.2, 1.4),
            "20260902" to DailyTemp(23.33, 10.11),
        ))
        val points = service.dailyGddSeries(
            key,
            start,
            Instant.parse("2026-09-03T00:00:00Z").toEpochMilli(),
            latitude = null,
            useBEDD = false,
        )

        assertEquals(0.0, points[0].daily, 0.0)
        assertEquals(6.72, points[1].daily, 0.000_001)
        assertEquals(points.sumOf { it.daily }, points.last().cumulative, 0.000_001)
    }

    @Test
    fun `provider caches cannot combine in one calculation`() {
        val service = DegreeDayService(timeZone = utc)
        val davis = DegreeDayService.davisKey("station-1")
        val openMeteo = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(davis, mapOf("20260901" to DailyTemp(30.0, 20.0)))
        service.installDailyTemps(openMeteo, mapOf("20260902" to DailyTemp(30.0, 20.0)))

        assertEquals(4, service.dailyGddSeries(davis, start, end, null, false).size)
        assertTrue(service.dailyGddSeries(davis, start, end, null, false).all { it.daily == 15.0 })
        assertFalse(service.hasCompleteData(davis, start, end))
        assertFalse(service.hasCompleteData(openMeteo, start, end))
    }

    @Test
    fun `missing Budburst produces no season-start GDD result`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, (1..4).associate { day -> "2026090$day" to DailyTemp(30.0, 10.0) })
        val block = Paddock(id = "b1", vineyardId = "v1", name = "North")

        val row = computeRows(service, key, -33.28, listOf(block), emptyList(), false, end).rows.single()

        assertNull(row.resetDateMs)
        assertFalse(row.hasGddValue)
        assertEquals(0.0, row.total, 0.0)
    }

    @Test
    fun `EL4 establishes Budburst and recalculates only from EL4 date`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, (1..4).associate { day -> "2026090$day" to DailyTemp(30.0, 10.0) })
        val block = Paddock(id = "b1", vineyardId = "v1", name = "North")
        val el4 = GrowthStageRecord(id = "el4", vineyardId = "v1", paddockId = "b1", stageCode = "EL4", observedAt = "2026-09-03T09:00:00Z")
        val update = BudburstReconciler.missingBudburstUpdates(listOf(block), listOf(el4)).single()
        val established = block.copy(budburstDate = "${update.localDate}T00:00:00Z")

        val row = computeRows(service, key, -33.28, listOf(established), emptyList(), false, end).rows.single()

        assertTrue(row.hasGddValue)
        assertEquals(Instant.parse("2026-09-03T00:00:00Z").toEpochMilli(), row.resetDateMs)
        assertEquals(20.0, row.total, 0.0001)
    }

    @Test
    fun `explicit Season Start uses vineyard start while missing Budburst never falls back`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, (1..4).associate { day -> "2026090$day" to DailyTemp(30.0, 10.0) })
        val seasonStart = Instant.parse("2026-09-01T00:00:00Z").toEpochMilli()
        val blocks = listOf(
            Paddock(id = "season", vineyardId = "v1", name = "Season", resetModeOverride = "seasonStart"),
            Paddock(id = "budburst", vineyardId = "v1", name = "Budburst", resetModeOverride = "budburst"),
        )

        val rows = computeRows(
            service, key, -33.28, blocks, emptyList(), false, end,
            seasonStart, GddResetMode.BUDBURST, GddCalculationMode.GDD, utc,
        ).rows.associateBy { it.block.id }

        assertEquals(40.0, rows.getValue("season").total, 0.0001)
        assertEquals(seasonStart, rows.getValue("season").resetDateMs)
        assertNull(rows.getValue("budburst").resetDateMs)
        assertFalse(rows.getValue("budburst").hasGddValue)
        assertEquals(seasonStart, earliestRequiredWeatherDate(blocks, seasonStart, GddResetMode.BUDBURST))
    }

    @Test
    fun `per-block calculation override wins over vineyard default`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(key, (1..4).associate { day -> "2026090$day" to DailyTemp(30.0, 10.0) })
        val blocks = listOf(
            Paddock(id = "gdd", vineyardId = "v1", name = "GDD", budburstDate = "2026-09-01", calculationModeOverride = "gdd"),
            Paddock(id = "bedd", vineyardId = "v1", name = "BEDD", budburstDate = "2026-09-01", calculationModeOverride = "bedd"),
        )

        val rows = computeRows(
            service, key, -33.28, blocks, emptyList(), true, end,
            start, GddResetMode.BUDBURST, GddCalculationMode.BEDD, utc,
        ).rows.associateBy { it.block.id }

        assertEquals(40.0, rows.getValue("gdd").total, 0.0001)
        assertTrue(rows.getValue("bedd").total < rows.getValue("gdd").total)
    }

    @Test
    fun `vineyard timezone controls season and day boundaries`() {
        val auckland = TimeZone.getTimeZone("Pacific/Auckland")
        val instant = Instant.parse("2026-09-01T11:30:00Z").toEpochMilli()
        assertEquals(Instant.parse("2026-08-31T12:00:00Z").toEpochMilli(), startOfDayMs(instant, utc))
        assertEquals(Instant.parse("2026-09-01T12:00:00Z").toEpochMilli(), startOfDayMs(instant, auckland))
        assertEquals(
            Instant.parse("2026-06-30T12:00:00Z").toEpochMilli(),
            seasonStartDate(7, 1, auckland, Instant.parse("2026-09-01T00:00:00Z").toEpochMilli()),
        )
    }

    @Test
    fun `persisted daily rows restore after service recreation`() {
        val cache = MemoryDailyWeatherCache()
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        DegreeDayService(cache, utc).installDailyTemps(key, mapOf("20260901" to DailyTemp(20.0, 10.0)))

        val recreated = DegreeDayService(cache, utc)

        assertTrue(recreated.hasUsableData(key))
        assertEquals(5.0, recreated.dailyGddSeries(key, start, Instant.parse("2026-09-02T00:00:00Z").toEpochMilli(), null, false).single().daily, 0.0)
    }

    @Test
    fun `warm cache requests only missing dates plus three-day overlap`() {
        val service = DegreeDayService(timeZone = utc)
        val key = DegreeDayService.openMeteoKey(-33.28, 149.10)
        val tenDayEnd = Instant.parse("2026-09-11T00:00:00Z").toEpochMilli()
        val rows = (1..10).associate { day -> "202609${day.toString().padStart(2, '0')}" to DailyTemp(20.0, 10.0) }.toMutableMap()
        rows.remove("20260904")
        service.installDailyTemps(key, rows)

        val windows = service.refreshWindows(key, start, tenDayEnd)

        assertEquals(2, windows.size)
        assertEquals(Instant.parse("2026-09-04T00:00:00Z").toEpochMilli(), windows[0].startEpochMs)
        assertEquals(Instant.parse("2026-09-05T00:00:00Z").toEpochMilli(), windows[0].endEpochMs)
        assertEquals(Instant.parse("2026-09-08T00:00:00Z").toEpochMilli(), windows[1].startEpochMs)
        assertEquals(tenDayEnd, windows[1].endEpochMs)
    }

    @Test
    fun `Davis selection remains authoritative for every ripeness calculation surface`() {
        val integration = VineyardWeatherIntegration(
            id = "i1", vineyardId = "v1", provider = WeatherIntegrationProvider.DAVIS,
            hasApiKey = true, hasApiSecret = true, stationId = "station-42", isActive = true,
        )
        val surfaces = listOf("hub", "detail", "season-total", "cumulative-chart", "daily-chart", "dashboard-chip", "projection")

        val keys = surfaces.map {
            resolveOptimalRipenessSource(Result.success(integration), -33.28, 149.10, null).sourceKey
        }.toSet()

        assertEquals(setOf("davis:station-42"), keys)
    }

    @Test
    fun `Open-Meteo selection remains authoritative for every ripeness calculation surface`() {
        val expected = DegreeDayService.openMeteoKey(-33.28, 149.10)
        val surfaces = List(7) { it }

        val keys = surfaces.map {
            resolveOptimalRipenessSource(Result.success(null), -33.28, 149.10, "davis:old").sourceKey
        }.toSet()

        assertEquals(setOf(expected), keys)
    }

    @Test
    fun `provider switch cannot reuse previous provider rows or coverage`() {
        val service = DegreeDayService(timeZone = utc)
        val davis = DegreeDayService.davisKey("station-1")
        val openMeteo = DegreeDayService.openMeteoKey(-33.28, 149.10)
        service.installDailyTemps(davis, (1..4).associate { day -> "2026090$day" to DailyTemp(20.0, 10.0) })

        assertTrue(service.hasCompleteData(davis, start, end))
        assertFalse(service.hasUsableData(openMeteo))
        assertFalse(service.hasCompleteData(openMeteo, start, end))
        assertEquals(listOf(WeatherDateWindow(start, end)), service.refreshWindows(openMeteo, start, end))
    }

    @Test
    fun `EL4 fills only an unset budburst and chooses earliest existing observation`() {
        val missing = Paddock(id = "b1", vineyardId = "v1", name = "North")
        val manual = Paddock(id = "b2", vineyardId = "v1", name = "South", budburstDate = "2026-09-03")
        val observations = listOf(
            GrowthStageRecord(id = "later", vineyardId = "v1", paddockId = "b1", stageCode = "EL4", observedAt = "2026-09-05T09:00:00Z"),
            GrowthStageRecord(id = "earlier", vineyardId = "v1", paddockId = "b1", stageCode = "el4", observedAt = "2026-09-02T09:00:00Z"),
            GrowthStageRecord(id = "manual-block", vineyardId = "v1", paddockId = "b2", stageCode = "EL4", observedAt = "2026-09-01T09:00:00Z"),
        )

        val updates = BudburstReconciler.missingBudburstUpdates(listOf(missing, manual), observations)

        assertEquals(1, updates.size)
        assertEquals("b1", updates.single().paddockId)
        assertEquals("earlier", updates.single().observationId)
        assertEquals("2026-09-02", updates.single().localDate)
    }

    private class MemoryDailyWeatherCache : DailyWeatherCache {
        private val rowsBySource = mutableMapOf<String, Map<String, DailyTemp>>()

        override fun load(sourceKey: String): Map<String, DailyTemp> = rowsBySource[sourceKey].orEmpty()

        override fun lastSuccessfulRefreshMs(sourceKey: String): Long? = null

        override fun save(
            sourceKey: String,
            timeZoneId: String,
            stationOrLocationId: String,
            rows: Map<String, DailyTemp>,
            refreshedAtMs: Long,
        ) {
            rowsBySource[sourceKey] = rows.toMap()
        }
    }
}

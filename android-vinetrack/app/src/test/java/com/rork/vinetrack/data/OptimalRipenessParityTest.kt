package com.rork.vinetrack.data

import com.rork.vinetrack.data.insights.BudburstReconciler
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock
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
}

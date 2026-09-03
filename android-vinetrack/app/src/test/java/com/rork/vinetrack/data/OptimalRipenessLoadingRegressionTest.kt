package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.ui.screens.OptimalRipenessScreenState
import com.rork.vinetrack.ui.screens.buildImmediateRipenessResult
import com.rork.vinetrack.ui.screens.planOptimalRipenessRefresh
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OptimalRipenessLoadingRegressionTest {
    private val vineyardId = "vineyard-1"
    private val block = Paddock(
        id = "block-1",
        vineyardId = vineyardId,
        name = "North Block",
        varietyAllocations = listOf(
            PaddockVarietyAllocation(
                varietyKey = "shiraz",
                varietyName = "Shiraz",
                percentage = 100.0,
            )
        ),
        budburstDate = "2026-09-01T00:00:00Z",
    )
    private val varieties = listOf(
        GrapeVarietyRow(
            id = "variety-1",
            vineyardId = vineyardId,
            varietyKey = "shiraz",
            displayName = "Shiraz",
            optimalGddOverride = 1_450.0,
        )
    )

    @Test
    fun `first Davis load renders local block metadata before weather completes`() {
        val immediate = buildImmediateRipenessResult(
            paddocks = listOf(block),
            grapeVarieties = varieties,
            seasonStartMs = 1_756_684_800_000L,
            globalResetMode = GddResetMode.BUDBURST,
            cachedSnapshot = null,
            fallbackSourceLabel = "Davis WeatherLink",
            sourceFingerprint = "davis:station-42",
        )
        val loading = OptimalRipenessScreenState(immediate, isUpdatingWeather = true)

        assertTrue(loading.isUpdatingWeather)
        assertEquals("Davis WeatherLink", loading.result.sourceLabel)
        assertEquals(1, loading.result.rows.size)
        assertEquals("North Block", loading.result.rows.single().block.name)
        assertEquals("Shiraz", loading.result.rows.single().varietyName)
        assertEquals(1_450.0, loading.result.rows.single().target, 0.0)
        assertTrue(loading.result.rows.single().resetDateMs != null)
        assertFalse(loading.result.rows.single().hasGddValue)
    }

    @Test
    fun `cached Davis values remain visible throughout a slow refresh`() {
        val cached = cachedDavis()
        val immediate = buildImmediateRipenessResult(
            paddocks = listOf(block),
            grapeVarieties = varieties,
            seasonStartMs = 1_756_684_800_000L,
            globalResetMode = GddResetMode.BUDBURST,
            cachedSnapshot = cached,
            fallbackSourceLabel = "Checking weather source…",
        )
        val loading = OptimalRipenessScreenState(immediate, isUpdatingWeather = true)

        assertTrue(loading.isUpdatingWeather)
        assertEquals("Davis WeatherLink", loading.result.sourceLabel)
        assertEquals(812.0, loading.result.rows.single().total, 0.0)
        assertTrue(loading.result.rows.single().hasGddValue)
    }

    @Test
    fun `confirmed weather source change keeps block rows but invalidates old GDD`() {
        val cached = cachedDavis()
        val openMeteoPlan = planOptimalRipenessRefresh(
            cachedSnapshot = cached,
            integrationRead = Result.success(null),
            latitude = -33.28,
            longitude = 149.10,
        )
        val replacement = buildImmediateRipenessResult(
            paddocks = listOf(block),
            grapeVarieties = varieties,
            seasonStartMs = 1_756_684_800_000L,
            globalResetMode = GddResetMode.BUDBURST,
            cachedSnapshot = openMeteoPlan.cachedSnapshot,
            fallbackSourceLabel = "Open-Meteo Archive",
            sourceFingerprint = openMeteoPlan.desiredFingerprint.orEmpty(),
        )

        assertTrue(openMeteoPlan.shouldRemoveCachedSnapshot)
        assertNull(openMeteoPlan.cachedSnapshot)
        assertEquals(1, replacement.rows.size)
        assertEquals("North Block", replacement.rows.single().block.name)
        assertFalse(replacement.rows.single().hasGddValue)
    }

    @Test
    fun `Davis historic windows use the maximum supported day and cover the range`() {
        val start = 1_700_000_000_000L
        val end = start + (90L * 86_400_000L) + 3_600_000L
        val windows = davisHistoricWindows(start, end)

        assertEquals(91, windows.size)
        assertEquals(start, windows.first().startEpochMs)
        assertEquals(end, windows.last().endEpochMs)
        assertTrue(windows.all { it.endEpochMs - it.startEpochMs in 1L..86_400_000L })
        assertTrue(windows.zipWithNext().all { (left, right) -> left.endEpochMs == right.startEpochMs })
    }

    private fun cachedDavis(): OptimalRipenessSnapshot = OptimalRipenessSnapshot(
        ownerId = "owner-1",
        vineyardId = vineyardId,
        sourceFingerprint = "davis:station-42",
        sourceLabel = "Davis WeatherLink",
        cachedAtEpochMs = 1_000L,
        rows = listOf(
            OptimalRipenessSnapshotRow(
                blockId = block.id,
                varietyName = "Shiraz",
                allocationPercent = 100.0,
                resetDateMs = 1_756_684_800_000L,
                total = 812.0,
                target = 1_450.0,
                daysToTarget = 31,
            )
        ),
    )
}

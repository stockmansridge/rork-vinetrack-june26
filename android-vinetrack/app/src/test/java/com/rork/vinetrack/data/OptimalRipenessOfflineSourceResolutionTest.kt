package com.rork.vinetrack.data

import com.rork.vinetrack.ui.screens.planOptimalRipenessRefresh
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class OptimalRipenessOfflineSourceResolutionTest {
    @Test
    fun `cached Davis rows remain visible when integration RPC is unavailable`() {
        val cachedDavis = OptimalRipenessSnapshot(
            ownerId = "owner-1",
            vineyardId = "vineyard-1",
            sourceFingerprint = "davis:station-42",
            sourceLabel = "Davis WeatherLink",
            cachedAtEpochMs = 1_000L,
            rows = listOf(
                OptimalRipenessSnapshotRow(
                    blockId = "block-1",
                    varietyName = "Shiraz",
                    total = 812.0,
                    target = 1_450.0,
                    daysToTarget = 31,
                )
            ),
        )

        val plan = planOptimalRipenessRefresh(
            cachedSnapshot = cachedDavis,
            integrationRead = Result.failure(IllegalStateException("offline")),
            latitude = -33.28,
            longitude = 149.10,
        )

        assertSame(cachedDavis, plan.cachedSnapshot)
        assertEquals(1, plan.cachedSnapshot?.rows?.size)
        assertEquals("Davis WeatherLink", plan.cachedSnapshot?.sourceLabel)
        assertEquals("davis:station-42", plan.desiredFingerprint)
        assertFalse(plan.shouldRefresh)
        assertFalse(plan.shouldRemoveCachedSnapshot)
        assertNull(plan.davisIntegration)
    }
}

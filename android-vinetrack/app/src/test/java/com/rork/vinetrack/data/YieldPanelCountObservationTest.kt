package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PanelCountEntry
import com.rork.vinetrack.data.model.PanelCountMeasurement
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class YieldPanelCountObservationTest {
    @Test fun rawPanelSnapshotSurvivesCrossDeviceJsonWithoutInventingBunchesPerVine() {
        val block = UUID.randomUUID().toString()
        val measurement = requireNotNull(PanelCountMeasurement.make(120, 10, 8, 1, 1, 6.0))
        val original = YieldEstimationSession(
            id = UUID.randomUUID().toString(),
            vineyardId = UUID.randomUUID().toString(),
            createdAt = "2026-11-05T05:00:00Z",
            selectedPaddockIds = listOf(block),
            countMethod = "panel",
            isCompleted = true,
            completedAt = "2026-11-05T05:01:00Z",
            sampleSites = listOf(SampleSite(
                id = UUID.randomUUID().toString(), paddockId = block,
                rowNumber = 12, latitude = -34.0, longitude = 149.0, siteIndex = 1,
                yieldRowReference = "12A", yieldPanelReference = "E-4",
                panelCountEntry = PanelCountEntry(measurement, "2026-11-05T05:00:30Z", "test"),
            )),
        )
        val restored = Json.decodeFromString<YieldEstimationSession>(Json.encodeToString(original))
        assertTrue(restored.isPanelCount)
        assertEquals("Panel Count", restored.countMethodName)
        assertEquals(120, restored.sampleSites.single().panelCountEntry?.measurement?.totalBunches)
        assertNull(restored.sampleSites.single().bunchCountEntry)
        assertTrue(restored.sampleSites.single().isRecorded)
        assertEquals("12A", restored.sampleSites.single().yieldRowReference)
        val vintage = YieldVintageReport.sessionVintage(restored, 7, 1)
        assertNull(YieldVintageReport.latestCompletedSessionForBlock(listOf(restored), block, vintage, 7, 1))
        assertTrue(YieldVintageReport.estimateRows(
            listOf(restored), emptyList(), remainingYieldMultiplier = { 1.0 }, vintage = vintage,
            seasonStartMonth = 7, seasonStartDay = 1
        ).isEmpty())
    }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regression for the header overlay used by refreshWorkTasks after its complete server read. */
class WorkTaskFullRefreshParityTest {
    @Test
    fun fullServerSnapshotRestoresTwentyFourTasksRegardlessOfPreviousSeventeenTaskCache() {
        val server = (0 until 24).map { index ->
            WorkTask(
                id = "task-$index", vineyardId = "stockmans-ridge",
                date = if (index == 0) "2026-06-23" else "2026-09-03",
                taskType = "Pruning",
            )
        }
        var local = server.take(17)
        assertEquals(17, local.size)
        // refreshWorkTasks uses the entire listWorkTasks response as this baseline.
        local = PendingWriteOverlay.overlayWorkTaskHeaders(server, emptyList(), "stockmans-ridge")
        assertEquals(24, local.size)
        assertEquals(24, local.map { it.id }.toSet().size)
        assertTrue(local.map { it.id }.containsAll(server.drop(17).map { it.id }))
        assertEquals(23, local.count { (it.date ?: "") >= "2026-07-01" })
    }
}

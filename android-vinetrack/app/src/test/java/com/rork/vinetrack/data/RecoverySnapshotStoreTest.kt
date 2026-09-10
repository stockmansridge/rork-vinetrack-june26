package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class RecoverySnapshotStoreTest {
    @Test
    fun `first pre-replay snapshot remains byte-identical after later replacement attempt`() {
        val bytes = mutableMapOf<String, String>()
        val store = RecoverySnapshotStore(
            readRaw = { bytes[it] },
            writeRawIfAbsent = { key, value -> if (bytes.containsKey(key)) false else { bytes[key] = value; true } },
        )
        val before = RecoverySnapshotStore.Snapshot(
            vineyardId = "vineyard",
            appVersion = "3.0.3",
            buildVersion = 8,
            snapshotAt = "2026-09-10T00:00:00Z",
            source = "before_vineyard_load_refresh_or_replay",
            pendingWrites = emptyList(),
            captureEvidence = emptyList(),
            cachedPins = emptyList(),
            cachedTrips = emptyList(),
            activeTrip = null,
            sourceStatuses = listOf(RecoverySnapshotStore.SourceStatus("cached_pins", "read", 175)),
            excludedOrUnreadable = listOf(
                RecoverySnapshotStore.ExcludedEvidence("pending_writes", "bad", "Vineyard could not be read."),
            ),
        )
        val after = before.copy(snapshotAt = "2026-09-10T00:01:00Z", sourceStatuses = emptyList())

        store.saveIfAbsent(before)
        store.saveIfAbsent(after)

        val restored = store.load("vineyard")!!
        assertEquals(before, restored)
        assertEquals(175, restored.sourceStatuses.single().itemCount)
        assertEquals(1, restored.excludedOrUnreadable.size)
    }
}

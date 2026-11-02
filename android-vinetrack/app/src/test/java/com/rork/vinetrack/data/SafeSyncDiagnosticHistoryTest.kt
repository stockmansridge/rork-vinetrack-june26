package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafeSyncDiagnosticHistoryTest {
    @Test fun onlyExactOwnerAndVineyardMayBeExported() {
        SafeSyncDiagnosticHistory.clear()
        try {
            SafeSyncDiagnosticHistory.record("PHASE5_ENTRY", "ownerA", "vineyardA")
            SafeSyncDiagnosticHistory.record("PHASE5_EXIT", "ownerB", "vineyardA")
            SafeSyncDiagnosticHistory.record("QUEUE_OBSERVED", "ownerA", "vineyardB")
            SafeSyncDiagnosticHistory.record("INVALID_CODE", "ownerA", "vineyardA")
            SafeSyncDiagnosticHistory.record("PHASE5_FREEZE", null, "vineyardA")
            val mine = SafeSyncDiagnosticHistory.snapshot("ownerA", "vineyardA")
            assertEquals(1, mine.size)
            assertEquals("PHASE5_ENTRY", mine.first()["code"])
            assertEquals(1, SafeSyncDiagnosticHistory.snapshot("ownerB", "vineyardA").size)
            assertEquals(1, SafeSyncDiagnosticHistory.snapshot("ownerA", "vineyardB").size)
            assertTrue(SafeSyncDiagnosticHistory.snapshot("ownerB", "vineyardB").isEmpty())
            assertFalse(mine.first().containsKey("ownerId"))
            assertFalse(mine.first().containsKey("vineyardId"))
        } finally {
            SafeSyncDiagnosticHistory.clear()
        }
    }

    @Test fun clearingRemovesAllRetainedEvents() {
        SafeSyncDiagnosticHistory.clear()
        SafeSyncDiagnosticHistory.record("MANUAL_REFRESH", "account", "block")
        assertEquals(1, SafeSyncDiagnosticHistory.snapshot("account", "block").size)
        SafeSyncDiagnosticHistory.clear()
        assertTrue(SafeSyncDiagnosticHistory.snapshot("account", "block").isEmpty())
    }
}

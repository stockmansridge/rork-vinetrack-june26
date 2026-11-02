package com.rork.vinetrack.data.spray

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Issue #47 — editing/reviewing is not a completed application and a queued
 * local operation is not evidence of a server-accepted spray record.
 */
class ManualSprayReviewStatusTest {
    @Test fun unsavedReviewIsNotCompleted() {
        val label = manualSprayReviewStatusLabel(ManualSprayReviewStatus.REVIEW_ONLY)
        assertEquals("Review only — not yet saved", label)
        assertFalse(label.contains("Completed"))
    }

    @Test fun locallyQueuedSaveDoesNotClaimServerAcceptance() {
        val label = manualSprayReviewStatusLabel(
            ManualSprayReviewStatus.SAVED_LOCALLY_PENDING_CONFIRMATION
        )
        assertEquals("Saved on device — awaiting server confirmation", label)
        assertFalse(label.contains("Completed"))
    }

    @Test fun completedIsOnlyForServerConfirmed() {
        assertEquals(
            "Completed — server confirmed",
            manualSprayReviewStatusLabel(ManualSprayReviewStatus.SERVER_CONFIRMED)
        )
    }
}

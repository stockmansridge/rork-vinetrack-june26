package com.rork.vinetrack.data.spray

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #47: label and actionable state after form dismissal, process
 * restoration, backend replay and account/vineyard isolation.
 *
 * These pure JVM checks do not replace device SharedPreferences tests.
 */
class ManualSprayReviewStatusTest {
    @Test fun unsavedReviewIsNotCompleted() {
        val value = manualSprayReviewStatus(
            serverConfirmed = false, hasRetainedSave = false, hasSubmissionMarker = false
        )
        assertEquals(ManualSprayReviewStatus.REVIEW_ONLY, value)
        assertTrue(value.canOfferSave())
        assertFalse(manualSprayReviewStatusLabel(value).contains("Completed"))
    }

    @Test fun reopenedOriginalPendingOperationStillBlocksSave() {
        val value = manualSprayReviewStatus(
            serverConfirmed = false, hasRetainedSave = true, hasSubmissionMarker = false
        )
        assertEquals(ManualSprayReviewStatus.SAVED_LOCALLY_PENDING_CONFIRMATION, value)
        assertFalse(value.canOfferSave())
        assertEquals("Saved on device — awaiting server confirmation", manualSprayReviewStatusLabel(value))
    }

    @Test fun backgroundAckWithoutReadbackIsVerificationRequired() {
        // The outbox has cleared, but the locally persisted submission marker
        // must prevent a second manual spray from being created.
        val value = manualSprayReviewStatus(
            serverConfirmed = false, hasRetainedSave = false, hasSubmissionMarker = true
        )
        assertEquals(ManualSprayReviewStatus.VERIFICATION_REQUIRED, value)
        assertFalse(value.canOfferSave())
        assertFalse(manualSprayReviewStatusLabel(value).contains("Completed"))
    }

    @Test fun inFlightRequestDisablesResubmissionAndDismissal() {
        val value = manualSprayReviewStatus(
            serverConfirmed = false, hasRetainedSave = false, hasSubmissionMarker = true,
            inFlight = true
        )
        assertEquals(ManualSprayReviewStatus.SUBMITTING, value)
        assertFalse(value.canOfferSave())
        assertEquals("Saving original manual spray — do not close", manualSprayReviewStatusLabel(value))
    }

    @Test fun completedRequiresExactCoordinatorConfirmation() {
        val value = manualSprayReviewStatus(
            serverConfirmed = true, hasRetainedSave = false, hasSubmissionMarker = true
        )
        assertEquals(ManualSprayReviewStatus.SERVER_CONFIRMED, value)
        assertFalse(value.canOfferSave())
        assertEquals("Completed — server confirmed", manualSprayReviewStatusLabel(value))
    }
}

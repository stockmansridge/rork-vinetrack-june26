package com.rork.vinetrack.data.spray

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Requires an Android device/emulator; exercises the *actual* local storage
 * implementation, not a mocked Boolean or ephemeral remember state. */
@RunWith(AndroidJUnit4::class)
class ManualSpraySubmissionGuardInstrumentedTest {
    @Test fun markerSurvivesScreenReopenAndSeparatesOwnerAndVineyard() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext
        val owner = UUID.randomUUID().toString()
        val otherOwner = UUID.randomUUID().toString()
        val vineyard = UUID.randomUUID().toString()
        val otherVineyard = UUID.randomUUID().toString()
        val original = UUID.randomUUID().toString()
        val alternate = UUID.randomUUID().toString()

        val first = ManualSpraySubmissionGuard(app)
        try {
            assertTrue(first.mark(owner, vineyard, original))
            // New instance reads original durable FieldStoreAccess prefs.
            val reopened = ManualSpraySubmissionGuard(app)
            assertEquals(original, reopened.submittedId(owner, vineyard, original))
            assertTrue(reopened.mark(owner, vineyard, alternate))
            assertEquals(alternate, reopened.submittedId(owner, vineyard, alternate))
            assertNull(reopened.submittedId(otherOwner, vineyard, original))
            assertNull(reopened.submittedId(owner, otherVineyard, original))
            reopened.clearIfMatching(owner, vineyard, alternate)
            assertEquals(original, reopened.submittedId(owner, vineyard, original))
            reopened.clearIfMatching(owner, vineyard, original)
            assertNull(reopened.submittedId(owner, vineyard, original))
        } finally {
            first.clearIfMatching(owner, vineyard, original)
        }
    }
}

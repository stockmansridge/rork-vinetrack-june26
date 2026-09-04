package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PinDuplicateCreateAttemptTest {
    @Test
    fun `Create anyway creates exactly once for that warning`() {
        var creates = 0
        val attempt = PinDuplicateCreateAttempt { creates += 1 }
        assertTrue(attempt.createAnyway())
        assertFalse(attempt.createAnyway())
        assertEquals(1, creates)
    }

    @Test
    fun `cancel creates nothing and a future attempt remains independently enabled`() {
        var creates = 0
        val cancelled = PinDuplicateCreateAttempt { creates += 1 }
        assertTrue(cancelled.cancel())
        assertFalse(cancelled.createAnyway())
        assertEquals(0, creates)

        val future = PinDuplicateCreateAttempt { creates += 1 }
        assertTrue(future.createAnyway())
        assertEquals(1, creates)
    }
}

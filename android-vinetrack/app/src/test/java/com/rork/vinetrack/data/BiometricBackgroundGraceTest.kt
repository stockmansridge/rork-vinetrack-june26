package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.BiometricBackgroundGrace
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BiometricBackgroundGraceTest {
    @Test fun graceThresholdAndDisabled() {
        listOf(30_000L, 300_000L, 3_540_000L, 3_599_999L).forEach {
            assertFalse(BiometricBackgroundGrace.shouldLock(it, true))
        }
        assertTrue(BiometricBackgroundGrace.shouldLock(3_600_000L, true))
        assertTrue(BiometricBackgroundGrace.shouldLock(3_600_001L, true))
        assertFalse(BiometricBackgroundGrace.shouldLock(3_600_000L, false))
        // A reboot resets elapsedRealtime; err toward locking rather than exposing data.
        assertTrue(BiometricBackgroundGrace.shouldLock(-1L, true))
    }
}

package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PinLocationFixValidatorTest {
    private val now = 90_000_000_000L

    private fun validate(
        ageMs: Long = 0,
        accuracy: Double = 5.0,
        latitude: Double = -32.99,
        longitude: Double = 148.99,
        hasAccuracy: Boolean = true,
    ): PinLocationResult = PinLocationFixValidator.validate(
        latitude = latitude,
        longitude = longitude,
        hasAccuracy = hasAccuracy,
        accuracyMetres = accuracy,
        fixTimeEpochMs = 1_700_000_000_000L,
        fixElapsedRealtimeNanos = now - ageMs * 1_000_000L,
        nowElapsedRealtimeNanos = now,
        bearingDegrees = 42.0,
    )

    @Test
    fun `stale shed cache is rejected`() {
        assertEquals(PinLocationResult.Stale, validate(ageMs = 5_001))
    }

    @Test
    fun `five second accurate boundary is accepted`() {
        assertTrue(validate(ageMs = 5_000, accuracy = 15.0) is PinLocationResult.Success)
    }

    @Test
    fun `low accuracy and missing accuracy are rejected`() {
        assertEquals(PinLocationResult.Inaccurate, validate(accuracy = 15.01))
        assertEquals(PinLocationResult.Invalid, validate(hasAccuracy = false))
    }

    @Test
    fun `non finite and out of range coordinates are rejected`() {
        assertEquals(PinLocationResult.Invalid, validate(latitude = Double.NaN))
        assertEquals(PinLocationResult.Invalid, validate(latitude = 91.0))
        assertEquals(PinLocationResult.Invalid, validate(longitude = 181.0))
    }

    @Test
    fun `stationary replacement fixes remain independently fresh`() {
        val first = validate(ageMs = 4_900)
        val replacement = validate(ageMs = 50)
        assertTrue(first is PinLocationResult.Success)
        assertTrue(replacement is PinLocationResult.Success)
        assertEquals(
            (first as PinLocationResult.Success).fix.latitude,
            (replacement as PinLocationResult.Success).fix.latitude,
            0.0,
        )
    }

    @Test
    fun `no fix and late callbacks can never resolve an old tap`() {
        val valid = validate(ageMs = 50)
        assertNull(PinTapCaptureGate.acceptedFix(true, PinLocationResult.Timeout))
        assertNull(PinTapCaptureGate.acceptedFix(true, PinLocationResult.Cancelled))
        assertNull(PinTapCaptureGate.acceptedFix(false, valid))
        assertTrue(PinTapCaptureGate.acceptedFix(true, valid) != null)
    }

    @Test
    fun `failure outcomes explain retry without implying a saved pin`() {
        val outcomes = listOf(
            PinLocationResult.PermissionDenied,
            PinLocationResult.ApproximatePermission,
            PinLocationResult.ServicesDisabled,
            PinLocationResult.Timeout,
            PinLocationResult.Cancelled,
        )
        outcomes.forEach { assertTrue(it.operatorMessage().contains("press", ignoreCase = true)) }
    }
}

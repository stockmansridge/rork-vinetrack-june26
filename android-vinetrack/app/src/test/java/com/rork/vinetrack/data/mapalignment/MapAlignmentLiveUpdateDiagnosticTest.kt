package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.QualifiedLocationFix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The arrival-only diagnostic that distinguishes "the subscription is
 * delivering readings that are not good enough yet" from "the subscription has
 * delivered nothing at all".
 *
 * These tests also pin down the things it must NOT do: it cannot accept or
 * reject a sample, and it cannot start, stop or restart the subscription.
 */
class MapAlignmentLiveUpdateDiagnosticTest {

    private val start = 10_000L

    private fun fresh() = MapAlignmentLiveUpdateDiagnostic.started(start)

    private fun fix(
        accuracy: Double,
        observationNanos: Long,
        latitude: Double = -33.2835,
        longitude: Double = 149.0988,
    ): PinLocationResult = PinLocationResult.Success(
        QualifiedLocationFix(
            latitude = latitude,
            longitude = longitude,
            accuracyMetres = accuracy,
            fixTimeEpochMs = 1_757_000_000_000,
            fixElapsedRealtimeNanos = observationNanos,
            bearingDegrees = null,
        ),
    )

    // ----- Silence with no callback at all -----

    @Test
    fun `no diagnostic during the first few seconds of silence`() {
        val diagnostic = fresh()

        // A receiver taking a moment to produce its first fix is ordinary.
        assertNull(diagnostic.message(start))
        assertNull(diagnostic.message(start + 1_000L))
        assertNull(diagnostic.message(start + 4_999L))
    }

    @Test
    fun `zero callbacks for over five seconds produces the no-update diagnostic`() {
        val diagnostic = fresh()

        assertEquals(
            "No GPS updates received for 5 s. Waiting for Android location services…",
            diagnostic.message(start + 5_000L),
        )
        assertFalse(diagnostic.hasReceivedAnyUpdate)
        assertEquals(0, diagnostic.callbackCount)
    }

    @Test
    fun `the silence count keeps rising while nothing arrives`() {
        val diagnostic = fresh()

        assertEquals(
            "No GPS updates received for 8 s. Waiting for Android location services…",
            diagnostic.message(start + 8_000L),
        )
        assertEquals(
            "No GPS updates received for 20 s. Waiting for Android location services…",
            diagnostic.message(start + 20_400L),
        )
    }

    // ----- One callback clears it -----

    @Test
    fun `one callback resets the diagnostic`() {
        val received = fresh().onCallbackReceived(start + 6_000L)

        assertEquals(1, received.callbackCount)
        assertTrue(received.hasReceivedAnyUpdate)
        assertNull("a fresh arrival must clear the line", received.message(start + 6_000L))
        assertNull(received.message(start + 9_000L))
    }

    @Test
    fun `callbacks arriving normally never raise the diagnostic`() {
        var diagnostic = fresh()

        // The real subscription interval is about two seconds.
        (1..10).forEach { tick ->
            val now = start + tick * 2_000L
            diagnostic = diagnostic.onCallbackReceived(now)
            assertNull(diagnostic.message(now))
            assertNull(diagnostic.message(now + 1_999L))
        }
        assertEquals(10, diagnostic.callbackCount)
    }

    // ----- A gap after a previous callback -----

    @Test
    fun `a gap over five seconds after a previous callback says no NEW update`() {
        val diagnostic = fresh().onCallbackReceived(start + 2_000L)

        assertNull(diagnostic.message(start + 6_000L))
        assertEquals(
            "No new GPS update received for 5 s. Waiting for Android location services…",
            diagnostic.message(start + 7_000L),
        )
        assertEquals(
            "No new GPS update received for 9 s. Waiting for Android location services…",
            diagnostic.message(start + 11_000L),
        )
    }

    @Test
    fun `a later callback clears the gap diagnostic`() {
        val stalled = fresh().onCallbackReceived(start + 2_000L)
        assertNotNull(stalled.message(start + 9_000L))

        val resumed = stalled.onCallbackReceived(start + 9_500L)

        assertNull(resumed.message(start + 9_500L))
        assertEquals(2, resumed.callbackCount)
        // The gap is measured from the newest arrival, not the attempt start.
        assertEquals(0L, resumed.silenceMillis(start + 9_500L))
    }

    @Test
    fun `the gap is measured from the last callback not the attempt start`() {
        val diagnostic = fresh().onCallbackReceived(start + 30_000L)

        assertEquals(2_000L, diagnostic.silenceMillis(start + 32_000L))
        assertNull(diagnostic.message(start + 32_000L))
    }

    // ----- Rejected and duplicate callbacks still count -----

    @Test
    fun `callbacks rejected for calibration still reset the no-update timer`() {
        // Each of these is refused as a calibration sample but proves the
        // subscription is alive, so each must clear the silence line.
        val rejected = listOf(
            fix(12.0, 1_000_000L),
            PinLocationResult.Inaccurate,
            PinLocationResult.Stale,
            PinLocationResult.Invalid,
            PinLocationResult.Timeout,
        )

        rejected.forEachIndexed { index, _ ->
            val now = start + 9_000L + index
            val diagnostic = fresh().onCallbackReceived(now)
            assertNull(diagnostic.message(now))
            assertEquals(1, diagnostic.callbackCount)
        }
    }

    @Test
    fun `a duplicate callback counts as an arrival`() {
        var diagnostic = fresh()
        var sampling = MapAlignmentGpsSampling()

        // The exact field failure: the same observation redelivered. Sampling
        // must stay at one sample, arrivals must keep counting.
        val cached = fix(6.1, 1_000_000_000L)
        (1..6).forEach { tick ->
            val now = start + tick * 2_000L
            diagnostic = diagnostic.onCallbackReceived(now)
            sampling = sampling.offer(cached).sampling
            assertNull("a live duplicate is not silence", diagnostic.message(now))
        }

        assertEquals(6, diagnostic.callbackCount)
        assertEquals(1, sampling.sampleCount)
    }

    @Test
    fun `arrivals are counted independently of accepted samples`() {
        var diagnostic = fresh()
        var sampling = MapAlignmentGpsSampling()

        // Three arrivals, none of them acceptable: 3 updates, 0 samples.
        listOf(
            fix(12.0, 1_000_000_000L),
            PinLocationResult.Inaccurate,
            fix(20.0, 3_000_000_000L),
        ).forEachIndexed { index, result ->
            diagnostic = diagnostic.onCallbackReceived(start + index * 2_000L)
            sampling = sampling.offer(result).sampling
        }

        assertEquals(3, diagnostic.callbackCount)
        assertEquals(0, sampling.sampleCount)
        assertTrue(
            "arrival evidence must not be derived from sampleCount",
            diagnostic.hasReceivedAnyUpdate && sampling.sampleCount == 0,
        )
    }

    // ----- It cannot influence sampling or the subscription -----

    @Test
    fun `recording an arrival does not change the sampling decision`() {
        val good = fix(4.0, 1_000_000_000L)

        val withoutDiagnostic = MapAlignmentGpsSampling().offer(good)
        var diagnostic = fresh()
        diagnostic = diagnostic.onCallbackReceived(start + 500L)
        val withDiagnostic = MapAlignmentGpsSampling().offer(good)

        assertEquals(withoutDiagnostic.sampling.sampleCount, withDiagnostic.sampling.sampleCount)
        assertEquals(withoutDiagnostic.sampling.representative, withDiagnostic.sampling.representative)
        assertEquals(withoutDiagnostic::class, withDiagnostic::class)
        assertEquals(1, diagnostic.callbackCount)
    }

    @Test
    fun `a long silence does not stop restart or otherwise touch the subscription`() {
        var starts = 0
        var stops = 0
        val session = MapAlignmentLiveGpsSession(
            start = { starts += 1 },
            stop = { stops += 1 },
        )
        session.begin {}

        var diagnostic = fresh()
        // Silence right through to beyond the sampling timeout.
        (5..60).forEach { second ->
            diagnostic.message(start + second * 1_000L)
        }
        diagnostic = diagnostic.onCallbackReceived(start + 61_000L)
        diagnostic.message(start + 70_000L)

        assertEquals("the diagnostic must never restart location", 1, starts)
        assertEquals("the diagnostic must never stop the subscription", 0, stops)
        assertTrue(session.isActive)
    }

    @Test
    fun `the diagnostic is immutable so it cannot mutate shared state`() {
        val original = fresh()

        val next = original.onCallbackReceived(start + 1_000L)

        assertEquals(0, original.callbackCount)
        assertNull(original.lastCallbackElapsedMillis)
        assertEquals(1, next.callbackCount)
        assertEquals(start + 1_000L, next.lastCallbackElapsedMillis)
        // The attempt start is carried forward untouched.
        assertEquals(start, next.attemptStartedElapsedMillis)
    }

    @Test
    fun `a fresh attempt starts with no arrival history`() {
        val previous = fresh()
            .onCallbackReceived(start + 1_000L)
            .onCallbackReceived(start + 3_000L)

        val retry = MapAlignmentLiveUpdateDiagnostic.started(start + 40_000L)

        assertEquals(2, previous.callbackCount)
        assertEquals(0, retry.callbackCount)
        assertNull(retry.lastCallbackElapsedMillis)
        assertNull("a retry gets its own quiet period", retry.message(start + 44_000L))
    }

    @Test
    fun `silence is never reported as negative`() {
        val diagnostic = fresh().onCallbackReceived(start + 5_000L)

        assertEquals(0L, diagnostic.silenceMillis(start))
        assertNull(diagnostic.message(start))
    }

    // ----- Thresholds and rules stay exactly as they were -----

    @Test
    fun `the diagnostic threshold is separate from every sampling rule`() {
        assertEquals(5_000L, MapAlignmentLiveUpdateDiagnostic.QUIET_PERIOD_MILLIS)
        // Unchanged by this work:
        assertEquals(5, MapAlignmentGpsRules.MIN_SAMPLES)
        assertEquals(5_000L, MapAlignmentGpsRules.MIN_SAMPLING_MILLIS)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES, 1e-9)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES, 1e-9)
        assertEquals(45_000L, MapAlignmentGpsRules.SAMPLING_TIMEOUT_MILLIS)
        assertEquals(
            15.0,
            com.rork.vinetrack.data.PinLocationFixValidator.MAX_ACCURACY_METRES,
            1e-9,
        )
        assertEquals(5_000L, com.rork.vinetrack.data.PinLocationFixValidator.MAX_AGE_MS)
    }

    @Test
    fun `five good fixes still reach Stable while the diagnostic merely observes`() {
        var diagnostic = fresh()
        var sampling = MapAlignmentGpsSampling()
        val origin = CanonicalCoordinate(-33.2835, 149.0988)

        (0 until 5).forEach { index ->
            diagnostic = diagnostic.onCallbackReceived(start + index * 2_000L)
            sampling = sampling.offer(
                fix(
                    accuracy = 4.0,
                    observationNanos = index * 2_000_000_000L,
                    latitude = origin.latitude + index * 0.000_002,
                    longitude = origin.longitude,
                ),
            ).sampling
        }

        assertTrue(sampling.isStable)
        assertEquals(5, sampling.sampleCount)
        assertEquals(5, diagnostic.callbackCount)
        assertEquals(8_000L, sampling.samplingDurationMillis)
    }
}

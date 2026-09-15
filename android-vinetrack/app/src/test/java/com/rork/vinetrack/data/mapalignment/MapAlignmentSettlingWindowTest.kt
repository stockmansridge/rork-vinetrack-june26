package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.PinLocationFixValidator
import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.QualifiedLocationFix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Reproduces and guards the ~203 m Point 3 field failure.
 *
 * Points 1 and 2 captured normally. The operator walked ~200 m to the next
 * corner and stood still for Point 3, which reported 7 samples over 14 s,
 * ±6.6 m representative, ±7.8 m worst — and a spread of 203 m, matching the
 * distance just walked. The cause was a production-valid observation GENERATED
 * at the previous corner (production legitimately admits a fix up to ~5 s old)
 * being accepted into the sample group, where the stability radius measures the
 * furthest sample and so stayed poisoned forever.
 */
class MapAlignmentSettlingWindowTest {

    /** Point 3, the new corner the operator is standing at. */
    private val point3 = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    /** Monotonic time the Point 3 attempt began. Arbitrary, large, realistic. */
    private val attemptStart: Long = 812_000_000_000L

    private val window = MapAlignmentSettlingWindow.startingAt(attemptStart)

    private fun nanos(millisAfterAttemptStart: Long): Long =
        attemptStart + millisAfterAttemptStart * 1_000_000L

    /** Move [metresEast]/[metresNorth] from [from] using the production transform. */
    private fun offsetFrom(
        from: CanonicalCoordinate,
        metresEast: Double,
        metresNorth: Double,
    ): CanonicalCoordinate {
        val display = from.toDisplay(
            MapAlignment(
                id = "fixture",
                scope = MapAlignmentScope("i", "v"),
                eastOffsetMetres = metresEast,
                northOffsetMetres = metresNorth,
                isEnabled = true,
            ),
        )
        return CanonicalCoordinate(display.latitude, display.longitude)
    }

    /** Point 2, the previous corner, ~200 m away. */
    private val point2 = offsetFrom(point3, metresEast = 200.0, metresNorth = 0.0)

    /**
     * A production-qualified fix. Built through the real validator so the test
     * cannot admit anything production would have refused.
     */
    private fun productionFix(
        coordinate: CanonicalCoordinate,
        accuracy: Double,
        observedAtNanos: Long,
        /** Arrival time; production allows up to MAX_AGE_MS of age. */
        deliveredAtNanos: Long = observedAtNanos,
    ): PinLocationResult {
        val result = PinLocationFixValidator.validate(
            latitude = coordinate.latitude,
            longitude = coordinate.longitude,
            hasAccuracy = true,
            accuracyMetres = accuracy,
            fixTimeEpochMs = 1_757_000_000_000L + observedAtNanos / 1_000_000L,
            fixElapsedRealtimeNanos = observedAtNanos,
            nowElapsedRealtimeNanos = deliveredAtNanos,
            bearingDegrees = null,
        )
        assertTrue(
            "fixture must be a fix production genuinely accepts, not a hand-built one",
            result is PinLocationResult.Success,
        )
        return result
    }

    private fun MapAlignmentGpsSampling.offerIn(
        production: PinLocationResult,
        nowNanos: Long,
    ): MapAlignmentGpsSampling.Outcome =
        offer(production = production, settling = window, nowElapsedRealtimeNanos = nowNanos)

    // ----- 8. The actual field failure -----

    @Test
    fun `the 203 metre field failure cannot recur`() {
        var sampling = MapAlignmentGpsSampling()
        var liveUpdates = MapAlignmentLiveUpdateDiagnostic.started(0L)

        // The poisoning observation: generated at Point 2 while the operator
        // was still there or walking away, delivered 2 s into the Point 3
        // attempt while still production-fresh. Accurate, valid — wrong place.
        val previousCorner = productionFix(
            coordinate = point2,
            accuracy = 6.5,
            observedAtNanos = nanos(2_000),
            deliveredAtNanos = nanos(2_100),
        )
        liveUpdates = liveUpdates.onCallbackReceived(2_100L)
        val settlingOutcome = sampling.offerIn(previousCorner, nanos(2_100))

        assertTrue(
            "a valid reading of the previous corner must not become evidence",
            settlingOutcome is MapAlignmentGpsSampling.Outcome.Settling,
        )
        sampling = settlingOutcome.sampling
        assertEquals("the sample counter must still be at zero", 0, sampling.sampleCount)

        // Seven genuine Point 3 observations after the boundary, at the field's
        // reported accuracies and tightly clustered.
        val postSettling = listOf(
            Triple(0.0, 0.0, 6.6),
            Triple(1.5, 0.5, 7.1),
            Triple(-1.0, 1.0, 6.2),
            Triple(0.5, -1.5, 7.8),
            Triple(-1.5, -0.5, 6.4),
            Triple(1.0, 1.5, 6.9),
            Triple(-0.5, 0.5, 7.0),
        )
        postSettling.forEachIndexed { index, (east, north, accuracy) ->
            val at = nanos(6_000 + index * 1_500L)
            liveUpdates = liveUpdates.onCallbackReceived(at / 1_000_000L)
            val outcome = sampling.offerIn(
                productionFix(offsetFrom(point3, east, north), accuracy, at),
                at,
            )
            assertTrue(
                "post-settling Point 3 readings must be accepted",
                outcome is MapAlignmentGpsSampling.Outcome.Accepted,
            )
            sampling = outcome.sampling
        }

        // The counter began with the first post-settling observation.
        assertEquals(postSettling.size, sampling.sampleCount)

        val evidence = requireNotNull(sampling.evidence)
        // The failure signature was 203 m. It must now reflect only Point 3.
        assertTrue(
            "spread was ${evidence.stabilityRadiusMetres} m; travel history is still in the group",
            evidence.stabilityRadiusMetres <= MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES,
        )
        assertTrue(evidence.stabilityRadiusMetres < 5.0)
        assertTrue("Point 3 must now be able to reach Stable", sampling.isStable)

        // The representative sits at Point 3, not dragged toward Point 2.
        val centre = requireNotNull(sampling.representative)
        assertTrue(
            MapAlignmentTransform.metresBetween(centre, point3) < 3.0,
        )
        assertTrue(
            "the representative must be nowhere near the previous corner",
            MapAlignmentTransform.metresBetween(centre, point2) > 190.0,
        )

        // The excluded reading still proved the subscription was alive.
        assertEquals(postSettling.size + 1, liveUpdates.callbackCount)
    }

    @Test
    fun `five current point readings alone reach stable after settling`() {
        var sampling = MapAlignmentGpsSampling()
        repeat(MapAlignmentGpsRules.MIN_SAMPLES) { index ->
            val at = nanos(5_000 + index * 1_600L)
            sampling = sampling.offerIn(
                productionFix(offsetFrom(point3, index * 0.8, 0.4), 7.0, at),
                at,
            ).sampling
        }

        assertEquals(MapAlignmentGpsRules.MIN_SAMPLES, sampling.sampleCount)
        assertTrue(sampling.isStable)
    }

    // ----- 2 & 3. Observation time, not arrival time -----

    @Test
    fun `a delayed observation stamped before the boundary is still excluded`() {
        // The trap a plain five-second wait would fall into: the callback lands
        // well after the boundary, but the observation itself is from the walk.
        val observedDuringSettling = nanos(3_000)
        val deliveredAfterBoundary = nanos(7_400)
        val outcome = MapAlignmentGpsSampling().offerIn(
            productionFix(
                coordinate = point2,
                accuracy = 5.0,
                observedAtNanos = observedDuringSettling,
                // Still inside production's 5 s age allowance on arrival.
                deliveredAtNanos = observedDuringSettling +
                    PinLocationFixValidator.MAX_AGE_MS * 1_000_000L,
            ),
            deliveredAfterBoundary,
        )

        assertTrue(outcome is MapAlignmentGpsSampling.Outcome.Settling)
        assertEquals(0, outcome.sampling.sampleCount)
    }

    @Test
    fun `an observation generated before the attempt began can never be evidence`() {
        val outcome = MapAlignmentGpsSampling().offerIn(
            productionFix(
                coordinate = point2,
                accuracy = 4.0,
                observedAtNanos = attemptStart - 1_500L * 1_000_000L,
                deliveredAtNanos = attemptStart + 500L * 1_000_000L,
            ),
            nanos(500),
        )

        assertTrue(
            "a pre-attempt observation describes wherever the operator previously was",
            outcome is MapAlignmentGpsSampling.Outcome.BeforeAttempt,
        )
        assertEquals(0, outcome.sampling.sampleCount)
    }

    @Test
    fun `the boundary is exactly the settling millis after the attempt start`() {
        val boundary = MapAlignmentGpsRules.SETTLING_MILLIS

        assertEquals(nanos(boundary), window.eligibleAfterElapsedRealtimeNanos)
        assertFalse(window.admits(nanos(boundary - 1)))
        assertTrue("the boundary itself is inclusive", window.admits(nanos(boundary)))
        assertTrue(window.admits(nanos(boundary + 1)))
    }

    @Test
    fun `an observation exactly on the boundary is accepted`() {
        val at = nanos(MapAlignmentGpsRules.SETTLING_MILLIS)
        val outcome = MapAlignmentGpsSampling().offerIn(productionFix(point3, 6.0, at), at)

        assertTrue(outcome is MapAlignmentGpsSampling.Outcome.Accepted)
        assertEquals(1, outcome.sampling.sampleCount)
    }

    // ----- 1 & 4. Settling is not a quality judgement -----

    @Test
    fun `settling and pre-attempt outcomes never call the reading inaccurate`() {
        val settlingAt = nanos(1_000)
        val settling = MapAlignmentGpsSampling()
            .offerIn(productionFix(point3, 2.0, settlingAt), settlingAt)
        val before = MapAlignmentGpsSampling().offerIn(
            productionFix(
                point3,
                2.0,
                attemptStart - 2_000L * 1_000_000L,
                deliveredAtNanos = attemptStart,
            ),
            attemptStart,
        )

        // A ±2 m reading is excellent; it is excluded only for WHEN it was made.
        assertNull(settling.calibrationMessage())
        assertNull(before.calibrationMessage())
        assertFalse(settling.isConfigurationProblem)
        assertFalse(before.isConfigurationProblem)
    }

    @Test
    fun `the countdown reports whole seconds remaining and never goes negative`() {
        assertEquals(5, window.remainingSeconds(attemptStart))
        assertEquals(4, window.remainingSeconds(nanos(1_000)))
        assertEquals(3, window.remainingSeconds(nanos(2_000)))
        assertEquals(1, window.remainingSeconds(nanos(4_200)))
        assertEquals(0, window.remainingSeconds(nanos(5_000)))
        assertEquals(0, window.remainingSeconds(nanos(90_000)))
        assertEquals(0L, window.remainingMillis(nanos(90_000)))
    }

    @Test
    fun `the window reports expiry on the monotonic clock`() {
        assertFalse(window.hasExpired(nanos(4_999)))
        assertTrue(window.hasExpired(nanos(MapAlignmentGpsRules.SETTLING_MILLIS)))
    }

    // ----- 7. Retry -----

    @Test
    fun `retry resets the settling boundary and inherits no samples`() {
        var first = MapAlignmentGpsSampling()
        val acceptedAt = nanos(6_000)
        first = first.offerIn(productionFix(point3, 6.0, acceptedAt), acceptedAt).sampling
        assertEquals(1, first.sampleCount)

        // Retry: a brand-new attempt starting 30 s later with an empty group.
        val retryStart = nanos(30_000)
        val retryWindow = MapAlignmentSettlingWindow.startingAt(retryStart)
        val retry = MapAlignmentGpsSampling()

        assertEquals(0, retry.sampleCount)
        assertEquals(
            retryStart + MapAlignmentGpsRules.SETTLING_MILLIS * 1_000_000L,
            retryWindow.eligibleAfterElapsedRealtimeNanos,
        )
        // The sample the previous attempt accepted is now inside the NEW
        // settling window, so it cannot leak into the fresh attempt.
        assertFalse(retryWindow.admits(acceptedAt))
        val leaked = retry.offer(
            production = productionFix(point3, 6.0, acceptedAt),
            settling = retryWindow,
            nowElapsedRealtimeNanos = retryStart,
        )
        assertTrue(leaked is MapAlignmentGpsSampling.Outcome.BeforeAttempt)
        assertEquals(0, leaked.sampling.sampleCount)
    }

    // ----- 5. Existing evidence rules unchanged -----

    @Test
    fun `post-settling rules are exactly as before`() {
        assertEquals(5, MapAlignmentGpsRules.MIN_SAMPLES)
        assertEquals(5_000L, MapAlignmentGpsRules.MIN_SAMPLING_MILLIS)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES, 1e-9)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES, 1e-9)
    }

    @Test
    fun `stability was not relaxed to tolerate the 203 metre point`() {
        // If the previous corner DID somehow enter the group, the point must
        // still refuse to become Stable. Settling keeps history out; it does
        // not make a spread point acceptable.
        var sampling = MapAlignmentGpsSampling()
        sampling = sampling.offer(productionFix(point2, 6.5, nanos(6_000))).sampling
        repeat(6) { index ->
            val at = nanos(8_000 + index * 1_500L)
            val here = offsetFrom(point3, index * 0.5, 0.0)
            sampling = sampling.offer(productionFix(here, 7.0, at)).sampling
        }

        assertEquals(7, sampling.sampleCount)
        assertTrue(sampling.stabilityRadiusMetres > 90.0)
        assertFalse("a 200 m spread must never be Stable", sampling.isStable)
    }

    @Test
    fun `a post-settling reading over eight metres is still too imprecise`() {
        val at = nanos(6_000)
        val outcome = MapAlignmentGpsSampling().offerIn(productionFix(point3, 8.6, at), at)

        assertTrue(outcome is MapAlignmentGpsSampling.Outcome.TooImprecise)
        assertEquals(0, outcome.sampling.sampleCount)
    }

    @Test
    fun `duplicate detection still applies after settling`() {
        val at = nanos(6_000)
        val fix = productionFix(point3, 6.0, at)
        var sampling = MapAlignmentGpsSampling().offerIn(fix, at).sampling
        val again = sampling.offerIn(fix, nanos(6_400))

        assertTrue(again is MapAlignmentGpsSampling.Outcome.Duplicate)
        assertEquals(1, again.sampling.sampleCount)
    }

    // ----- 6. Timeout interpretation -----

    @Test
    fun `settling is added to the collection window not taken out of it`() {
        assertEquals(45_000L, MapAlignmentGpsRules.SAMPLING_TIMEOUT_MILLIS)
        assertEquals(5_000L, MapAlignmentGpsRules.SETTLING_MILLIS)
        // The operator keeps the full 45 s of real collection opportunity.
        assertEquals(50_000L, MapAlignmentGpsRules.TOTAL_ATTEMPT_TIMEOUT_MILLIS)
        assertEquals(
            MapAlignmentGpsRules.SAMPLING_TIMEOUT_MILLIS,
            MapAlignmentGpsRules.TOTAL_ATTEMPT_TIMEOUT_MILLIS -
                MapAlignmentGpsRules.SETTLING_MILLIS,
        )
    }

    // ----- 9 & 10. Not a distance rule; production untouched -----

    @Test
    fun `a post-settling reading 200 metres away is not rejected for being far`() {
        // Large movement between reference points is legitimate. The rule is
        // about time, never proximity to the previous reference.
        val at = nanos(6_000)
        val outcome = MapAlignmentGpsSampling().offerIn(productionFix(point2, 6.0, at), at)

        assertTrue(
            "distance from a previous reference must never itself reject a fix",
            outcome is MapAlignmentGpsSampling.Outcome.Accepted,
        )
    }

    @Test
    fun `production validator constants are unchanged`() {
        assertEquals(5_000L, PinLocationFixValidator.MAX_AGE_MS)
        assertEquals(15.0, PinLocationFixValidator.MAX_ACCURACY_METRES, 1e-9)
    }

    @Test
    fun `production still decides first and settling only narrows`() {
        // A fix production refuses can never be admitted, whenever it was made.
        val stale = PinLocationFixValidator.validate(
            latitude = point3.latitude,
            longitude = point3.longitude,
            hasAccuracy = true,
            accuracyMetres = 5.0,
            fixTimeEpochMs = 1_757_000_000_000L,
            fixElapsedRealtimeNanos = nanos(6_000),
            nowElapsedRealtimeNanos = nanos(6_000) + 6_000L * 1_000_000L,
            bearingDegrees = null,
        )
        assertEquals(PinLocationResult.Stale, stale)

        val outcome = MapAlignmentGpsSampling().offerIn(stale, nanos(12_000))
        assertTrue(outcome is MapAlignmentGpsSampling.Outcome.RejectedByProduction)
        assertEquals(0, outcome.sampling.sampleCount)
    }

    @Test
    fun `sampling without a window behaves exactly as before`() {
        // Callers that pass no window are unaffected, so nothing outside the
        // wizard's sampling attempt changes behaviour.
        val outcome = MapAlignmentGpsSampling()
            .offer(productionFix(point2, 6.0, attemptStart - 60_000L * 1_000_000L))

        assertTrue(outcome is MapAlignmentGpsSampling.Outcome.Accepted)
    }
}

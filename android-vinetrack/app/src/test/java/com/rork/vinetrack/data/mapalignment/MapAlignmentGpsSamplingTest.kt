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
 * The wizard's multi-sample GPS evidence gate.
 *
 * The properties that matter: a single fix can never become a reference, the
 * same fix cannot be counted twice, the canonical coordinate is a ROBUST centre
 * rather than the last reading, and production's own admission rules are
 * untouched — this layer can only ever reject more.
 */
class MapAlignmentGpsSamplingTest {

    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    /** Move [metresEast]/[metresNorth] from [origin] using the production transform. */
    private fun near(metresEast: Double, metresNorth: Double): CanonicalCoordinate {
        val display = origin.toDisplay(
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

    private fun success(
        coordinate: CanonicalCoordinate,
        accuracy: Double,
        timeMs: Long,
    ): PinLocationResult = PinLocationResult.Success(
        QualifiedLocationFix(
            latitude = coordinate.latitude,
            longitude = coordinate.longitude,
            accuracyMetres = accuracy,
            fixTimeEpochMs = timeMs,
            fixElapsedRealtimeNanos = timeMs * 1_000_000L,
            bearingDegrees = null,
        ),
    )

    /** Five tight, unique fixes spanning six seconds. */
    private fun stableRun(): MapAlignmentGpsSampling {
        var sampling = MapAlignmentGpsSampling()
        listOf(
            near(0.0, 0.0) to 0L,
            near(1.0, 0.0) to 1_500L,
            near(0.0, 1.0) to 3_000L,
            near(-1.0, 0.0) to 4_500L,
            near(0.0, -1.0) to 6_000L,
        ).forEach { (coordinate, offsetMs) ->
            val outcome = sampling.offer(success(coordinate, 4.0, 1_757_000_000_000 + offsetMs))
            sampling = outcome.sampling
        }
        return sampling
    }

    // ----- Sample admission -----

    @Test
    fun `fewer than five unique samples is never stable`() {
        var sampling = MapAlignmentGpsSampling()
        for (index in 0 until MapAlignmentGpsRules.MIN_SAMPLES - 1) {
            sampling = sampling
                .offer(success(near(index * 1.0, 0.0), 3.0, 1_757_000_000_000 + index * 2_000L))
                .sampling
            assertFalse(
                "a single fix must never be enough evidence",
                sampling.isStable,
            )
            assertTrue(sampling.progress is MapAlignmentGpsSampling.Progress.Collecting)
        }
        assertEquals(MapAlignmentGpsRules.MIN_SAMPLES - 1, sampling.sampleCount)
    }

    @Test
    fun `the same fix offered repeatedly is counted once`() {
        var sampling = MapAlignmentGpsSampling()
        val fix = success(origin, 3.0, 1_757_000_000_000)
        repeat(10) { sampling = sampling.offer(fix).sampling }

        // A cached fix redelivered is the SAME observation, not new evidence.
        assertEquals(1, sampling.sampleCount)
        assertTrue(sampling.offer(fix) is MapAlignmentGpsSampling.Outcome.Duplicate)
        assertFalse(sampling.isStable)
        assertEquals(0L, sampling.samplingDurationMillis)
    }

    @Test
    fun `five unique fixes collected too quickly are not yet stable`() {
        var sampling = MapAlignmentGpsSampling()
        // Five distinct fixes, but spanning only 400 ms: one momentary error
        // could produce all of them.
        repeat(MapAlignmentGpsRules.MIN_SAMPLES) { index ->
            sampling = sampling
                .offer(success(near(index * 0.5, 0.0), 3.0, 1_757_000_000_000 + index * 100L))
                .sampling
        }
        assertEquals(MapAlignmentGpsRules.MIN_SAMPLES, sampling.sampleCount)
        assertTrue(sampling.samplingDurationMillis < MapAlignmentGpsRules.MIN_SAMPLING_MILLIS)
        assertFalse(sampling.isStable)
        assertTrue(sampling.progress is MapAlignmentGpsSampling.Progress.Improving)
    }

    @Test
    fun `a fix worse than the calibration limit is not counted as evidence`() {
        val sampling = MapAlignmentGpsSampling()
        val tooRough = MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES + 2.0
        val outcome = sampling.offer(success(origin, tooRough, 1_757_000_000_000))

        assertTrue(outcome is MapAlignmentGpsSampling.Outcome.TooImprecise)
        assertEquals(0, outcome.sampling.sampleCount)
        // Production would have accepted it; calibration will not.
        assertTrue(tooRough < PinLocationFixValidator.MAX_ACCURACY_METRES)
    }

    @Test
    fun `a fix at exactly the calibration limit is accepted`() {
        val outcome = MapAlignmentGpsSampling().offer(
            success(origin, MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES, 1_757_000_000_000),
        )
        assertTrue(outcome is MapAlignmentGpsSampling.Outcome.Accepted)
        assertEquals(1, outcome.sampling.sampleCount)
    }

    @Test
    fun `production rejections pass through with their existing wording`() {
        val sampling = MapAlignmentGpsSampling()
        listOf(
            PinLocationResult.PermissionDenied,
            PinLocationResult.ApproximatePermission,
            PinLocationResult.ServicesDisabled,
            PinLocationResult.Stale,
            PinLocationResult.Inaccurate,
            PinLocationResult.Invalid,
            PinLocationResult.Timeout,
            PinLocationResult.Cancelled,
        ).forEach { rejection ->
            val outcome = sampling.offer(rejection)
            assertTrue(outcome is MapAlignmentGpsSampling.Outcome.RejectedByProduction)
            val rejected = outcome as MapAlignmentGpsSampling.Outcome.RejectedByProduction
            assertEquals(
                "production wording must not be rewritten",
                rejection.operatorMessage(),
                rejected.underlying.operatorMessage(),
            )
            // A rejected fix never becomes evidence.
            assertEquals(0, outcome.sampling.sampleCount)
        }
    }

    @Test
    fun `sampling never manufactures a position`() {
        val empty = MapAlignmentGpsSampling()
        assertNull(empty.representative)
        assertNull(empty.evidence)
        assertEquals(
            MapAlignmentGpsSampling.Progress.WaitingForGps,
            empty.progress,
        )
    }

    // ----- Robust representative -----

    @Test
    fun `the representative is a median, not the final sample`() {
        var sampling = MapAlignmentGpsSampling()
        // Four readings clustered at the true position...
        listOf(0.0, 0.5, -0.5, 0.2).forEachIndexed { index, east ->
            sampling = sampling
                .offer(success(near(east, 0.0), 3.0, 1_757_000_000_000 + index * 1_500L))
                .sampling
        }
        // ...then one last reading that wandered 6 m away.
        sampling = sampling.offer(success(near(6.0, 0.0), 5.0, 1_757_000_000_006_000)).sampling

        val representative = requireNotNull(sampling.representative)
        val fromTruth = MapAlignmentTransform.metresBetween(origin, representative)
        val fromLast = MapAlignmentTransform.metresBetween(near(6.0, 0.0), representative)

        // The median stays with the cluster and ignores the stray reading.
        assertTrue("median should sit near the cluster", fromTruth < 1.0)
        assertTrue("median must not be the last sample", fromLast > 4.0)
    }

    @Test
    fun `median handles odd and even counts by the standard rule`() {
        assertEquals(3.0, MapAlignmentGpsSampling.median(listOf(5.0, 1.0, 3.0)), 1e-9)
        assertEquals(4.0, MapAlignmentGpsSampling.median(listOf(7.0, 1.0, 5.0, 3.0)), 1e-9)
    }

    // ----- Stability -----

    @Test
    fun `stability radius is the distance of the furthest sample`() {
        val sampling = stableRun()
        val evidence = requireNotNull(sampling.evidence)
        // All five samples sit within ~1 m of the centre.
        assertTrue(evidence.stabilityRadiusMetres <= 1.5)
        assertEquals(5, evidence.sampleCount)
        assertEquals(6_000L, evidence.samplingDurationMillis)
        assertEquals(4.0, evidence.representativeAccuracyMetres, 1e-9)
        assertEquals(4.0, evidence.worstAccuracyMetres, 1e-9)
    }

    @Test
    fun `a scattered sample group is refused even when every fix looked acceptable`() {
        var sampling = MapAlignmentGpsSampling()
        // Five fixes, each reporting a healthy 4 m, but spread over ~30 m.
        listOf(0.0, 15.0, -15.0, 8.0, -12.0).forEachIndexed { index, east ->
            sampling = sampling
                .offer(success(near(east, 0.0), 4.0, 1_757_000_000_000 + index * 1_500L))
                .sampling
        }
        assertEquals(5, sampling.sampleCount)
        val evidence = requireNotNull(sampling.evidence)
        assertTrue(evidence.worstAccuracyMetres <= MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES)
        // Reported accuracy said fine; agreement between fixes says otherwise.
        assertTrue(
            evidence.stabilityRadiusMetres > MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES,
        )
        assertFalse(sampling.isStable)
        assertTrue(sampling.progress is MapAlignmentGpsSampling.Progress.Improving)
    }

    @Test
    fun `a settled group reaches the stable state`() {
        val sampling = stableRun()
        assertTrue(sampling.isStable)
        val progress = sampling.progress
        assertTrue(progress is MapAlignmentGpsSampling.Progress.Stable)
        assertTrue(progress.message().startsWith("GPS stable"))
    }

    @Test
    fun `progress wording moves through the expected states`() {
        assertEquals(
            "Waiting for GPS…",
            MapAlignmentGpsSampling.Progress.WaitingForGps.message(),
        )
        assertEquals(
            "Collecting GPS samples… 2 of 5",
            MapAlignmentGpsSampling.Progress.Collecting(have = 2).message(),
        )
        assertTrue(
            MapAlignmentGpsSampling.Progress.Improving("x").message()
                .startsWith("Improving GPS accuracy…"),
        )
    }

    // ----- Production rules untouched -----

    @Test
    fun `production admission thresholds are unchanged and strictly looser`() {
        // The wizard narrows; it can never widen. If these ever invert, the
        // wizard could accept a fix production refused.
        assertEquals(15.0, PinLocationFixValidator.MAX_ACCURACY_METRES, 0.0)
        assertEquals(5_000L, PinLocationFixValidator.MAX_AGE_MS)
        assertTrue(
            MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES <
                PinLocationFixValidator.MAX_ACCURACY_METRES,
        )
    }
}

package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.QualifiedLocationFix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The calibration live-GPS subscription lifecycle.
 *
 * The field defect this protects against: sampling stalled at `1 of 5` because
 * a one-shot location API kept returning the same cached observation, while a
 * new request was fired every second without awaiting the last. The properties
 * that matter now are that exactly ONE subscription is ever open, that every
 * way of leaving an attempt closes it, and that a superseded subscription can
 * never feed the current sample group.
 */
class MapAlignmentLiveGpsSessionTest {

    /** Records start/stop calls and lets a test push fixes to the live listener. */
    private class FakeProvider {
        var starts: Int = 0
        var stops: Int = 0
        private var listener: ((PinLocationResult) -> Unit)? = null

        val session: MapAlignmentLiveGpsSession = MapAlignmentLiveGpsSession(
            start = { onFix ->
                starts += 1
                listener = onFix
            },
            stop = {
                stops += 1
                listener = null
            },
        )

        /** Deliver to whoever the provider currently holds, as the OS would. */
        fun deliver(result: PinLocationResult) = listener?.invoke(result)

        /** Deliver to a listener captured earlier, simulating a stale callback. */
        fun deliverTo(captured: (PinLocationResult) -> Unit, result: PinLocationResult) =
            captured(result)

        fun currentListener(): (PinLocationResult) -> Unit = requireNotNull(listener)
    }

    private fun fix(accuracy: Double, observationNanos: Long): PinLocationResult =
        PinLocationResult.Success(
            QualifiedLocationFix(
                latitude = -33.2835,
                longitude = 149.0988,
                accuracyMetres = accuracy,
                fixTimeEpochMs = 1_757_000_000_000,
                fixElapsedRealtimeNanos = observationNanos,
                bearingDegrees = null,
            ),
        )

    @Test
    fun `beginning a session opens exactly one subscription`() {
        val provider = FakeProvider()

        provider.session.begin {}

        assertEquals(1, provider.starts)
        assertEquals(0, provider.stops)
        assertTrue(provider.session.isActive)
    }

    @Test
    fun `retry stops the old subscription before starting the new one`() {
        val provider = FakeProvider()
        provider.session.begin {}

        provider.session.begin {}

        // Two attempts, two subscriptions — never two at once.
        assertEquals(2, provider.starts)
        assertEquals(1, provider.stops)
        assertEquals(
            "a retry must not leave a second subscription running",
            provider.starts - provider.stops,
            1,
        )
        assertTrue(provider.session.isActive)
    }

    @Test
    fun `a fix from a superseded attempt is discarded`() {
        val provider = FakeProvider()
        val firstAttempt = mutableListOf<PinLocationResult>()
        provider.session.begin { firstAttempt += it }
        val staleListener = provider.currentListener()

        val secondAttempt = mutableListOf<PinLocationResult>()
        provider.session.begin { secondAttempt += it }

        // The old subscription's callback fires late, after Retry.
        provider.deliverTo(staleListener, fix(4.0, 1_000_000L))
        provider.deliver(fix(4.0, 2_000_000L))

        assertTrue("a superseded attempt must not keep collecting", firstAttempt.isEmpty())
        assertEquals(1, secondAttempt.size)
    }

    @Test
    fun `ending the session stops the subscription and is idempotent`() {
        val provider = FakeProvider()
        provider.session.begin {}

        // Cancel, timeout, dispose and wizard exit all land here.
        provider.session.end()
        provider.session.end()
        provider.session.end()

        assertEquals("stop must not be called for an already closed session", 1, provider.stops)
        assertFalse(provider.session.isActive)
    }

    @Test
    fun `no fix is delivered after the session ends`() {
        val provider = FakeProvider()
        val received = mutableListOf<PinLocationResult>()
        provider.session.begin { received += it }
        val listener = provider.currentListener()

        provider.session.end()
        provider.deliverTo(listener, fix(4.0, 1_000_000L))

        assertTrue(received.isEmpty())
    }

    @Test
    fun `ending without beginning does nothing`() {
        val provider = FakeProvider()

        provider.session.end()

        assertEquals(0, provider.starts)
        assertEquals(0, provider.stops)
        assertFalse(provider.session.isActive)
    }

    // ----- Integration with the sampling rules -----

    /**
     * Drive the sampler exactly as the sampling step does: one subscription,
     * fixes offered as they arrive, subscription closed the moment the group
     * becomes Stable.
     */
    private class SamplingRun(private val provider: FakeProvider) {
        var sampling: MapAlignmentGpsSampling = MapAlignmentGpsSampling()
            private set
        val messages: MutableList<String?> = mutableListOf()

        fun start() = provider.session.begin { production ->
            if (sampling.isStable) return@begin
            val outcome = sampling.offer(production)
            sampling = outcome.sampling
            if (outcome !is MapAlignmentGpsSampling.Outcome.Accepted &&
                outcome !is MapAlignmentGpsSampling.Outcome.Duplicate
            ) {
                messages += outcome.calibrationMessage()
            }
            if (sampling.isStable) provider.session.end()
        }
    }

    /** Move east/north of a fixed origin using the production transform. */
    private fun near(metresEast: Double, metresNorth: Double): CanonicalCoordinate {
        val origin = CanonicalCoordinate(-33.2835, 149.0988)
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

    private fun liveFix(
        coordinate: CanonicalCoordinate,
        accuracy: Double,
        observationNanos: Long,
    ): PinLocationResult = PinLocationResult.Success(
        QualifiedLocationFix(
            latitude = coordinate.latitude,
            longitude = coordinate.longitude,
            accuracyMetres = accuracy,
            fixTimeEpochMs = 1_757_000_000_000,
            fixElapsedRealtimeNanos = observationNanos,
            bearingDegrees = null,
        ),
    )

    private fun seconds(value: Long): Long = value * 1_000_000_000L

    @Test
    fun `five unique live fixes reach Stable and close the subscription`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()

        listOf(
            near(0.0, 0.0) to seconds(0),
            near(1.0, 0.0) to seconds(2),
            near(0.0, 1.0) to seconds(4),
            near(-1.0, 0.0) to seconds(6),
            near(0.0, -1.0) to seconds(8),
        ).forEach { (coordinate, nanos) ->
            provider.deliver(liveFix(coordinate, 4.0, nanos))
        }

        assertEquals(5, run.sampling.sampleCount)
        assertTrue(run.sampling.isStable)
        // Frozen: the subscription is closed as soon as the group qualifies.
        assertFalse(provider.session.isActive)
        assertEquals(1, provider.stops)
    }

    @Test
    fun `unique observations advance the counter one at a time`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()

        val counts = (0 until 5).map { index ->
            provider.deliver(liveFix(near(index.toDouble(), 0.0), 4.0, seconds(index * 2L)))
            run.sampling.sampleCount
        }

        assertEquals(listOf(1, 2, 3, 4, 5), counts)
    }

    @Test
    fun `one observation redelivered many times remains one sample`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()

        // Exactly the field failure: a cached fix returned over and over.
        val cached = liveFix(near(0.0, 0.0), 6.1, seconds(1))
        repeat(20) { provider.deliver(cached) }

        assertEquals("a cached observation cannot fake five samples", 1, run.sampling.sampleCount)
        assertFalse(run.sampling.isStable)
        assertEquals(
            MapAlignmentGpsSampling.Progress.Collecting(have = 1),
            run.sampling.progress,
        )
        // Duplicates are routine, not failures, so they raise no wording.
        assertTrue(run.messages.isEmpty())
        // Still sampling: the subscription must stay open.
        assertTrue(provider.session.isActive)
    }

    @Test
    fun `a stale repetition cannot satisfy the duration requirement either`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()

        repeat(10) { provider.deliver(liveFix(near(0.0, 0.0), 5.0, seconds(3))) }

        assertEquals(1, run.sampling.sampleCount)
        assertEquals(0L, run.sampling.samplingDurationMillis)
    }

    @Test
    fun `duration is measured on the monotonic observation clock`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()

        // Wall-clock stays identical across all five; only the monotonic
        // observation time advances, and that is what must count.
        listOf(0L, 2L, 4L, 6L, 8L).forEachIndexed { index, second ->
            provider.deliver(liveFix(near(index.toDouble() * 0.5, 0.0), 4.0, seconds(second)))
        }

        assertEquals(8_000L, run.sampling.samplingDurationMillis)
        assertTrue(run.sampling.isStable)
    }

    @Test
    fun `a production-success fix worse than eight metres does not count`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()

        // Inside production's 15 m pin rule, outside calibration's 8 m rule.
        provider.deliver(liveFix(near(0.0, 0.0), 12.0, seconds(1)))

        assertEquals(0, run.sampling.sampleCount)
        assertEquals(
            "Latest reading was ±12 m. Waiting for ±8 m or better…",
            run.messages.single(),
        )
        assertTrue(provider.session.isActive)
    }

    @Test
    fun `fixes at or inside eight metres do count`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()

        // The exact field accuracies that previously stalled, plus the boundary.
        provider.deliver(liveFix(near(0.0, 0.0), 6.1, seconds(0)))
        provider.deliver(liveFix(near(1.0, 0.0), 7.7, seconds(2)))
        provider.deliver(liveFix(near(0.0, 1.0), 8.0, seconds(4)))

        assertEquals(3, run.sampling.sampleCount)
        assertTrue(run.messages.isEmpty())
    }

    @Test
    fun `a frozen group ignores further fixes`() {
        val provider = FakeProvider()
        val run = SamplingRun(provider)
        run.start()
        val listener = provider.currentListener()
        (0 until 5).forEach { index ->
            provider.deliver(liveFix(near(index.toDouble() * 0.5, 0.0), 4.0, seconds(index * 2L)))
        }
        val frozen = requireNotNull(run.sampling.representative)
        val frozenEvidence = requireNotNull(run.sampling.evidence)

        // A late fix arrives while the operator is deciding.
        provider.deliverTo(listener, liveFix(near(50.0, 50.0), 3.0, seconds(20)))

        assertEquals(5, run.sampling.sampleCount)
        assertEquals(frozen, run.sampling.representative)
        assertEquals(frozenEvidence, run.sampling.evidence)
    }

    // ----- Calibration wording -----

    @Test
    fun `calibration wording never quotes the pin limit or tells the operator to press again`() {
        val sampling = MapAlignmentGpsSampling()
        val outcomes = listOf(
            MapAlignmentGpsSampling.Outcome.TooImprecise(sampling, 9.4),
            MapAlignmentGpsSampling.Outcome.RejectedByProduction(
                sampling,
                PinLocationResult.Inaccurate,
            ),
            MapAlignmentGpsSampling.Outcome.RejectedByProduction(sampling, PinLocationResult.Stale),
            MapAlignmentGpsSampling.Outcome.RejectedByProduction(
                sampling,
                PinLocationResult.Timeout,
            ),
            MapAlignmentGpsSampling.Outcome.RejectedByProduction(
                sampling,
                PinLocationResult.Invalid,
            ),
        )

        outcomes.forEach { outcome ->
            val message = requireNotNull(outcome.calibrationMessage())
            assertFalse("automatic sampling must not say 'press again': $message", message.contains("press"))
            assertFalse("the 15 m pin rule is not the calibration rule: $message", message.contains("15 m"))
        }
    }

    @Test
    fun `inaccurate and stale outcomes get calibration-appropriate wording`() {
        val sampling = MapAlignmentGpsSampling()

        assertEquals(
            "Latest GPS reading was not accurate enough. Waiting for a better reading…",
            MapAlignmentGpsSampling.Outcome
                .RejectedByProduction(sampling, PinLocationResult.Inaccurate)
                .calibrationMessage(),
        )
        assertEquals(
            "Waiting for a fresh GPS reading…",
            MapAlignmentGpsSampling.Outcome
                .RejectedByProduction(sampling, PinLocationResult.Stale)
                .calibrationMessage(),
        )
    }

    @Test
    fun `configuration problems still name the actual cause`() {
        val sampling = MapAlignmentGpsSampling()
        val problems = listOf(
            PinLocationResult.PermissionDenied to "permission",
            PinLocationResult.ApproximatePermission to "precise",
            PinLocationResult.ServicesDisabled to "Location services",
        )

        problems.forEach { (result, expectedFragment) ->
            val outcome =
                MapAlignmentGpsSampling.Outcome.RejectedByProduction(sampling, result)
            val message = requireNotNull(outcome.calibrationMessage())
            assertTrue(
                "the operator must be told what to fix: $message",
                message.contains(expectedFragment),
            )
            assertTrue(outcome.isConfigurationProblem)
        }
    }

    @Test
    fun `routine outcomes stay silent`() {
        val sampling = MapAlignmentGpsSampling()

        assertEquals(null, MapAlignmentGpsSampling.Outcome.Duplicate(sampling).calibrationMessage())
        assertEquals(null, MapAlignmentGpsSampling.Outcome.Accepted(sampling).calibrationMessage())
        assertFalse(
            MapAlignmentGpsSampling.Outcome
                .RejectedByProduction(sampling, PinLocationResult.Stale)
                .isConfigurationProblem,
        )
    }

    // ----- Production rules must be untouched -----

    @Test
    fun `production pin thresholds and calibration thresholds are unchanged`() {
        assertEquals(15.0, com.rork.vinetrack.data.PinLocationFixValidator.MAX_ACCURACY_METRES, 1e-9)
        assertEquals(5_000L, com.rork.vinetrack.data.PinLocationFixValidator.MAX_AGE_MS)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES, 1e-9)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES, 1e-9)
        assertEquals(5, MapAlignmentGpsRules.MIN_SAMPLES)
        assertEquals(5_000L, MapAlignmentGpsRules.MIN_SAMPLING_MILLIS)
        assertEquals(45_000L, MapAlignmentGpsRules.SAMPLING_TIMEOUT_MILLIS)
    }

    @Test
    fun `production wording for manual pin capture is unchanged`() {
        // Calibration maps outcomes to its own wording rather than editing this.
        assertEquals(
            "GPS accuracy is not yet within 15 m. Wait for accuracy to improve, then press again.",
            PinLocationResult.Inaccurate.operatorMessage(),
        )
        assertEquals(
            "The GPS position is stale. Wait for a fresh fix, then press the pin button again.",
            PinLocationResult.Stale.operatorMessage(),
        )
    }
}

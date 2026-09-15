package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.QualifiedLocationFix

/**
 * Multi-sample GPS evidence for ONE calibration reference point.
 *
 * ## Why one fix is not enough
 *
 * A reported accuracy of ±3–5 m does not mean the fix is *centred* on the true
 * position — it describes a confidence radius, not a guarantee. The imagery
 * displacement being measured here may itself only be a few metres, so a single
 * fix can easily be the same size as the quantity it is supposed to measure.
 *
 * The correction is not a tighter single-fix threshold. It is **stability**:
 * several independent fixes, collected over time, that agree with each other.
 * A tight cluster is evidence the receiver has genuinely settled; a scattered
 * group is evidence it has not, whatever each individual fix claimed.
 *
 * ## The pipeline, unchanged below this point
 *
 * ```
 * LocationTracker (existing, unchanged)
 *   -> PinLocationFixValidator   (existing production rule: 15 m / 5 s)
 *     -> MapAlignmentGpsSampling (wizard-only: dedupe, ≤8 m, ≥5 unique, ≥5 s, stability)
 * ```
 *
 * Every sample has ALREADY passed production validation before this type sees
 * it. No competing `LocationManager`/`FusedLocationProvider` subscription is
 * created: the wizard repeatedly calls the same existing one-shot path. No
 * production threshold, message or code path is modified, and nothing here is
 * reachable from pin capture, spray trips or row placement.
 *
 * Nothing in this file is persisted.
 */

/** One accepted GPS observation contributing to a calibration reference. */
data class MapAlignmentGpsSample(
    val latitude: Double,
    val longitude: Double,
    val accuracyMetres: Double,
    /** Identity of the underlying fix. Two samples with this value are the same fix. */
    val fixTimeEpochMs: Long,
) {
    val coordinate: CanonicalCoordinate get() = CanonicalCoordinate(latitude, longitude)
}

/**
 * The summarised quality of one reference point's sample group.
 *
 * Retained alongside the reference so the review screen can explain *why* a
 * point behaves the way it does. Diagnostics, not truth.
 */
data class MapAlignmentGpsEvidence(
    val sampleCount: Int,
    val samplingDurationMillis: Long,
    /** Median reported accuracy across the accepted samples, in metres. */
    val representativeAccuracyMetres: Double,
    /** Worst reported accuracy across the accepted samples, in metres. */
    val worstAccuracyMetres: Double,
    /**
     * How far the furthest accepted sample sits from the representative
     * position, in metres. This — not the reported accuracy — is what says the
     * receiver had actually settled.
     */
    val stabilityRadiusMetres: Double,
)

/**
 * The wizard's sampling rules. Centralised so no screen invents its own.
 */
object MapAlignmentGpsRules {

    /** Unique accepted fixes required before a reference may be created. */
    const val MIN_SAMPLES: Int = 5

    /** Minimum wall-clock span the samples must cover, in millis. */
    const val MIN_SAMPLING_MILLIS: Long = 5_000L

    /**
     * Strictest per-sample accuracy the wizard accepts, in metres.
     *
     * Well inside the production 15 m limit, but deliberately not so tight that
     * sampling never completes under canopy. Stability, below, is what actually
     * protects the result.
     */
    const val MAX_SAMPLE_ACCURACY_METRES: Double = 8.0

    /** Accuracy at or below which a sample is comfortable. Presentation only. */
    const val GOOD_SAMPLE_ACCURACY_METRES: Double = 3.0

    /**
     * Widest acceptable spread of the accepted group around its representative
     * position, in metres. Above this the group has not settled and the
     * reference must not be accepted silently.
     */
    const val MAX_STABILITY_RADIUS_METRES: Double = 8.0

    /** How long to keep sampling before offering Retry, in millis. Never blocks forever. */
    const val SAMPLING_TIMEOUT_MILLIS: Long = 45_000L
}

/**
 * An in-progress sample group for one reference point.
 *
 * Immutable: every accepted fix returns a new instance. Pure — no Android
 * types, no coroutines, no persistence — so all of the admission, median and
 * stability rules are directly unit-testable.
 */
data class MapAlignmentGpsSampling(
    val samples: List<MapAlignmentGpsSample> = emptyList(),
) {
    /** What happened to one offered fix. */
    sealed interface Outcome {
        /** The resulting group, unchanged unless the fix was accepted. */
        val sampling: MapAlignmentGpsSampling

        /** Accepted as new evidence. */
        data class Accepted(override val sampling: MapAlignmentGpsSampling) : Outcome

        /** The same underlying fix was already counted; the group is unchanged. */
        data class Duplicate(override val sampling: MapAlignmentGpsSampling) : Outcome

        /** Rejected by the existing production pipeline, with its wording intact. */
        data class RejectedByProduction(
            override val sampling: MapAlignmentGpsSampling,
            val underlying: PinLocationResult,
        ) : Outcome

        /** Production accepted it, but it is not precise enough to calibrate with. */
        data class TooImprecise(
            override val sampling: MapAlignmentGpsSampling,
            val accuracyMetres: Double,
        ) : Outcome
    }

    /** Operator-facing progress through the sampling run. */
    sealed interface Progress {
        data object WaitingForGps : Progress

        data class Collecting(val have: Int, val need: Int = MapAlignmentGpsRules.MIN_SAMPLES) :
            Progress

        /** Enough samples, but the group has not settled (spread or duration). */
        data class Improving(val reason: String) : Progress

        data class Stable(val evidence: MapAlignmentGpsEvidence) : Progress

        val isStable: Boolean get() = this is Stable

        fun message(): String = when (this) {
            WaitingForGps -> "Waiting for GPS…"
            is Collecting -> "Collecting GPS samples… $have of $need"
            is Improving -> "Improving GPS accuracy… $reason"
            is Stable ->
                "GPS stable — ±${format(evidence.representativeAccuracyMetres)} m, " +
                    "${evidence.sampleCount} samples within " +
                    "${format(evidence.stabilityRadiusMetres)} m"
        }
    }

    val sampleCount: Int get() = samples.size

    /** Wall-clock span covered by the accepted samples, in millis. */
    val samplingDurationMillis: Long
        get() = if (samples.size < 2) {
            0L
        } else {
            samples.maxOf { it.fixTimeEpochMs } - samples.minOf { it.fixTimeEpochMs }
        }

    /**
     * Offer one result from the existing production pipeline.
     *
     * Ordering matters and is the safety property: production decides first,
     * and this only ever narrows. A fix production rejected can never be
     * accepted here.
     */
    fun offer(production: PinLocationResult): Outcome {
        val fix: QualifiedLocationFix = (production as? PinLocationResult.Success)?.fix
            ?: return Outcome.RejectedByProduction(this, production)

        if (fix.accuracyMetres > MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES) {
            return Outcome.TooImprecise(this, fix.accuracyMetres)
        }
        // A repeated cached fix is the SAME observation, not new evidence.
        // Counting it twice would fake both the sample count and the stability.
        if (samples.any { it.fixTimeEpochMs == fix.fixTimeEpochMs }) {
            return Outcome.Duplicate(this)
        }
        return Outcome.Accepted(
            copy(
                samples = samples + MapAlignmentGpsSample(
                    latitude = fix.latitude,
                    longitude = fix.longitude,
                    accuracyMetres = fix.accuracyMetres,
                    fixTimeEpochMs = fix.fixTimeEpochMs,
                ),
            ),
        )
    }

    /**
     * The robust centre of the accepted group: a component-wise median of
     * latitude and longitude.
     *
     * A median rather than a mean because one wandering fix — a reflection off
     * a shed, a moment of poor geometry — should not drag the reference. The
     * median simply ignores it; a mean would not.
     *
     * The underlying production fixes are NOT modified. This derives a new
     * canonical coordinate from them.
     */
    val representative: CanonicalCoordinate?
        get() {
            if (samples.isEmpty()) return null
            return CanonicalCoordinate(
                latitude = median(samples.map { it.latitude }),
                longitude = median(samples.map { it.longitude }),
            )
        }

    /**
     * Spread of the accepted group around [representative], in metres: the
     * distance of the furthest sample. Zero for a single sample.
     */
    val stabilityRadiusMetres: Double
        get() {
            val centre = representative ?: return 0.0
            return samples.maxOfOrNull {
                MapAlignmentTransform.metresBetween(centre, it.coordinate)
            } ?: 0.0
        }

    /** Summary of the group so far. Null before any sample is accepted. */
    val evidence: MapAlignmentGpsEvidence?
        get() {
            if (samples.isEmpty()) return null
            return MapAlignmentGpsEvidence(
                sampleCount = samples.size,
                samplingDurationMillis = samplingDurationMillis,
                representativeAccuracyMetres = median(samples.map { it.accuracyMetres }),
                worstAccuracyMetres = samples.maxOf { it.accuracyMetres },
                stabilityRadiusMetres = stabilityRadiusMetres,
            )
        }

    /**
     * Whether the group is adequate evidence for a calibration reference.
     *
     * All three conditions must hold: enough unique fixes, collected over
     * enough time, agreeing closely enough. Each catches a different failure —
     * too few samples cannot reveal scatter, too short a window can repeat one
     * momentary error, and a wide spread means the receiver never settled.
     */
    val progress: Progress
        get() {
            val current = evidence ?: return Progress.WaitingForGps
            if (samples.size < MapAlignmentGpsRules.MIN_SAMPLES) {
                return Progress.Collecting(have = samples.size)
            }
            if (samplingDurationMillis < MapAlignmentGpsRules.MIN_SAMPLING_MILLIS) {
                return Progress.Improving("holding position a moment longer")
            }
            if (current.stabilityRadiusMetres > MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES) {
                return Progress.Improving(
                    "readings are spread over ${format(current.stabilityRadiusMetres)} m",
                )
            }
            return Progress.Stable(current)
        }

    /** True when [progress] is [Progress.Stable]. */
    val isStable: Boolean get() = progress.isStable

    companion object {
        /**
         * Standard mathematical median: middle value for an odd count, mean of
         * the two middle values for an even count.
         */
        fun median(values: List<Double>): Double {
            require(values.isNotEmpty()) { "Median of an empty sample group is undefined" }
            val sorted = values.sorted()
            val middle = sorted.size / 2
            return if (sorted.size % 2 == 1) {
                sorted[middle]
            } else {
                (sorted[middle - 1] + sorted[middle]) / 2.0
            }
        }

        internal fun format(value: Double): String =
            if (value >= 10.0) {
                value.toInt().toString()
            } else {
                String.format(java.util.Locale.US, "%.1f", value)
            }
    }
}

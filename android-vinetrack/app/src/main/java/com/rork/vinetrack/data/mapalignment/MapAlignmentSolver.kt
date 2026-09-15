package com.rork.vinetrack.data.mapalignment

/**
 * Derives a translation-only alignment from collected reference points.
 *
 * Pure and side-effect free: no persistence, no sync, no Android types. It reads
 * evidence and returns a candidate — it never applies anything to a map and
 * never touches a canonical coordinate.
 *
 * ## Why the MEDIAN, not the mean
 *
 * The arithmetic mean is the least-squares fit for a pure translation, and for
 * clean evidence it is the more efficient estimator. It is deliberately not
 * used here, because the failure mode we actually expect is not gaussian noise
 * — it is a single *wrong* point:
 *
 * * a reference marked against the wrong post;
 * * a mis-tap on the satellite image;
 * * one location with unusually poor local GPS;
 * * a visually ambiguous spot on the imagery.
 *
 * A mean lets one such point drag the whole candidate; with four points a 30 m
 * mistake moves the result by 7.5 m, which is larger than the offset being
 * measured. A component-wise median simply ignores it. Robustness matters more
 * than statistical efficiency when a single operator error is the likely
 * problem, so the estimator is:
 *
 * ```
 * candidate east  = median(all per-point east offsets)
 * candidate north = median(all per-point north offsets)
 * ```
 *
 * Every reference is retained regardless. Outliers are **surfaced** through the
 * residual statistics, never silently discarded — an automatically dropped
 * point would hide the very mistake the operator needs to see.
 *
 * ## Why coverage is a diagnostic, not an eligibility rule
 *
 * Broad spatial spread genuinely produces a better calibration, and a rotation
 * or scale mismatch only reveals itself across distance. But a hard "four
 * points each ≥40 m apart" gate makes a legitimate small-block calibration
 * impossible, which is worse than a somewhat weaker alignment. So spread is
 * reported ([Solution.widestSpanMetres]) and encouraged in wording, while
 * eligibility enforces only what is genuinely required: enough points, in one
 * scope, at genuinely distinct locations — see [NEAR_DUPLICATE_METRES].
 */
object MapAlignmentSolver {

    /** Minimum completed reference points before an alignment may be derived. */
    const val MIN_POINTS: Int = 4

    /**
     * Two references closer together than this are treated as the same place,
     * in metres.
     *
     * This is the conservative replacement for the old 40 m separation gate. It
     * exists to stop *duplicate* evidence — recording the same corner twice
     * inflates the point count without adding any new information about the
     * imagery — while still allowing a small block to be calibrated from points
     * that are genuinely metres apart.
     */
    const val NEAR_DUPLICATE_METRES: Double = 10.0

    /** Spread below which the operator is encouraged to spread out further, in metres. */
    const val ENCOURAGE_SPREAD_METRES: Double = 40.0

    /** RMS residual at or below which the fit is Good, in metres. */
    const val GOOD_RMS_RESIDUAL_METRES: Double = 3.0

    /** Maximum single residual at or below which the fit is Good, in metres. */
    const val GOOD_MAX_RESIDUAL_METRES: Double = 6.0

    /** Wording for the operator, shown wherever spread is discussed. */
    const val SPREAD_ADVICE: String =
        "Spread reference points around the vineyard or block where possible."

    /** Wording shown when a new reference lands on top of an existing one. */
    const val NEAR_DUPLICATE_MESSAGE: String =
        "This reference is too close to an existing point. Choose another identifiable " +
            "location further away."

    /**
     * Overall confidence in a derived candidate.
     *
     * Deliberately only two values, and deliberately not worded as accuracy.
     * This is a field-test preview: "Good" means the evidence is internally
     * consistent, NOT that the result is survey-grade or independently correct.
     */
    enum class Quality {
        Good,
        CheckAlignment,
        ;

        val label: String
            get() = when (this) {
                Good -> "Good"
                CheckAlignment -> "Check alignment"
            }
    }

    /** Why a set of reference points cannot yet produce an alignment. */
    sealed interface Readiness {
        data object Ready : Readiness

        data class NeedMorePoints(val have: Int, val need: Int = MIN_POINTS) : Readiness

        /** Two or more references describe effectively the same location. */
        data class DuplicateLocations(val duplicateCount: Int) : Readiness

        val isReady: Boolean get() = this is Ready

        fun operatorMessage(): String = when (this) {
            Ready -> "Ready to calculate alignment."
            is NeedMorePoints ->
                "Record ${need - have} more reference point${if (need - have == 1) "" else "s"} " +
                    "($have of $need). $SPREAD_ADVICE"
            is DuplicateLocations ->
                "$duplicateCount reference point${if (duplicateCount == 1) " is" else "s are"} " +
                    "too close to another point. Remove or retake " +
                    "${if (duplicateCount == 1) "it" else "them"} further away."
        }
    }

    /**
     * A derived candidate alignment plus the quality evidence behind it.
     *
     * [calibration] carries the alignment together with every point that
     * produced it, so the evidence is never reduced to two numbers.
     */
    data class Solution(
        val calibration: MapAlignmentCalibration,
        /**
         * Root-mean-square residual magnitude in metres.
         *
         * RMS rather than a plain mean because squaring weights the worst
         * disagreement more heavily — a fit with one bad point should not look
         * as healthy as one that is uniformly close.
         */
        val rmsResidualMetres: Double,
        /** Worst single residual magnitude in metres. */
        val maxResidualMetres: Double,
        /** Widest separation between any two reference points, in metres. Diagnostic. */
        val widestSpanMetres: Double,
    ) {
        val alignment: MapAlignment get() = calibration.alignment

        val pointCount: Int get() = calibration.referencePoints.size

        /** Per-point residual magnitudes, in reference-point order. */
        val residualMagnitudesMetres: List<Double>
            get() = calibration.residuals().map { it.magnitudeMetres }

        /**
         * Classification of the fit. Good requires enough points AND a tight
         * RMS AND no single bad point — any one of those failing means the
         * result deserves a look before it is trusted.
         */
        val quality: Quality
            get() = if (
                pointCount >= MIN_POINTS &&
                rmsResidualMetres <= GOOD_RMS_RESIDUAL_METRES &&
                maxResidualMetres <= GOOD_MAX_RESIDUAL_METRES
            ) {
                Quality.Good
            } else {
                Quality.CheckAlignment
            }

        /** True when a pure translation does not adequately explain the evidence. */
        val needsReview: Boolean get() = quality != Quality.Good

        /** Index of the worst-fitting reference, for highlighting. Null when empty. */
        val worstPointIndex: Int?
            get() = residualMagnitudesMetres
                .withIndex()
                .maxByOrNull { it.value }
                ?.index

        /** True when the operator should be encouraged to spread out further. */
        val spreadIsNarrow: Boolean get() = widestSpanMetres < ENCOURAGE_SPREAD_METRES
    }

    /**
     * References that sit within [NEAR_DUPLICATE_METRES] of an earlier
     * reference in [points].
     *
     * @param excludingId when re-marking or retaking one reference, its own id
     *   must be excluded so a point can never collide with itself.
     */
    fun duplicateLocations(
        points: List<MapAlignmentReferencePoint>,
        excludingId: String? = null,
    ): List<MapAlignmentReferencePoint> {
        val considered = points.filterNot { it.id == excludingId }
        val duplicates = mutableListOf<MapAlignmentReferencePoint>()
        considered.forEachIndexed { index, candidate ->
            val clashesWithEarlier = considered.take(index).any { earlier ->
                MapAlignmentTransform.metresBetween(
                    earlier.canonicalCoordinate,
                    candidate.canonicalCoordinate,
                ) < NEAR_DUPLICATE_METRES
            }
            if (clashesWithEarlier) duplicates += candidate
        }
        return duplicates
    }

    /**
     * Whether [coordinate] may be used as a NEW reference location.
     *
     * @param excludingId the reference being retaken or re-marked, so it does
     *   not collide with its own previous position.
     */
    fun isNearDuplicate(
        coordinate: CanonicalCoordinate,
        points: List<MapAlignmentReferencePoint>,
        excludingId: String? = null,
    ): Boolean = points
        .filterNot { it.id == excludingId }
        .any {
            MapAlignmentTransform.metresBetween(it.canonicalCoordinate, coordinate) <
                NEAR_DUPLICATE_METRES
        }

    /**
     * Whether [points] can yet produce an alignment.
     *
     * Eligibility is only: at least [MIN_POINTS] references, and no two of them
     * describing the same location. Spread beyond that is a quality signal, not
     * a gate — see the class docs.
     */
    fun readiness(points: List<MapAlignmentReferencePoint>): Readiness {
        if (points.size < MIN_POINTS) return Readiness.NeedMorePoints(have = points.size)
        val duplicates = duplicateLocations(points)
        if (duplicates.isNotEmpty()) {
            return Readiness.DuplicateLocations(duplicateCount = duplicates.size)
        }
        return Readiness.Ready
    }

    /**
     * Derive the candidate alignment for [scope] from [points].
     *
     * @param points evidence already captured for exactly [scope].
     * @param alignmentId identity for the derived candidate. Session-local in
     *   this phase; nothing is persisted.
     * @return the solution, or null when [readiness] is not [Readiness.Ready].
     *
     * The returned alignment is enabled so it can drive the private before/after
     * preview. Being enabled does NOT make it live: it is not persisted and no
     * production map consults it in this phase.
     */
    fun solve(
        points: List<MapAlignmentReferencePoint>,
        scope: MapAlignmentScope,
        alignmentId: String,
        nowEpochMillis: Long? = null,
    ): Solution? {
        if (!readiness(points).isReady) return null
        require(points.all { it.scope == scope }) {
            "Cannot solve: reference points do not all belong to scope $scope"
        }

        // Robust estimator: one mis-marked point must not drag the candidate.
        val eastMedian = median(points.map { it.observedOffset.eastMetres })
        val northMedian = median(points.map { it.observedOffset.northMetres })

        val alignment = MapAlignment(
            id = alignmentId,
            scope = scope,
            eastOffsetMetres = eastMedian,
            northOffsetMetres = northMedian,
            isEnabled = true,
            createdAtEpochMillis = nowEpochMillis,
            updatedAtEpochMillis = nowEpochMillis,
        )

        // Stamp the evidence with the alignment it produced, then let the
        // calibration aggregate enforce its single-scope invariant.
        val calibration = MapAlignmentCalibration(
            alignment = alignment,
            referencePoints = points.map { it.copy(alignmentId = alignmentId) },
        )
        val magnitudes = calibration.residuals().map { it.magnitudeMetres }

        return Solution(
            calibration = calibration,
            rmsResidualMetres = kotlin.math.sqrt(magnitudes.sumOf { it * it } / magnitudes.size),
            maxResidualMetres = magnitudes.max(),
            widestSpanMetres = widestSpan(points),
        )
    }

    /**
     * Standard mathematical median: middle value for an odd count, mean of the
     * two middle values for an even count.
     */
    fun median(values: List<Double>): Double {
        require(values.isNotEmpty()) { "Median of no values is undefined" }
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 1) {
            sorted[middle]
        } else {
            (sorted[middle - 1] + sorted[middle]) / 2.0
        }
    }

    /** Widest straight-line separation between any two points, in metres. */
    fun widestSpan(points: List<MapAlignmentReferencePoint>): Double {
        if (points.size < 2) return 0.0
        var widest = 0.0
        for (i in points.indices) {
            for (j in i + 1 until points.size) {
                val span = MapAlignmentTransform.metresBetween(
                    points[i].canonicalCoordinate,
                    points[j].canonicalCoordinate,
                )
                if (span > widest) widest = span
            }
        }
        return widest
    }
}

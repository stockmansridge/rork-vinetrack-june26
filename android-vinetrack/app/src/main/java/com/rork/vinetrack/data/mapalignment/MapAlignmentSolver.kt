package com.rork.vinetrack.data.mapalignment

/**
 * Derives a translation-only alignment from collected reference points.
 *
 * Pure and side-effect free: no persistence, no sync, no Android types. It reads
 * evidence and returns a candidate — it never applies anything to a map and
 * never touches a canonical coordinate.
 *
 * ## Why the mean is the correct fit here
 *
 * V1 is a pure translation, so the least-squares best fit over N observations is
 * exactly the arithmetic mean of the per-point observed offsets. There is no
 * iteration, no rotation and no scale to estimate, so a more elaborate solver
 * would add risk without adding accuracy.
 *
 * Averaging is also the reason several well-separated points are required rather
 * than one: independent GPS errors partially cancel, so the derived offset is
 * more certain than any single fix that produced it.
 *
 * ## Why separation is enforced
 *
 * Four points clustered around one gate measure that gate, not the vineyard.
 * Imagery offset is only meaningfully established across the working area, and
 * clustered evidence would also hide a rotational or scale mismatch that V1
 * cannot correct — the residuals are what reveal it, and residuals from
 * clustered points are uninformative.
 */
object MapAlignmentSolver {

    /** Minimum reference points before an alignment may be derived. */
    const val MIN_POINTS: Int = 4

    /**
     * Minimum straight-line separation between any two reference points, in
     * metres. Two points closer than this are treated as the same observation
     * for spread purposes.
     */
    const val MIN_SEPARATION_METRES: Double = 40.0

    /**
     * Residual magnitude above which the fit is flagged for review, in metres.
     *
     * A large residual does NOT mean the calculation failed — it means a pure
     * translation does not explain the evidence (likely rotation/scale in the
     * imagery, or a mis-tapped point). Surfacing it is the point; V1 must not
     * silently absorb it.
     */
    const val RESIDUAL_REVIEW_METRES: Double = 5.0

    /** Why a set of reference points cannot yet produce an alignment. */
    sealed interface Readiness {
        data object Ready : Readiness

        data class NeedMorePoints(val have: Int, val need: Int = MIN_POINTS) : Readiness

        /** Enough points, but they are not spread across the vineyard. */
        data class NotWellSeparated(
            val wellSeparatedCount: Int,
            val need: Int = MIN_POINTS,
            val widestSpanMetres: Double,
        ) : Readiness

        val isReady: Boolean get() = this is Ready

        fun operatorMessage(): String = when (this) {
            Ready -> "Ready to calculate alignment."
            is NeedMorePoints ->
                "Record ${need - have} more reference point${if (need - have == 1) "" else "s"} " +
                    "($have of $need)."
            is NotWellSeparated ->
                "Your reference points are too close together. Only $wellSeparatedCount of " +
                    "$need are well separated (widest spread ${widestSpanMetres.toInt()} m). " +
                    "Spread them around the vineyard, at least " +
                    "${MIN_SEPARATION_METRES.toInt()} m apart."
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
        /** Mean residual magnitude in metres — the typical remaining disagreement. */
        val meanResidualMetres: Double,
        /** Worst single residual magnitude in metres. */
        val maxResidualMetres: Double,
        /** Widest separation between any two reference points, in metres. */
        val widestSpanMetres: Double,
    ) {
        val alignment: MapAlignment get() = calibration.alignment

        /** True when a pure translation does not adequately explain the evidence. */
        val needsReview: Boolean get() = maxResidualMetres > RESIDUAL_REVIEW_METRES

        val pointCount: Int get() = calibration.referencePoints.size
    }

    /**
     * Whether [points] can yet produce an alignment.
     *
     * Separation is assessed with a greedy well-separated subset: a point counts
     * only when it is at least [MIN_SEPARATION_METRES] from every point already
     * counted. Four points around one gate therefore yield a count of one, which
     * is the intended outcome.
     */
    fun readiness(points: List<MapAlignmentReferencePoint>): Readiness {
        if (points.size < MIN_POINTS) return Readiness.NeedMorePoints(have = points.size)
        val separated = wellSeparatedSubset(points)
        if (separated.size < MIN_POINTS) {
            return Readiness.NotWellSeparated(
                wellSeparatedCount = separated.size,
                widestSpanMetres = widestSpan(points),
            )
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

        // Least-squares fit for a pure translation is the mean of the per-point
        // observed offsets.
        val eastMean = points.sumOf { it.observedOffset.eastMetres } / points.size
        val northMean = points.sumOf { it.observedOffset.northMetres } / points.size

        val alignment = MapAlignment(
            id = alignmentId,
            scope = scope,
            eastOffsetMetres = eastMean,
            northOffsetMetres = northMean,
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
            meanResidualMetres = magnitudes.average(),
            maxResidualMetres = magnitudes.max(),
            widestSpanMetres = widestSpan(points),
        )
    }

    /**
     * Greedy well-separated subset: each accepted point is at least
     * [MIN_SEPARATION_METRES] from every previously accepted point.
     */
    fun wellSeparatedSubset(
        points: List<MapAlignmentReferencePoint>,
    ): List<MapAlignmentReferencePoint> {
        val accepted = mutableListOf<MapAlignmentReferencePoint>()
        points.forEach { candidate ->
            val farFromAll = accepted.none { existing ->
                MapAlignmentTransform.metresBetween(
                    existing.canonicalCoordinate,
                    candidate.canonicalCoordinate,
                ) < MIN_SEPARATION_METRES
            }
            if (farFromAll) accepted += candidate
        }
        return accepted
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

package com.rork.vinetrack.data.mapalignment

/**
 * Advisory detection of a reference point that disagrees with the others.
 *
 * ## The field case this exists for
 *
 * A real calibration produced residuals of 1.4 m, 1.5 m, 6.1 m and 1.3 m. The
 * overall fit was not catastrophic, so the existing quality rule had little to
 * say — but three points agreed closely and one did not, which is exactly the
 * shape of a single mistake: a reference marked against the wrong post, a
 * mis-tap on the imagery, or one location with unusually poor local GPS. The
 * operator should be told to go and look at that point before saving.
 *
 * ## Advisory only — this changes no arithmetic
 *
 * This type reads a solved candidate and returns an opinion. It does NOT:
 *
 * * remove, reweight, downweight or re-order any reference point;
 * * alter the median east/north estimator, which remains authoritative;
 * * change [MapAlignmentSolver.Quality], the RMS/max rule, or readiness;
 * * decide anything about whether a calibration may be saved.
 *
 * Automatically dropping a point would hide the very mistake the operator needs
 * to see, and would let a confident-looking alignment be derived from evidence
 * the operator never agreed to exclude. The operator stays in control; all this
 * does is point at the odd one out.
 *
 * ## Why it is deliberately NOT the overall quality rule
 *
 * [MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES] and
 * [MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES] answer "is this calibration
 * good?". This answers a different question: "is one point unlike its
 * siblings?". The two must not be conflated, because a uniformly mediocre
 * calibration — say 4.0, 4.1, 4.3, 4.2 — is genuinely poor overall but contains
 * no odd point at all. Flagging its worst point would send the operator to
 * re-walk a reference that is no worse than the rest, and would quietly imply
 * the calibration is fine once that point is "fixed". That case is already
 * handled, correctly, by the overall **Check alignment** result.
 *
 * ## The rule
 *
 * ```
 * flag a reference when
 *   residual > max(MIN_FLAG_RESIDUAL_METRES, median(residuals) × RESIDUAL_MULTIPLE)
 * ```
 *
 * The **median** is the comparison baseline, not the mean: the mean is dragged
 * upward by the very outlier being looked for, which raises the bar and can
 * hide it. The median of the residual set is barely moved by one bad value.
 *
 * The absolute floor matters as much as the multiple. With near-perfect
 * evidence — 0.2, 0.3, 0.2, 0.9 — a pure multiple would flag a 0.9 m residual
 * as suspect, which is noise, not a mistake, and would send the operator
 * walking for nothing. Nothing below [MIN_FLAG_RESIDUAL_METRES] is ever worth
 * re-walking, so the floor wins whenever the evidence is tight.
 */
object MapAlignmentOutliers {

    /**
     * Absolute floor, in metres. A residual at or below this is never flagged,
     * however tightly the other references agree.
     *
     * Deliberately equal to [MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES] in
     * value but NOT the same rule: this is a per-point floor, that is an
     * overall fit threshold. They are free to diverge.
     */
    const val MIN_FLAG_RESIDUAL_METRES: Double = 3.0

    /** How many times the median residual a point must exceed to be flagged. */
    const val RESIDUAL_MULTIPLE: Double = 2.0

    /**
     * Fewest references before the check runs at all.
     *
     * With fewer than this a "median" is not a description of a group — with
     * two points each one is half the evidence, and calling either odd is
     * meaningless. This matches [MapAlignmentSolver.MIN_POINTS], which is also
     * the fewest that can produce a candidate at all.
     */
    const val MIN_POINTS_FOR_DETECTION: Int = MapAlignmentSolver.MIN_POINTS

    /** One reference the operator is advised to check, with the evidence why. */
    data class Suspect(
        /** 1-based position, matching the "Point 3" wording the operator sees. */
        val pointNumber: Int,
        val point: MapAlignmentReferencePoint,
        val residualMetres: Double,
        /** The typical residual it is being compared against. */
        val medianResidualMetres: Double,
    ) {
        /** Restrained list wording. Never says the point is wrong. */
        val listLabel: String get() = "Point $pointNumber — Review recommended"
    }

    /**
     * The advisory verdict for one solved candidate.
     *
     * An empty [suspects] means "no point stands out", which is NOT the same as
     * "this calibration is good" — see the class docs.
     */
    data class Review(
        val suspects: List<Suspect>,
        val medianResidualMetres: Double,
        /** The threshold actually applied, in metres. Shown in diagnostics. */
        val thresholdMetres: Double,
    ) {
        val hasSuspects: Boolean get() = suspects.isNotEmpty()

        val suspectCount: Int get() = suspects.size

        /** True when this reference is one the operator was advised to check. */
        fun isSuspect(pointId: String): Boolean = suspects.any { it.point.id == pointId }

        fun suspectFor(pointId: String): Suspect? = suspects.firstOrNull { it.point.id == pointId }

        /** Dialog title: names the point when there is exactly one. */
        fun title(): String = when (suspects.size) {
            0 -> "Reference points look consistent"
            1 -> "Check reference point ${suspects.first().pointNumber}"
            else -> "Check $suspectCount reference points"
        }

        /** Primary action wording, matching [title]. */
        fun reviewActionLabel(): String = when (suspects.size) {
            0 -> "Review reference points"
            1 -> "Review point ${suspects.first().pointNumber}"
            else -> "Review $suspectCount reference points"
        }

        /**
         * Body text. States the measurement and the likely causes without
         * claiming which of the two is at fault — we genuinely do not know
         * whether the GPS reading or the image mark is the source, and saying
         * otherwise would send the operator to redo the wrong one.
         */
        fun message(): String {
            if (suspects.isEmpty()) return "No reference point differs from the others."
            val subject = if (suspects.size == 1) {
                "Point ${suspects.first().pointNumber} differs"
            } else {
                suspects.joinToString(
                    separator = ", ",
                    prefix = "Points ",
                    postfix = " differ",
                ) { it.pointNumber.toString() }
            }
            val readings = suspects.joinToString("\n") { suspect ->
                "Point ${suspect.pointNumber} residual: " +
                    "${formatMetres(suspect.residualMetres)} m"
            }
            return "$subject more than the other reference points.\n\n" +
                "$readings\n" +
                "Typical residual: ${formatMetres(medianResidualMetres)} m\n\n" +
                "This can happen if the GPS position or satellite-image point was " +
                "slightly misplaced.\n\n" +
                "We recommend checking " +
                "${if (suspects.size == 1) "this point" else "these points"} before " +
                "saving the calibration."
        }
    }

    /** The "nothing stands out" verdict for [median]. */
    private fun consistent(median: Double, threshold: Double): Review =
        Review(suspects = emptyList(), medianResidualMetres = median, thresholdMetres = threshold)

    /**
     * Assess [solution]'s reference points.
     *
     * @return the advisory verdict. Always safe to call — an empty or
     *   too-small point set simply yields no suspects rather than throwing.
     */
    fun review(solution: MapAlignmentSolver.Solution): Review =
        review(solution.calibration.referencePoints, solution.residualMagnitudesMetres)

    /**
     * Assess raw residuals directly.
     *
     * @param points the references, in the order the operator sees them.
     * @param residualMetres each point's residual magnitude, in the SAME order.
     */
    fun review(
        points: List<MapAlignmentReferencePoint>,
        residualMetres: List<Double>,
    ): Review {
        if (points.isEmpty() || points.size != residualMetres.size) {
            return consistent(median = 0.0, threshold = MIN_FLAG_RESIDUAL_METRES)
        }
        val median = MapAlignmentSolver.median(residualMetres)
        val threshold = maxOf(MIN_FLAG_RESIDUAL_METRES, median * RESIDUAL_MULTIPLE)

        // Too few references for "typical" to mean anything. Say nothing rather
        // than accuse a point on the strength of one or two comparisons.
        if (points.size < MIN_POINTS_FOR_DETECTION) return consistent(median, threshold)

        val suspects = points.mapIndexedNotNull { index, point ->
            val residual = residualMetres[index]
            if (residual > threshold) {
                Suspect(
                    pointNumber = index + 1,
                    point = point,
                    residualMetres = residual,
                    medianResidualMetres = median,
                )
            } else {
                null
            }
        }
        return Review(
            suspects = suspects,
            medianResidualMetres = median,
            thresholdMetres = threshold,
        )
    }

    /** One decimal place below 10 m, whole metres above. Matches the wizard. */
    private fun formatMetres(value: Double): String =
        if (value >= 10.0) {
            value.toInt().toString()
        } else {
            String.format(java.util.Locale.US, "%.1f", value)
        }
}

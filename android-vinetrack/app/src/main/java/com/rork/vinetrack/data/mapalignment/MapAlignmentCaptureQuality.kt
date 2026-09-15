package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.QualifiedLocationFix

/**
 * The calibration wizard's ADDITIONAL, stricter GPS admission rule.
 *
 * ## Why a second rule exists, and why it changes nothing in production
 *
 * The production admission rule ([com.rork.vinetrack.data.PinLocationFixValidator],
 * 15 m / 5 s) is correct for pins, spray trips and row placement: it decides
 * whether a fix is good enough to record where work happened. Calibration is a
 * different question. The imagery discrepancy being measured may itself be only
 * a few metres, so a single 10–15 m fix is not acceptable evidence — it could be
 * larger than the very offset it is supposed to measure.
 *
 * This object therefore *narrows* the existing rule inside the wizard only. It
 * is deliberately built as a filter that runs AFTER the production validator has
 * already returned [PinLocationResult.Success]:
 *
 * ```
 * LocationTracker (existing, unchanged)
 *   -> PinLocationFixValidator  (existing production rule, unchanged: 15 m / 5 s)
 *     -> MapAlignmentCaptureQuality  (wizard-only, stricter)
 * ```
 *
 * Consequences of that ordering, which are the point:
 *
 * * The wizard cannot ACCEPT anything production would reject — it only ever
 *   rejects more.
 * * No production threshold, message or code path is modified. Nothing here is
 *   reachable from pin, trip or row placement.
 * * There is no second GPS manager, subscription or location request. The wizard
 *   reuses the existing [com.rork.vinetrack.data.LocationTracker] pipeline.
 */
object MapAlignmentCaptureQuality {

    /**
     * Strictest accuracy the wizard will accept, in metres.
     *
     * Chosen to sit well inside the production 15 m limit: a reference point
     * must be materially more certain than the discrepancy being measured,
     * otherwise the calibration is fitting GPS noise rather than an imagery
     * offset.
     */
    const val MAX_ACCURACY_METRES: Double = 5.0

    /**
     * Accuracy at or below which a fix is comfortable rather than merely
     * acceptable. Presentation only — used to encourage the operator to wait a
     * moment longer; it never rejects anything.
     */
    const val GOOD_ACCURACY_METRES: Double = 3.0

    /** Outcome of the wizard's extra quality gate. */
    sealed interface Result {
        /** Accepted by BOTH the production rule and the stricter wizard rule. */
        data class Accepted(val fix: QualifiedLocationFix) : Result

        /**
         * Rejected by the production pipeline. [underlying] is carried verbatim
         * so the operator sees the existing, already-correct wording for
         * permissions, services, staleness and so on.
         */
        data class Rejected(val underlying: PinLocationResult) : Result

        /**
         * Production accepted it, but it is not precise enough to calibrate
         * with. This is the wizard-only outcome.
         */
        data class TooImpreciseForCalibration(
            val fix: QualifiedLocationFix,
            val accuracyMetres: Double,
        ) : Result

        val acceptedFix: QualifiedLocationFix? get() = (this as? Accepted)?.fix

        /** Wording for the operator. Production rejections keep their existing message. */
        fun operatorMessage(): String = when (this) {
            is Accepted ->
                "Position recorded to ±${format(fix.accuracyMetres)} m."
            is Rejected -> underlying.operatorMessage()
            is TooImpreciseForCalibration ->
                "GPS accuracy is ±${format(accuracyMetres)} m. Alignment needs " +
                    "±${format(MAX_ACCURACY_METRES)} m or better, because the offset being " +
                    "measured may itself only be a few metres. Wait for accuracy to improve, " +
                    "then record again."
        }
    }

    /**
     * Apply the stricter wizard rule to a result the existing production
     * pipeline has already produced.
     *
     * @param production the unmodified outcome from the existing
     *   `LocationTracker` / `PinLocationFixValidator` path.
     */
    fun evaluate(production: PinLocationResult): Result {
        val fix = (production as? PinLocationResult.Success)?.fix
            ?: return Result.Rejected(production)
        val accuracy = fix.accuracyMetres
        // Production has already established this is finite and >= 0.
        return if (accuracy > MAX_ACCURACY_METRES) {
            Result.TooImpreciseForCalibration(fix = fix, accuracyMetres = accuracy)
        } else {
            Result.Accepted(fix)
        }
    }

    /** True when [accuracyMetres] is comfortable, not merely acceptable. Presentation only. */
    fun isComfortable(accuracyMetres: Double): Boolean = accuracyMetres <= GOOD_ACCURACY_METRES

    private fun format(value: Double): String =
        if (value >= 10.0) {
            value.toInt().toString()
        } else {
            String.format(java.util.Locale.US, "%.1f", value)
        }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * Pure, backend-neutral duplicate detector for Repairs/Growth launcher pins.
 *
 * Two complementary paths, both mirroring the iOS `PinDuplicateChecker` flow
 * (`RepairsGrowthView.checkDuplicate` runs along-row first, raw distance second):
 *
 * 1. [nearbyAlongRow] — preferred. When a new launcher pin has been snapped to a
 *    vine row, warn if there is already an *open* pin on the same block + same
 *    attached row + same side + same mode whose stored along-row position is
 *    within [ALONG_ROW_DUPLICATE_METRES]. Catches a repair tapped twice on the
 *    same vine even when GPS jitter spreads the raw fixes apart.
 *
 * 2. [nearbyRawDistance] — legacy fallback. Older pins were created before
 *    row-attachment existed, so they carry no `pin_row_number` /
 *    `along_row_distance_m` and never participate in the along-row path. This
 *    fallback still catches them using raw GPS distance, scoped conservatively
 *    to the same block / mode / side / manual row so it stays safe.
 *
 * Matching notes (parity with iOS):
 * - iOS re-snaps each existing pin's raw coordinate to the row at check time;
 *   Android compares the **stored** `along_row_distance_m` in the along-row path.
 * - iOS' raw fallback (`nearbyPin`) scopes only by vineyard + radius. Android's
 *   fallback is intentionally stricter (block + mode + side + manual row) to
 *   avoid false positives across blocks, while keeping the same threshold.
 * - Matching is by mode (Repairs vs Growth), not by category — same as iOS.
 * - Soft-deleted pins are never matched; open pins are preferred.
 */
object PinDuplicateChecker {

    /** Along-row radius (m) within which two same-row pins are treated as duplicates. */
    const val ALONG_ROW_DUPLICATE_METRES: Double = 2.5

    /**
     * Raw-distance fallback radii, mirroring iOS `PinDuplicateChecker`:
     * half the block's row spacing, clamped to [MIN_RADIUS_METRES, MAX_RADIUS_METRES],
     * or [FALLBACK_RADIUS_METRES] when the block has no known row width.
     */
    const val FALLBACK_RADIUS_METRES: Double = 3.0
    const val MIN_RADIUS_METRES: Double = 2.5
    const val MAX_RADIUS_METRES: Double = 6.0

    private const val METRES_PER_DEG_LAT = 111_320.0

    /**
     * A likely-duplicate match. [alongRow] distinguishes the two paths so the UI
     * can word the warning correctly: along-row matches know the attached row and
     * exact along-row distance; raw-distance fallbacks only know straight-line
     * GPS distance within the block.
     */
    data class Match(
        val pin: Pin,
        val distanceM: Double,
        val alongRow: Boolean,
    )

    /**
     * Find the nearest likely duplicate of a pin whose resolved [candidate]
     * attachment sits on a known vine row inside [paddockId]. Returns null when
     * there is no row context or no open same-row/side/mode pin within range.
     */
    fun nearbyAlongRow(
        candidate: RowAttachment.Attachment,
        paddockId: String?,
        mode: String?,
        pins: List<Pin>,
    ): Match? {
        if (paddockId == null) return null
        val candidateSide = candidate.pinSide?.lowercase()?.takeIf { it == "left" || it == "right" }
        val candidateMode = mode?.lowercase()?.takeIf { it.isNotBlank() }

        var best: Match? = null
        for (pin in pins) {
            if (pin.deletedAt != null) continue
            if (pin.isCompleted) continue
            if (pin.paddockId != paddockId) continue

            // Same attached vine row (snapped row), tolerant to fractional values.
            val existingRow = pin.pinRowNumber ?: continue
            if (existingRow != candidate.pinRowNumber) continue

            // Constrain by side only when both sides are known.
            if (candidateSide != null) {
                val existingSide = (pin.pinSide ?: pin.side)?.lowercase()
                if (existingSide == "left" || existingSide == "right") {
                    if (existingSide != candidateSide) continue
                }
            }

            // Constrain by mode (Repairs vs Growth) when known.
            if (candidateMode != null) {
                val existingMode = pin.mode?.lowercase()
                if (!existingMode.isNullOrBlank() && existingMode != candidateMode) continue
            }

            val existingAlong = pin.alongRowDistanceM ?: continue
            val delta = abs(existingAlong - candidate.alongRowDistanceM)
            if (delta > ALONG_ROW_DUPLICATE_METRES) continue

            if (best == null || delta < best.distanceM) {
                best = Match(pin = pin, distanceM = delta, alongRow = true)
            }
        }
        return best
    }

    /**
     * Legacy fallback for older pins lacking row attachment. Uses raw GPS
     * distance from the new pin's [latitude]/[longitude] to each existing pin's
     * stored coordinate, within a row-spacing-derived radius.
     *
     * Only pins that did NOT participate in [nearbyAlongRow] are considered here
     * (i.e. those missing `pin_row_number` or `along_row_distance_m`), so the two
     * paths never double-warn for the same pin. Matching is scoped to the same
     * block, same mode (when known), same side (when both present) and same
     * manual `row_number` (when both present) to keep it conservative.
     */
    fun nearbyRawDistance(
        latitude: Double?,
        longitude: Double?,
        paddockId: String?,
        mode: String?,
        side: String?,
        manualRowNumber: Int?,
        paddock: Paddock?,
        pins: List<Pin>,
    ): Match? {
        if (latitude == null || longitude == null) return null
        if (paddockId == null) return null
        val candidateSide = side?.lowercase()?.takeIf { it == "left" || it == "right" }
        val candidateMode = mode?.lowercase()?.takeIf { it.isNotBlank() }
        val radius = duplicateRadius(paddock)

        var best: Match? = null
        for (pin in pins) {
            if (pin.deletedAt != null) continue
            if (pin.isCompleted) continue
            if (pin.paddockId != paddockId) continue

            // Only legacy pins missing row attachment — row-attached pins are
            // handled by the (preferred) along-row path.
            if (pin.pinRowNumber != null && pin.alongRowDistanceM != null) continue

            val existingLat = pin.latitude ?: continue
            val existingLng = pin.longitude ?: continue

            // Constrain by side only when both sides are known.
            if (candidateSide != null) {
                val existingSide = (pin.pinSide ?: pin.side)?.lowercase()
                if (existingSide == "left" || existingSide == "right") {
                    if (existingSide != candidateSide) continue
                }
            }

            // Constrain by mode (Repairs vs Growth) when known.
            if (candidateMode != null) {
                val existingMode = pin.mode?.lowercase()
                if (!existingMode.isNullOrBlank() && existingMode != candidateMode) continue
            }

            // Constrain by manual row number only when both pins have one.
            if (manualRowNumber != null && pin.rowNumber != null) {
                if (pin.rowNumber != manualRowNumber) continue
            }

            val d = metresBetween(latitude, longitude, existingLat, existingLng)
            if (d > radius) continue

            if (best == null || d < best.distanceM) {
                best = Match(pin = pin, distanceM = d, alongRow = false)
            }
        }
        return best
    }

    /**
     * Raw-distance warning radius: half the block's row spacing clamped to
     * [MIN_RADIUS_METRES, MAX_RADIUS_METRES], falling back to
     * [FALLBACK_RADIUS_METRES]. Mirrors iOS `PinDuplicateChecker.duplicateRadius`.
     */
    fun duplicateRadius(paddock: Paddock?): Double {
        val width = paddock?.rowWidth
        return if (width != null && width > 0) {
            (width / 2.0).coerceIn(MIN_RADIUS_METRES, MAX_RADIUS_METRES)
        } else {
            FALLBACK_RADIUS_METRES
        }
    }

    /** Straight-line distance (m) between two lat/lng points (equirectangular). */
    private fun metresBetween(
        lat1: Double,
        lng1: Double,
        lat2: Double,
        lng2: Double,
    ): Double {
        val midLat = (lat1 + lat2) / 2.0
        val mPerDegLon = METRES_PER_DEG_LAT * cos(midLat * Math.PI / 180.0)
        val dx = (lng2 - lng1) * mPerDegLon
        val dy = (lat2 - lat1) * METRES_PER_DEG_LAT
        return sqrt(dx * dx + dy * dy)
    }
}

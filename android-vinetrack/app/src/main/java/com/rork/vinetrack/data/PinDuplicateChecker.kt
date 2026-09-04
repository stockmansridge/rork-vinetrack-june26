package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

/** Pure, read-only duplicate evaluator shared by every Repairs/Growth launcher. */
object PinDuplicateChecker {
    const val ALONG_ROW_DUPLICATE_METRES: Double = 2.5
    const val FALLBACK_RADIUS_METRES: Double = 3.0
    const val MIN_RADIUS_METRES: Double = 2.5
    const val MAX_RADIUS_METRES: Double = 6.0

    private const val METRES_PER_DEG_LAT: Double = 111_320.0

    enum class Method(val diagnosticName: String) {
        ALONG_ROW("along_row"),
        RAW_DISTANCE("raw_distance"),
    }

    data class Match(
        val pin: Pin,
        val distanceM: Double,
        val radiusM: Double,
        val method: Method,
    ) {
        val alongRow: Boolean get() = method == Method.ALONG_ROW
    }

    data class Diagnostics(
        val candidateKey: PinTypeKey,
        val vineyardPinsInspected: Int,
        val sameTypeCandidates: Int,
        val method: Method?,
        val matchedType: PinTypeKey?,
        val distanceM: Double?,
        val radiusM: Double,
        val result: String,
    ) {
        fun description(): String = buildString {
            append("candidate=$candidateKey")
            append("; inspected=$vineyardPinsInspected")
            append("; same_type=$sameTypeCandidates")
            append("; method=${method?.diagnosticName ?: "none"}")
            append("; matched_type=${matchedType ?: "none"}")
            append("; distance_m=${distanceM?.let { String.format(java.util.Locale.US, "%.2f", it) } ?: "none"}")
            append("; radius_m=${String.format(java.util.Locale.US, "%.2f", radiusM)}")
            append("; result=$result")
        }
    }

    data class Evaluation(
        val match: Match?,
        val diagnostics: Diagnostics,
    )

    /** Along-row first, then legacy raw distance. Type filtering precedes both. */
    fun evaluate(
        candidate: RowAttachment.Attachment?,
        latitude: Double?,
        longitude: Double?,
        vineyardId: String?,
        paddockId: String?,
        mode: String,
        logicalType: String,
        side: String?,
        manualRowNumber: Int?,
        paddock: Paddock?,
        pins: List<Pin>,
    ): Evaluation {
        val candidateKey = PinTypeKey.candidate(mode = mode, logicalType = logicalType)
        val radius = duplicateRadius(paddock)
        if (vineyardId == null) return noMatch(candidateKey, 0, 0, radius)

        val vineyardPins = pins.filter { it.vineyardId == vineyardId }
        val sameTypePins = vineyardPins.filter {
            it.deletedAt == null && !it.isCompleted && PinTypeKey.existing(it) == candidateKey
        }

        val alongRow = candidate?.let {
            nearbyAlongRow(
                candidate = it,
                paddockId = paddockId,
                candidateKey = candidateKey,
                pins = sameTypePins,
            )
        }
        if (alongRow != null) {
            return matched(alongRow, candidateKey, vineyardPins.size, sameTypePins.size)
        }

        val raw = nearbyRawDistance(
            latitude = latitude,
            longitude = longitude,
            paddockId = paddockId,
            candidateKey = candidateKey,
            side = side,
            manualRowNumber = manualRowNumber,
            radius = radius,
            pins = sameTypePins,
        )
        return if (raw != null) {
            matched(raw, candidateKey, vineyardPins.size, sameTypePins.size)
        } else {
            noMatch(candidateKey, vineyardPins.size, sameTypePins.size, radius)
        }
    }

    private fun nearbyAlongRow(
        candidate: RowAttachment.Attachment,
        paddockId: String?,
        candidateKey: PinTypeKey,
        pins: List<Pin>,
    ): Match? {
        if (paddockId == null) return null
        val candidateSide = normalizedSide(candidate.pinSide)
        var best: Match? = null

        for (pin in pins) {
            if (pin.deletedAt != null || pin.isCompleted) continue
            if (PinTypeKey.existing(pin) != candidateKey) continue
            if (pin.paddockId != paddockId) continue
            if (pin.pinRowNumber != candidate.pinRowNumber) continue

            val existingSide = normalizedSide(pin.pinSide ?: pin.side)
            if (candidateSide != null && existingSide != null && existingSide != candidateSide) continue

            val existingAlong = pin.alongRowDistanceM ?: continue
            val distance = abs(existingAlong - candidate.alongRowDistanceM)
            if (distance > ALONG_ROW_DUPLICATE_METRES) continue
            if (best == null || distance < best.distanceM) {
                best = Match(pin, distance, ALONG_ROW_DUPLICATE_METRES, Method.ALONG_ROW)
            }
        }
        return best
    }

    private fun nearbyRawDistance(
        latitude: Double?,
        longitude: Double?,
        paddockId: String?,
        candidateKey: PinTypeKey,
        side: String?,
        manualRowNumber: Int?,
        radius: Double,
        pins: List<Pin>,
    ): Match? {
        if (latitude == null || longitude == null || paddockId == null) return null
        val candidateSide = normalizedSide(side)
        var best: Match? = null

        for (pin in pins) {
            if (pin.deletedAt != null || pin.isCompleted) continue
            if (PinTypeKey.existing(pin) != candidateKey) continue
            if (pin.paddockId != paddockId) continue

            // Row-attached pins are handled only by the along-row path. They
            // cannot re-enter as a false raw match from an adjacent row.
            if (pin.pinRowNumber != null || pin.alongRowDistanceM != null || pin.snappedToRow) continue

            val existingSide = normalizedSide(pin.pinSide ?: pin.side)
            if (candidateSide != null && existingSide != null && existingSide != candidateSide) continue
            if (manualRowNumber != null && pin.rowNumber != null && pin.rowNumber != manualRowNumber) continue

            val existingLat = pin.latitude ?: continue
            val existingLng = pin.longitude ?: continue
            val distance = metresBetween(latitude, longitude, existingLat, existingLng)
            if (distance > radius) continue
            if (best == null || distance < best.distanceM) {
                best = Match(pin, distance, radius, Method.RAW_DISTANCE)
            }
        }
        return best
    }

    fun duplicateRadius(paddock: Paddock?): Double {
        val width = paddock?.rowWidth
        return if (width != null && width > 0) {
            (width / 2.0).coerceIn(MIN_RADIUS_METRES, MAX_RADIUS_METRES)
        } else {
            FALLBACK_RADIUS_METRES
        }
    }

    private fun matched(
        match: Match,
        candidateKey: PinTypeKey,
        inspected: Int,
        sameType: Int,
    ): Evaluation = Evaluation(
        match = match,
        diagnostics = Diagnostics(
            candidateKey = candidateKey,
            vineyardPinsInspected = inspected,
            sameTypeCandidates = sameType,
            method = match.method,
            matchedType = PinTypeKey.existing(match.pin),
            distanceM = match.distanceM,
            radiusM = match.radiusM,
            result = if (match.alongRow) {
                "duplicate_same_type_along_row"
            } else {
                "duplicate_same_type_raw_distance"
            },
        ),
    )

    private fun noMatch(
        candidateKey: PinTypeKey,
        inspected: Int,
        sameType: Int,
        radius: Double,
    ): Evaluation = Evaluation(
        match = null,
        diagnostics = Diagnostics(
            candidateKey = candidateKey,
            vineyardPinsInspected = inspected,
            sameTypeCandidates = sameType,
            method = null,
            matchedType = null,
            distanceM = null,
            radiusM = radius,
            result = "no_same_type_duplicate",
        ),
    )

    private fun normalizedSide(value: String?): String? = value
        ?.trim()
        ?.lowercase()
        ?.takeIf { it == "left" || it == "right" }

    private fun metresBetween(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val midLat = (lat1 + lat2) / 2.0
        val metresPerDegreeLongitude = METRES_PER_DEG_LAT * cos(midLat * Math.PI / 180.0)
        val dx = (lng2 - lng1) * metresPerDegreeLongitude
        val dy = (lat2 - lat1) * METRES_PER_DEG_LAT
        return sqrt(dx * dx + dy * dy)
    }
}

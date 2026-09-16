package com.rork.vinetrack.data.insights

import java.util.UUID

/**
 * The Scout capture domain — pure data and pure rules, no Android, no network.
 *
 * Mirrored by iOS `ScoutModels.swift`. Both platforms capture the same shapes
 * so a visit recorded on a phone in the rows reads identically on the other
 * platform and, later, in a report.
 */

/** Lifecycle of a Scout visit. */
enum class ScoutStatus(val code: String, val label: String) {
    DRAFT("draft", "Draft"),
    COMPLETED("completed", "Completed"),
    ;

    companion object {
        fun byCode(code: String?): ScoutStatus = entries.firstOrNull { it.code == code } ?: DRAFT
    }
}

/** Completion state of one block's assessment. */
enum class ScoutAssessmentStatus(val code: String, val label: String) {
    IN_PROGRESS("in_progress", "In progress"),
    COMPLETE("complete", "Complete"),
    ;

    companion object {
        fun byCode(code: String?): ScoutAssessmentStatus =
            entries.firstOrNull { it.code == code } ?: IN_PROGRESS
    }
}

/**
 * How honestly a photo's coordinates are known.
 *
 * This exists because the alternative — a nullable latitude — cannot tell the
 * difference between "we did not try", "we tried and failed" and "this is
 * where it was". A scouting photo is evidence; a photo silently carrying the
 * shed's coordinates, or the block centroid, is worse than a photo with no
 * coordinates at all, because it looks precise.
 */
enum class PhotoLocationStatus(val code: String, val label: String) {
    /** A fresh fix passing the existing strict validation was attached. */
    GPS_CONFIRMED("gps_confirmed", "GPS confirmed"),

    /**
     * No qualifying fix was available. The photo is associated with the BLOCK
     * only and carries no coordinates whatsoever — not a stale fix, not a
     * last-known position, not a centroid.
     */
    UNAVAILABLE("location_unavailable", "Location unavailable — block association only"),
    ;

    companion object {
        fun byCode(code: String?): PhotoLocationStatus =
            entries.firstOrNull { it.code == code } ?: UNAVAILABLE
    }
}

/**
 * A photo attached to one observation.
 *
 * Coordinates are only ever populated together with
 * [PhotoLocationStatus.GPS_CONFIRMED]; [blockOnly] is the only other legal
 * shape. There is intentionally no constructor that lets a caller supply
 * coordinates with an unavailable status.
 */
data class ScoutPhoto(
    val id: String,
    val observationId: String,
    /** App-private file path, written BEFORE any upload is attempted. */
    val localPath: String?,
    /** Server storage path once uploaded; null while local-only. */
    val storagePath: String?,
    val capturedAtIso: String,
    val capturedByUserId: String?,
    val latitude: Double?,
    val longitude: Double?,
    val accuracyMetres: Double?,
    val locationStatus: PhotoLocationStatus,
) {
    init {
        // A structurally impossible claim is rejected at construction rather
        // than discovered in a report months later.
        if (locationStatus == PhotoLocationStatus.UNAVAILABLE) {
            require(latitude == null && longitude == null) {
                "A photo without a qualifying fix must not carry coordinates"
            }
        }
    }

    companion object {
        /** A photo whose position came from a fix that passed validation. */
        fun gpsConfirmed(
            observationId: String,
            localPath: String?,
            capturedAtIso: String,
            capturedByUserId: String?,
            latitude: Double,
            longitude: Double,
            accuracyMetres: Double,
            id: String = UUID.randomUUID().toString(),
        ): ScoutPhoto = ScoutPhoto(
            id = id,
            observationId = observationId,
            localPath = localPath,
            storagePath = null,
            capturedAtIso = capturedAtIso,
            capturedByUserId = capturedByUserId,
            latitude = latitude,
            longitude = longitude,
            accuracyMetres = accuracyMetres,
            locationStatus = PhotoLocationStatus.GPS_CONFIRMED,
        )

        /**
         * A photo with no trustworthy position. The caller cannot pass
         * coordinates here even by mistake — that is the entire point of the
         * separate factory.
         */
        fun blockOnly(
            observationId: String,
            localPath: String?,
            capturedAtIso: String,
            capturedByUserId: String?,
            id: String = UUID.randomUUID().toString(),
        ): ScoutPhoto = ScoutPhoto(
            id = id,
            observationId = observationId,
            localPath = localPath,
            storagePath = null,
            capturedAtIso = capturedAtIso,
            capturedByUserId = capturedByUserId,
            latitude = null,
            longitude = null,
            accuracyMetres = null,
            locationStatus = PhotoLocationStatus.UNAVAILABLE,
        )
    }
}

/**
 * One captured assessment item for one block.
 *
 * [valueCode] and [valueLabel] are stored together deliberately: the code is
 * the queryable truth and the label is what the operator actually read on the
 * day. A future relabelling changes new captures only.
 */
data class ScoutObservation(
    val id: String,
    val assessmentId: String,
    val item: ScoutItem,
    val valueCode: String?,
    val valueLabel: String?,
    val notes: String?,
    val photos: List<ScoutPhoto> = emptyList(),
    /** Nullable linkage reserved for the later reviewed-action workflow. */
    val linkedPinId: String? = null,
    /** Canonical `growth_stage_records.id` when [item] is GROWTH_STAGE. */
    val linkedGrowthStageRecordId: String? = null,
) {
    /** True when this row carries anything at all worth keeping. */
    val hasContent: Boolean
        get() = VineyardInsightsCatalog.isAssessed(item, valueCode) ||
            !notes.isNullOrBlank() ||
            photos.isNotEmpty() ||
            linkedGrowthStageRecordId != null

    val needsAttention: Boolean
        get() = VineyardInsightsCatalog.needsAttention(item, valueCode)

    companion object {
        /** An empty, defaulted observation for [item]. */
        fun empty(assessmentId: String, item: ScoutItem): ScoutObservation {
            val defaultCode = if (item.isFreeText || item == ScoutItem.GROWTH_STAGE) {
                null
            } else {
                VineyardInsightsCatalog.NOT_ASSESSED_CODE
            }
            return ScoutObservation(
                id = UUID.randomUUID().toString(),
                assessmentId = assessmentId,
                item = item,
                valueCode = defaultCode,
                valueLabel = defaultCode?.let { VineyardInsightsCatalog.NOT_ASSESSED_LABEL },
                notes = null,
            )
        }
    }
}

/** One block's assessment within a visit. */
data class ScoutBlockAssessment(
    val id: String,
    val visitId: String,
    val vineyardId: String,
    val paddockId: String,
    val status: ScoutAssessmentStatus = ScoutAssessmentStatus.IN_PROGRESS,
    val observations: List<ScoutObservation> = emptyList(),
) {
    fun observation(item: ScoutItem): ScoutObservation? = observations.firstOrNull { it.item == item }

    /** Observations carrying real content — what the review and report count. */
    val recordedObservations: List<ScoutObservation>
        get() = observations.filter { it.hasContent }

    val photoCount: Int get() = observations.sumOf { it.photos.size }

    val attentionItems: List<ScoutObservation>
        get() = observations.filter { it.needsAttention }

    /**
     * Completion rule for ONE block.
     *
     * Deliberately not "every dropdown answered": a scout who walks a block
     * and finds nothing worth noting has done their job, and forcing six
     * selections to record that would train people to click through defaults.
     * What IS required is evidence that the block was actually visited — at
     * least one observation, issue or recommendation.
     */
    val isComplete: Boolean
        get() = recordedObservations.isNotEmpty()

    fun withObservation(updated: ScoutObservation): ScoutBlockAssessment {
        val existing = observations.indexOfFirst { it.item == updated.item }
        val next = if (existing >= 0) {
            observations.toMutableList().apply { this[existing] = updated }
        } else {
            observations + updated
        }
        return copy(observations = next)
    }

    companion object {
        /** A fresh assessment with every item present and defaulted. */
        fun create(visitId: String, vineyardId: String, paddockId: String): ScoutBlockAssessment {
            val id = UUID.randomUUID().toString()
            return ScoutBlockAssessment(
                id = id,
                visitId = visitId,
                vineyardId = vineyardId,
                paddockId = paddockId,
                observations = ScoutItem.entries.map { ScoutObservation.empty(id, it) },
            )
        }
    }
}

/**
 * A current-weather snapshot captured alongside a visit.
 *
 * Every field is optional and [isStale] / [isUnavailable] are explicit, because
 * the honest answer "we could not reach the weather service" must survive into
 * the record. A report that silently omits a missing reading invites the reader
 * to assume conditions were unremarkable.
 */
data class ScoutWeatherSnapshot(
    val observedAtIso: String?,
    val capturedAtIso: String,
    val source: String?,
    val temperatureCelsius: Double?,
    val humidityPercent: Double?,
    val windSpeedKph: Double?,
    val windGustKph: Double?,
    val recentRainfallMm: Double?,
    val isStale: Boolean = false,
    val isUnavailable: Boolean = false,
) {
    companion object {
        /** The recorded absence of weather — never an invented reading. */
        fun unavailable(capturedAtIso: String, source: String? = null): ScoutWeatherSnapshot =
            ScoutWeatherSnapshot(
                observedAtIso = null,
                capturedAtIso = capturedAtIso,
                source = source,
                temperatureCelsius = null,
                humidityPercent = null,
                windSpeedKph = null,
                windGustKph = null,
                recentRainfallMm = null,
                isStale = false,
                isUnavailable = true,
            )
    }
}

/** A Scout visit: the unit an operator starts, saves and completes. */
data class ScoutVisit(
    /** Client-generated UUID — the offline idempotency key. */
    val id: String,
    val vineyardId: String,
    /** Server-resolved; the client value is display-only until sync returns. */
    val vintageYear: Int,
    val scoutDateIso: String,
    val status: ScoutStatus = ScoutStatus.DRAFT,
    val visitSummary: String? = null,
    val weather: ScoutWeatherSnapshot? = null,
    val scoutUserId: String?,
    val scoutNameSnapshot: String?,
    val assessments: List<ScoutBlockAssessment> = emptyList(),
    val clientUpdatedAtIso: String,
    val syncVersion: Long = 0,
) {
    val isEditable: Boolean get() = status == ScoutStatus.DRAFT

    fun assessment(paddockId: String): ScoutBlockAssessment? =
        assessments.firstOrNull { it.paddockId == paddockId }

    /**
     * Add a block, or return unchanged if it is already assessed.
     *
     * The uniqueness of one assessment per visit and block is a domain rule,
     * not only a database constraint: two partially-filled assessments for the
     * same block would make "what did the scout find in Block 4?" ambiguous.
     */
    fun withBlock(paddockId: String): ScoutVisit =
        if (assessment(paddockId) != null) {
            this
        } else {
            copy(
                assessments = assessments +
                    ScoutBlockAssessment.create(id, vineyardId, paddockId),
            )
        }

    fun withoutBlock(paddockId: String): ScoutVisit =
        copy(assessments = assessments.filterNot { it.paddockId == paddockId })

    fun withAssessment(updated: ScoutBlockAssessment): ScoutVisit {
        val index = assessments.indexOfFirst { it.id == updated.id }
        if (index < 0) return this
        return copy(
            assessments = assessments.toMutableList().apply { this[index] = updated },
        )
    }
}

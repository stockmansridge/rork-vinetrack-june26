package com.rork.vinetrack.data

import java.util.UUID

/**
 * P0 3.1.9: explains why an active Trip is or is not operable on this device.
 *
 * `AppUiState.activeTrip` combines five predicates into one boolean. When any
 * of them failed, the Trip detail said "read-only on this device", and implied
 * another device owned it. That wording was wrong for a vineyard-selection
 * mismatch or a pending local end. This evaluator reports every predicate
 * separately, with exact-string and typed-UUID vineyard equality, and returns
 * one reason. It never grants authority. Only [Reason.DEVICE_TRIP] enables
 * controls, and that still requires the unchanged `activeTrip` result.
 */
object DeviceTripStatus {
    enum class Reason(val code: String) {
        DEVICE_TRIP("DEVICE_TRIP"),
        NOT_ACTIVE("TRIP_NOT_ACTIVE"),
        LOCAL_END_PENDING("LOCAL_END_PENDING"),
        SELECTED_VINEYARD_MISMATCH("SELECTED_VINEYARD_MISMATCH"),
        VINEYARD_ID_FORMAT_MISMATCH("VINEYARD_ID_FORMAT_MISMATCH"),
        NO_SELECTED_VINEYARD("NO_SELECTED_VINEYARD"),
        CLAIM_NOT_LOADED("DEVICE_CLAIM_NOT_LOADED"),
        CLAIM_UNREADABLE("DEVICE_CLAIM_UNREADABLE"),
        CLAIM_FOR_OTHER_TRIP("DEVICE_CLAIM_FOR_OTHER_TRIP"),
        NO_DEVICE_CLAIM("NO_DEVICE_CLAIM"),
        UNEXPLAINED("ACTIVE_TRIP_PREDICATES_UNEXPLAINED"),
    }

    /** Read-only evidence from the persisted active-Trip snapshot (the durable tracking claim). */
    data class PersistedClaim(
        val readable: Boolean,
        val tripId: String? = null,
        val vineyardId: String? = null,
        val ownerMatchesSession: Boolean = false,
        val tripActive: Boolean = false,
    )

    data class Input(
        val tripId: String,
        val tripVineyardId: String,
        val tripIsActive: Boolean,
        val tripEndTime: String?,
        val selectedVineyardId: String?,
        val deviceActiveTripId: String?,
        val computedActiveTripId: String?,
        val locallyEnded: Boolean,
        val claim: PersistedClaim,
        val userHasTripVineyard: Boolean,
    )

    data class Result(
        val reason: Reason,
        /** Return to Trip is offered only for a verified own-claim vineyard mismatch. */
        val canReturnToTrip: Boolean,
        val predicates: List<Pair<String, String>>,
    ) {
        val isDeviceTrip: Boolean get() = reason == Reason.DEVICE_TRIP
        /** True only when the evidence verifies that this device does not hold the Trip. */
        val verifiedNotThisDevice: Boolean get() =
            reason == Reason.NO_DEVICE_CLAIM || reason == Reason.CLAIM_FOR_OTHER_TRIP
    }

    /** Typed UUID equality; null when either value is not a UUID. */
    fun sameUuid(a: String?, b: String?): Boolean? {
        if (a == null || b == null) return null
        val ua = runCatching { UUID.fromString(a.trim()) }.getOrNull() ?: return null
        val ub = runCatching { UUID.fromString(b.trim()) }.getOrNull() ?: return null
        return ua == ub
    }

    fun evaluate(input: Input): Result {
        val claim = input.claim
        val claimMatchesTrip = claim.readable && claim.ownerMatchesSession && claim.tripId == input.tripId
        val claimVineyardMatchesTrip = claimMatchesTrip &&
            (claim.vineyardId == input.tripVineyardId || sameUuid(claim.vineyardId, input.tripVineyardId) == true)
        val vineyardExact = input.selectedVineyardId != null && input.selectedVineyardId == input.tripVineyardId
        val vineyardUuid = sameUuid(input.selectedVineyardId, input.tripVineyardId)
        val predicates = listOf(
            "computed_active_trip_matches" to (input.computedActiveTripId == input.tripId).toString(),
            "device_active_trip_id_matches" to when (input.deviceActiveTripId) {
                null -> "none"; input.tripId -> "true"; else -> "other_trip"
            },
            "selected_vineyard_exact_equal" to vineyardExact.toString(),
            "selected_vineyard_uuid_equal" to (vineyardUuid?.toString() ?: "not_uuid_or_absent"),
            "trip_is_active" to input.tripIsActive.toString(),
            "trip_end_time_blank" to input.tripEndTime.isNullOrBlank().toString(),
            "trip_locally_ended" to input.locallyEnded.toString(),
            "persisted_claim_readable" to claim.readable.toString(),
            "persisted_claim_trip_matches" to (claim.readable && claim.tripId == input.tripId).toString(),
            "persisted_claim_owner_matches" to (claim.readable && claim.ownerMatchesSession).toString(),
            "persisted_claim_vineyard_matches_trip" to claimVineyardMatchesTrip.toString(),
            "persisted_claim_trip_active" to (claim.readable && claim.tripActive).toString(),
        )
        fun result(reason: Reason, returnable: Boolean = false) = Result(reason, returnable, predicates)

        if (input.computedActiveTripId == input.tripId) return result(Reason.DEVICE_TRIP)
        if (!input.tripIsActive || !input.tripEndTime.isNullOrBlank()) return result(Reason.NOT_ACTIVE)
        if (input.locallyEnded) return result(Reason.LOCAL_END_PENDING)

        val heldInMemory = input.deviceActiveTripId == input.tripId
        val ownedEvidence = heldInMemory || claimMatchesTrip
        if (ownedEvidence) {
            if (input.selectedVineyardId == null) return result(Reason.NO_SELECTED_VINEYARD)
            if (!vineyardExact) {
                if (vineyardUuid == true) return result(Reason.VINEYARD_ID_FORMAT_MISMATCH)
                // A genuine different selection. Return only when the durable claim
                // itself names this Trip and its vineyard, and the account can open it.
                return result(Reason.SELECTED_VINEYARD_MISMATCH,
                    returnable = claimVineyardMatchesTrip && input.userHasTripVineyard)
            }
            return if (heldInMemory) result(Reason.UNEXPLAINED) else result(Reason.CLAIM_NOT_LOADED)
        }
        if (!claim.readable) return result(Reason.CLAIM_UNREADABLE)
        if (input.deviceActiveTripId != null) return result(Reason.CLAIM_FOR_OTHER_TRIP)
        return result(Reason.NO_DEVICE_CLAIM)
    }

    fun diagnosticLines(tripId: String, result: Result): List<String> =
        listOf("device_trip_status: trip=$tripId reason=${result.reason.code} return_to_trip=${result.canReturnToTrip}") +
            result.predicates.map { (k, v) -> "  $k: $v" }
}

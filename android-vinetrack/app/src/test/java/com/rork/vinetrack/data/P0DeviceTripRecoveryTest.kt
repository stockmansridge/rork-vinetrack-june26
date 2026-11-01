package com.rork.vinetrack.data

import com.rork.vinetrack.data.DeviceTripStatus.Reason
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P0 3.1.9 incident: Android original device showed its own active Trip as
 * read-only, and the Tank 1 session vanished while the actual remained.
 */
class P0DeviceTripRecoveryTest {
    private val tripId = "3bfb7f81-2ae2-4f33-8fd8-6666b2b45393"
    private val vineyard = "6f0f7c3e-1111-4a2b-9c3d-0123456789ab"
    private val otherVineyard = "aa0f7c3e-2222-4a2b-9c3d-0123456789ab"
    private val tank1 = TankSession(id = "b1a1c0de-0000-4000-8000-000000000001", tankNumber = 1,
        startTime = "2026-11-01T01:00:00Z")

    private fun input(
        selected: String? = vineyard,
        deviceActive: String? = tripId,
        computed: String? = null,
        locallyEnded: Boolean = false,
        claim: DeviceTripStatus.PersistedClaim = DeviceTripStatus.PersistedClaim(
            readable = true, tripId = tripId, vineyardId = vineyard, ownerMatchesSession = true, tripActive = true),
        tripVineyard: String = vineyard,
        active: Boolean = true,
        member: Boolean = true,
    ) = DeviceTripStatus.Input(tripId, tripVineyard, active, null, selected, deviceActive, computed,
        locallyEnded, claim, member)

    @Test fun deviceTripWhenComputedActiveMatches() {
        val r = DeviceTripStatus.evaluate(input(computed = tripId))
        assertEquals(Reason.DEVICE_TRIP, r.reason)
        assertTrue(r.isDeviceTrip)
    }

    @Test fun genuineVineyardMismatchOffersReturnAndIsNotOtherDevice() {
        val r = DeviceTripStatus.evaluate(input(selected = otherVineyard))
        assertEquals(Reason.SELECTED_VINEYARD_MISMATCH, r.reason)
        assertTrue(r.canReturnToTrip)
        assertFalse(r.verifiedNotThisDevice)
    }

    @Test fun vineyardMismatchWithoutMembershipDoesNotOfferReturn() {
        val r = DeviceTripStatus.evaluate(input(selected = otherVineyard, member = false))
        assertEquals(Reason.SELECTED_VINEYARD_MISMATCH, r.reason)
        assertFalse(r.canReturnToTrip)
    }

    @Test fun vineyardMismatchWithForeignClaimDoesNotOfferReturn() {
        val r = DeviceTripStatus.evaluate(input(selected = otherVineyard,
            claim = DeviceTripStatus.PersistedClaim(readable = true, tripId = tripId, vineyardId = vineyard,
                ownerMatchesSession = false, tripActive = true)))
        assertEquals(Reason.SELECTED_VINEYARD_MISMATCH, r.reason)
        assertFalse(r.canReturnToTrip)
    }

    @Test fun caseOnlyVineyardDifferenceIsFormatMismatchNotOwnership() {
        val r = DeviceTripStatus.evaluate(input(selected = vineyard.uppercase()))
        assertEquals(Reason.VINEYARD_ID_FORMAT_MISMATCH, r.reason)
        assertFalse(r.canReturnToTrip)
        assertFalse(r.verifiedNotThisDevice)
        assertTrue(r.predicates.contains("selected_vineyard_exact_equal" to "false"))
        assertTrue(r.predicates.contains("selected_vineyard_uuid_equal" to "true"))
    }

    @Test fun locallyEndedIsSeparateFromOwnership() {
        val r = DeviceTripStatus.evaluate(input(locallyEnded = true))
        assertEquals(Reason.LOCAL_END_PENDING, r.reason)
        assertFalse(r.verifiedNotThisDevice)
    }

    @Test fun persistedClaimNotYetLoadedIsNotOtherDevice() {
        val r = DeviceTripStatus.evaluate(input(deviceActive = null))
        assertEquals(Reason.CLAIM_NOT_LOADED, r.reason)
        assertFalse(r.verifiedNotThisDevice)
    }

    @Test fun noClaimIsVerifiedReadOnly() {
        val r = DeviceTripStatus.evaluate(input(deviceActive = null,
            claim = DeviceTripStatus.PersistedClaim(readable = true)))
        assertEquals(Reason.NO_DEVICE_CLAIM, r.reason)
        assertTrue(r.verifiedNotThisDevice)
        assertFalse(r.canReturnToTrip)
    }

    @Test fun claimForAnotherTripIsVerifiedReadOnly() {
        val r = DeviceTripStatus.evaluate(input(deviceActive = "other",
            claim = DeviceTripStatus.PersistedClaim(readable = true, tripId = "other", vineyardId = vineyard,
                ownerMatchesSession = true, tripActive = true)))
        assertEquals(Reason.CLAIM_FOR_OTHER_TRIP, r.reason)
    }

    @Test fun unreadableClaimIsHeldNotOwnership() {
        val r = DeviceTripStatus.evaluate(input(deviceActive = null,
            claim = DeviceTripStatus.PersistedClaim(readable = false)))
        assertEquals(Reason.CLAIM_UNREADABLE, r.reason)
        assertFalse(r.verifiedNotThisDevice)
    }

    // ---- occurrence restore must not displace local Tank 1 ----

    private fun trip(sessions: List<TankSession>, active: Int? = null, paused: Boolean = false) = Trip(
        id = tripId, vineyardId = vineyard, isActive = true, isPaused = paused,
        startTime = "2026-11-01T00:59:00Z", tankSessions = sessions, activeTankNumber = active,
    )

    @Test fun serverRowWithoutSessionsKeepsLocalTank1AndRequiresReplay() {
        val saved = trip(listOf(tank1), active = 1)
        val server = trip(emptyList())
        val r = OccurrenceRestoreLocalProgress.apply(projected = server, server = server, saved = saved)
        assertEquals(listOf(tank1), r.trip.tankSessions)
        assertEquals(1, r.trip.activeTankNumber)
        assertTrue(r.tankReplayRequired)
        assertFalse(r.tankConflict)
    }

    @Test fun serverRowAlreadyHoldingSessionNeedsNoReplay() {
        val saved = trip(listOf(tank1), active = 1)
        val server = trip(listOf(tank1), active = 1)
        val r = OccurrenceRestoreLocalProgress.apply(server, server, saved)
        assertEquals(listOf(tank1), r.trip.tankSessions)
        assertFalse(r.tankReplayRequired)
    }

    @Test fun serverOnlySessionIsRetainedNotDropped() {
        val tank2 = TankSession(id = "b1a1c0de-0000-4000-8000-000000000002", tankNumber = 2,
            startTime = "2026-11-01T02:00:00Z")
        val saved = trip(listOf(tank1), active = 1)
        val server = trip(listOf(tank2), active = 2)
        val r = OccurrenceRestoreLocalProgress.apply(server, server, saved)
        assertEquals(setOf(tank1.id, tank2.id), r.trip.tankSessions.map { it.id }.toSet())
    }

    @Test fun conflictingSessionKeepsLocalEvidenceUnchangedAndHolds() {
        val saved = trip(listOf(tank1), active = 1)
        val server = trip(listOf(tank1.copy(tankNumber = 2)))
        val r = OccurrenceRestoreLocalProgress.apply(server, server, saved)
        assertTrue(r.tankConflict)
        assertEquals(listOf(tank1), r.trip.tankSessions)
        assertFalse(r.tankReplayRequired)
    }

    @Test fun localPauseIsNotDisplacedByServerRow() {
        val saved = trip(listOf(tank1), active = 1, paused = true)
            .copy(pauseTimestamps = listOf("2026-11-01T01:30:00Z"))
        val server = trip(emptyList(), paused = false)
        val r = OccurrenceRestoreLocalProgress.apply(server, server, saved)
        assertTrue(r.trip.isPaused)
        assertEquals(listOf("2026-11-01T01:30:00Z"), r.trip.pauseTimestamps)
    }

    @Test fun noServerRowLeavesProjectionUnchanged() {
        val saved = trip(listOf(tank1), active = 1)
        val r = OccurrenceRestoreLocalProgress.apply(saved, null, saved)
        assertEquals(saved, r.trip)
        assertFalse(r.tankReplayRequired)
    }
}

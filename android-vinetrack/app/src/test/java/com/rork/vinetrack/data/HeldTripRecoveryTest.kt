package com.rork.vinetrack.data

import com.rork.vinetrack.data.HeldTripRecovery.Reason
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class HeldTripRecoveryTest {
    private val trip = Trip(id = "trip-1", vineyardId = "v1", isActive = true, startTime = "2026-11-06T00:04:15Z")
    private fun snap(owner: String = "u1", vineyard: String = "v1", t: Trip = trip) =
        ActiveTripStore.Snapshot(owner, vineyard, t, 1_000L)

    private fun classify(
        hasClaim: Boolean = true,
        snapshot: ActiveTripStore.Snapshot? = snap(),
        user: String? = "u1",
        selected: String? = "v1",
        visible: String? = null,
        ended: Boolean = false,
    ) = HeldTripRecovery.classify(hasClaim, snapshot, user, selected, visible, ended)

    @Test fun noClaimIsNotHeld() = assertNull(classify(hasClaim = false))

    @Test fun visibleActiveTripIsNotHeld() = assertNull(classify(visible = "trip-1"))

    @Test fun inactiveSnapshotIsNotHeld() = assertNull(classify(snapshot = snap(t = trip.copy(isActive = false))))

    /** The field report: ended on device, crash/restart, end still syncing, Trip hidden, start refused. */
    @Test fun locallyEndedTripStillSyncingIsHeldEvenIfStillListedAsVisible() {
        assertEquals(Reason.END_SYNCING, classify(ended = true)?.reason)
        assertEquals(Reason.END_SYNCING, classify(ended = true, visible = "trip-1")?.reason)
    }

    @Test fun otherVineyardTakesPriorityOverEnd() =
        assertEquals(Reason.OTHER_VINEYARD, classify(selected = "v2", ended = true)?.reason)

    @Test fun otherAccount() = assertEquals(Reason.OTHER_ACCOUNT, classify(user = "u2")?.reason)

    @Test fun unreadableClaim() = assertEquals(Reason.UNREADABLE, classify(snapshot = null)?.reason)

    @Test fun activeButNotRestored() {
        val held = classify()!!
        assertEquals(Reason.NOT_SHOWN, held.reason)
        assertEquals("trip-1", held.tripId)
        assertEquals("v1", held.vineyardId)
        assertEquals(1_000L, held.savedAtMs)
    }

    @Test fun everyReasonHasAStartMessageNamingTheWayOut() {
        Reason.entries.forEach { reason ->
            val msg = HeldTripRecovery.startBlockedMessage(HeldTripRecovery.Held(reason, "t", "v", null, null, null), "Block A")
            assertTrue(reason.name, msg.isNotBlank())
            assertTrue(reason.name, HeldTripRecovery.cardTitle(reason).isNotBlank())
        }
        assertTrue(HeldTripRecovery.startBlockedMessage(
            HeldTripRecovery.Held(Reason.OTHER_VINEYARD, "t", "v", null, null, null), "Pinot Hill").contains("Pinot Hill"))
    }

    @Test fun crashLogKeepsLatestThreeAndSummarisesNewest() {
        val dir = Files.createTempDirectory("crash").toFile()
        assertTrue(CrashLog.summary(dir).contains("none recorded"))
        (1L..5L).forEach { CrashLog.record(dir, "main", IllegalStateException("boom $it", RuntimeException("root")), it * 1000) }
        assertEquals(3, dir.listFiles()!!.size)
        val summary = CrashLog.summary(dir)
        assertTrue(summary, summary.contains("Recent crashes: 3"))
        assertTrue(summary, summary.contains("boom 5"))
        assertTrue(summary, summary.contains("Caused by: java.lang.RuntimeException: root"))
        dir.deleteRecursively()
    }
}

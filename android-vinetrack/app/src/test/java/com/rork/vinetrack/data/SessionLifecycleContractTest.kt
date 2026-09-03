package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionDecision
import com.rork.vinetrack.data.auth.SessionDecisions
import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.auth.SessionValidity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression tests for the authentication-session contract.
 *
 * Governing rule: loss of internet access must never, by itself, sign a
 * VineTrack user out. Only an explicit logout, or a definitive rejection from
 * a reachable server, may clear the local session.
 */
class SessionLifecycleContractTest {

    // ---- Connectivity failures must never sign out ------------------------

    @Test
    fun `airplane mode while logged in keeps the user logged in`() {
        assertEquals(
            SessionDecision.KeepOffline,
            SessionDecisions.onUnauthorized(isOnline = false, validity = null),
        )
    }

    @Test
    fun `network timeout does not sign out`() {
        // A timeout leaves the auth server unreachable, so it can never be read
        // as a credential rejection.
        assertEquals(
            SessionDecision.KeepOffline,
            SessionDecisions.onUnauthorized(isOnline = true, validity = SessionValidity.Unreachable),
        )
    }

    @Test
    fun `DNS failure does not sign out`() {
        assertEquals(
            SessionDecision.KeepOffline,
            SessionDecisions.onUnauthorized(isOnline = true, validity = SessionValidity.Unreachable),
        )
    }

    @Test
    fun `supabase unavailable does not sign out`() {
        assertEquals(
            SessionDecision.KeepOffline,
            SessionDecisions.onUnauthorized(isOnline = true, validity = SessionValidity.Unreachable),
        )
    }

    @Test
    fun `no connectivity never produces a sign-out whatever the server said before`() {
        SessionValidity.entries.forEach { validity ->
            assertNotEquals(
                "offline must never sign out (validity=$validity)",
                SessionDecision.SignOut,
                SessionDecisions.onUnauthorized(isOnline = false, validity = validity),
            )
        }
    }

    // ---- Permission denials are not authentication failures ---------------

    @Test
    fun `401 or 403 that revalidates successfully keeps the session`() {
        // Produced by RLS/permission denials and by requests that raced token
        // hydration — the credentials themselves are fine.
        assertEquals(
            SessionDecision.KeepOnline,
            SessionDecisions.onUnauthorized(isOnline = true, validity = SessionValidity.Valid),
        )
    }

    // ---- The one permitted automatic sign-out -----------------------------

    @Test
    fun `definitively revoked credentials while online sign the user out`() {
        assertEquals(
            SessionDecision.SignOut,
            SessionDecisions.onUnauthorized(isOnline = true, validity = SessionValidity.Rejected),
        )
    }

    // ---- Connectivity transitions -----------------------------------------

    @Test
    fun `going offline moves an authenticated user to the offline phase`() {
        assertEquals(
            SessionPhase.AuthenticatedOffline,
            SessionDecisions.onConnectivityChange(SessionPhase.AuthenticatedOnline, online = false),
        )
    }

    @Test
    fun `coming back online moves an authenticated user to the online phase`() {
        assertEquals(
            SessionPhase.AuthenticatedOnline,
            SessionDecisions.onConnectivityChange(SessionPhase.AuthenticatedOffline, online = true),
        )
    }

    @Test
    fun `connectivity changes never sign anyone out`() {
        SessionPhase.entries.forEach { phase ->
            listOf(true, false).forEach { online ->
                val next = SessionDecisions.onConnectivityChange(phase, online)
                if (phase.isAuthenticated) {
                    assertTrue(
                        "authenticated user must stay authenticated ($phase, online=$online)",
                        next.isAuthenticated,
                    )
                }
            }
        }
    }

    @Test
    fun `connectivity changes do not disturb a restoring session`() {
        assertEquals(
            SessionPhase.Restoring,
            SessionDecisions.onConnectivityChange(SessionPhase.Restoring, online = false),
        )
        assertEquals(
            SessionPhase.Restoring,
            SessionDecisions.onConnectivityChange(SessionPhase.Restoring, online = true),
        )
    }

    @Test
    fun `connectivity changes do not resurrect a signed-out session`() {
        assertEquals(
            SessionPhase.SignedOut,
            SessionDecisions.onConnectivityChange(SessionPhase.SignedOut, online = true),
        )
    }

    // ---- Hydration races ---------------------------------------------------

    @Test
    fun `a null user while restoring is never treated as signed out`() {
        assertFalse(SessionDecisions.mayTreatNullUserAsSignedOut(SessionPhase.Restoring))
    }

    @Test
    fun `a null user after restoration completes may be treated as signed out`() {
        assertTrue(SessionDecisions.mayTreatNullUserAsSignedOut(SessionPhase.SignedOut))
    }

    // ---- Phase classification ----------------------------------------------

    @Test
    fun `offline authenticated users may still use the app`() {
        assertTrue(SessionPhase.AuthenticatedOffline.isAuthenticated)
        assertTrue(SessionPhase.AuthenticatedOnline.isAuthenticated)
        assertFalse(SessionPhase.Restoring.isAuthenticated)
        assertFalse(SessionPhase.SignedOut.isAuthenticated)
    }
}

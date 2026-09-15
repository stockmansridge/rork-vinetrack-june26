package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.auth.SessionPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android Map Alignment is System Admin gated and unreleased. These tests pin
 * the single access decision used by the visibility and navigation layers, so
 * no screen can drift from it.
 *
 * There is deliberately no mutation-guard test here: no persistent alignment
 * operation exists yet, and write authorisation will belong to the server
 * (RPC/RLS), not to this cached client-side decision.
 */
class MapAlignmentAccessTest {

    private fun access(phase: SessionPhase, isSystemAdmin: Boolean) =
        MapAlignmentAccess.resolve(sessionPhase = phase, isSystemAdmin = isSystemAdmin)

    @Test
    fun `system admin may access the preview`() {
        assertTrue(access(SessionPhase.AuthenticatedOnline, isSystemAdmin = true).isAllowed)
    }

    @Test
    fun `system admin keeps access while working offline`() {
        // A confirmed platform admin must not lose tooling on a shed reconnection.
        assertTrue(access(SessionPhase.AuthenticatedOffline, isSystemAdmin = true).isAllowed)
    }

    @Test
    fun `authenticated non admin is denied`() {
        val result = access(SessionPhase.AuthenticatedOnline, isSystemAdmin = false)
        assertFalse(result.isAllowed)
        assertEquals(
            MapAlignmentAccess.Unavailable(MapAlignmentAccess.Reason.NotSystemAdmin),
            result,
        )
    }

    @Test
    fun `vineyard roles never grant access on their own`() {
        // Owner, manager and supervisor are VINEYARD memberships, not platform
        // authority. None of them is System Admin, so none may reach this feature.
        // The gate takes no role parameter at all — this asserts that the only
        // input that can ever flip the decision is the authoritative admin flag.
        listOf(SessionPhase.AuthenticatedOnline, SessionPhase.AuthenticatedOffline).forEach { phase ->
            assertFalse(
                "no vineyard role may open the preview",
                access(phase, isSystemAdmin = false).isAllowed,
            )
        }
    }

    @Test
    fun `unauthenticated users cannot access it`() {
        val result = access(SessionPhase.SignedOut, isSystemAdmin = false)
        assertFalse(result.isAllowed)
        assertEquals(
            MapAlignmentAccess.Unavailable(MapAlignmentAccess.Reason.NotAuthenticated),
            result,
        )
    }

    @Test
    fun `a stale admin flag cannot survive sign out`() {
        // Defence in depth: even if a true flag lingered from a previous user,
        // a signed-out session must still be refused.
        val result = access(SessionPhase.SignedOut, isSystemAdmin = true)
        assertFalse(result.isAllowed)
        assertEquals(
            MapAlignmentAccess.Unavailable(MapAlignmentAccess.Reason.NotAuthenticated),
            result,
        )
    }

    @Test
    fun `access is denied while the session is still restoring`() {
        // Fail closed: nothing is known about the user yet.
        val result = access(SessionPhase.Restoring, isSystemAdmin = false)
        assertFalse(result.isAllowed)
        assertEquals(
            MapAlignmentAccess.Unavailable(MapAlignmentAccess.Reason.SessionRestoring),
            result,
        )
        assertFalse(access(SessionPhase.Restoring, isSystemAdmin = true).isAllowed)
    }

    @Test
    fun `only a confirmed system admin session is ever allowed`() {
        // Every non-admin combination stays denied for visibility AND navigation.
        listOf(
            access(SessionPhase.AuthenticatedOnline, isSystemAdmin = false),
            access(SessionPhase.AuthenticatedOffline, isSystemAdmin = false),
            access(SessionPhase.SignedOut, isSystemAdmin = false),
            access(SessionPhase.SignedOut, isSystemAdmin = true),
            access(SessionPhase.Restoring, isSystemAdmin = true),
            access(SessionPhase.Restoring, isSystemAdmin = false),
        ).forEach { denied ->
            assertFalse("must be refused: $denied", denied.isAllowed)
        }
        assertTrue(access(SessionPhase.AuthenticatedOnline, isSystemAdmin = true).isAllowed)
    }
}

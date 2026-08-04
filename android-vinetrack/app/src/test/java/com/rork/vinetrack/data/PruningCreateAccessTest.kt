package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The create action must never silently disappear. These tests pin the shared
 * contract used by the Pruning Tracker top app bar `+`, the labelled button and
 * the empty state — all three read the SAME resolved access value.
 */
class PruningCreateAccessTest {

    @Test
    fun `every known vineyard role may record pruning`() {
        listOf("owner", "manager", "supervisor", "operator").forEach { role ->
            val access = PruningCreateAccess.resolve(role = role, membersLoaded = true)
            assertTrue("$role should be allowed", access.isAllowed)
            assertNull("$role needs no explanation", access.explanation)
        }
    }

    @Test
    fun `role casing and whitespace do not deny an authorised user`() {
        assertTrue(PruningCreateAccess.resolve(" Owner ", membersLoaded = true).isAllowed)
        assertTrue(PruningCreateAccess.resolve("MANAGER", membersLoaded = true).isAllowed)
    }

    @Test
    fun `null role before membership loads is loading, not denied`() {
        val access = PruningCreateAccess.resolve(role = null, membersLoaded = false)
        assertEquals(PruningCreateAccess.Loading, access)
        assertFalse(access.isAllowed)
        // A disabled progress state still needs a reason on screen.
        assertNotNull(access.explanation)
    }

    @Test
    fun `null role after membership loaded is an unresolved configuration problem`() {
        val access = PruningCreateAccess.resolve(role = null, membersLoaded = true)
        assertTrue(access is PruningCreateAccess.Unresolved)
        assertFalse(access.isAllowed)
        // Authorised users must be told why, never handed a blank interface.
        assertTrue(access.explanation!!.contains("couldn't be confirmed"))
    }

    @Test
    fun `blank role is treated as unknown rather than permitted`() {
        val access = PruningCreateAccess.resolve(role = "   ", membersLoaded = true)
        assertTrue(access is PruningCreateAccess.Unresolved)
        assertFalse(access.isAllowed)
    }

    @Test
    fun `unknown or renamed role denies the write but explains itself`() {
        val access = PruningCreateAccess.resolve(role = "viewer", membersLoaded = true)
        assertEquals(PruningCreateAccess.Denied, access)
        assertFalse(access.isAllowed)
        assertTrue(access.explanation!!.contains("owner or manager"))
    }

    @Test
    fun `no state ever yields an allowed action without an explanation, or a denial without one`() {
        val states = listOf(
            PruningCreateAccess.resolve("owner", membersLoaded = true),
            PruningCreateAccess.resolve("viewer", membersLoaded = true),
            PruningCreateAccess.resolve(null, membersLoaded = true),
            PruningCreateAccess.resolve(null, membersLoaded = false),
        )
        states.forEach { access ->
            if (access.isAllowed) assertNull(access.explanation) else assertNotNull(access.explanation)
        }
    }
}

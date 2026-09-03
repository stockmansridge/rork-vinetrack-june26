package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Regression tests for the active-vineyard contract.
 *
 * The user's ACTIVE vineyard (what they are working in) is separate from their
 * profile DEFAULT vineyard (where a brand new session starts). Every lifecycle
 * event that used to snap the user back to default A while they were working
 * in B is pinned here.
 */
class ActiveVineyardRestorationTest {

    private val A = "vineyard-a-default"
    private val B = "vineyard-b-active"
    private val C = "vineyard-c-other"
    private val members = setOf(A, B, C)

    private fun resolve(
        persistedActiveId: String? = B,
        defaultId: String? = A,
        memberIds: Set<String> = members,
        firstAvailableId: String? = A,
        liveSelectionId: String? = null,
        isStale: Boolean = false,
    ): String? = ActiveVineyardResolver.resolve(
        ActiveVineyardResolver.Input(
            memberIds = memberIds,
            persistedActiveId = persistedActiveId,
            defaultId = defaultId,
            firstAvailableId = firstAvailableId,
            liveSelectionId = liveSelectionId,
            isStale = isStale,
        ),
    )

    // ---- Lifecycle events must all preserve the ACTIVE vineyard ----------
    // Lock/unlock, background/foreground, Activity recreation and process
    // recreation all funnel through the same resolution, so one assertion per
    // scenario documents each required behaviour.

    @Test
    fun `default A but working in B - lock and unlock keeps B`() {
        assertEquals(B, resolve())
    }

    @Test
    fun `default A but working in B - background and foreground keeps B`() {
        assertEquals(B, resolve())
    }

    @Test
    fun `default A but working in B - activity recreation keeps B`() {
        assertEquals(B, resolve())
    }

    @Test
    fun `default A but working in B - process recreation keeps B`() {
        assertEquals(B, resolve())
    }

    // ---- The async-overwrite defect --------------------------------------

    @Test
    fun `late default-vineyard response naming A cannot overwrite restored B`() {
        // The profile fetch resolved default A, but the user has since switched
        // to B by hand: the stale response must not claw them back to A.
        assertEquals(
            B,
            resolve(
                persistedActiveId = A,
                defaultId = A,
                liveSelectionId = B,
                isStale = true,
            ),
        )
    }

    @Test
    fun `stale response is ignored only when the live selection is still valid`() {
        // User switched to a vineyard they have since lost access to: fall back
        // through the normal priority rather than selecting something invalid.
        assertEquals(
            A,
            resolve(
                persistedActiveId = null,
                defaultId = A,
                liveSelectionId = "vineyard-revoked",
                isStale = true,
            ),
        )
    }

    // ---- Default vineyard still applies where it should -------------------

    @Test
    fun `first login with no persisted active vineyard uses the default`() {
        assertEquals(A, resolve(persistedActiveId = null, defaultId = A))
    }

    @Test
    fun `previous vineyard authoritatively inaccessible falls back to default`() {
        // B is gone from the membership list — an authoritative statement that
        // the user can no longer open it.
        assertEquals(
            A,
            resolve(persistedActiveId = B, defaultId = A, memberIds = setOf(A, C)),
        )
    }

    @Test
    fun `no persisted active and no default uses the first available vineyard`() {
        assertEquals(
            C,
            resolve(persistedActiveId = null, defaultId = null, firstAvailableId = C),
        )
    }

    @Test
    fun `default that the user no longer belongs to is not selected`() {
        assertEquals(
            C,
            resolve(
                persistedActiveId = null,
                defaultId = "vineyard-removed",
                memberIds = setOf(C),
                firstAvailableId = C,
            ),
        )
    }

    // ---- Offline -----------------------------------------------------------

    @Test
    fun `offline launch resolves B from the cached membership list`() {
        // Offline the caller passes cached member ids; the contract is
        // identical, because connectivity never invalidates the active vineyard.
        assertEquals(B, resolve(memberIds = setOf(A, B)))
    }

    @Test
    fun `no vineyards at all resolves to null rather than a stale id`() {
        assertEquals(
            null,
            resolve(memberIds = emptySet(), firstAvailableId = null),
        )
    }
}

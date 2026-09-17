package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.OperationalToolLayout
import com.rork.vinetrack.data.OperationalToolLayoutResolver
import com.rork.vinetrack.ui.main.OperationalToolCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Vineyard Insights is an unreleased System Admin preview. These tests pin the
 * single access decision every layer consults, so no screen, tile or saved
 * layout can drift from it.
 *
 * The rule under test is a conjunction — platform System Admin AND membership
 * of the selected vineyard — and most of these cases exist to prove that
 * satisfying only one half is not enough.
 */
class VineyardInsightsAccessTest {

    private fun access(
        phase: SessionPhase = SessionPhase.AuthenticatedOnline,
        isSystemAdmin: Boolean = true,
        vineyardId: String? = "vineyard-1",
        isMember: Boolean = true,
    ) = VineyardInsightsAccess.resolve(
        sessionPhase = phase,
        isSystemAdmin = isSystemAdmin,
        selectedVineyardId = vineyardId,
        isMemberOfSelectedVineyard = isMember,
    )

    // --- The two halves of the rule -------------------------------------

    @Test
    fun `system admin who is a member of the selected vineyard may use the preview`() {
        assertTrue(access().isAllowed)
    }

    @Test
    fun `system admin keeps access while working offline`() {
        // Scouting happens where there is no signal. A confirmed platform admin
        // must not lose the tool on a shed reconnection.
        assertTrue(access(phase = SessionPhase.AuthenticatedOffline).isAllowed)
    }

    @Test
    fun `a vineyard owner who is not system admin is denied`() {
        // Owner is a CUSTOMER-level role over their own vineyard. It confers no
        // platform authority, and this is the case that would leak an
        // unreleased preview to every customer if the two were ever conflated.
        val result = access(isSystemAdmin = false)

        assertFalse(result.isAllowed)
        assertEquals(
            VineyardInsightsAccess.Unavailable(VineyardInsightsAccess.Reason.NotSystemAdmin),
            result,
        )
    }

    @Test
    fun `a manager who is not system admin is denied`() {
        assertFalse(access(isSystemAdmin = false, isMember = true).isAllowed)
    }

    @Test
    fun `system admin without membership of the selected vineyard is denied`() {
        // Platform authority is not a skeleton key into a grower's business.
        val result = access(isMember = false)

        assertFalse(result.isAllowed)
        assertEquals(
            VineyardInsightsAccess.Unavailable(VineyardInsightsAccess.Reason.NotVineyardMember),
            result,
        )
    }

    @Test
    fun `system admin with no vineyard selected is denied`() {
        assertFalse(access(vineyardId = null).isAllowed)
        assertFalse(access(vineyardId = "").isAllowed)
    }

    // --- Fail-closed ------------------------------------------------------

    @Test
    fun `a restoring session is denied rather than optimistically allowed`() {
        // This is what stops the tile flashing into view during launch. A flash
        // is not untidy, it discloses that the feature exists.
        val result = access(phase = SessionPhase.Restoring)

        assertFalse(result.isAllowed)
        assertEquals(
            VineyardInsightsAccess.Unavailable(VineyardInsightsAccess.Reason.SessionRestoring),
            result,
        )
    }

    @Test
    fun `signing out removes access immediately`() {
        val result = access(phase = SessionPhase.SignedOut)

        assertFalse(result.isAllowed)
        assertEquals(
            VineyardInsightsAccess.Unavailable(VineyardInsightsAccess.Reason.NotAuthenticated),
            result,
        )
    }

    @Test
    fun `losing system admin status removes access`() {
        assertTrue(access(isSystemAdmin = true).isAllowed)
        assertFalse(access(isSystemAdmin = false).isAllowed)
    }

    @Test
    fun `a signed out session is denied even for a system admin flag left set`() {
        // Order matters: authentication is checked before the admin flag, so a
        // stale cached true cannot outlive the session that earned it.
        assertFalse(access(phase = SessionPhase.SignedOut, isSystemAdmin = true).isAllowed)
    }

    // --- Catalogue integration -------------------------------------------

    @Test
    fun `existing eligible installation renders the newly authorised tile`() {
        val decision = access()
        val authorised = OperationalToolCatalog.authorisedIds(
            canViewCosting = true,
            canUseVineyardInsights = decision.isAllowed,
        )
        val preInsightsLayout = OperationalToolLayout(
            visibleToolIds = OperationalToolCatalog.defaultOrder.filterNot {
                it == VineyardInsightsCatalog.TOOL_ID
            },
            isReady = true,
        )

        val rendered = OperationalToolLayoutResolver.visibleToolIds(preInsightsLayout, authorised)

        assertTrue(VineyardInsightsCatalog.TOOL_ID in rendered)
        assertEquals(VineyardInsightsCatalog.TOOL_ID, rendered.last())
    }

    @Test
    fun `owner without system admin and admin without membership never render the tile`() {
        listOf(
            access(isSystemAdmin = false, isMember = true),
            access(isSystemAdmin = true, isMember = false),
        ).forEach { decision ->
            val authorised = OperationalToolCatalog.authorisedIds(
                canViewCosting = true,
                canUseVineyardInsights = decision.isAllowed,
            )
            assertFalse(VineyardInsightsCatalog.TOOL_ID in authorised)
        }
    }

    @Test
    fun `the tool is absent from the authorised catalogue for a non admin`() {
        val ids = OperationalToolCatalog.authorisedIds(
            canViewCosting = true,
            canUseVineyardInsights = false,
        )

        assertFalse(ids.contains(VineyardInsightsCatalog.TOOL_ID))
    }

    @Test
    fun `the tool appears in the authorised catalogue only when access is allowed`() {
        val ids = OperationalToolCatalog.authorisedIds(
            canViewCosting = false,
            canUseVineyardInsights = true,
        )

        assertTrue(ids.contains(VineyardInsightsCatalog.TOOL_ID))
    }

    @Test
    fun `authorisation defaults to closed when the caller has not resolved access`() {
        // An older call site, or one that has not yet resolved the decision,
        // must not expose the preview by omission.
        val ids = OperationalToolCatalog.authorisedIds(canViewCosting = true)

        assertFalse(ids.contains(VineyardInsightsCatalog.TOOL_ID))
    }

    @Test
    fun `a saved layout cannot reveal the tool to a non admin`() {
        // Customisation is applied ON TOP of the authorised catalogue. A
        // preference row naming the preview is simply an unknown id to a
        // caller who is not entitled to it.
        val authorised = OperationalToolCatalog.authorisedIds(
            canViewCosting = true,
            canUseVineyardInsights = false,
        )
        val savedLayout = listOf(VineyardInsightsCatalog.TOOL_ID, "work_tasks")

        val rendered = savedLayout.filter { it in authorised }

        assertEquals(listOf("work_tasks"), rendered)
    }

    @Test
    fun `the costing permission cannot substitute for system admin`() {
        // The two requirements are independent. Costing is a vineyard role
        // permission; this is platform authority.
        val costingOnly = OperationalToolCatalog.authorised(
            canViewCosting = true,
            canUseVineyardInsights = false,
        )

        assertTrue(costingOnly.any { it.id == "cost_reports" })
        assertFalse(costingOnly.any { it.requiresSystemAdmin })
    }

    @Test
    fun `the preview tool declares the exact required display strings`() {
        val tool = OperationalToolCatalog.tool(VineyardInsightsCatalog.TOOL_ID)

        requireNotNull(tool)
        assertEquals("Vineyard Insights", tool.title)
        assertEquals("Scouting, vintage notes & reports", tool.subtitle)
        assertTrue(tool.requiresSystemAdmin)
        assertEquals("System Admin Preview", VineyardInsightsCatalog.PREVIEW_BADGE)
    }

    @Test
    fun `the preview is the last tool in the default order`() {
        // Matches SQL 236's display_order 140 — the next slot after
        // resistance_planner. A mismatch would give the two platforms and the
        // database three different default layouts.
        assertEquals(
            VineyardInsightsCatalog.TOOL_ID,
            OperationalToolCatalog.defaultOrder.last(),
        )
    }
}

package com.rork.vinetrack.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2F.2 — role-aware restricted-vineyard messaging (Android side of the
 * shared contract; iOS asserts the identical rules in
 * `RestrictedVineyardMessagingTests.swift`).
 *
 * Every case decodes a REAL `get_my_vineyard_access_matrix()` row (sql/157 +
 * sql/158) so the tests also protect the wire contract the copy depends on:
 * `vineyard_access_reason`, `membership_role`, `can_manage_billing` and the
 * new `is_billing_authority`.
 */
class RestrictedVineyardMessagingTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun entry(
        role: String,
        reason: String = RestrictedVineyardMessage.SOLO_FUNDING_REASON_CODE,
        hasAccess: Boolean = false,
        billingAuthority: Boolean? = null,
        includeBillingAuthorityKey: Boolean = true,
    ): VineyardAccessEntry {
        val authority = billingAuthority ?: (role == "owner")
        val authorityKey =
            if (includeBillingAuthorityKey) ",\"is_billing_authority\": $authority" else ""
        val payload = """
            {
              "vineyard_id": "3f1a1f2e-0000-4000-8000-00000000000a",
              "vineyard_name": "Stockmans Ridge",
              "membership_role": "$role",
              "membership_status": "active",
              "has_vineyard_access": $hasAccess,
              "vineyard_access_reason": "$reason",
              "vineyard_access_source": "none",
              "is_billing_owner": false,
              "can_manage_billing": ${role == "owner"},
              "requires_billing_attention": ${role == "owner"}
              $authorityKey
            }
        """.trimIndent()
        return json.decodeFromString(payload)
    }

    private fun message(
        role: String,
        reason: String = RestrictedVineyardMessage.SOLO_FUNDING_REASON_CODE,
        billingAuthority: Boolean? = null,
        includeBillingAuthorityKey: Boolean = true,
        hasAccess: Boolean = false,
        isMatrixResolved: Boolean = true,
    ): RestrictedVineyardMessage = RestrictedVineyardMessage.make(
        vineyardName = "Stockmans Ridge",
        entry = entry(role, reason, hasAccess, billingAuthority, includeBillingAuthorityKey),
        isMatrixResolved = isMatrixResolved,
    )

    // ---- Owner with billing authority ------------------------------------

    @Test
    fun `owner sees solo to team upgrade`() {
        val result = message(role = "owner", billingAuthority = true)
        assertEquals(RestrictedVineyardAudience.BILLING_OWNER, result.audience)
        assertTrue(result.showsUpgradeToTeam)
        assertFalse(result.showsReviewBilling)
        assertTrue(result.title.contains("Team plan"))
        assertTrue(result.body.contains("covers your own account only"))
        assertTrue(result.body.contains("Upgrade to a Team plan"))
    }

    @Test
    fun `owner with expired plan keeps review billing not upgrade`() {
        val result = message(
            role = "owner",
            reason = "no_vineyard_entitlement",
            billingAuthority = true,
        )
        assertEquals(RestrictedVineyardAudience.BILLING_OWNER, result.audience)
        assertFalse(result.showsUpgradeToTeam)
        assertTrue(result.showsReviewBilling)
        assertTrue(result.title.contains("has expired"))
    }

    // ---- Co-Owner without billing authority ------------------------------

    @Test
    fun `co-owner sees managed by another owner without purchase`() {
        val result = message(role = "owner", billingAuthority = false)
        assertEquals(RestrictedVineyardAudience.CO_OWNER, result.audience)
        assertFalse(result.showsUpgradeToTeam)
        assertFalse(result.showsReviewBilling)
        assertFalse(result.offersBillingAction)
        assertTrue(result.body.contains("managed by another Owner"))
    }

    @Test
    fun `co-owner message never names the billing owner`() {
        val result = message(role = "owner", billingAuthority = false)
        assertFalse(result.body.contains("@"))
        assertFalse(result.body.lowercase().contains("subscription id"))
        assertNull(result.footnote)
    }

    @Test
    fun `co-owner with expired plan also has no purchase action`() {
        val result = message(
            role = "owner",
            reason = "no_vineyard_entitlement",
            billingAuthority = false,
        )
        assertEquals(RestrictedVineyardAudience.CO_OWNER, result.audience)
        assertFalse(result.offersBillingAction)
    }

    // ---- Manager / Supervisor / Operator ---------------------------------

    @Test
    fun `manager sees owner managed message without purchase`() {
        val result = message(role = "manager")
        assertEquals(RestrictedVineyardAudience.TEAM_MEMBER, result.audience)
        assertFalse(result.offersBillingAction)
        assertTrue(result.body.contains("managed by its Vineyard Owner"))
        assertTrue(result.body.contains("pending invitations remain available"))
    }

    @Test
    fun `supervisor sees owner managed message without purchase`() {
        val result = message(role = "supervisor")
        assertEquals(RestrictedVineyardAudience.TEAM_MEMBER, result.audience)
        assertFalse(result.showsUpgradeToTeam)
        assertFalse(result.showsReviewBilling)
    }

    @Test
    fun `operator sees owner managed message without purchase`() {
        val result = message(role = "operator")
        assertEquals(RestrictedVineyardAudience.TEAM_MEMBER, result.audience)
        assertFalse(result.offersBillingAction)
        assertTrue(result.body.contains("Ask the Vineyard Owner to upgrade"))
    }

    @Test
    fun `team member with expired plan keeps owner managed copy`() {
        val result = message(role = "operator", reason = "no_vineyard_entitlement")
        assertEquals(RestrictedVineyardAudience.TEAM_MEMBER, result.audience)
        assertFalse(result.offersBillingAction)
        assertTrue(result.title.contains("has expired"))
    }

    // ---- Server-confirmed gate -------------------------------------------

    @Test
    fun `unresolved matrix never shows upgrade state`() {
        val result = message(role = "owner", billingAuthority = true, isMatrixResolved = false)
        assertEquals(RestrictedVineyardAudience.UNRESOLVED, result.audience)
        assertFalse(result.offersBillingAction)
        assertEquals("Checking your VineTrack access…", result.title)
    }

    @Test
    fun `missing entry never shows upgrade state`() {
        val result = RestrictedVineyardMessage.make(
            vineyardName = "Stockmans Ridge",
            entry = null,
            isMatrixResolved = true,
        )
        assertEquals(RestrictedVineyardAudience.UNRESOLVED, result.audience)
        assertFalse(result.offersBillingAction)
    }

    @Test
    fun `still accessible vineyard never shows upgrade state`() {
        val result = message(role = "owner", billingAuthority = true, hasAccess = true)
        assertEquals(RestrictedVineyardAudience.UNRESOLVED, result.audience)
        assertFalse(result.offersBillingAction)
    }

    // ---- Backend compatibility -------------------------------------------

    @Test
    fun `pre sql158 backend keeps owner upgrade action`() {
        val owner = message(role = "owner", includeBillingAuthorityKey = false)
        assertEquals(RestrictedVineyardAudience.BILLING_OWNER, owner.audience)
        assertTrue(owner.showsUpgradeToTeam)

        val manager = message(role = "manager", includeBillingAuthorityKey = false)
        assertEquals(RestrictedVineyardAudience.TEAM_MEMBER, manager.audience)
        assertFalse(manager.offersBillingAction)
    }

    @Test
    fun `billing authority field decodes from matrix row`() {
        assertEquals(false, entry(role = "owner", billingAuthority = false).isBillingAuthority)
        assertEquals(true, entry(role = "owner", billingAuthority = true).isBillingAuthority)
        assertNull(entry(role = "owner", includeBillingAuthorityKey = false).isBillingAuthority)
    }

    // ---- Cross-platform wording parity ------------------------------------

    @Test
    fun `action titles match the shared contract`() {
        assertEquals("Upgrade to Team", RestrictedVineyardMessage.UPGRADE_ACTION_TITLE)
        assertEquals("Review billing", RestrictedVineyardMessage.REVIEW_BILLING_ACTION_TITLE)
        assertEquals(
            "owner_plan_not_vineyard_funding",
            RestrictedVineyardMessage.SOLO_FUNDING_REASON_CODE,
        )
    }
}

package com.rork.vinetrack.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2A compatibility tests: the Android DTO must parse BOTH the legacy
 * sql/096 resolver response and the extended sql/132 response, and the
 * access decision (`grantsAppAccess`) must be identical for equivalent rows.
 * Mirrors the SupabaseClient JSON configuration (ignoreUnknownKeys = true).
 */
class VineTrackAccessRowCompatTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `legacy sql096 response still parses and grants`() {
        val legacy = """
            {
              "user_id": "00000000-0000-4000-8000-000000000001",
              "has_supabase_access": true,
              "access_source": "internal",
              "is_owner": true,
              "plan_code": "internal_unlimited",
              "plan_tier": "internal",
              "billing_provider": "manual",
              "status": "manual",
              "portal_access": true,
              "portal_access_level": "full",
              "can_use_ios_app": true,
              "can_use_portal": true,
              "unlimited_licences": true,
              "solo_check_required": false
            }
        """.trimIndent()

        val row = json.decodeFromString<VineTrackAccessRow>(legacy)
        assertTrue(row.grantsSupabaseAccess)
        assertTrue(row.grantsAppAccess)
        assertFalse(row.requiresSoloCheck)
        // New SQL 132 fields absent → null, never a parse failure.
        assertNull(row.reasonCode)
        assertNull(row.canUseAndroidApp)
        assertNull(row.enforcementEnabled)
        assertEquals("supabase:internal", row.verificationStatusLabel)
    }

    @Test
    fun `sql132 response parses with appended fields`() {
        val extended = """
            {
              "user_id": "00000000-0000-4000-8000-000000000001",
              "has_supabase_access": true,
              "access_source": "internal",
              "is_owner": true,
              "plan_code": "internal_unlimited",
              "plan_tier": "internal",
              "billing_provider": "manual",
              "status": "manual",
              "portal_access": true,
              "portal_access_level": "full",
              "can_use_ios_app": true,
              "can_use_portal": true,
              "unlimited_licences": true,
              "solo_check_required": false,
              "reason_code": "internal_unlimited",
              "is_unlimited": true,
              "can_use_android_app": true,
              "last_verified_at": "2026-07-28T05:00:00.123456+00:00",
              "enforcement_enabled": true,
              "some_future_column": "ignored"
            }
        """.trimIndent()

        val row = json.decodeFromString<VineTrackAccessRow>(extended)
        assertTrue(row.grantsAppAccess)
        assertEquals("internal_unlimited", row.reasonCode)
        assertEquals(true, row.isUnlimited)
        assertEquals(true, row.enforcementEnabled)
        assertEquals("supabase:internal:internal_unlimited", row.verificationStatusLabel)
    }

    @Test
    fun `sql132 denial parses with reason code`() {
        val denied = """
            {
              "user_id": "00000000-0000-4000-8000-000000000001",
              "has_supabase_access": false,
              "access_source": "none",
              "can_use_ios_app": false,
              "can_use_android_app": false,
              "solo_check_required": true,
              "reason_code": "expired",
              "enforcement_enabled": false
            }
        """.trimIndent()

        val row = json.decodeFromString<VineTrackAccessRow>(denied)
        assertFalse(row.grantsSupabaseAccess)
        assertFalse(row.grantsAppAccess)
        assertTrue(row.requiresSoloCheck)
        assertEquals("expired", row.reasonCode)
    }

    @Test
    fun `sql135 store subscription response parses with appended fields`() {
        // Phase 2B: a verified APPLE purchase must grant Android access —
        // purchase_platform records where the purchase happened, not where
        // VineTrack may be used.
        val store = """
            {
              "user_id": "00000000-0000-4000-8000-000000000001",
              "has_supabase_access": true,
              "access_source": "solo",
              "plan_code": "solo",
              "billing_provider": "apple",
              "status": "active",
              "current_period_end": "2026-08-28T00:00:00+00:00",
              "can_use_ios_app": true,
              "can_use_android_app": true,
              "can_use_portal": true,
              "solo_check_required": false,
              "reason_code": "app_store_subscription",
              "purchase_platform": "ios",
              "cancel_at_period_end": false,
              "grace_period_end": null
            }
        """.trimIndent()

        val row = json.decodeFromString<VineTrackAccessRow>(store)
        assertTrue(row.grantsSupabaseAccess)
        assertTrue(row.grantsAppAccess)
        assertFalse(row.requiresSoloCheck)
        assertEquals("app_store_subscription", row.reasonCode)
        assertEquals("ios", row.purchasePlatform)
        assertEquals(false, row.cancelAtPeriodEnd)
        assertNull(row.gracePeriodEnd)
    }

    @Test
    fun `sql135 fields absent in old responses never break parsing`() {
        val old = """
            {"has_supabase_access": true, "can_use_ios_app": true, "reason_code": "portal_subscription"}
        """.trimIndent()
        val row = json.decodeFromString<VineTrackAccessRow>(old)
        assertTrue(row.grantsAppAccess)
        assertNull(row.purchasePlatform)
        assertNull(row.cancelAtPeriodEnd)
        assertNull(row.gracePeriodEnd)
    }

    // ------------------------------------------------------------------
    // SQL 144 — server-authoritative account trial (Phase 2C.1)
    // ------------------------------------------------------------------

    @Test
    fun `sql144 active server trial grants access`() {
        val trial = """
            {
              "user_id": "00000000-0000-4000-8000-000000000001",
              "has_supabase_access": true,
              "access_source": "trial",
              "plan_code": "trial",
              "plan_tier": "trial",
              "billing_provider": "trial",
              "status": "trialling",
              "trial_end": "2026-10-28T00:00:00+00:00",
              "portal_access": true,
              "can_use_ios_app": true,
              "can_use_android_app": true,
              "can_use_portal": true,
              "solo_check_required": false,
              "reason_code": "active_trial",
              "purchase_platform": null,
              "expires_at": "2026-10-28T00:00:00+00:00"
            }
        """.trimIndent()

        val row = json.decodeFromString<VineTrackAccessRow>(trial)
        assertTrue(row.grantsSupabaseAccess)
        assertTrue(row.grantsAppAccess)
        assertFalse(row.requiresSoloCheck)
        assertEquals("active_trial", row.reasonCode)
        // purchase_platform is NULL for the trial — never the text "none".
        assertNull(row.purchasePlatform)
        // The cache cap resolves to the trial end.
        val nowMs = 1_753_660_800_000L // 2025-ish, well before the trial end
        val cap = row.knownExpiresAtMs(nowMs)
        assertEquals(1_792_540_800_000L, cap) // 2026-10-28T00:00:00Z
    }

    @Test
    fun `sql144 expired server trial denies with original end`() {
        val expired = """
            {
              "has_supabase_access": false,
              "access_source": "trial",
              "plan_code": "trial",
              "status": "expired",
              "trial_end": "2025-01-01T00:00:00+00:00",
              "solo_check_required": true,
              "reason_code": "expired",
              "purchase_platform": null,
              "expires_at": "2025-01-01T00:00:00+00:00"
            }
        """.trimIndent()

        val row = json.decodeFromString<VineTrackAccessRow>(expired)
        assertFalse(row.grantsSupabaseAccess)
        assertFalse(row.grantsAppAccess)
        assertTrue(row.requiresSoloCheck)
        assertEquals("expired", row.reasonCode)
        // A past expiry never yields a future cache cap.
        assertNull(row.knownExpiresAtMs(1_790_000_000_000L))
    }

    @Test
    fun `sql144 expires_at absent in old responses never breaks parsing`() {
        val old = """
            {"has_supabase_access": true, "can_use_ios_app": true, "reason_code": "portal_subscription"}
        """.trimIndent()
        val row = json.decodeFromString<VineTrackAccessRow>(old)
        assertTrue(row.grantsAppAccess)
        assertNull(row.expiresAt)
        assertNull(row.knownExpiresAtMs(0L))
    }

    @Test
    fun `knownExpiresAtMs picks the earliest future expiry`() {
        val row = json.decodeFromString<VineTrackAccessRow>(
            """
            {
              "has_supabase_access": true,
              "trial_end": "2026-09-01T00:00:00+00:00",
              "current_period_end": "2026-08-01T00:00:00+00:00"
            }
            """.trimIndent(),
        )
        // Both future: the earlier one caps the cache.
        val nowMs = 1_753_660_800_000L
        assertEquals(1_784_937_600_000L, row.knownExpiresAtMs(nowMs)) // 2026-08-01
    }

    @Test
    fun `old snapshot without known expiry still decodes`() {
        val legacySnapshot = """
            {"user_id":"abc","last_verified_at_ms":1753660800000,"was_entitled":true,"product_status":"active:x"}
        """.trimIndent()
        val snap = json.decodeFromString<com.rork.vinetrack.data.subscription.EntitlementVerificationSnapshot>(legacySnapshot)
        assertTrue(snap.wasEntitled)
        assertNull(snap.knownExpiresAtMs)
    }

    @Test
    fun `can_use_android_app is preferred over can_use_ios_app`() {
        // Hypothetical platform-split response: Android flag wins.
        val split = """
            {"has_supabase_access": true, "can_use_ios_app": true, "can_use_android_app": false}
        """.trimIndent()
        val row = json.decodeFromString<VineTrackAccessRow>(split)
        assertFalse(row.grantsAppAccess)

        val legacyOnly = """
            {"has_supabase_access": true, "can_use_ios_app": true}
        """.trimIndent()
        assertTrue(json.decodeFromString<VineTrackAccessRow>(legacyOnly).grantsAppAccess)
    }
}

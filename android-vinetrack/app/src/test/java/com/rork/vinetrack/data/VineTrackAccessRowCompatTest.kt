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

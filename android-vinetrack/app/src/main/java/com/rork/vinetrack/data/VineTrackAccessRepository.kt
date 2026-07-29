package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Decoded row from the Supabase RPC `get_my_vinetrack_access()` (sql/096,
 * hardened + extended in sql/132) — Android port of the iOS
 * `BackendVineTrackAccess` model. Every field is optional and unknown keys
 * are ignored so schema evolution never breaks the client. The RPC is
 * SECURITY DEFINER and only reports the caller's own access.
 */
@Serializable
data class VineTrackAccessRow(
    @SerialName("has_supabase_access") val hasSupabaseAccess: Boolean? = null,
    @SerialName("has_access") val hasAccess: Boolean? = null,
    /** 'enterprise' | 'internal' | 'team' | 'legacy' | 'solo' | 'none'. */
    @SerialName("access_source") val accessSource: String? = null,
    @SerialName("solo_check_required") val soloCheckRequired: Boolean? = null,
    @SerialName("plan_code") val planCode: String? = null,
    @SerialName("plan_tier") val planTier: String? = null,
    @SerialName("plan_name") val planName: String? = null,
    /** 'apple' | 'stripe' | 'manual'. */
    @SerialName("billing_provider") val billingProvider: String? = null,
    /** 'trialing' | 'active' | 'manual' | 'past_due' | … */
    @SerialName("status") val status: String? = null,
    @SerialName("trial_end") val trialEnd: String? = null,
    @SerialName("current_period_end") val currentPeriodEnd: String? = null,
    @SerialName("portal_access") val portalAccess: Boolean? = null,
    @SerialName("portal_access_level") val portalAccessLevel: String? = null,
    @SerialName("can_use_ios_app") val canUseIosApp: Boolean? = null,
    @SerialName("can_use_portal") val canUsePortal: Boolean? = null,
    @SerialName("is_owner") val isOwner: Boolean? = null,
    @SerialName("unlimited_licences") val unlimitedLicences: Boolean? = null,
    @SerialName("manual_grant_reason") val manualGrantReason: String? = null,
    @SerialName("vineyard_id") val vineyardId: String? = null,
    @SerialName("licence_id") val licenceId: String? = null,
    // SQL 132 additive fields — all optional so this DTO parses both the
    // old (sql/096) and new (sql/132) response shapes.
    /**
     * Stable machine reason: 'internal_unlimited' | 'enterprise_subscription' |
     * 'portal_subscription' | 'assigned_licence' | 'app_store_subscription' |
     * 'active_trial' | 'expired' | 'revoked' | 'no_entitlement'.
     */
    @SerialName("reason_code") val reasonCode: String? = null,
    @SerialName("is_unlimited") val isUnlimited: Boolean? = null,
    @SerialName("can_use_android_app") val canUseAndroidApp: Boolean? = null,
    @SerialName("last_verified_at") val lastVerifiedAt: String? = null,
    /** Whether the shared-entitlement rollout flag covers this caller (iOS-only today). */
    @SerialName("enforcement_enabled") val enforcementEnabled: Boolean? = null,
    @SerialName("manual_grant_expires_at") val manualGrantExpiresAt: String? = null,
    // SQL 135 additive fields (Phase 2B — verified store subscriptions).
    // All optional with defaults so old resolver responses keep parsing.
    /** Where the purchase happened ('ios' | 'android' | 'web') — NOT where VineTrack works. */
    @SerialName("purchase_platform") val purchasePlatform: String? = null,
    /** Auto-renew turned off; access continues until the paid period end. */
    @SerialName("cancel_at_period_end") val cancelAtPeriodEnd: Boolean? = null,
    /** Provider-supplied billing-issue grace end — access holds until then. */
    @SerialName("grace_period_end") val gracePeriodEnd: String? = null,
    // SQL 144 additive fields (Phase 2C.1 — server-authoritative account trial).
    /**
     * Earliest KNOWN future expiry of the granted source (trial end, period
     * end + grace, manual grant expiry). Null for open-ended grants. On a
     * trial-expired denial this carries the ORIGINAL trial end.
     */
    @SerialName("expires_at") val expiresAt: String? = null,
) {
    /** Effective "Supabase grants access" flag, tolerant of either key (iOS parity). */
    val grantsSupabaseAccess: Boolean get() = hasSupabaseAccess ?: hasAccess ?: false

    /**
     * Whether the mobile app should be unlocked via the backend. Prefers the
     * SQL 132 `can_use_android_app` flag; falls back to the platform-agnostic
     * `can_use_ios_app` ("can use the mobile app") and finally to the general
     * access flag, so both old and new resolver responses keep working.
     */
    val grantsAppAccess: Boolean
        get() = grantsSupabaseAccess && (canUseAndroidApp ?: canUseIosApp ?: true)

    /** Diagnostic status string persisted in the entitlement snapshot. */
    val verificationStatusLabel: String
        get() = buildString {
            append("supabase:")
            append(accessSourceLabel)
            reasonCode?.takeIf { it.isNotBlank() }?.let { append(':').append(it) }
        }

    /** Whether the client should still verify RevenueCat Solo (iOS parity). */
    val requiresSoloCheck: Boolean get() = soloCheckRequired ?: !grantsSupabaseAccess

    /** Short label for debug/diagnostics, e.g. "team", "enterprise", "internal". */
    val accessSourceLabel: String
        get() = planTier?.takeIf { it.isNotBlank() }
            ?: accessSource?.takeIf { it.isNotBlank() }
            ?: "none"

    /**
     * Earliest KNOWN future entitlement expiry in epoch millis, used to CAP
     * the offline grace cache so cached access never outlives a known expiry
     * (e.g. the server-authoritative trial end — SQL 143/144). Prefers the
     * resolver's `expires_at`; falls back to the individual date columns for
     * older resolver responses. Null when no future-dated expiry applies
     * (e.g. an open-ended Internal Unlimited grant).
     */
    fun knownExpiresAtMs(nowMs: Long = System.currentTimeMillis()): Long? =
        listOfNotNull(expiresAt, manualGrantExpiresAt, trialEnd, currentPeriodEnd, gracePeriodEnd)
            .mapNotNull(::parseIsoToEpochMsOrNull)
            .filter { it > nowMs }
            .minOrNull()

    private companion object {
        /** Tolerant ISO-8601 → epoch-ms parse (Postgres timestamptz shapes). */
        fun parseIsoToEpochMsOrNull(raw: String): Long? = try {
            java.time.OffsetDateTime.parse(raw).toInstant().toEpochMilli()
        } catch (_: Exception) {
            try {
                java.time.Instant.parse(raw).toEpochMilli()
            } catch (_: Exception) {
                null
            }
        }
    }
}

/**
 * Reads the caller's VineTrack entitlement from the Supabase RPC
 * `get_my_vinetrack_access()` — Android port of the iOS
 * `VineTrackAccessRepository`. Grants Team / Enterprise / internal / legacy /
 * portal-trial access; Solo (store) access falls back to RevenueCat.
 */
class VineTrackAccessRepository(private val session: SessionStore) {

    /**
     * Fetch the current user's backend access, or null when the RPC returns no
     * row. Throws on configuration/auth/transport failure so the caller can
     * fall back to RevenueCat without treating "no row" as an error.
     */
    suspend fun fetchMyAccess(): VineTrackAccessRow? = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(RPC_NAME)) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody("{}")
        }
        when {
            response.status.isSuccess() -> {
                // The RPC `returns table (...)` → decode an array, take the first.
                val rows: List<VineTrackAccessRow> = response.body()
                rows.firstOrNull()
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }

    private companion object {
        const val RPC_NAME = "get_my_vinetrack_access"
    }
}

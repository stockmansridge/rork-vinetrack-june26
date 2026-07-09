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
 * Decoded row from the Supabase RPC `get_my_vinetrack_access()` (sql/096) —
 * Android port of the iOS `BackendVineTrackAccess` model. Every field is
 * optional and unknown keys are ignored so schema evolution never breaks the
 * client. The RPC is SECURITY DEFINER and only reports the caller's own access.
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
) {
    /** Effective "Supabase grants access" flag, tolerant of either key (iOS parity). */
    val grantsSupabaseAccess: Boolean get() = hasSupabaseAccess ?: hasAccess ?: false

    /**
     * Whether the mobile app should be unlocked via the backend. The RPC's
     * `can_use_ios_app` flag is platform-agnostic ("can use the mobile app");
     * defaults to the general access flag when absent, matching iOS.
     */
    val grantsAppAccess: Boolean get() = grantsSupabaseAccess && (canUseIosApp ?: true)

    /** Whether the client should still verify RevenueCat Solo (iOS parity). */
    val requiresSoloCheck: Boolean get() = soloCheckRequired ?: !grantsSupabaseAccess

    /** Short label for debug/diagnostics, e.g. "team", "enterprise", "internal". */
    val accessSourceLabel: String
        get() = planTier?.takeIf { it.isNotBlank() }
            ?: accessSource?.takeIf { it.isNotBlank() }
            ?: "none"
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

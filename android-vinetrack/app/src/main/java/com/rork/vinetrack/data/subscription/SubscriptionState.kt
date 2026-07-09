package com.rork.vinetrack.data.subscription

import android.content.Context
import androidx.core.content.edit
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Snapshot of the last *successful online* entitlement/access verification.
 *
 * Direct port of the iOS `EntitlementVerificationSnapshot`: persisted locally so
 * a paying user in a no-service vineyard keeps working during the offline grace
 * window even when neither RevenueCat nor Supabase can be reached. Never
 * contains raw billing payloads — only the coarse status needed to evaluate the
 * grace window.
 */
@Serializable
data class EntitlementVerificationSnapshot(
    /** Supabase auth user the verification belongs to. */
    @SerialName("user_id") val userId: String? = null,
    /** Epoch millis when the last successful online verification completed. */
    @SerialName("last_verified_at_ms") val lastVerifiedAtMs: Long,
    /** Whether that verification granted entitlement/access. */
    @SerialName("was_entitled") val wasEntitled: Boolean,
    /** Short, non-sensitive product/entitlement status (e.g. "active:…"). */
    @SerialName("product_status") val productStatus: String? = null,
)

/**
 * Local persistence for the entitlement grace window, mirroring iOS
 * `EntitlementVerificationStore`. Single-snapshot, keyed by user id so a
 * different account never inherits a stale grace.
 */
class EntitlementVerificationStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_entitlement", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true }

    fun load(): EntitlementVerificationSnapshot? {
        val raw = prefs.getString(KEY, null) ?: return null
        return try {
            json.decodeFromString(EntitlementVerificationSnapshot.serializer(), raw)
        } catch (_: Exception) {
            null
        }
    }

    /** Returns the persisted snapshot only when it belongs to [userId] (parity with iOS). */
    fun load(userId: String?): EntitlementVerificationSnapshot? {
        val snapshot = load() ?: return null
        if (userId == null) return if (snapshot.userId == null) snapshot else null
        return if (snapshot.userId == null || snapshot.userId == userId) snapshot else null
    }

    fun save(snapshot: EntitlementVerificationSnapshot) {
        val raw = try {
            json.encodeToString(EntitlementVerificationSnapshot.serializer(), snapshot)
        } catch (_: Exception) {
            return
        }
        prefs.edit { putString(KEY, raw) }
    }

    /** Records a fresh verification result (only call after an ONLINE check). */
    fun recordVerification(
        userId: String?,
        entitled: Boolean,
        productStatus: String?,
    ): EntitlementVerificationSnapshot {
        val snapshot = EntitlementVerificationSnapshot(
            userId = userId,
            lastVerifiedAtMs = System.currentTimeMillis(),
            wasEntitled = entitled,
            productStatus = productStatus,
        )
        save(snapshot)
        return snapshot
    }

    private companion object {
        const val KEY = "vinetrack.entitlementVerification.v1"
    }
}

/** A purchasable package rendered on the subscription screen. */
data class PaywallPackageUi(
    /** RevenueCat package identifier (e.g. `$rc_annual` / `annual`). */
    val packageId: String,
    /** Plan title, e.g. "Annual plan" (derived exactly like iOS `planTitle`). */
    val title: String,
    /** e.g. "3 months free, then $179.99/year" (parity with iOS `renewalText`). */
    val renewalLine: String,
    /** Localised store product title, shown as the caption line. */
    val productTitle: String,
)

/**
 * Subscription/paywall UI state exposed to Compose, mirroring the observable
 * surface of the iOS `SubscriptionService`.
 */
data class SubscriptionUiState(
    /** True while offerings/customer info are being (re)fetched. */
    val isLoading: Boolean = false,
    /** Packages of the current offering; empty when not yet set up in Play. */
    val packages: List<PaywallPackageUi> = emptyList(),
    val isPurchasing: Boolean = false,
    val isRestoring: Boolean = false,
    val lastError: String? = null,
    /** False when the RevenueCat public SDK key is missing from the build. */
    val isConfigured: Boolean = true,
    /** Device is currently offline — purchases can't complete. */
    val isOffline: Boolean = false,
)

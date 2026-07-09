package com.rork.vinetrack.data.subscription

import android.app.Activity
import android.content.Context
import android.util.Log
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.LogLevel
import com.revenuecat.purchases.Offering
import com.revenuecat.purchases.Package
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchasesTransactionException
import com.revenuecat.purchases.awaitCustomerInfo
import com.revenuecat.purchases.awaitLogIn
import com.revenuecat.purchases.awaitLogOut
import com.revenuecat.purchases.awaitOfferings
import com.revenuecat.purchases.awaitPurchase
import com.revenuecat.purchases.awaitRestore
import com.revenuecat.purchases.interfaces.UpdatedCustomerInfoListener
import com.rork.vinetrack.data.AppConfig

/**
 * RevenueCat subscription service for Android — direct port of the iOS
 * `SubscriptionService` RevenueCat surface.
 *
 * Parity contract (audited from iOS):
 *  - Entitlement identifier: `pro` (same RevenueCat project/entitlement).
 *  - appUserID: the Supabase auth user UUID (`Purchases.logIn(userId)`).
 *  - Offering/package/product IDs are NOT hardcoded — the SDK fetches the
 *    current offering at runtime, exactly like iOS.
 *  - Missing SDK key degrades gracefully (no configure, no crash).
 *
 * Google Play side sells only `vinetrack_solo_yearly`; Team/Enterprise are
 * portal-managed and honoured via the Supabase access check, never Play.
 */
class RevenueCatManager(private val context: Context) {

    private var didConfigure = false
    private var loggedInUserId: String? = null

    /** True once the SDK has been configured with a non-empty public key. */
    val isConfigured: Boolean get() = didConfigure

    /**
     * Configure the SDK once (parity with iOS `configureIfNeeded`). Returns
     * false when the public SDK key is missing so callers can surface a
     * "not configured" state instead of crashing.
     */
    fun configureIfNeeded(): Boolean {
        if (didConfigure) return true
        val key = AppConfig.revenueCatAndroidApiKey.trim()
        if (key.isEmpty()) {
            Log.w(TAG, "RevenueCat Android SDK key missing — skipping configure().")
            return false
        }
        return try {
            Purchases.logLevel = LogLevel.WARN
            Purchases.configure(PurchasesConfiguration.Builder(context.applicationContext, key).build())
            didConfigure = true
            true
        } catch (e: Exception) {
            Log.w(TAG, "RevenueCat configure failed: ${e.message}")
            false
        }
    }

    /**
     * Observe pushed CustomerInfo updates (purchases, renewals, restores) —
     * the Android equivalent of the iOS `customerInfoStream`.
     */
    fun setCustomerInfoListener(onUpdate: (CustomerInfo) -> Unit) {
        if (!didConfigure) return
        Purchases.sharedInstance.updatedCustomerInfoListener =
            UpdatedCustomerInfoListener { info -> onUpdate(info) }
    }

    /**
     * Identify RevenueCat with the Supabase auth user id (iOS parity: never
     * anonymous). Returns the resulting CustomerInfo, or null when the SDK is
     * unconfigured or the call fails.
     */
    suspend fun logIn(supabaseUserId: String): CustomerInfo? {
        if (!configureIfNeeded()) return null
        if (loggedInUserId == supabaseUserId) {
            return try {
                Purchases.sharedInstance.awaitCustomerInfo()
            } catch (e: Exception) {
                Log.w(TAG, "customerInfo failed: ${e.message}")
                null
            }
        }
        return try {
            val result = Purchases.sharedInstance.awaitLogIn(supabaseUserId)
            loggedInUserId = supabaseUserId
            result.customerInfo
        } catch (e: Exception) {
            Log.w(TAG, "logIn failed: ${e.message}")
            null
        }
    }

    /** Reset RevenueCat identity on sign out (iOS parity: `Purchases.logOut()`). */
    suspend fun logOut() {
        loggedInUserId = null
        if (!didConfigure) return
        try {
            Purchases.sharedInstance.awaitLogOut()
        } catch (e: Exception) {
            // Logging out an anonymous user throws — ignore, matching iOS.
            Log.d(TAG, "logOut ignored: ${e.message}")
        }
    }

    /** Fetch the latest CustomerInfo, or null on failure/unconfigured. */
    suspend fun customerInfo(): CustomerInfo? {
        if (!configureIfNeeded()) return null
        return try {
            Purchases.sharedInstance.awaitCustomerInfo()
        } catch (e: Exception) {
            Log.w(TAG, "customerInfo failed: ${e.message}")
            null
        }
    }

    /** Fetch the current offering (iOS parity: `offerings.current`), or null. */
    suspend fun currentOffering(): Offering? {
        if (!configureIfNeeded()) return null
        return try {
            Purchases.sharedInstance.awaitOfferings().current
        } catch (e: Exception) {
            Log.w(TAG, "offerings failed: ${e.message}")
            null
        }
    }

    /** Outcome of a purchase attempt, mirroring the iOS purchase handling. */
    sealed interface PurchaseOutcome {
        /** Purchase completed and the entitlement is now active. */
        data class Unlocked(val info: CustomerInfo) : PurchaseOutcome
        /** Purchase completed but the entitlement is not active (shouldn't happen). */
        data class NotEntitled(val info: CustomerInfo) : PurchaseOutcome
        /** User backed out of the Play billing sheet — not an error. */
        data object Cancelled : PurchaseOutcome
        data class Failure(val message: String) : PurchaseOutcome
    }

    /** Launch the Google Play purchase flow for [rcPackage]. */
    suspend fun purchase(activity: Activity, rcPackage: Package): PurchaseOutcome {
        if (!configureIfNeeded()) return PurchaseOutcome.Failure("Subscription service is not configured.")
        return try {
            val result = Purchases.sharedInstance.awaitPurchase(
                PurchaseParams.Builder(activity, rcPackage).build(),
            )
            if (isEntitled(result.customerInfo)) {
                PurchaseOutcome.Unlocked(result.customerInfo)
            } else {
                PurchaseOutcome.NotEntitled(result.customerInfo)
            }
        } catch (e: PurchasesTransactionException) {
            if (e.userCancelled) {
                PurchaseOutcome.Cancelled
            } else {
                PurchaseOutcome.Failure(e.error.message)
            }
        } catch (e: Exception) {
            PurchaseOutcome.Failure(e.message ?: "Purchase failed.")
        }
    }

    /** Restore Play Store purchases for the current user, or null on failure. */
    suspend fun restore(): CustomerInfo? {
        if (!configureIfNeeded()) return null
        return try {
            Purchases.sharedInstance.awaitRestore()
        } catch (e: Exception) {
            Log.w(TAG, "restore failed: ${e.message}")
            null
        }
    }

    /** Whether the shared `pro` entitlement is active (same check as iOS). */
    fun isEntitled(info: CustomerInfo?): Boolean =
        info?.entitlements?.get(ENTITLEMENT_ID)?.isActive == true

    /**
     * Short, non-sensitive description of the active entitlement — direct port
     * of the iOS `productStatusString` used for the verification snapshot.
     */
    fun productStatus(info: CustomerInfo?): String? {
        val entitlement = info?.entitlements?.get(ENTITLEMENT_ID) ?: return null
        if (!entitlement.isActive) return null
        return when {
            entitlement.periodType == com.revenuecat.purchases.PeriodType.TRIAL ->
                "trial:${entitlement.productIdentifier}"
            entitlement.willRenew -> "active:${entitlement.productIdentifier}"
            else -> "expiring:${entitlement.productIdentifier}"
        }
    }

    companion object {
        /** RevenueCat entitlement identifier for full app access (same as iOS). */
        const val ENTITLEMENT_ID = "pro"

        /** Offline grace window, in days (same as iOS `offlineGraceDays`). */
        const val OFFLINE_GRACE_DAYS = 30

        private const val TAG = "VineTrackRC"
    }
}

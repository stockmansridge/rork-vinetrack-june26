package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.SharedPreferences
import java.util.WeakHashMap
import androidx.core.content.edit

/**
 * Persists the Supabase session tokens so the user stays signed in across
 * launches, mirroring the iOS session restore behaviour.
 */
class SessionStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_session", Context.MODE_PRIVATE)

    val retentionGuard: AuthRetentionGuard = synchronized(retentionGuards) {
        retentionGuards.getOrPut(prefs) {
            AuthRetentionGuard(
                readLocked = { prefs.getBoolean(KEY_RECOVERY_LOCK, false) },
                persistLock = { prefs.edit().putBoolean(KEY_RECOVERY_LOCK, true).commit() },
            )
        }
    }

    init {
        // Surviving session context is ambiguity evidence, not ownership. Old auth exits may
        // have removed tokens without clearing authorless queues. Do not open those stores.
        if (runCatching {
            prefs.getString(KEY_REFRESH, null).isNullOrBlank() &&
                prefs.getString(KEY_VINEYARD_CACHE_OWNER, null) != null
        }.getOrDefault(true)) {
            retentionGuard.rejectSession { clearCredentials() }
        }
    }

    var accessToken: String?
        get() = if (retentionGuard.isLocked) null else prefs.getString(KEY_ACCESS, null)
        set(value) { retentionGuard.requireUnlocked(); prefs.edit { putString(KEY_ACCESS, value) } }

    var refreshToken: String?
        get() = if (retentionGuard.isLocked) null else prefs.getString(KEY_REFRESH, null)
        set(value) { retentionGuard.requireUnlocked(); prefs.edit { putString(KEY_REFRESH, value) } }

    var userId: String?
        get() = if (retentionGuard.isLocked) null else prefs.getString(KEY_USER_ID, null)
        set(value) { retentionGuard.requireUnlocked(); prefs.edit { putString(KEY_USER_ID, value) } }

    var userEmail: String?
        get() = prefs.getString(KEY_EMAIL, null)
        set(value) = prefs.edit { putString(KEY_EMAIL, value) }

    var userName: String?
        get() = prefs.getString(KEY_NAME, null)
        set(value) = prefs.edit { putString(KEY_NAME, value) }

    /**
     * ISO timestamp the Supabase auth user was created (auth `created_at`).
     * Cached so the 3-month initial free-access window (parity with iOS
     * `SubscriptionService.isInInitialFreeAccessPeriod`) can be evaluated on an
     * offline launch too.
     */
    var userCreatedAt: String?
        get() = prefs.getString(KEY_CREATED_AT, null)
        set(value) = prefs.edit { putString(KEY_CREATED_AT, value) }

    var selectedVineyardId: String?
        get() = prefs.getString(KEY_SELECTED_VINEYARD, null)
        set(value) = prefs.edit { putString(KEY_SELECTED_VINEYARD, value) }

    /**
     * Cached copy of the user's preferred default vineyard (server is the
     * source of truth). Kept locally so an offline launch can still prefer the
     * default when the profile can't be fetched.
     */
    var defaultVineyardId: String?
        get() = prefs.getString(KEY_DEFAULT_VINEYARD, null)
        set(value) = prefs.edit { putString(KEY_DEFAULT_VINEYARD, value) }

    val hasSession: Boolean get() = !accessToken.isNullOrBlank() && !refreshToken.isNullOrBlank()

    fun save(
        accessToken: String,
        refreshToken: String,
        userId: String?,
        email: String?,
        name: String? = null,
        createdAt: String? = null,
    ) {
        synchronized(retentionGuard) {
        retentionGuard.requireUnlocked()
        // The cache owner is a switch detector only, never proof of pending-operation authorship.
        val previousAccount = prefs.getString(KEY_USER_ID, null) ?: prefs.getString(KEY_VINEYARD_CACHE_OWNER, null)
        if (previousAccount != null && previousAccount != userId) {
            retentionGuard.rejectSession { clearCredentials() }
            error(AuthRetentionGuard.RECOVERY_MESSAGE)
        }
        // If a *different* user is signing in, drop the previous user's cached
        // vineyard selection/default so it can't leak into the new session.
        // We track ownership with a dedicated key that survives `clear()` (which
        // wipes userId on sign-out), so a sign-out → different-user sign-in is
        // still detected. A token refresh for the same user keeps the cache.
        val cacheOwner = prefs.getString(KEY_VINEYARD_CACHE_OWNER, null)
        val isDifferentUser = userId != null && cacheOwner != null && userId != cacheOwner
        prefs.edit {
            putString(KEY_ACCESS, accessToken)
            putString(KEY_REFRESH, refreshToken)
            putString(KEY_USER_ID, userId)
            putString(KEY_EMAIL, email)
            if (name != null) putString(KEY_NAME, name)
            if (createdAt != null) putString(KEY_CREATED_AT, createdAt)
            if (userId != null) putString(KEY_VINEYARD_CACHE_OWNER, userId)
            if (isDifferentUser) {
                remove(KEY_SELECTED_VINEYARD)
                remove(KEY_DEFAULT_VINEYARD)
            }
        }
        }
    }

    /** Captures this process's auth incarnation, not ownership of any existing field record. */
    fun accountAccess(): AuthRetentionGuard.AccountAccess? = synchronized(retentionGuard) {
        if (accessToken.isNullOrBlank()) null else retentionGuard.captureAccount(userId)
    }

    fun withAccountAccess(access: AuthRetentionGuard.AccountAccess, action: () -> Unit): Boolean =
        retentionGuard.withAccount(access, { userId?.takeIf { !accessToken.isNullOrBlank() } }, action)

    fun isAccountAccessCurrent(access: AuthRetentionGuard.AccountAccess): Boolean =
        withAccountAccess(access) { }

    /** Credential rejection locks local field access before any credential removal. */
    fun clear() {
        retentionGuard.rejectSession { clearCredentials() }
    }

    private fun clearCredentials() {
        check(prefs.edit().apply {
            remove(KEY_ACCESS)
            remove(KEY_REFRESH)
            remove(KEY_USER_ID)
            remove(KEY_EMAIL)
            remove(KEY_NAME)
            remove(KEY_CREATED_AT)
            // Field records and selection evidence remain untouched and locked.
        }.commit()) { "Couldn't persist credential revocation; recovery remains locked." }
    }

    private companion object {
        val retentionGuards = WeakHashMap<SharedPreferences, AuthRetentionGuard>()
        const val KEY_RECOVERY_LOCK = "field_recovery_locked_v1"
        const val KEY_ACCESS = "access_token"
        const val KEY_REFRESH = "refresh_token"
        const val KEY_USER_ID = "user_id"
        const val KEY_EMAIL = "user_email"
        const val KEY_NAME = "user_name"
        const val KEY_CREATED_AT = "user_created_at"
        const val KEY_SELECTED_VINEYARD = "selected_vineyard_id"
        const val KEY_DEFAULT_VINEYARD = "default_vineyard_id"
        const val KEY_VINEYARD_CACHE_OWNER = "vineyard_cache_owner"
    }
}

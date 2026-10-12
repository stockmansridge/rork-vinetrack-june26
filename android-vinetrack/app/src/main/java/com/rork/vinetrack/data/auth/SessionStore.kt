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
    private val appContext: Context = context.applicationContext

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_session", Context.MODE_PRIVATE)

    val retentionGuard: AuthRetentionGuard = synchronized(retentionGuards) {
        retentionGuards.getOrPut(prefs) {
            AuthRetentionGuard(
                readLocked = { prefs.getBoolean(KEY_RECOVERY_LOCK, false) },
                persistLock = { persistRecoveryClaimAndRevoke() },
                readIdentityEpoch = { prefs.getLong(KEY_IDENTITY_EPOCH, 0L) },
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
            retentionGuard.rejectSession { }
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
        retentionGuard.serialized {
        retentionGuard.requireUnlocked()
        if (prefs.getBoolean(KEY_CLEAN_EXIT, false)) {
            val evidence = AccountTransitionEvidence(appContext)
            check(evidence.inspectCleanExit() != null) {
                "Local state changed after sign-out (${evidence.failureCategory}). Keep this installation and contact support."
            }
        }
        // The cache owner is a switch detector only, never proof of pending-operation authorship.
        val previousAccount = prefs.getString(KEY_USER_ID, null) ?: prefs.getString(KEY_VINEYARD_CACHE_OWNER, null)
        if (previousAccount != null && previousAccount != userId) {
            retentionGuard.rejectSession { }
            error(AuthRetentionGuard.RECOVERY_MESSAGE)
        }
        // If a *different* user is signing in, drop the previous user's cached
        // vineyard selection/default so it can't leak into the new session.
        // We track ownership with a dedicated key that survives `clear()` (which
        // wipes userId on sign-out), so a sign-out → different-user sign-in is
        // still detected. A token refresh for the same user keeps the cache.
        val cacheOwner = prefs.getString(KEY_VINEYARD_CACHE_OWNER, null)
        val isDifferentUser = userId != null && cacheOwner != null && userId != cacheOwner
        check(prefs.edit().apply {
            remove(KEY_CLEAN_EXIT)
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
        }.commit()) { "Couldn't persist the authenticated session." }
        }
    }

    /** Supabase UUID captured from the session being rejected, never from email/cache membership. */
    val recoveryPrincipal: String?
        get() = retentionGuard.serialized {
            if (!retentionGuard.isLocked) null else runCatching {
                prefs.getString(KEY_RECOVERY_PRINCIPAL, null)?.takeIf(::isSupabaseUuid)
            }.getOrNull()
        }

    /** Fixed refresh authority; tokens intentionally have no data-class/debug string representation. */
    internal class RefreshAccess(
        val account: AuthRetentionGuard.AccountAccess,
        val token: String,
    )

    internal fun refreshAccess(): RefreshAccess? = retentionGuard.serialized {
        val token = refreshToken?.takeIf { it.isNotBlank() } ?: return@serialized null
        val account = retentionGuard.captureAccount(userId) ?: return@serialized null
        RefreshAccess(account, token)
    }

    internal fun withRefreshAccess(access: RefreshAccess, action: () -> Unit): Boolean =
        retentionGuard.withAccount(access.account, {
            userId?.takeIf { refreshToken == access.token }
        }, action)

    /** Reject only the exact refresh incarnation that the server evaluated. */
    internal fun rejectRefreshIfCurrent(access: RefreshAccess): Boolean = retentionGuard.serialized {
        if (refreshToken != access.token || !retentionGuard.isAccountCurrent(access.account, userId)) {
            return@serialized false
        }
        retentionGuard.rejectSession { }
        // Runtime access is revoked even if disk persistence failed; original field bytes are untouched.
        true
    }

    /** Captures this process's auth incarnation, not ownership of any existing field record. */
    fun accountAccess(): AuthRetentionGuard.AccountAccess? = retentionGuard.serialized {
        if (accessToken.isNullOrBlank()) null else retentionGuard.captureAccount(userId)
    }

    fun withAccountAccess(access: AuthRetentionGuard.AccountAccess, action: () -> Unit): Boolean =
        retentionGuard.withAccount(access, { userId?.takeIf { !accessToken.isNullOrBlank() } }, action)

    fun isAccountAccessCurrent(access: AuthRetentionGuard.AccountAccess): Boolean =
        withAccountAccess(access) { }

    /** Capture before a delayed location/capture/save begins; complete only after its durable outcome. */
    fun fieldOperation(): AuthRetentionGuard.FieldOperation? = retentionGuard.serialized {
        if (accessToken.isNullOrBlank()) null else retentionGuard.beginOperation(userId)
    }

    fun withFieldOperation(operation: AuthRetentionGuard.FieldOperation, action: () -> Unit): Boolean =
        retentionGuard.withOperation(operation, { userId?.takeIf { !accessToken.isNullOrBlank() } }, action)

    /** Opaque remote logout authority; a delayed logout never mutates a newer local session. */
    internal class CleanExit internal constructor(val accessToken: String)

    /** Privacy-safe explanation of the last voluntary refusal; never contains stored identifiers. */
    @Volatile var cleanExitRefusal: String = "Work is still completing. Wait briefly, then try signing out again."
        private set

    internal fun cleanExit(account: AuthRetentionGuard.AccountAccess): CleanExit? {
        cleanExitRefusal = "Work is still completing. Wait briefly, then try signing out again."
        var exit: CleanExit? = null
        val committed = retentionGuard.cleanExitIfIdle(account, { userId }) {
            val token = accessToken ?: return@cleanExitIfIdle false
            if (!hasSession) return@cleanExitIfIdle false
            val evidence = AccountTransitionEvidence(appContext)
            if (evidence.inspectCleanExit() == null) {
                cleanExitRefusal = when (evidence.failureCategory) {
                    "vinetrack_active_trip" -> "An active Trip is retained. Finish the Trip before signing out."
                    "vinetrack_spray_tank_actuals" -> "Tank actual records are retained. Check Sync Status before signing out."
                    "vinetrack_pending_writes", "vinetrack_domain_cache" -> "Pending records or uncertain cached evidence are retained. Check Sync Status; do not clear app storage."
                    "vinetrack_pending_photos", "vinetrack_pin_capture_evidence", PhotoCaptureReceipt.PREFERENCES -> "A photograph or capture is unfinished. Complete it before signing out."
                    "vinetrack_local_planning", "vinetrack_manual_spray_drafts_v1", "vinetrack_paired_growth_capture" -> "An unresolved draft is retained. Finish or review the draft before signing out."
                    "file dependencies" -> "Local files or unfinished photographs need review. Keep this installation and contact support."
                    else -> "Local settings or legacy records could not be verified. Keep this installation and contact support."
                }
                return@cleanExitIfIdle false
            }
            // Removing every account-selection key in the same credential transaction makes restart unambiguous.
            if (!prefs.edit().clear().putBoolean(KEY_CLEAN_EXIT, true)
                    .putLong(KEY_IDENTITY_EPOCH, retentionGuard.identityEpoch.value + 1L).commit()) return@cleanExitIfIdle false
            exit = CleanExit(token)
            true
        }
        return if (committed) exit else null
    }

    /** Caller must first verify /auth/user and current memberships using the isolated recovery client. */
    internal fun restoreOriginal(
        accessToken: String,
        refreshToken: String,
        user: com.rork.vinetrack.data.model.AppUser,
        permittedVineyards: Set<String>,
    ): Boolean = retentionGuard.recoverIfIdle {
        if (user.id != recoveryPrincipal || accessToken.isBlank() || refreshToken.isBlank()) return@recoverIfIdle false
        val evidence = AccountTransitionEvidence(appContext).inspect(user.id) ?: return@recoverIfIdle false
        if (!permittedVineyards.containsAll(evidence.vineyards)) return@recoverIfIdle false
        prefs.edit().apply {
            putString(KEY_ACCESS, accessToken)
            putString(KEY_REFRESH, refreshToken)
            putString(KEY_USER_ID, user.id)
            putString(KEY_EMAIL, user.email)
            putString(KEY_NAME, user.displayName)
            putString(KEY_CREATED_AT, user.createdAt)
            putString(KEY_VINEYARD_CACHE_OWNER, user.id)
            remove(KEY_RECOVERY_PRINCIPAL)
            remove(KEY_CLEAN_EXIT)
            putBoolean(KEY_RECOVERY_LOCK, false)
            putLong(KEY_IDENTITY_EPOCH, retentionGuard.identityEpoch.value + 1L)
            if (prefs.getString(KEY_SELECTED_VINEYARD, null) !in permittedVineyards) remove(KEY_SELECTED_VINEYARD)
            if (prefs.getString(KEY_DEFAULT_VINEYARD, null) !in permittedVineyards) remove(KEY_DEFAULT_VINEYARD)
        }.commit()
    }

    /** Credential rejection locks local field access before any credential removal. */
    fun clear() {
        retentionGuard.rejectSession { }
    }

    private fun persistRecoveryClaimAndRevoke(): Boolean {
        val existing = prefs.getString(KEY_RECOVERY_PRINCIPAL, null)
        val original = prefs.getString(KEY_USER_ID, null)?.takeIf(::isSupabaseUuid)
        // One session preference transaction publishes both the hold and its principal before
        // credentials disappear. Historical tokenless cache context is deliberately not adopted.
        return prefs.edit().apply {
            putBoolean(KEY_RECOVERY_LOCK, true)
            putLong(KEY_IDENTITY_EPOCH, retentionGuard.identityEpoch.value)
            if (existing == null && original != null) putString(KEY_RECOVERY_PRINCIPAL, original)
            remove(KEY_ACCESS)
            remove(KEY_REFRESH)
            remove(KEY_USER_ID)
            remove(KEY_EMAIL)
            remove(KEY_NAME)
            remove(KEY_CREATED_AT)
            // Field records and selection evidence remain untouched and locked.
        }.commit()
    }

    private fun isSupabaseUuid(value: String): Boolean =
        value.matches(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"))

    private companion object {
        val retentionGuards = WeakHashMap<SharedPreferences, AuthRetentionGuard>()
        const val KEY_IDENTITY_EPOCH = "account_ui_epoch_v1"
        const val KEY_CLEAN_EXIT = "verified_clean_exit_v1"
        const val KEY_RECOVERY_LOCK = "field_recovery_locked_v1"
        const val KEY_RECOVERY_PRINCIPAL = "field_recovery_principal_v1"
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

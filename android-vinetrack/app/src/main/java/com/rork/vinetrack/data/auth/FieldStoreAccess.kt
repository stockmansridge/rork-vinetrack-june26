package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.SharedPreferences
import android.os.Looper

/** A production store handle is pinned to its first authorised incarnation, never the next login. */
internal class FieldStoreAccess(context: Context) {
    private val session = SessionStore(context)
    @Volatile private var account: AuthRetentionGuard.AccountAccess? = snapshot()

    private fun snapshot(): AuthRetentionGuard.AccountAccess? =
        session.retentionGuard.snapshotAccount { session.userId?.takeIf { !session.accessToken.isNullOrBlank() } }

    private fun captured(): AuthRetentionGuard.AccountAccess = account ?: synchronized(this) {
        account ?: (snapshot() ?: throw FieldAccessRevoked()).also { account = it }
    }

    /** Only available after validation inside an admitted operation, never evidence of record ownership. */
    internal val ownerUserId: String get() = captured().userId
    internal val identityEpoch: Long get() = session.retentionGuard.identityEpoch.value

    private fun currentUserId(): String? = session.userId?.takeIf { !session.accessToken.isNullOrBlank() }

    /** Nonblocking leaf commit: safe even when the caller already holds a storage monitor. */
    fun <T> commit(action: () -> T): T = execute(captured(), wait = false, action)

    /** Whole synchronous mutation admission. MUST be called before acquiring any storage monitor. */
    fun <T> admitted(action: () -> T): T = execute(captured(), wait = true, action)

    fun <T> admittedForOwner(ownerUserId: String, action: () -> T): T {
        val access = captured()
        if (access.userId != ownerUserId) throw FieldAccessRevoked()
        return execute(access, wait = true, action)
    }

    private fun <T> execute(access: AuthRetentionGuard.AccountAccess, wait: Boolean, action: () -> T): T {
        var result: T? = null
        val outcome = if (wait) session.retentionGuard.awaitWithAccount(
            access, ::currentUserId,
            // Legacy synchronous UI boundaries have a small finite bound, not an ANR-length wait.
            if (Looper.myLooper() == Looper.getMainLooper()) 100L else 5_000L,
        ) { result = action() }
        else session.retentionGuard.tryWithAccount(access, ::currentUserId) { result = action() }
        when (outcome) {
            AuthRetentionGuard.Admission.BUSY -> throw FieldSaveBusy()
            AuthRetentionGuard.Admission.REVOKED -> throw FieldAccessRevoked()
            AuthRetentionGuard.Admission.ADMITTED -> Unit
        }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    fun <T> commitForOwner(ownerUserId: String, action: () -> T): T {
        val access = captured()
        if (access.userId != ownerUserId) throw FieldAccessRevoked()
        return execute(access, wait = false, action)
    }

    /** Editors retain their original authority; no retry can recapture a later account generation. */
    // Opt-in only for stores without storage monitors: acquire authority before prefs.commit().
    // Leaf stores that may already own a storage monitor remain strictly nonblocking.
    fun preferences(prefs: SharedPreferences, waitBeforeCommit: Boolean = false): SharedPreferences = object : SharedPreferences by prefs {
        override fun edit(): SharedPreferences.Editor {
            val access = captured()
            val editor = prefs.edit()
            return object : SharedPreferences.Editor {
                override fun putString(key: String?, value: String?) = apply { editor.putString(key, value) }
                override fun putStringSet(key: String?, values: MutableSet<String>?) = apply { editor.putStringSet(key, values?.toMutableSet()) }
                override fun putInt(key: String?, value: Int) = apply { editor.putInt(key, value) }
                override fun putLong(key: String?, value: Long) = apply { editor.putLong(key, value) }
                override fun putFloat(key: String?, value: Float) = apply { editor.putFloat(key, value) }
                override fun putBoolean(key: String?, value: Boolean) = apply { editor.putBoolean(key, value) }
                override fun remove(key: String?) = apply { editor.remove(key) }
                override fun clear() = apply { editor.clear() }
                override fun commit(): Boolean = try { execute(access, wait = waitBeforeCommit) { editor.commit() } }
                    catch (_: FieldAccessRevoked) { false }
                override fun apply() {
                    if (!execute(access, wait = waitBeforeCommit) { editor.commit() }) throw FieldPersistenceFailure()
                }
            }
        }
    }
}

/** Recoverable contention, not authentication revocation; no success has been acknowledged. */
internal class FieldSaveBusy : IllegalStateException("Local saving is temporarily busy. Your save has not completed; keep this screen open and retry.")

/** Admission succeeded but durable storage did not. */
internal class FieldPersistenceFailure : IllegalStateException("Couldn't durably save local work. Keep this screen open, check device storage and retry.")

/** Neutral failure, with no account, location or retained-record content. */
internal class FieldAccessRevoked : IllegalStateException("Account access changed. Local work was retained; return to account recovery.")

package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.SharedPreferences

/** A production store handle is pinned to its first authorised incarnation, never the next login. */
internal class FieldStoreAccess(context: Context) {
    private val session = SessionStore(context)
    @Volatile private var account: AuthRetentionGuard.AccountAccess? = session.accountAccess()

    private fun captured(): AuthRetentionGuard.AccountAccess? {
        account?.let { return it }
        if (session.accessToken.isNullOrBlank()) return null
        val candidate = session.retentionGuard.tryCaptureAccount(session.userId) ?: return null
        return synchronized(this) { account ?: candidate.also { account = it } }
    }

    fun <T> commit(action: () -> T): T {
        val access = captured() ?: run {
            CleanExitDiagnostics.checkpoint("field.commit.capture.unavailable")
            throw FieldAccessRevoked()
        }
        var result: T? = null
        if (!session.retentionGuard.tryWithAccount(access, { session.userId }) { result = action() }) throw FieldAccessRevoked()
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    fun <T> commitForOwner(ownerUserId: String, action: () -> T): T {
        val access = captured() ?: throw FieldAccessRevoked()
        if (access.userId != ownerUserId) throw FieldAccessRevoked()
        return commit(action)
    }

    /** Editors capture authority when editing begins and revalidate at the actual disk commit. */
    fun preferences(prefs: SharedPreferences): SharedPreferences = object : SharedPreferences by prefs {
        override fun edit(): SharedPreferences.Editor {
            val access = captured() ?: throw FieldAccessRevoked()
            val editor = prefs.edit()
            return object : SharedPreferences.Editor {
                override fun putString(key: String?, value: String?) = apply { editor.putString(key, value) }
                override fun putStringSet(key: String?, values: MutableSet<String>?) = apply { editor.putStringSet(key, values) }
                override fun putInt(key: String?, value: Int) = apply { editor.putInt(key, value) }
                override fun putLong(key: String?, value: Long) = apply { editor.putLong(key, value) }
                override fun putFloat(key: String?, value: Float) = apply { editor.putFloat(key, value) }
                override fun putBoolean(key: String?, value: Boolean) = apply { editor.putBoolean(key, value) }
                override fun remove(key: String?) = apply { editor.remove(key) }
                override fun clear() = apply { editor.clear() }
                override fun commit(): Boolean {
                    var committed = false
                    val admitted = session.retentionGuard.tryWithAccount(access, { session.userId }) { committed = editor.commit() }
                    return admitted && committed
                }
                override fun apply() {
                    check(commit()) { "Couldn't durably save local work. Account access may have changed." }
                }
            }
        }
    }
}

/** Neutral failure, with no account, location or retained-record content. */
internal class FieldAccessRevoked : IllegalStateException("Account access changed. Local work was retained; return to account recovery.")

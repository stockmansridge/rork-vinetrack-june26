package com.rork.vinetrack.data.auth

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Conservative auth boundary; no ownership inference, field IO, cleanup or unlock API. */
class AuthRetentionGuard(
    readLocked: () -> Boolean,
    private val persistLock: () -> Boolean,
) {
    private val locked = MutableStateFlow(runCatching(readLocked).getOrDefault(true))
    val state: StateFlow<Boolean> = locked.asStateFlow()
    val isLocked: Boolean get() = locked.value

    /** Runtime authority only; it never establishes ownership of persisted legacy records. */
    class AccountAccess internal constructor(val userId: String, internal val authority: AuthRetentionGuard)

    @Synchronized
    fun captureAccount(userId: String?): AccountAccess? =
        userId?.takeIf { it.isNotBlank() && !isLocked }?.let { AccountAccess(it, this) }

    /** Serialises a synchronous callback with revocation; never hold this monitor across network waits. */
    @Synchronized
    fun withAccount(access: AccountAccess, currentUserId: () -> String?, action: () -> Unit): Boolean {
        if (isLocked || access.authority !== this || currentUserId() != access.userId) return false
        action()
        return true
    }

    /** No global field-store emptiness/ownership certificate exists yet. */
    fun canSignOut(): Boolean = false

    /** Revokes runtime admission first; failed persistence never authorises credential replacement. */
    @Synchronized
    fun rejectSession(clearCredentials: () -> Unit): Boolean {
        locked.value = true
        val durable = runCatching(persistLock).getOrDefault(false)
        if (durable) clearCredentials()
        return durable
    }

    fun requireUnlocked() {
        check(!isLocked) { RECOVERY_MESSAGE }
    }

    companion object {
        const val RECOVERY_MESSAGE = "Local vineyard work is retained and locked. Account access is paused until recovery can be verified. Do not clear app storage or reinstall."
        const val SIGN_OUT_MESSAGE = "Sign-out is temporarily blocked to protect local vineyard work. Unsynchronised or unresolved vineyard work must be resolved first. Keep this installation; contact support if synchronising does not resolve it. Safe account switching is not yet available."
    }
}

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
        const val SIGN_OUT_MESSAGE = "Sign-out is temporarily blocked to protect local vineyard work. Keep this installation and finish synchronising your work. Safe account switching is not yet available."
    }
}

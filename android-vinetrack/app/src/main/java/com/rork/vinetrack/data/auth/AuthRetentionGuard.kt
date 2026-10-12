package com.rork.vinetrack.data.auth

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Shared runtime account admission; a generation never establishes persisted record ownership. */
class AuthRetentionGuard(
    readLocked: () -> Boolean,
    private val persistLock: () -> Boolean,
    readIdentityEpoch: () -> Long = { 0L },
) {
    private val authorityLock = ReentrantLock()
    private val locked = MutableStateFlow(runCatching(readLocked).getOrDefault(true))
    val state: StateFlow<Boolean> = locked.asStateFlow()
    val isLocked: Boolean get() = locked.value
    private var generation: Long = 0
    private val epoch = MutableStateFlow(runCatching(readIdentityEpoch).getOrDefault(0L))
    /** Recreates account-bound UI holders after exit or recovery, never as record ownership. */
    val identityEpoch: StateFlow<Long> = epoch.asStateFlow()
    private val finishing = MutableStateFlow(false)
    /** Keeps Login admission closed until account-wide cleanup has completed. */
    val finishingCleanExit: StateFlow<Boolean> = finishing.asStateFlow()
    internal fun finishCleanExit() { serialized { finishing.value = false } }
    private var commitDepth: Int = 0
    private var transitionClosed: Boolean = false
    private val operations = mutableSetOf<FieldOperation>()

    class AccountAccess internal constructor(
        val userId: String,
        internal val authority: AuthRetentionGuard,
        internal val generation: Long,
    )

    /** Fixed before asynchronous acquisition; completion is idempotent, including after revocation. */
    class FieldOperation internal constructor(
        val account: AccountAccess,
        internal val guard: AuthRetentionGuard,
        val id: String = java.util.UUID.randomUUID().toString(),
    ) {
        fun complete() = guard.completeOperation(this)
    }

    internal fun <T> serialized(action: () -> T): T = authorityLock.withLock(action)

    fun captureAccount(userId: String?): AccountAccess? = serialized {
        userId?.takeIf { it.isNotBlank() && !isLocked && !transitionClosed && !finishing.value }
            ?.let { AccountAccess(it, this, generation) }
    }

    internal fun tryCaptureAccount(userId: String?): AccountAccess? {
        if (!authorityLock.tryLock()) return null
        return try { captureAccount(userId) } finally { authorityLock.unlock() }
    }

    internal fun isAccountCurrent(access: AccountAccess, userId: String?): Boolean = serialized {
        !isLocked && !transitionClosed && !finishing.value && access.authority === this &&
            access.generation == generation && userId == access.userId
    }

    fun beginOperation(userId: String?): FieldOperation? = serialized {
        captureAccount(userId)?.let { FieldOperation(it, this).also(operations::add) }
    }

    private fun completeOperation(operation: FieldOperation) { serialized { operations.remove(operation) } }
    fun hasOutstandingOperations(): Boolean = serialized { operations.isNotEmpty() }

    /** Activity recreation may recover the same live ticket, never mint authority for an old result. */
    fun operation(id: String): FieldOperation? = serialized { operations.firstOrNull { it.id == id } }

    fun withOperation(operation: FieldOperation, currentUserId: () -> String?, action: () -> Unit): Boolean = serialized {
        if (operation.guard !== this || operation !in operations) false
        else withAccount(operation.account, currentUserId, action)
    }

    /** Serialises only the synchronous publication/commit, never a network or location wait. */
    fun withAccount(access: AccountAccess, currentUserId: () -> String?, action: () -> Unit): Boolean = serialized {
        if (!isAccountCurrent(access, currentUserId())) return@serialized false
        commitDepth++
        try { action(); true } finally { commitDepth-- }
    }

    /** Low-level stores may already own their storage monitor; never invert auth → storage ordering. */
    internal fun tryWithAccount(access: AccountAccess, currentUserId: () -> String?, action: () -> Unit): Boolean {
        if (!authorityLock.tryLock()) return false
        return try { withAccount(access, currentUserId, action) } finally { authorityLock.unlock() }
    }

    /** Closes new admission while inspecting and committing. Outstanding work defers without cancellation. */
    fun transitionIfIdle(checkAndCommit: () -> Boolean): Boolean {
        if (!authorityLock.tryLock()) return false
        return try {
            if (isLocked || transitionClosed || finishing.value || commitDepth != 0) return false
            transitionClosed = true
            try { if (operations.isNotEmpty()) false else checkAndCommit() }
            finally { transitionClosed = false }
        } finally { authorityLock.unlock() }
    }

    /** A Boolean query is not a cleanliness certificate; exits use the atomic transition below. */
    fun canSignOut(): Boolean = false

    internal fun cleanExitIfIdle(account: AccountAccess, currentUserId: () -> String?, inspectAndCommit: () -> Boolean): Boolean {
        if (!authorityLock.tryLock()) return false
        return try {
            if (!isAccountCurrent(account, currentUserId())) false else cleanExitIfIdle(inspectAndCommit)
        } finally { authorityLock.unlock() }
    }

    private fun cleanExitIfIdle(inspectAndCommit: () -> Boolean): Boolean = transitionIfIdle {
        if (!inspectAndCommit()) false else {
            finishing.value = true
            generation++
            epoch.value++
            true
        }
    }

    /** Opens a fresh incarnation only after the original principal and retained evidence are checked. */
    internal fun recoverIfIdle(inspectAndCommit: () -> Boolean): Boolean {
        if (!authorityLock.tryLock()) return false
        return try {
            if (!isLocked || transitionClosed || commitDepth != 0 || operations.isNotEmpty()) return false
            transitionClosed = true
            try {
                if (!inspectAndCommit()) false else {
                    generation++
                    epoch.value++
                    locked.value = false
                    true
                }
            } finally { transitionClosed = false }
        } finally { authorityLock.unlock() }
    }

    fun rejectSession(clearCredentials: () -> Unit): Boolean = serialized {
        check(commitDepth == 0) { "An account transition cannot run inside a field commit." }
        if (!locked.value) {
            generation++
            epoch.value++
        }
        locked.value = true
        val durable = runCatching(persistLock).getOrDefault(false)
        if (durable) clearCredentials()
        durable
    }

    fun requireUnlocked() { check(!isLocked && !transitionClosed && !finishing.value) { RECOVERY_MESSAGE } }

    companion object {
        const val RECOVERY_MESSAGE = "Local vineyard work is retained and locked. Account access is paused until recovery can be verified. Do not clear app storage or reinstall."
        const val SIGN_OUT_MESSAGE = "Sign-out could not verify that this installation is clear of retained field work. Finish active work and check Sync Status. Unresolved drafts, photos or unreadable records remain protected; synchronising alone may not resolve them. Keep this installation and contact support if this persists."
    }
}

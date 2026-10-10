package com.rork.vinetrack.data.isolation

import java.util.concurrent.locks.ReentrantReadWriteLock

/** All legacy writers, constructor repairs and export snapshot writes must participate before certification. */
internal class FieldHandoverFence(private val expectedParticipants: Set<String>) {
    private val lock = ReentrantReadWriteLock(true)
    private val registered = mutableSetOf<String>()

    @Synchronized fun register(participant: String) {
        require(participant in expectedParticipants)
        registered += participant
    }

    fun <T> legacyOperation(participant: String, action: () -> T): T {
        synchronized(this) { check(participant in registered) { "Unregistered legacy writer" } }
        check(!lock.isWriteLockedByCurrentThread) { "Reentrant mutation during baseline refused" }
        check(lock.readLock().tryLock()) { "Admission closed; retain operation for retry, never wait or discard" }
        try { return action() } finally { lock.readLock().unlock() }
    }

    /** Does not wait for or pause a running field operation. Call again at an independently established idle boundary. */
    fun <T> idleBaseline(activeOrUnresolvedClaim: () -> Boolean, action: () -> T): T? {
        synchronized(this) { check(registered == expectedParticipants) { "Incomplete writer fence coverage" } }
        if (!lock.writeLock().tryLock()) return null
        try {
            if (activeOrUnresolvedClaim()) return null
            return action()
        } finally { lock.writeLock().unlock() }
    }
}

internal sealed interface FieldStartupResult {
    data object DeferredActiveWork : FieldStartupResult
    data object PreservedLocked : FieldStartupResult
    data object RecoveryRequired : FieldStartupResult
}

/** Disabled application composition boundary. Factories are lazy; no constructor, observer or worker is passed eagerly. */
internal class FieldStartupBoundary(
    private val fence: FieldHandoverFence,
    private val vault: RawEvidenceVault,
    private val activeOrUnresolvedClaim: () -> Boolean,
    private val accountStore: AccountEvidenceStore,
) {
    private var ready = false

    @Synchronized fun bootstrap(): FieldStartupResult {
        ready = false
        accountStore.revoke()
        return try {
            fence.idleBaseline(activeOrUnresolvedClaim) { vault.preserve() }?.let {
                ready = true
                FieldStartupResult.PreservedLocked
            } ?: FieldStartupResult.DeferredActiveWork
        } catch (_: Exception) { FieldStartupResult.RecoveryRequired }
    }

    /** Construct only NEW account namespaces. No factory is ever given the raw legacy source context. */
    @Synchronized fun openVerifiedAccount(account: String, vineyards: Set<String>): FieldAccountCapability {
        check(ready) { "Preservation must precede account repository construction" }
        return accountStore.authenticateVerifiedAccount(account, vineyards)
    }

    @Synchronized fun <T> construct(capability: FieldAccountCapability, vineyard: String, factory: () -> T): T {
        check(ready)
        accountStore.metadata(capability, vineyard, "bootstrap-access")
        return factory()
    }

    @Synchronized fun rejectSession() { accountStore.revoke() }
}

package com.rork.vinetrack.data

/** Coalesces only equivalent reads. Never serialises different accounts or vineyards together. */
class ScopedSyncReadGate {
    data class Scope(val owner: String, val identityEpoch: Long, val vineyard: String, val selectionEpoch: Long)
    class Lease internal constructor(val scope: Scope)
    private val active = mutableMapOf<Scope, Lease>()

    @Synchronized fun acquire(scope: Scope): Lease? {
        if (active.containsKey(scope)) return null
        return Lease(scope).also { active[scope] = it }
    }

    @Synchronized fun release(lease: Lease) {
        if (active[lease.scope] === lease) active.remove(lease.scope)
    }
}

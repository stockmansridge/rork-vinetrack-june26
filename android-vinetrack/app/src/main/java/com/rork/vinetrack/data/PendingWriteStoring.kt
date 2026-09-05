package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingWrite

/**
 * Persistence contract for the pending-write outbox.
 *
 * Named separately from [PendingWriteStore] so [PendingWriteRepository] can be built without
 * an Android `Context`. That matters for one reason: the outbox is where a grower's offline
 * edit physically lives, and the rules that decide whether it survives a REVISION_CONFLICT —
 * keep the row, mark it CONFLICT, never replay it — were untestable while the only store
 * needed SharedPreferences. A conflict means the authored value exists on exactly one device,
 * so "we believe it is retained" is not good enough.
 */
interface PendingWriteStoring {
    /** Read all persisted pending writes (empty on first run or parse failure). */
    fun load(): List<PendingWrite>

    /** Persist the full outbox, replacing any previous contents. */
    fun save(writes: List<PendingWrite>): Boolean

    /** Drop the entire outbox. */
    fun clear(): Boolean
}

/**
 * Volatile [PendingWriteStoring] for tests.
 *
 * Deliberately keeps the list in a field rather than no-op'ing, so a test can build a SECOND
 * [PendingWriteRepository] over the same instance and reproduce an app restart — the only
 * honest way to prove a conflicted write is still there after the process is killed.
 */
class InMemoryPendingWriteStore(initial: List<PendingWrite> = emptyList()) : PendingWriteStoring {
    private var writes: List<PendingWrite> = initial

    override fun load(): List<PendingWrite> = writes

    override fun save(writes: List<PendingWrite>): Boolean {
        this.writes = writes
        return true
    }

    override fun clear(): Boolean {
        writes = emptyList()
        return true
    }
}

package com.rork.vinetrack.data

/** Bounded numeric read-traffic evidence; request fingerprints are memory-only and never exported. */
internal class ReadTrafficLedger {
    enum class Dataset { WORK_TASKS, TASK_PADDOCKS, TASK_LABOUR, TASK_MACHINES, TASK_MATERIALS, TRIP_ALLOCATIONS, BLOCKS, PINS, TRIPS, OTHER }
    class Attempt internal constructor(internal val generation: Long, internal val dataset: Dataset) {
        internal var received: Long = 0L
    }
    data class Totals(val attempts: Int = 0, val repeated: Int = 0, val retries: Int = 0, val bodyBytes: Long = 0)
    private var generation = 0L
    private val seen = LinkedHashSet<String>()
    private val counts = mutableMapOf<Dataset, Totals>()
    private var evicted = 0

    @Synchronized fun begin(dataset: Dataset, fingerprint: String, retry: Boolean): Attempt {
        val repeated = fingerprint in seen
        if (!repeated) {
            if (seen.size >= 2000) { seen.remove(seen.first()); evicted++ }
            seen.add(fingerprint)
        }
        val previous = counts[dataset] ?: Totals()
        counts[dataset] = previous.copy(attempts = previous.attempts + 1,
            repeated = previous.repeated + if (repeated) 1 else 0,
            retries = previous.retries + if (retry) 1 else 0)
        return Attempt(generation, dataset)
    }

    /** Progress is cumulative per attempt. Repeated callbacks never double-count bytes. */
    @Synchronized fun received(attempt: Attempt, cumulativeBytes: Long) {
        if (attempt.generation != generation || cumulativeBytes <= attempt.received) return
        val previous = counts[attempt.dataset] ?: return
        counts[attempt.dataset] = previous.copy(bodyBytes = previous.bodyBytes + cumulativeBytes - attempt.received)
        attempt.received = cumulativeBytes
    }
    @Synchronized fun snapshot(): Map<Dataset, Totals> = counts.toMap()
    @Synchronized fun evictedFingerprints(): Int = evicted
    @Synchronized fun clear() { generation++; seen.clear(); counts.clear(); evicted = 0 }
}

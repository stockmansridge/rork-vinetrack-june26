package com.rork.vinetrack.data

/** A bounded read schedule, not an outbox. Same evidence cannot restart polling on every sync pass. */
class ReadOnlyVerificationSchedule<K, E> {
    private val attempted = mutableMapOf<K, E>()
    val delaysMillis: List<Long> = listOf(0L, 5_000L, 30_000L)
    @Synchronized fun claim(key: K, evidence: E): Boolean {
        if (attempted.containsKey(key) && attempted[key] == evidence) return false
        attempted[key] = evidence
        return true
    }
    @Synchronized fun isCurrent(key: K, evidence: E): Boolean = attempted.containsKey(key) && attempted[key] == evidence
}

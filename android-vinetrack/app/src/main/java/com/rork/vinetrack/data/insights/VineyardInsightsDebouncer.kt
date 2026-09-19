package com.rork.vinetrack.data.insights

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Owns cancellable pre-sync timers; started sync work is intentionally independent. */
class VineyardInsightsDebouncer(
    private val scope: CoroutineScope,
    private val delayMillis: Long = 650,
    private val startSync: (String) -> Unit,
) {
    private val jobs = mutableMapOf<String, Job>()
    private var generation: Long = 0

    fun schedule(vineyardId: String) {
        jobs.remove(vineyardId)?.cancel()
        val scheduledGeneration = generation
        jobs[vineyardId] = scope.launch {
            delay(delayMillis)
            if (scheduledGeneration != generation) return@launch
            jobs.remove(vineyardId)
            startSync(vineyardId)
        }
    }

    fun cancelAll() {
        generation += 1
        jobs.values.forEach { it.cancel() }
        jobs.clear()
    }
}

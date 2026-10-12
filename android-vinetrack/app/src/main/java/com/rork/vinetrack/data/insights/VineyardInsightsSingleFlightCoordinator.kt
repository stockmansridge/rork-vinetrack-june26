package com.rork.vinetrack.data.insights

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes full Insights sync passes independently for each vineyard. */
class VineyardInsightsSingleFlightCoordinator {
    private data class State(var isRunning: Boolean = false, var needsAnotherPass: Boolean = false)

    private val mutex = Mutex()
    private val states = mutableMapOf<String, State>()
    private var generation: Long = 0

    suspend fun request(vineyardId: String, runPass: suspend () -> Unit) {
        currentCoroutineContext().ensureActive()
        val requestGeneration: Long
        val ownedState = State(isRunning = true)
        val shouldRun = mutex.withLock {
            requestGeneration = generation
            val state = states.getOrPut(vineyardId) { State() }
            if (state.isRunning) {
                state.needsAnotherPass = true
                false
            } else {
                states[vineyardId] = ownedState
                true
            }
        }
        if (!shouldRun) return

        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                runPass()
                currentCoroutineContext().ensureActive()
                val continueRunning = mutex.withLock {
                    if (requestGeneration != generation) return@withLock false
                    val state = states[vineyardId] ?: return@withLock false
                    if (state.needsAnotherPass) {
                        state.needsAnotherPass = false
                        true
                    } else {
                        states.remove(vineyardId)
                        false
                    }
                }
                if (!continueRunning) return
            }
        } finally {
            // Only release bookkeeping; never finish network/storage work in a cancelled job.
            withContext(NonCancellable) {
                mutex.withLock {
                    if (requestGeneration == generation && states[vineyardId] === ownedState) states.remove(vineyardId)
                }
            }
        }
    }

    /** Invalidates active passes and discards every retained follow-up request. */
    suspend fun invalidateAll() {
        mutex.withLock {
            generation += 1
            states.clear()
        }
    }
}

package com.rork.vinetrack.data.insights

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes full Insights sync passes independently for each vineyard. */
class VineyardInsightsSingleFlightCoordinator {
    private data class State(var isRunning: Boolean = false, var needsAnotherPass: Boolean = false)

    private val mutex = Mutex()
    private val states = mutableMapOf<String, State>()
    private var generation: Long = 0

    suspend fun request(vineyardId: String, runPass: suspend () -> Unit) {
        val requestGeneration: Long
        val shouldRun = mutex.withLock {
            requestGeneration = generation
            val state = states.getOrPut(vineyardId) { State() }
            if (state.isRunning) {
                state.needsAnotherPass = true
                false
            } else {
                state.isRunning = true
                true
            }
        }
        if (!shouldRun) return

        while (true) {
            val failure = runCatching { runPass() }.exceptionOrNull()
            val continueRunning = mutex.withLock {
                if (requestGeneration != generation) return@withLock false
                val state = states[vineyardId] ?: return@withLock false
                if (state.needsAnotherPass) {
                    state.needsAnotherPass = false
                    true
                } else {
                    state.isRunning = false
                    states.remove(vineyardId)
                    false
                }
            }
            if (!continueRunning) {
                if (failure != null) throw failure
                return
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

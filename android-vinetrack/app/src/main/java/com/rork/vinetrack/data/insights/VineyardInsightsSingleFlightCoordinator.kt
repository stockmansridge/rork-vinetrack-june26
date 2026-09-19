package com.rork.vinetrack.data.insights

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes full Insights sync passes independently for each vineyard. */
class VineyardInsightsSingleFlightCoordinator {
    private data class State(var isRunning: Boolean = false, var needsAnotherPass: Boolean = false)

    private val mutex = Mutex()
    private val states = mutableMapOf<String, State>()

    suspend fun request(vineyardId: String, runPass: suspend () -> Unit) {
        val shouldRun = mutex.withLock {
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
                val state = states.getValue(vineyardId)
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
}

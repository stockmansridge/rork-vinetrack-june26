package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SeasonYieldOverview

/**
 * Thin coordinator for the canonical seasonal yield estimate (sql/221).
 *
 * Lives outside `AppViewModel` deliberately: that file is ~13.7k lines and the
 * module compiles Kotlin in-process on a fixed 4 GB heap, so growing it is what
 * tips `compileReleaseKotlin` into GC thrash. Keeping the try/catch here leaves
 * the ViewModel with a few lines of state plumbing.
 *
 * Nothing here touches UI state — it returns outcomes and lets the caller
 * decide what to show.
 */
class SeasonYieldController(session: SessionStore) {

    private val repository = SeasonYieldRepository(session)

    /** What the caller must do with the result. */
    sealed interface Outcome {
        data class Loaded(val overview: SeasonYieldOverview) : Outcome
        /** The session is gone — the caller signs out. */
        data object Unauthorized : Outcome
        /** Transient: keep whatever is on screen and show [message]. */
        data class Failed(val message: String) : Outcome
    }

    private companion object {
        const val LOAD_FAILED =
            "Couldn't load the seasonal yield estimate. Check your connection and try again."
        const val REFRESH_FAILED =
            "Couldn't update the seasonal yield estimate. Your settings were saved — pull to refresh to try again."
    }

    /** Fetch the canonical BASE overview for one vineyard + vintage. */
    suspend fun load(vineyardId: String, vintage: Int): Outcome = runOutcome(LOAD_FAILED) {
        repository.fetchOverview(vineyardId, vintage)
    }

    /**
     * Re-derive the vintage's pruning estimates server-side, then re-read the
     * overview. Never downgrades a bunch_count or manual estimate — the server
     * skips those rows.
     */
    suspend fun refreshAfterPruningSave(vineyardId: String, vintage: Int): Outcome =
        runOutcome(REFRESH_FAILED) {
            repository.refreshPruningEstimates(vineyardId, vintage)
            repository.fetchOverview(vineyardId, vintage)
        }

    private suspend fun runOutcome(
        failureMessage: String,
        block: suspend () -> SeasonYieldOverview,
    ): Outcome = try {
        Outcome.Loaded(block())
    } catch (e: BackendError.Unauthorized) {
        Outcome.Unauthorized
    } catch (e: Exception) {
        Outcome.Failed(failureMessage)
    }
}

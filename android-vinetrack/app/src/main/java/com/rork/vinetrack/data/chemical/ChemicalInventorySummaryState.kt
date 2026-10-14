package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Screen-local, single-worker read cache. All callers run on the owning UI dispatcher. */
internal class ChemicalInventorySummaryState(
    private val coroutineScope: CoroutineScope,
    private val fetch: suspend (String) -> CatalogueRow,
) {
    data class Snapshot(val scope: String? = null, val summaries: Map<String, CatalogueRow> = emptyMap(), val loading: Boolean = false, val error: String? = null)
    private val mutable = MutableStateFlow(Snapshot())
    val state = mutable.asStateFlow()
    private var scope: String? = null
    private var chemicals: Map<String, SavedChemical> = emptyMap()
    private val pending = linkedSetOf<String>()
    private val revisions = mutableMapOf<String, Int>()
    private var generation = 0
    private var worker: Job? = null

    fun update(scope: String?, rows: List<SavedChemical>, force: Set<String> = emptySet()) {
        if (this.scope != scope) {
            generation++
            this.scope = scope
            chemicals = emptyMap(); pending.clear(); revisions.clear()
            mutable.value = Snapshot(scope = scope, loading = worker?.isActive == true)
        }
        val incoming = if (scope == null) emptyMap() else ChemicalStorePresentation.active(rows).associateBy { it.id }
        val changed = incoming.keys.filter { incoming[it] != chemicals[it] }.toSet() + force.intersect(incoming.keys)
        chemicals = incoming
        mutable.value = mutable.value.copy(summaries = mutable.value.summaries.filterKeys { it in incoming && it !in changed })
        pending.retainAll(incoming.keys)
        changed.forEach { revisions[it] = (revisions[it] ?: 0) + 1; pending.add(it) }
        if (worker?.isActive == true || pending.isEmpty()) return
        mutable.value = mutable.value.copy(loading = true)
        worker = coroutineScope.launch {
            try {
                while (pending.isNotEmpty()) {
                    val id = pending.first().also { pending.remove(it) }
                    val capturedGeneration = generation
                    val revision = revisions[id]
                    try {
                        val row = fetch(id)
                        if (generation == capturedGeneration && revisions[id] == revision && id in chemicals) {
                            mutable.value = mutable.value.copy(summaries = mutable.value.summaries + (id to row))
                        }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) {
                        if (generation == capturedGeneration && revisions[id] == revision && id in chemicals) {
                            mutable.value = mutable.value.copy(error = "Unable to load inventory. Check access and try again.")
                        }
                    }
                }
            } finally { mutable.value = mutable.value.copy(loading = false) }
        }
    }

    suspend fun waitForRefresh() { worker?.join() }

    fun retry() {
        mutable.value = mutable.value.copy(error = null)
        update(scope, chemicals.values.toList(), chemicals.keys)
    }
}

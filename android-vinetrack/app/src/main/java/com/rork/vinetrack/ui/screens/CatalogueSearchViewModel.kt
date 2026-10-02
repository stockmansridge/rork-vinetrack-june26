package com.rork.vinetrack.ui.screens

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.*

data class CatalogueSearchState(val query: String = "", val matches: List<CatalogueRow> = emptyList(), val result: CatalogueRow? = null,
    val job: CatalogueRow? = null, val context: CatalogueDiscoveryContext? = null, val busy: Boolean = false, val searched: Boolean = false, val error: String? = null)

class CatalogueSearchViewModel(app: Application) : AndroidViewModel(app) {
    private val repository = CatalogueRepository(app)
    private val prefs = app.getSharedPreferences("chemical_catalogue_discovery", 0)
    private val _state = MutableStateFlow(CatalogueSearchState())
    val state = _state.asStateFlow()
    private var pollJob: Job? = null
    private fun key(vineyard: String) = "${repository.userId}:$vineyard"
    fun query(value: String) { _state.update { it.copy(query = value) } }
    fun restore(vineyard: String) {
        if (runCatching { repository.userId }.isFailure) return
        if (_state.value.context == null) {
            val restored = prefs.getString(key(vineyard), null)?.let { runCatching { SupabaseClient.json.decodeFromString<CatalogueDiscoveryContext>(it) }.getOrNull() }
            val result = if (restored == null) prefs.getString("result:${key(vineyard)}", null)?.let {
                runCatching { CatalogueRow(SupabaseClient.json.parseToJsonElement(it).jsonObject) }.getOrNull()
            } else null
            _state.update { it.copy(context = restored, query = restored?.query ?: it.query, result = result) }
        }
        if (_state.value.context != null) poll()
    }
    fun search(country: String) {
        if (_state.value.busy || _state.value.context != null) return
        val query = _state.value.query
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, result = null, searched = false) }
            try { val rows = repository.search(query, country); _state.update { it.copy(matches = rows, searched = true) } }
            catch (_: Exception) { _state.update { it.copy(error = "Catalogue search is unavailable. Try again.") } }
            finally { _state.update { it.copy(busy = false) } }
        }
    }
    fun select(row: CatalogueRow) {
        if (_state.value.context != null) return
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null) }
            try { val result = repository.revision(requireNotNull(row.text("revision_id"))); _state.update { it.copy(result = result) } }
            catch (_: Exception) { _state.update { it.copy(error = "Unable to load this result. Try again.") } }
            finally { _state.update { it.copy(busy = false) } }
        }
    }
    fun discover(vineyard: String, country: String, photo: ByteArray? = null) {
        if (_state.value.busy) return
        if (_state.value.context != null) { poll(); return }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null) }
            try {
                val path = photo?.let { repository.upload(it) }
                val kind = if (photo == null) "text" else "photo"
                val query = _state.value.query
                val row = repository.rows(repository.rpc("start_chemical_v3_discovery", buildJsonObject {
                    put("p_query", query.takeIf { it.isNotBlank() }?.let(::JsonPrimitive) ?: JsonNull)
                    put("p_country_code", country.takeIf { it.isNotBlank() }?.let(::JsonPrimitive) ?: JsonNull)
                    put("p_input_kind", kind); put("p_photo_path", path?.let(::JsonPrimitive) ?: JsonNull)
                })).single()
                val saved = CatalogueDiscoveryContext(requireNotNull(row.text("job_id")), repository.userId, vineyard, query, country, kind, path, System.currentTimeMillis())
                check(prefs.edit().putString(key(vineyard), SupabaseClient.json.encodeToString(saved)).commit())
                _state.update { it.copy(context = saved) }
                if (!row.isTerminal) {
                    try { repository.invoke(saved.jobId) } catch (_: Exception) { _state.update { it.copy(error = "Discovery is saved. Resume to check progress.") } }
                }
                poll()
            } catch (_: Exception) { _state.update { it.copy(error = "Unable to start discovery. Check your connection and try again.") } }
            finally { _state.update { it.copy(busy = false) } }
        }
    }
    fun poll() {
        val context = _state.value.context ?: return
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            var invokedQueued = false
            repeat(150) {
                try {
                    val job = repository.job(context.jobId); _state.update { it.copy(job = job) }
                    if (job.text("status") == "queued" && !invokedQueued) { invokedQueued = true; repository.invoke(context.jobId) }
                    if (job.isTerminal) {
                        if (job.isSuccess) {
                            val result = CatalogueTerminalResolver.result(job, repository::revision)
                            check(prefs.edit().putString("result:${key(context.vineyardId)}", result.fields.toString()).commit())
                            _state.update { it.copy(result = result) }
                        } else _state.update { it.copy(error = "Discovery could not finish. You can search again.") }
                        prefs.edit().remove(key(context.vineyardId)).commit()
                        _state.update { it.copy(context = null) }; return@launch
                    }
                    delay(2000)
                } catch (_: Exception) { _state.update { it.copy(error = "Discovery is saved. Resume when connected to retrieve the result.") }; return@launch }
            }
            _state.update { it.copy(error = "Discovery is still running. Resume to check the same job.") }
        }
    }
    fun add(vineyard: String, onSaved: (SavedChemical) -> Unit) {
        val result = _state.value.result ?: return
        viewModelScope.launch {
            _state.update { it.copy(busy = true) }
            try { onSaved(repository.add(result.id, vineyard)) }
            catch (_: Exception) { _state.update { it.copy(error = "Unable to add this result. Check permissions and try again.") } }
            finally { _state.update { it.copy(busy = false) } }
        }
    }
}

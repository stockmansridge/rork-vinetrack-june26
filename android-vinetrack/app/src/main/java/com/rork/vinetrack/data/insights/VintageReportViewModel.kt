package com.rork.vinetrack.data.insights

import android.content.Context
import android.util.AtomicFile
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID

/** Durable exact-operation recovery; loading, refresh and export never initiate generation. */
class VintageReportViewModel(
    context: Context, private val account: String, private val vineyard: String, private val vintage: Int,
    private val canAccess: () -> Boolean,
) : ViewModel() {
    private val session = SessionStore(context.applicationContext)
    private val codec = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = true }
    private val file = AtomicFile(File(context.filesDir, "vintage-reports/$account/$vineyard/$vintage.json"))
    private var cacheUnreadable: Boolean = false
    private var selectedThrough: String? = null
    private val _ui = MutableStateFlow(VintageReportUiState())
    val ui: StateFlow<VintageReportUiState> = _ui.asStateFlow()
    private fun scoped(): Boolean = session.userId == account && canAccess()
    init {
        if (scoped()) {
            try {
                val cached = try {
                    codec.decodeFromString<VintageReportCache>(file.openRead().bufferedReader().use { it.readText() })
                } catch (missing: java.io.FileNotFoundException) {
                    if (file.baseFile.exists() || File("${file.baseFile.path}.bak").exists()) throw missing
                    VintageReportCache()
                }
                _ui.value = VintageReportUiState(cache = cached)
                refresh()
            } catch (_: Exception) {
                cacheUnreadable = true
                _ui.value = VintageReportUiState(message = "Saved cache is unreadable and has been preserved. Use Refresh to recover server requests before any new generation.")
            }
        }
    }
    private suspend fun persist(cache: VintageReportCache) = withContext(Dispatchers.IO) {
        check(scoped())
        check(file.baseFile.parentFile?.mkdirs() == true || file.baseFile.parentFile?.isDirectory == true)
        val stream = file.startWrite()
        try { stream.write(codec.encodeToString(cache).toByteArray()); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
    }
    private suspend fun transport(path: String, body: JsonObject): String {
        check(scoped())
        val token = session.accessToken ?: error("No session")
        val response = SupabaseClient.http.post("${SupabaseClient.baseUrl}$path") {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json); setBody(body.toString())
        }
        check(scoped())
        check(response.status.isSuccess()) { "Report server request failed" }
        return response.bodyAsText()
    }
    private fun params(command: String, operation: String? = null, expected: String? = null, through: String? = null, narrative: String? = null, offset: Int = 0, beforeRevision: Int? = null) = buildJsonObject {
        put("p_author_id", account); put("p_command", command); put("p_vineyard_id", vineyard); put("p_vintage", vintage)
        put("p_operation_id", operation?.let(::JsonPrimitive) ?: JsonNull)
        put("p_expected_revision_id", expected?.let(::JsonPrimitive) ?: JsonNull)
        put("p_report_through", through?.let(::JsonPrimitive) ?: JsonNull)
        put("p_content", narrative?.let { buildJsonObject { put("narrative", it) } } ?: JsonNull)
        put("p_offset", offset); put("p_before_revision", beforeRevision?.let(::JsonPrimitive) ?: JsonNull)
    }
    private suspend inline fun <reified T> command(params: JsonObject): T = codec.decodeFromString(transport("/rest/v1/rpc/vintage_report_command", params))
    private suspend fun load() {
        var offset = 0
        val rows = mutableListOf<VintageReportRevision>()
        var pointer: String? = null
        var beforeRevision: Int? = null
        var serverRequest: VintageReportRequest? = null
        while (true) {
            val result: VintageReportRead = command(params("read", beforeRevision = beforeRevision))
            if (offset == 0) { pointer = result.report?.current_revision_id; serverRequest = result.requests.firstOrNull() }
            rows += result.revisions; offset += result.revisions.size
            beforeRevision = result.revisions.lastOrNull()?.revision
            if (result.revisions.size < 20) break
        }
        val previous = _ui.value.cache
        val coverage: VintageReportCoverage = command(params("coverage", through = selectedThrough))
        check(scoped())
        val recoverable = serverRequest?.input?.let { input -> VintageReportCommand(input.action, requireNotNull(serverRequest).operation_id, input.expected, input.through, input.content?.narrative) }
        val cache = previous.copy(revisions = rows, currentID = pointer, coverage = coverage,
            pending = previous.pending ?: recoverable, request = previous.request ?: serverRequest)
        if (cacheUnreadable && file.baseFile.exists()) withContext(Dispatchers.IO) {
            file.baseFile.copyTo(File(file.baseFile.parentFile, "${file.baseFile.name}.unreadable-${System.currentTimeMillis()}"))
        }
        persist(cache); cacheUnreadable = false; _ui.value = _ui.value.copy(cache = cache)
    }
    fun refresh() = work { load() }
    fun updateThrough(through: String) = work {
        check(!cacheUnreadable)
        val coverage: VintageReportCoverage = command(params("coverage", through = through))
        selectedThrough = coverage.report_through
        val cache = _ui.value.cache.copy(coverage = coverage); persist(cache); _ui.value = _ui.value.copy(cache = cache)
    }
    private fun work(block: suspend () -> Unit) {
        if (_ui.value.busy || !scoped()) return
        _ui.value = _ui.value.copy(busy = true, message = null)
        viewModelScope.launch {
            try { block() }
            catch (_: Exception) { if (scoped()) _ui.value = _ui.value.copy(message = "Server request unavailable or uncertain. Keep downloaded reports and recover the same request; do not create a replacement.") }
            finally { _ui.value = _ui.value.copy(busy = false) }
        }
    }
    fun submit(action: String, through: String, narrative: String? = null, editingRevisionID: String? = null) = work {
        check(!cacheUnreadable && _ui.value.cache.pending == null)
        require(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}").matches(through)) { "Use YYYY-MM-DD" }
        if (action == "edit" && (editingRevisionID == null || editingRevisionID != _ui.value.cache.currentID)) {
            _ui.value = _ui.value.copy(message = "The current report changed since this draft was opened. Your wording is retained; review the newer revision before starting a new edit. Nothing was sent.")
            return@work
        }
        selectedThrough = through
        val intent = VintageReportCommand(action, UUID.randomUUID().toString(), if (action == "edit") editingRevisionID else _ui.value.cache.currentID, through, narrative)
        val cache = _ui.value.cache.copy(pending = intent, request = null)
        persist(cache); _ui.value = _ui.value.copy(cache = cache)
        recoverRequest(intent)
    }
    fun recover() = work { _ui.value.cache.pending?.let { recoverRequest(it) } }
    private suspend fun recoverRequest(intent: VintageReportCommand) {
        var request: VintageReportRequest = command(params(intent.action, intent.operation, intent.expected, intent.through, intent.narrative))
        var cache = _ui.value.cache.copy(request = request); persist(cache); _ui.value = _ui.value.copy(cache = cache)
        if (intent.action != "edit" && request.status in listOf("queued", "running", "failed")) {
            request = codec.decodeFromString(transport("/functions/v1/vintage-report", buildJsonObject {
                put("operation_id", intent.operation); put("action", if (request.status == "queued") "execute" else "status")
            }))
            cache = _ui.value.cache.copy(request = request); persist(cache); _ui.value = _ui.value.copy(cache = cache)
        }
        load()
        _ui.value = _ui.value.copy(message = when (request.status) {
            "unchanged" -> "No new information to add"
            "failed" -> "Request failed: ${request.error_code}. Previous report retained. No automatic paid retry."
            else -> "Request ${request.status}"
        })
    }
    fun acknowledge() = work {
        check(_ui.value.cache.request?.status in listOf("succeeded", "failed", "unchanged"))
        val cache = _ui.value.cache.copy(pending = null, request = null)
        persist(cache); _ui.value = _ui.value.copy(cache = cache)
    }
    fun abandon() = work {
        val intent = _ui.value.cache.pending ?: return@work
        val input = buildJsonObject {
            put("action", intent.action); put("through", intent.through)
            put("expected", intent.expected?.let(::JsonPrimitive) ?: JsonNull)
            put("content", intent.narrative?.let { buildJsonObject { put("narrative", it) } } ?: JsonNull)
        }
        val request = codec.decodeFromString<VintageReportRequest>(transport("/rest/v1/rpc/vintage_report_abandon", buildJsonObject {
            put("p_author_id", account); put("p_vineyard_id", vineyard); put("p_vintage", vintage); put("p_operation_id", intent.operation); put("p_input", input)
        }))
        val cache = _ui.value.cache.copy(request = request); persist(cache); _ui.value = _ui.value.copy(cache = cache,
            message = if (request.status == "running") "Already running. Recover its status; do not replace this paid call." else "Cancellation receipt saved. Acknowledge the result to start a corrected request.")
    }
    fun activate(revision: VintageReportRevision) = work {
        val saved: VintageReportRevision = command(params("activate", revision.operation_id, _ui.value.cache.pending?.expected ?: _ui.value.cache.currentID))
        val cache = _ui.value.cache.copy(currentID = saved.id); persist(cache); _ui.value = _ui.value.copy(cache = cache)
    }
}

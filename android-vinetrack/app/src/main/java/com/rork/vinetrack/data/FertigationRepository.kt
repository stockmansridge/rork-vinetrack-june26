package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

class FertigationPermanentFailure : Exception("Fertigation was rejected. Check vineyard access and the Program Step, then retry.")

/** Canonical SQL 266 RPC boundary, gated before every Fertigation request. */
class FertigationRepository(
    private val adminCheck: suspend () -> Boolean,
    private val transport: suspend (String, JsonObject) -> String,
) {
    constructor(session: SessionStore, expectedOwnerId: String? = null) : this(
        adminCheck = {
            check(expectedOwnerId == null || session.userId == expectedOwnerId) { "Account changed." }
            val allowed = SystemAdminRepository(session).isSystemAdmin()
            check(expectedOwnerId == null || session.userId == expectedOwnerId) { "Account changed." }
            allowed
        },
        transport = { name, params ->
            withContext(Dispatchers.IO) {
                if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
                val token = session.accessToken ?: throw BackendError.Unauthorized
                val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
                    headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
                    contentType(ContentType.Application.Json)
                    setBody(params)
                }
                when {
                    response.status.isSuccess() -> response.bodyAsText()
                    response.status.value == 401 -> throw BackendError.Unauthorized
                    response.status.value in listOf(400, 403, 404, 409, 422) -> throw FertigationPermanentFailure()
                    else -> throw IllegalStateException("Couldn't complete Fertigation. Please try again.")
                }
            }
        },
    )
    private val json = Json { ignoreUnknownKeys = true }
    private suspend fun call(name: String, params: JsonObject): JsonElement {
        check(adminCheck()) { "System Admin required." }
        return json.parseToJsonElement(transport(name, params))
    }
    suspend fun capabilities(vineyardId: String): JsonObject = call("get_fertigation_capabilities", buildJsonObject {
        put("p_vineyard_id", vineyardId)
    }).jsonObject
    suspend fun programSteps(vineyardId: String): List<JsonObject> = call("list_fertigation_program_steps", buildJsonObject {
        put("p_vineyard_id", vineyardId)
    }).jsonArray.map { it.jsonObject }.filter { FertigationDomain.isSelectable(it, vineyardId, true) }
    suspend fun sessionApplication(vineyardId: String, sessionId: String): JsonObject? = call("get_irrigation_session_fertigation", buildJsonObject {
        put("p_vineyard_id", vineyardId); put("p_irrigation_session_id", sessionId)
    }).let { if (it == JsonNull) null else it.jsonObject }
    suspend fun applications(vineyardId: String, vintageYear: Int? = null, programStepId: String? = null, includeReversed: Boolean = false): List<JsonObject> =
        call("list_fertigation_applications", buildJsonObject {
            put("p_vineyard_id", vineyardId)
            put("p_vintage_year", vintageYear?.let(::JsonPrimitive) ?: JsonNull)
            put("p_program_step_id", programStepId?.let(::JsonPrimitive) ?: JsonNull)
            put("p_include_reversed", includeReversed)
        }).jsonArray.map { it.jsonObject }
    /** One scoped list request; no RPC per irrigation row. */
    suspend fun historyIndex(vineyardId: String, vintageYear: Int? = null, isSystemAdmin: Boolean): Map<String, JsonObject> {
        if (!isSystemAdmin) return emptyMap()
        return FertigationHistory.index(applications(vineyardId, vintageYear, includeReversed = true), true)
    }
    suspend fun historicalSession(vineyardId: String, sessionId: String, vintageYear: Int, isSystemAdmin: Boolean): JsonObject? {
        if (!isSystemAdmin) return null
        return sessionApplication(vineyardId, sessionId) ?: historyIndex(vineyardId, vintageYear, true)[sessionId.lowercase()]
    }
    suspend fun upsert(id: String, vineyardId: String, sessionId: String, stepId: String, frozenName: String?, growthStageCode: String?, notes: String?, products: List<JsonObject>): JsonObject =
        call("upsert_fertigation_application", buildJsonObject {
            put("p_id", id); put("p_vineyard_id", vineyardId); put("p_irrigation_session_id", sessionId); put("p_program_step_id", stepId)
            put("p_program_step_name", frozenName?.let(::JsonPrimitive) ?: JsonNull)
            put("p_growth_stage_code", growthStageCode?.let(::JsonPrimitive) ?: JsonNull)
            put("p_notes", notes?.let(::JsonPrimitive) ?: JsonNull)
            put("p_products", JsonArray(products))
        }).jsonObject
    suspend fun reverse(id: String, reason: String?): JsonObject = call("reverse_fertigation_application", buildJsonObject {
        put("p_id", id); put("p_reason", reason?.let(::JsonPrimitive) ?: JsonNull)
    }).jsonObject
}

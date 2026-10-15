package com.rork.vinetrack.data.spray

import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Request
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Scope
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Receipt
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Failure
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Code

/** Test transports implement the same status-preserving boundary as native HTTP. */
interface SprayPlanningTransport {
    data class Response(val status: Int, val body: String)
    suspend fun call(rpc: String, body: String): Response
}

/** No production caller is wired while the independent planning operational gate remains closed. */
class SprayPlanningClient(private val journal: SprayPlanningAttemptJournal,
    private val transport: SprayPlanningTransport, private val currentScope: () -> Scope) {
    private val lock = Mutex()
    private val json = Json { encodeDefaults = true; explicitNulls = true }
    suspend fun recover() {
        if (!lock.tryLock()) throw Failure(Code.CONFLICT)
        try {
            val scope = currentScope(); val pending = journal.pending(scope)
            if (pending.isEmpty()) return
            val body = buildJsonObject {
                put("p_vineyard_id", scope.vineyardId)
                put("p_operation_ids", JsonArray(pending.map { JsonPrimitive(it.request.operationId) }))
                put("p_record_ids", JsonArray(pending.map { it.request.snapshot.recordId }.distinct().sorted().map(::JsonPrimitive)))
                put("p_trip_ids", JsonArray(pending.mapNotNull { it.request.snapshot.tripId }.distinct().sorted().map(::JsonPrimitive)))
            }
            val response = transport.call("get_spray_planning_recovery_v1", body.toString())
            journal.pending(currentScope())
            if (response.status != 200) throw Failure(Code.UNAVAILABLE)
            val recovery = json.decodeFromString<SprayPlanningProtocol.Recovery>(response.body)
            SprayPlanningProtocol.check(recovery.contract == SprayPlanningProtocol.CONTRACT && recovery.schemaVersion == 1 &&
                recovery.actorId == scope.actorId && recovery.vineyardId == scope.vineyardId &&
                recovery.receipts.map { it.operationId }.distinct().size == recovery.receipts.size, Code.INVALID_RECEIPT)
            val rawReceipts = json.parseToJsonElement(response.body).jsonObject["receipts"]?.jsonArray ?: throw Failure(Code.INVALID_RECEIPT)
            rawReceipts.forEach { raw ->
                val id = raw.jsonObject["operationId"]?.jsonPrimitive?.content
                val original = pending.firstOrNull { it.request.operationId == id }?.request ?: throw Failure(Code.INVALID_RECEIPT)
                journal.accept(verifiedReceipt(raw, original), currentScope())
            }
            // Missing receipt is unknown, not proof of failure. Current mutable state never acknowledges an intent.
        } finally { lock.unlock() }
    }
    suspend fun send(r: Request) {
        if (!lock.tryLock()) throw Failure(Code.CONFLICT)
        try {
            val scope = currentScope(); journal.prepare(r, scope)
            val c = transport.call("get_spray_planning_capability_v1", buildJsonObject { put("p_vineyard_id", scope.vineyardId) }.toString())
            journal.pending(currentScope())
            val capability = if (c.status == 200) runCatching { json.decodeFromString<SprayPlanningProtocol.Capability>(c.body) }.getOrNull() else null
            if (capability?.supports(r) != true) throw Failure(Code.UNAVAILABLE)
            journal.markSent(r.operationId, currentScope())
            val body = buildJsonObject { put("p_operation_id", r.operationId); put("p_request", json.encodeToJsonElement(r)) }
            val response = transport.call(r.kind.rpc, body.toString())
            journal.pending(currentScope())
            if (response.status == 409) {
                journal.hold(r.operationId, currentScope(), "http_409"); throw Failure(Code.CONFLICT)
            }
            if (response.status !in 200..299) throw Failure(Code.UNAVAILABLE)
            try { journal.accept(verifiedReceipt(json.parseToJsonElement(response.body), r), currentScope()) }
            catch (e: Exception) { journal.hold(r.operationId, currentScope(), "unverified_receipt"); throw e }
        } finally { lock.unlock() }
    }
    private fun verifiedReceipt(raw: JsonElement, request: Request): Receipt {
        val original = json.encodeToJsonElement(request).jsonObject
        SprayPlanningProtocol.check(equivalent(raw.jsonObject["request"], original) &&
            equivalent(raw.jsonObject["result"]?.jsonObject?.get("snapshot"), original["snapshot"]), Code.INVALID_RECEIPT)
        return json.decodeFromJsonElement<Receipt>(raw).also { SprayPlanningProtocol.verify(it, request) }
    }
    /** JSONB number formatting may differ; key presence, nulls, strings and array order may not. */
    private fun equivalent(a: JsonElement?, b: JsonElement?): Boolean {
        if (a == null || b == null) return a == b
        if (a is JsonObject && b is JsonObject) return a.keys == b.keys && a.keys.all { equivalent(a[it], b[it]) }
        if (a is JsonArray && b is JsonArray) return a.size == b.size && a.indices.all { equivalent(a[it], b[it]) }
        if (a is JsonPrimitive && b is JsonPrimitive && !a.isString && !b.isString && a != JsonNull && b != JsonNull) {
            val x = a.content.toBigDecimalOrNull(); val y = b.content.toBigDecimalOrNull()
            if (x != null && y != null) return x.compareTo(y) == 0
        }
        return a == b
    }
}

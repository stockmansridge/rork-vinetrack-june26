package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import com.rork.vinetrack.data.model.textOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.UUID

/** One atomic account/vineyard/trip-scoped document contains base, intents and Undo evidence. */
class TripOccurrenceJournal(private val storage: Storage, private val scope: Scope) {
    interface Storage { fun read(): String?; fun commit(value: String): Boolean }
    @Serializable data class Scope(val ownerId: String, val vineyardId: String, val tripId: String)
    @Serializable data class Operation(val id: String, val action: JsonObject, val before: JsonObject,
                                       val after: JsonObject, val params: JsonObject)
    @Serializable data class Snapshot(val scope: Scope, val acknowledged: JsonObject,
                                      val pending: List<Operation> = emptyList(),
                                      val history: List<Operation> = emptyList(), val heldReason: String? = null)
    private val json = Json { encodeDefaults = true }

    @Synchronized fun load(): Snapshot? = storage.read()?.let {
        json.decodeFromString<Snapshot>(it).also { state ->
            check(state.scope == scope) { "Occurrence journal belongs to a different account, vineyard or trip." }
            TripOccurrenceCoverage.requireDocument(state.acknowledged)
            state.pending.forEach { op -> TripOccurrenceCoverage.requireDocument(op.after) }
        }
    }
    @Synchronized fun initialize(coverage: JsonObject) {
        TripOccurrenceCoverage.requireDocument(coverage)
        check(load() == null) { "Occurrence journal already exists; identities were retained." }
        save(Snapshot(scope, coverage))
    }
    fun projected(state: Snapshot): JsonObject = state.pending.lastOrNull()?.after ?: state.acknowledged
    fun targetId(): String? = load()?.let { TripOccurrenceCoverage.requireDocument(projected(it)).targetId }
    fun undoTarget(): Operation? = load()?.let { state ->
        val d = TripOccurrenceCoverage.requireDocument(projected(state))
        state.history.asReversed().firstOrNull { op ->
            val id = op.action["occurrenceId"].textOrNull()
            op.action["kind"].textOrNull() in listOf("setStatus", "undo") && id in d.order &&
                d.state(id!!)["lastOperationId"].textOrNull() == op.id
        }
    }
    @Synchronized fun setStatus(id: String, status: String, tankSessionIds: List<String> = emptyList(), source: String = "manual"): Operation {
        require(status in listOf("incomplete", "done", "skipped"))
        require(source in listOf("manual", "correction", "endReview")) // GPS intentionally not enabled.
        return append { d -> buildJsonObject {
            put("kind", "setStatus"); put("planId", d.planId); put("occurrenceId", id)
            put("blockId", d.items.single { it.id == id }.blockId)
            put("expectedBeforeState", d.state(id)); put("toStatus", status); put("source", source)
            put("tankSessionIds", JsonArray(tankSessionIds.map(::JsonPrimitive)))
        } }
    }
    @Synchronized fun select(id: String): Operation = append { d -> buildJsonObject {
        put("kind", "selectOccurrence"); put("planId", d.planId); put("occurrenceId", id)
        put("blockId", d.items.single { it.id == id }.blockId)
    } }
    @Synchronized fun reorder(order: List<String>): Operation = append { d ->
        require(order.size == d.order.size && order.toSet() == d.order.toSet())
        buildJsonObject {
            put("kind", "editPlan"); put("planId", d.planId); put("items", d.raw.getValue("items"))
            put("activeOrder", JsonArray(order.map(::JsonPrimitive))); put("retired", d.raw.getValue("retired"))
        }
    }
    @Synchronized fun undo(operationId: String): Operation {
        val state = load() ?: error("Occurrence journal missing.")
        val previous = state.history.single { it.id == operationId }
        val id = previous.action.getValue("occurrenceId").jsonPrimitive.content
        return append { d ->
            require(d.state(id)["lastOperationId"].textOrNull() == operationId) { "Undo needs reconciliation; this occurrence has a newer action." }
            buildJsonObject {
                put("kind", "undo"); put("planId", d.planId); put("occurrenceId", id)
                put("blockId", d.items.single { it.id == id }.blockId); put("undoOfOperationId", operationId)
            }
        }
    }
    private fun append(actionBuilder: (TripOccurrenceCoverage.Document) -> JsonObject): Operation {
        val state = load() ?: error("Occurrence journal missing.")
        check(state.heldReason == null) { state.heldReason ?: "Reconciliation required." }
        val before = projected(state)
        val d = TripOccurrenceCoverage.requireDocument(before)
        val action = actionBuilder(d)
        val id = UUID.randomUUID().toString()
        val after = reduce(d, action, id, state.history)
        val params = buildJsonObject {
            put("p_operation_id", id); put("p_trip_id", scope.tripId)
            put("p_expected_revision", d.revision); put("p_expected_plan_revision", d.planRevision); put("p_action", action)
        }
        val op = Operation(id, action, before, after, params)
        save(state.copy(pending = state.pending + op, history = state.history + op))
        return op
    }
    /** Only the exact head acknowledgement clears work; delayed duplicates never replace newer state. */
    @Synchronized fun acknowledge(result: JsonObject) {
        val state = load() ?: error("Occurrence journal missing.")
        require(result["tripId"].textOrNull() == scope.tripId)
        val id = result["operationId"].textOrNull()
        val op = state.pending.firstOrNull() ?: return
        if (id != op.id) return
        val coverage = result.getValue("coverage").jsonObject
        TripOccurrenceCoverage.requireDocument(coverage)
        if (coverage != op.after) {
            save(state.copy(heldReason = "The accepted action differs from local evidence. Coverage retained for reconciliation.")); return
        }
        save(state.copy(acknowledged = coverage, pending = state.pending.drop(1)))
    }
    @Synchronized fun reconcile(remote: JsonObject) {
        val state = load() ?: error("Occurrence journal missing.")
        val incoming = TripOccurrenceCoverage.requireDocument(remote)
        val base = TripOccurrenceCoverage.requireDocument(state.acknowledged)
        require(incoming.planId == base.planId)
        if (incoming.revision < base.revision) return
        if (remote == state.acknowledged) return
        if (state.pending.isNotEmpty() || incoming.revision == base.revision) {
            save(state.copy(heldReason = "Another update needs review. Pending occurrence actions have been retained."))
        } else save(state.copy(acknowledged = remote))
    }
    @Synchronized fun hold(code: String) {
        val state = load() ?: error("Occurrence journal missing.")
        save(state.copy(heldReason = if (code.contains("UPDATE_REQUIRED") || code.contains("UNSUPPORTED"))
            "Update required. This trip cannot use numeric coverage; saved occurrence work is retained."
            else "Occurrence sync needs reconciliation ($code). Saved actions are retained."))
    }
    private fun save(state: Snapshot) {
        check(storage.commit(json.encodeToString(Snapshot.serializer(), state))) { "Occurrence action was not saved. Retry before leaving this trip." }
    }
    private fun reduce(d: TripOccurrenceCoverage.Document, action: JsonObject, operationId: String, history: List<Operation>): JsonObject {
        val fields = d.raw.toMutableMap()
        val states = d.raw.getValue("states").jsonObject.toMutableMap()
        val id = action["occurrenceId"].textOrNull()
        if (id != null) require(id in d.order)
        when (action["kind"].textOrNull()) {
            "setStatus" -> states[id!!] = buildJsonObject {
                put("status", action.getValue("toStatus")); put("source", action.getValue("source"))
                put("lastOperationId", operationId); put("tankSessionIds", action.getValue("tankSessionIds"))
            }
            "undo" -> {
                val prior = history.single { it.id == action["undoOfOperationId"].textOrNull() }
                require(prior.action["kind"].textOrNull() in listOf("setStatus", "undo"))
                val before = TripOccurrenceCoverage.requireDocument(prior.before).state(id!!).toMutableMap()
                before["lastOperationId"] = JsonPrimitive(operationId); before["source"] = JsonPrimitive("correction")
                states[id] = JsonObject(before)
            }
            "selectOccurrence" -> fields["selectedOccurrenceId"] = JsonPrimitive(id)
            "editPlan" -> {
                fields["activeOrder"] = action.getValue("activeOrder")
                fields["planRevision"] = JsonPrimitive(d.planRevision + 1); fields["selectedOccurrenceId"] = JsonNull
            }
            else -> error("Unsupported occurrence action.")
        }
        if (action["kind"].textOrNull() in listOf("setStatus", "undo") && fields["selectedOccurrenceId"].textOrNull() == id)
            fields["selectedOccurrenceId"] = JsonNull
        fields["states"] = JsonObject(states)
        fields["revision"] = JsonPrimitive(d.revision + 1)
        val order = fields.getValue("activeOrder").jsonArray.map { it.jsonPrimitive.content }
        fields["plannedCursorId"] = order.firstOrNull { states.getValue(it).jsonObject["status"].textOrNull() == "incomplete" }
            ?.let(::JsonPrimitive) ?: JsonNull
        return JsonObject(fields).also { TripOccurrenceCoverage.requireDocument(it) }
    }
}

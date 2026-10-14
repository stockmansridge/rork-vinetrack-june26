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
                                       val after: JsonObject, val params: JsonObject) {
        val rpc: String get() = when (action["kind"].textOrNull()) {
            "create" -> "create_trip_with_occurrences_v1"
            "activate" -> "activate_trip_occurrences_v1"
            "finalize" -> "finalize_trip_occurrences_v1"
            else -> "apply_trip_occurrence_action_v1"
        }
    }
    @Serializable data class Snapshot(val scope: Scope, val acknowledged: JsonObject,
                                      val pending: List<Operation> = emptyList(),
                                      val history: List<Operation> = emptyList(), val heldReason: String? = null,
                                      val creationConfirmed: Boolean = true, val serverActive: Boolean? = null)
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
    /** Establishes all creation data in one commit; activation awaits an exact server receipt. */
    @Synchronized fun prepareCreation(trip: JsonObject, coverage: JsonObject): Operation {
        require(trip["id"].textOrNull() == scope.tripId && trip["vineyard_id"].textOrNull() == scope.vineyardId)
        val d = TripOccurrenceCoverage.requireDocument(coverage)
        require(d.revision == 0L && d.planRevision == 1L && d.items.all { d.status(it.id) == "incomplete" })
        check(load() == null) { "Creation already saved. Retry the original operation instead of creating another trip." }
        val id = UUID.randomUUID().toString()
        val action = buildJsonObject { put("kind", "create"); put("planId", d.planId); put("trip", trip) }
        val params = buildJsonObject { put("p_operation_id", id); put("p_trip", trip); put("p_coverage", coverage) }
        val op = Operation(id, action, coverage, coverage, params)
        save(Snapshot(scope, coverage, pending = listOf(op), history = listOf(op), creationConfirmed = false, serverActive = false))
        return op
    }

    @Synchronized fun activate(start: JsonObject): Operation = lifecycle("activate", start)
    @Synchronized fun finalize(end: JsonObject): Operation = lifecycle("finalize", end)
    private fun lifecycle(kind: String, metadata: JsonObject): Operation {
        val state = load() ?: error("Occurrence journal missing.")
        check(state.creationConfirmed && state.heldReason == null)
        check(state.pending.none { it.action["kind"].textOrNull() in listOf("activate", "finalize") })
        if (kind == "activate") check(state.serverActive == false && state.pending.isEmpty())
        else check(state.serverActive != false)
        val before = projected(state); val d = TripOccurrenceCoverage.requireDocument(before)
        val id = UUID.randomUUID().toString()
        val after = JsonObject(before.toMutableMap().also { fields ->
            fields["revision"] = JsonPrimitive(d.revision + 1)
            if (kind == "finalize") fields["selectedOccurrenceId"] = JsonNull
        })
        val action = buildJsonObject { put("kind", kind); put("planId", d.planId); put("metadata", metadata) }
        val params = buildJsonObject {
            put("p_operation_id", id); put("p_trip_id", scope.tripId)
            put("p_expected_revision", d.revision); put("p_expected_plan_revision", d.planRevision)
            if (kind == "activate") put("p_start", metadata)
            else { put("p_reviewed_states", before.getValue("states")); put("p_end", metadata) }
        }
        val op = Operation(id, action, before, after, params)
        save(state.copy(pending = state.pending + op, history = state.history + op))
        return op
    }

    /** Recover only server-supplied current reversible evidence; never infer history by label. */
    @Synchronized fun recover(response: JsonObject) {
        require(response["contract"].textOrNull() == "vinetrack.occurrence-recovery" && response["schemaVersion"]?.jsonPrimitive?.int == 1)
        require(response["tripId"].textOrNull() == scope.tripId && response["vineyardId"].textOrNull() == scope.vineyardId)
        val remote = response.getValue("coverage").jsonObject
        val d = TripOccurrenceCoverage.requireDocument(remote)
        val initial = load()
        if (initial == null) save(Snapshot(scope, remote, serverActive = response.getValue("isActive").jsonPrimitive.boolean))
        else require(TripOccurrenceCoverage.requireDocument(initial.acknowledged).planId == d.planId)
        val receipts = response.getValue("receipts").jsonArray.map { it.jsonObject }
        repeat(256) {
            val op = load()?.pending?.firstOrNull() ?: return@repeat
            val receipt = receipts.firstOrNull { it["operationId"].textOrNull() == op.id } ?: return@repeat
            require(receipt["actorId"].textOrNull() == scope.ownerId && receipt["request"] == serverRequest(op))
            acknowledge(receipt.getValue("result").jsonObject)
        }
        var state = load() ?: error("Occurrence journal missing.")
        val base = TripOccurrenceCoverage.requireDocument(state.acknowledged)
        if (d.revision < base.revision) return
        if (state.pending.isNotEmpty() && remote != state.acknowledged) {
            save(state.copy(heldReason = "Another update needs review. Original pending occurrence requests were retained.")); return
        }
        if (state.pending.isEmpty() && d.revision == base.revision && remote != state.acknowledged) {
            save(state.copy(heldReason = "Conflicting occurrence snapshot at the same revision. Saved evidence was retained.")); return
        }
        val recovered = response.getValue("reversibleOperations").jsonArray.map { value ->
            val row = value.jsonObject; val result = row.getValue("result").jsonObject
            val after = result.getValue("coverage").jsonObject; val accepted = TripOccurrenceCoverage.requireDocument(after)
            val action = row.getValue("request").jsonObject.getValue("action").jsonObject
            val id = row.getValue("operationId").jsonPrimitive.content
            val target = action.getValue("occurrenceId").jsonPrimitive.content
            require(row["tripId"].textOrNull() == scope.tripId && result["tripId"].textOrNull() == scope.tripId && result["operationId"].textOrNull() == id)
            require(accepted.planId == d.planId && accepted.revision <= d.revision && target in d.order)
            require(action["kind"].textOrNull() in listOf("setStatus", "undo") && d.state(target)["lastOperationId"].textOrNull() == id)
            require(row["resultingState"] == d.state(target) && accepted.state(target) == d.state(target))
            val before = JsonObject(after.toMutableMap().also { fields ->
                fields["states"] = JsonObject(after.getValue("states").jsonObject.toMutableMap().also { it[target] = row.getValue("previousState") })
                fields["revision"] = JsonPrimitive(accepted.revision - 1)
            })
            TripOccurrenceCoverage.requireDocument(before)
            Operation(id, action, before, after, buildJsonObject {})
        }
        state = load() ?: error("Occurrence journal missing.")
        val pendingIds = state.pending.map { it.id }.toSet()
        val history = (state.history.filter { it.id in pendingIds || it.action["kind"].textOrNull() in listOf("create", "activate", "finalize") } + recovered).distinctBy { it.id }
            .sortedBy { TripOccurrenceCoverage.requireDocument(it.after).revision }
        save(state.copy(acknowledged = remote, history = history,
            serverActive = response.getValue("isActive").jsonPrimitive.boolean))
    }
    private fun serverRequest(op: Operation): JsonObject = when (op.action["kind"].textOrNull()) {
        "create" -> buildJsonObject { put("kind", "create"); put("trip", op.params.getValue("p_trip")); put("coverage", op.params.getValue("p_coverage")) }
        else -> buildJsonObject {
            val kind = op.action["kind"].textOrNull()
            if (kind in listOf("activate", "finalize")) put("kind", kind)
            put("tripId", scope.tripId); put("expectedRevision", op.params.getValue("p_expected_revision"))
            put("expectedPlanRevision", op.params.getValue("p_expected_plan_revision"))
            when (kind) {
                "activate" -> put("start", op.params.getValue("p_start"))
                "finalize" -> { put("reviewedStates", op.params.getValue("p_reviewed_states")); put("end", op.params.getValue("p_end")) }
                else -> put("action", op.action)
            }
        }
    }

    fun projected(state: Snapshot): JsonObject = state.pending.lastOrNull()?.after ?: state.acknowledged
    fun targetId(): String? = load()?.let { TripOccurrenceCoverage.requireDocument(projected(it)).targetId }
    fun undoTarget(): Operation? = load()?.let { state ->
        if (!state.creationConfirmed || state.serverActive == false || state.heldReason != null || state.pending.any { it.action["kind"].textOrNull() in listOf("activate", "finalize") }) return@let null
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
        check(state.creationConfirmed && state.serverActive != false && state.pending.none { it.action["kind"].textOrNull() in listOf("activate", "finalize") }) {
            "Creation or activation is not confirmed, or finalisation is pending. Saved occurrence identity was retained."
        }
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
        val kind = op.action["kind"].textOrNull()
        val active = when (kind) {
            "create" -> op.action.getValue("trip").jsonObject["is_active"]?.jsonPrimitive?.boolean ?: false
            "activate" -> true
            "finalize" -> false
            else -> state.serverActive
        }
        save(state.copy(acknowledged = coverage, pending = state.pending.drop(1), creationConfirmed = true, serverActive = active))
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

package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Scope
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Request
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Receipt
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Code
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Failure

/** Synchronous durable replacement precedes transmission, receipt publication and projection success. */
class SprayPlanningAttemptJournal(private val storage: Storage, private val scope: Scope) {
    interface Storage { fun read(): String?; fun commit(value: String): Boolean }
    @Serializable enum class Stage { INTENT_DURABLE, OUTCOME_UNKNOWN, RECEIPT_VERIFIED, LOCAL_STATE_REPAIRED, COMPLETE, HELD, QUARANTINED }
    @Serializable data class Attempt(val request: Request, val stage: Stage = Stage.INTENT_DURABLE,
        val receipt: Receipt? = null, val reason: String? = null)
    @Serializable data class Document(val schemaVersion: Int = 1, val scope: Scope, val attempts: List<Attempt> = emptyList())
    private val json = Json { encodeDefaults = true; explicitNulls = true }
    init { SprayPlanningProtocol.check(listOf(scope.actorId, scope.vineyardId, scope.incarnation).all(SprayPlanningProtocol::uuid), Code.SCOPE) }
    @Synchronized fun load(): Document {
        val d = storage.read()?.let { json.decodeFromString<Document>(it) } ?: Document(scope = scope)
        SprayPlanningProtocol.check(d.schemaVersion == 1 && d.scope == scope && d.attempts.map { it.request.operationId }.distinct().size == d.attempts.size, Code.SCOPE)
        d.attempts.forEach { a ->
            SprayPlanningProtocol.validate(a.request)
            SprayPlanningProtocol.check(a.request.actorId == scope.actorId && a.request.vineyardId == scope.vineyardId, Code.SCOPE)
            a.receipt?.let { SprayPlanningProtocol.verify(it, a.request) }
        }
        return d
    }
    @Synchronized fun prepare(r: Request, current: Scope): Attempt {
        fence(current); SprayPlanningProtocol.validate(r)
        SprayPlanningProtocol.check(r.actorId == scope.actorId && r.vineyardId == scope.vineyardId, Code.SCOPE)
        val d = load()
        d.attempts.firstOrNull { it.request.operationId == r.operationId }?.let {
            SprayPlanningProtocol.check(it.request == r, Code.CONFLICT); return it
        }
        SprayPlanningProtocol.check(d.attempts.none { it.request.snapshot.recordId == r.snapshot.recordId && it.stage != Stage.COMPLETE }, Code.CONFLICT)
        d.attempts.lastOrNull { it.request.snapshot.recordId == r.snapshot.recordId }?.receipt?.let {
            SprayPlanningProtocol.check(r.snapshot.expectedPreviousRevisionId == it.result.recipeRevisionId && r.snapshot.expectedRecipeDigest == it.recipeSHA256, Code.CONFLICT)
        }
        val a = Attempt(r); save(d.copy(attempts = d.attempts + a)); return a
    }
    @Synchronized fun pending(current: Scope): List<Attempt> { fence(current); return load().attempts.filter { it.stage != Stage.COMPLETE } }
    @Synchronized fun markSent(id: String, current: Scope) {
        fence(current); mutate(id) {
            SprayPlanningProtocol.check(it.stage in listOf(Stage.INTENT_DURABLE, Stage.OUTCOME_UNKNOWN), Code.CONFLICT)
            it.copy(stage = Stage.OUTCOME_UNKNOWN)
        }
    }
    @Synchronized fun accept(receipt: Receipt, current: Scope) {
        fence(current); mutate(receipt.operationId) {
            SprayPlanningProtocol.verify(receipt, it.request)
            if (it.receipt != null) { SprayPlanningProtocol.check(it.receipt == receipt, Code.CONFLICT); it }
            else {
                SprayPlanningProtocol.check(it.stage in listOf(Stage.INTENT_DURABLE, Stage.OUTCOME_UNKNOWN), Code.CONFLICT)
                it.copy(stage = Stage.RECEIPT_VERIFIED, receipt = receipt, reason = null)
            }
        }
    }
    /** Repair must use a current-revision CAS and idempotent existing native stores, not repeat effects. */
    @Synchronized fun repair(id: String, current: Scope, apply: (Receipt) -> Boolean) {
        fence(current)
        val a = load().attempts.firstOrNull { it.request.operationId == id } ?: throw Failure(Code.REPAIR_REQUIRED)
        val receipt = a.receipt ?: throw Failure(Code.REPAIR_REQUIRED)
        if (a.stage == Stage.COMPLETE) return
        SprayPlanningProtocol.check(a.stage in listOf(Stage.RECEIPT_VERIFIED, Stage.LOCAL_STATE_REPAIRED), Code.CONFLICT)
        if (a.stage == Stage.RECEIPT_VERIFIED) {
            SprayPlanningProtocol.check(apply(receipt), Code.REPAIR_REQUIRED)
            mutate(id) { it.copy(stage = Stage.LOCAL_STATE_REPAIRED) }
        }
        mutate(id) { it.copy(stage = Stage.COMPLETE) }
    }
    @Synchronized fun hold(id: String, current: Scope, reason: String) {
        fence(current); mutate(id) { if (it.stage == Stage.COMPLETE) it else it.copy(stage = Stage.HELD, reason = reason) }
    }
    private fun fence(current: Scope) {
        if (current == scope) return
        val d = load(); save(d.copy(attempts = d.attempts.map {
            if (it.stage == Stage.COMPLETE) it else it.copy(stage = Stage.QUARANTINED, reason = "scope_changed")
        })); throw Failure(Code.SCOPE)
    }
    private fun mutate(id: String, change: (Attempt) -> Attempt) {
        val d = load(); SprayPlanningProtocol.check(d.attempts.any { it.request.operationId == id }, Code.INVALID_RECEIPT)
        save(d.copy(attempts = d.attempts.map { if (it.request.operationId == id) change(it) else it }))
    }
    private fun save(d: Document) { SprayPlanningProtocol.check(storage.commit(json.encodeToString(d)), Code.STORAGE) }
}

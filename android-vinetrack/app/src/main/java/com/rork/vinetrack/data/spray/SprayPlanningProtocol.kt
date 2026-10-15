package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.*
import java.util.UUID

/** Complete domain evidence, not a reconstruction from current rows, catalogue or regional settings. */
object SprayPlanningProtocol {
    const val CONTRACT = "vinetrack.spray-planning"
    const val DIGEST = "pg-jsonb-text-sha256-v1"
    @Serializable enum class Kind(val rpc: String) {
        @SerialName("save_plan") SAVE("save_spray_plan_v1"),
        @SerialName("replace_plan") REPLACE("replace_spray_plan_v1"),
        @SerialName("bind_route") BIND("bind_spray_plan_route_v1"),
        @SerialName("start_spray") START("start_spray_plan_v1"),
        @SerialName("start_tank") TANK("start_spray_plan_tank_v1")
    }
    @Serializable data class Scope(val actorId: String, val vineyardId: String, val incarnation: String)
    @Serializable data class Snapshot(
        val recordId: String, val tripId: String?, val recipeRevisionId: String,
        val expectedPreviousRevisionId: String?, val expectedRecipeDigest: String?, val routeRevisionId: String?,
        val tankSessionId: String?, val actualUseId: String?,
        val planningInputs: JsonObject, val frozenOutputs: JsonObject, val chemicalLines: JsonArray,
        val equipment: JsonObject, val geometry: JsonObject, val route: JsonObject?,
        val originalRecord: JsonObject, val originalTrip: JsonObject?, val reviewedActuals: JsonObject?, val dependencies: JsonObject,
    )
    @Serializable data class Request(
        val contract: String = CONTRACT, val schemaVersion: Int = 1,
        val operationId: String = UUID.randomUUID().toString(), val actorId: String, val vineyardId: String,
        val kind: Kind, val snapshot: Snapshot,
    )
    @Serializable enum class Phase { @SerialName("saved_unbound") SAVED_UNBOUND, @SerialName("bound") BOUND, @SerialName("ready") READY, @SerialName("active") ACTIVE }
    @Serializable data class Result(
        val recordId: String, val tripId: String?, val recipeRevisionId: String, val routeRevisionId: String?,
        val tankSessionId: String?, val actualUseId: String?, val phase: Phase, val snapshot: Snapshot,
        val establishedEffects: JsonObject,
    )
    @Serializable data class Receipt(
        val contract: String, val schemaVersion: Int, val operationId: String, val actorId: String, val vineyardId: String,
        val request: Request, val digestAlgorithm: String, val canonicalRequestSHA256: String, val recipeSHA256: String,
        val serverRevision: Int, val acceptedAt: String, val result: Result,
    )
    @Serializable data class Capability(
        val contract: String, val schemaVersion: Int, val vineyardId: String, val enabled: Boolean,
        val migrationId: String, val validationSuiteId: String, val digestAlgorithm: String,
        val operations: List<Kind>, val occurrenceVersion: Int, val tankVersion: Int,
    ) {
        fun supports(r: Request): Boolean = contract == CONTRACT && schemaVersion == 1 && enabled && vineyardId == r.vineyardId &&
            migrationId.isNotBlank() && validationSuiteId.isNotBlank() && digestAlgorithm == DIGEST &&
            occurrenceVersion == 1 && tankVersion == 1 && r.kind in operations
    }
    @Serializable data class Recovery(val contract: String, val schemaVersion: Int, val actorId: String,
        val vineyardId: String, val receipts: List<Receipt>, val currentState: JsonElement)
    enum class Code { STORAGE, SCOPE, CONFLICT, INVALID_RECEIPT, UNAVAILABLE, INVALID_REQUEST, REPAIR_REQUIRED }
    class Failure(val code: Code) : Exception(when (code) {
        Code.STORAGE -> "Unable to retain the original spray plan. Nothing was submitted."
        Code.SCOPE -> "This pending plan is quarantined for its original account and vineyard."
        Code.CONFLICT -> "The spray plan needs reconciliation. Its original request is retained."
        Code.INVALID_RECEIPT -> "The server receipt could not be verified. No success has been recorded."
        Code.UNAVAILABLE -> "Spray planning operations are not yet available. Local evidence is retained."
        Code.INVALID_REQUEST -> "The plan is incomplete or its revision changed. Review it again."
        Code.REPAIR_REQUIRED -> "The accepted plan needs local repair. Do not create another attempt."
    })
    fun uuid(s: String): Boolean = runCatching { UUID.fromString(s).toString() == s }.getOrDefault(false)
    fun digest(s: String): Boolean = s.length == 64 && s.all { it in "0123456789abcdef" }
    fun validate(r: Request) {
        val s = r.snapshot
        check(r.contract == CONTRACT && r.schemaVersion == 1 &&
            listOf(r.operationId, r.actorId, r.vineyardId, s.recordId, s.recipeRevisionId).all(::uuid) &&
            listOfNotNull(s.tripId, s.expectedPreviousRevisionId, s.routeRevisionId, s.actualUseId).all(::uuid) &&
            s.chemicalLines.isNotEmpty(), Code.INVALID_REQUEST)
        if (r.kind != Kind.SAVE) check(s.expectedPreviousRevisionId != null && s.expectedRecipeDigest?.let(::digest) == true, Code.INVALID_REQUEST)
        if (r.kind in listOf(Kind.BIND, Kind.START, Kind.TANK)) check(s.route != null && s.routeRevisionId != null, Code.INVALID_REQUEST)
        if (r.kind in listOf(Kind.START, Kind.TANK)) check(s.tripId != null && s.originalTrip != null, Code.INVALID_REQUEST)
        if (r.kind == Kind.TANK) check(!s.tankSessionId.isNullOrEmpty() && s.actualUseId != null && s.reviewedActuals != null, Code.INVALID_REQUEST)
        val intent = Json.decodeFromJsonElement<SprayPlanningIntent>(s.planningInputs)
        val resolved = Json.decodeFromJsonElement<SprayPlanningResolution>(s.frozenOutputs)
        check(intent.frozenResolutionBlocker(resolved) == null, Code.INVALID_REQUEST)
        s.chemicalLines.forEach { raw ->
            val line = raw as? JsonObject ?: throw Failure(Code.INVALID_REQUEST)
            val quantity = (line["quantity"] as? JsonPrimitive)?.doubleOrNull
            check((line["rateBasis"] as? JsonPrimitive)?.content in listOf("whole_block_area", "treated_area", "per_100_litres", "per_100_metres") &&
                quantity != null && quantity.isFinite() && quantity > 0 &&
                !(line["unit"] as? JsonPrimitive)?.content.isNullOrBlank(), Code.INVALID_REQUEST)
        }
        if (r.kind == Kind.SAVE && s.route == null) check(s.tripId == null && s.originalTrip == null, Code.INVALID_REQUEST)
        // No label-permission requirement: genuine dose validation remains with the existing engine.
    }
    fun verify(receipt: Receipt, r: Request) {
        val s = r.snapshot; val a = receipt.result
        check(receipt.contract == CONTRACT && receipt.schemaVersion == 1 && receipt.operationId == r.operationId &&
            receipt.actorId == r.actorId && receipt.vineyardId == r.vineyardId && receipt.request == r &&
            receipt.digestAlgorithm == DIGEST && digest(receipt.canonicalRequestSHA256) && digest(receipt.recipeSHA256) &&
            receipt.serverRevision > 0 && receipt.acceptedAt.isNotBlank() && a.recordId == s.recordId && a.tripId == s.tripId &&
            a.recipeRevisionId == s.recipeRevisionId && a.routeRevisionId == s.routeRevisionId && a.tankSessionId == s.tankSessionId &&
            a.actualUseId == s.actualUseId && a.snapshot == s, Code.INVALID_RECEIPT)
        if (r.kind in listOf(Kind.START, Kind.TANK)) check(a.phase == Phase.ACTIVE, Code.INVALID_RECEIPT)
        if (r.kind == Kind.SAVE && s.route == null) check(a.phase == Phase.SAVED_UNBOUND && a.tripId == null, Code.INVALID_RECEIPT)
        if (r.kind == Kind.BIND) check(a.phase in listOf(Phase.BOUND, Phase.READY), Code.INVALID_RECEIPT)
        if (r.kind in listOf(Kind.SAVE, Kind.REPLACE, Kind.BIND)) check(a.phase != Phase.ACTIVE, Code.INVALID_RECEIPT)
        if (r.kind !in listOf(Kind.SAVE, Kind.REPLACE)) check(receipt.recipeSHA256 == s.expectedRecipeDigest, Code.INVALID_RECEIPT)
    }
    fun check(value: Boolean, code: Code) { if (!value) throw Failure(code) }
}

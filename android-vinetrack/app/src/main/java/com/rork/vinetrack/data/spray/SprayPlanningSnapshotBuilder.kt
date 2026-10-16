package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import kotlinx.serialization.json.*

/** Freeze original native record/tank evidence verbatim; no alternative calculation or legacy REST writer. */
object SprayPlanningSnapshotBuilder {
    data class Binding(val recipeRevisionId: String, val previousRevisionId: String?, val previousRecipeDigest: String?,
        val routeRevisionId: String?, val route: JsonObject?, val trip: Trip?, val equipment: JsonObject,
        val physicalGeometry: JsonObject, val dependencies: JsonObject, val tankSessionId: String?, val actualUseId: String?,
        val reviewedActuals: JsonObject?)
    private val json = Json { encodeDefaults = true; explicitNulls = true }
    fun freeze(record: SprayRecord, scope: SprayPlanningProtocol.Scope, kind: SprayPlanningProtocol.Kind, binding: Binding): SprayPlanningProtocol.Request {
        val geometry = record.applicationGeometry ?: throw SprayPlanningProtocol.Failure(SprayPlanningProtocol.Code.INVALID_REQUEST)
        val intent = geometry.planningIntent ?: throw SprayPlanningProtocol.Failure(SprayPlanningProtocol.Code.INVALID_REQUEST)
        val resolution = geometry.planningResolution ?: throw SprayPlanningProtocol.Failure(SprayPlanningProtocol.Code.INVALID_REQUEST)
        SprayPlanningProtocol.check(record.vineyardId == scope.vineyardId && intent.frozenResolutionBlocker(resolution) == null &&
            intent.fullTankExecutionBlocker(resolution, geometry.grossAreaHa) == null &&
            (binding.trip == null || binding.trip.id == record.tripId && binding.trip.vineyardId == record.vineyardId), SprayPlanningProtocol.Code.INVALID_REQUEST)
        val lines = record.tanks.orEmpty().flatMap { tank ->
            SprayPlanningProtocol.check(tank.waterVolume.isFinite() && tank.waterVolume > 0, SprayPlanningProtocol.Code.INVALID_REQUEST)
            tank.chemicals.map { chemical -> buildJsonObject {
                put("tankId", tank.id); put("tankNumber", tank.tankNumber); put("lineId", chemical.id)
                put("rateBasis", chemical.rateBasis ?: throw SprayPlanningProtocol.Failure(SprayPlanningProtocol.Code.INVALID_REQUEST))
                put("quantity", chemical.volumePerTank); put("unit", chemical.unit)
                put("originalLine", json.encodeToJsonElement(chemical))
            } }
        }
        val snapshot = SprayPlanningProtocol.Snapshot(record.id, binding.trip?.id, binding.recipeRevisionId,
            binding.previousRevisionId, binding.previousRecipeDigest, binding.routeRevisionId, binding.tankSessionId,
            binding.actualUseId, json.encodeToJsonElement(intent).jsonObject, json.encodeToJsonElement(resolution).jsonObject,
            JsonArray(lines), binding.equipment, buildJsonObject { put("application", json.encodeToJsonElement(geometry)); put("physical", binding.physicalGeometry) },
            binding.route, json.encodeToJsonElement(record).jsonObject, binding.trip?.let { json.encodeToJsonElement(it).jsonObject },
            binding.reviewedActuals, binding.dependencies)
        return SprayPlanningProtocol.Request(actorId = scope.actorId, vineyardId = scope.vineyardId, kind = kind, snapshot = snapshot)
            .also(SprayPlanningProtocol::validate)
    }
    fun validateTankConfirmation(captured: SprayRecord, current: SprayRecord?) {
        SprayPlanningProtocol.check(captured == current, SprayPlanningProtocol.Code.CONFLICT)
    }
}

package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.math.abs
import kotlin.math.roundToLong

// =============================================================================
// Irrigation Records (SQL 125) — DTOs
// Canonical units everywhere: litres, litres/hour, m², mm, whole minutes.
// =============================================================================

@Serializable
data class IrrigationSystemRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val name: String,
    @SerialName("water_source") val waterSource: String? = null,
    @SerialName("is_active") val isActive: Boolean = true,
    val notes: String? = null,
)

@Serializable
data class IrrigationValveRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("irrigation_system_id") val irrigationSystemId: String,
    val name: String,
    @SerialName("valve_number") val valveNumber: String? = null,
    @SerialName("configured_flow_litres_per_hour") val configuredFlowLph: Double? = null,
    @SerialName("measured_flow_litres_per_hour") val measuredFlowLph: Double? = null,
    @SerialName("is_active") val isActive: Boolean = true,
    val notes: String? = null,
    @SerialName("system_name") val systemName: String? = null,
    @SerialName("active_block_count") val activeBlockCount: Int? = null,
)

@Serializable
data class IrrigationValveBlockRow(
    val id: String,
    @SerialName("valve_id") val valveId: String,
    @SerialName("block_id") val blockId: String,
    @SerialName("allocation_method") val allocationMethod: String = "manual_percentage",
    @SerialName("allocation_percentage") val allocationPercentage: Double? = null,
    @SerialName("serviced_area_m2") val servicedAreaM2: Double? = null,
    @SerialName("serviced_vine_count") val servicedVineCount: Int? = null,
    @SerialName("block_name") val blockName: String? = null,
)

@Serializable
data class IrrigationSetupSeason(
    val configured: Boolean = true,
    @SerialName("season_start_month") val seasonStartMonth: Int = 7,
    @SerialName("season_start_day") val seasonStartDay: Int = 1,
    @SerialName("current_vintage_year") val currentVintageYear: Int = 0,
)

@Serializable
data class IrrigationSetupRequired(
    @SerialName("active_block_count") val activeBlockCount: Int = 0,
    @SerialName("blocks_ok") val blocksOk: Boolean = false,
    @SerialName("active_system_count") val activeSystemCount: Int = 0,
    @SerialName("systems_ok") val systemsOk: Boolean = false,
    @SerialName("active_valve_count") val activeValveCount: Int = 0,
    @SerialName("valves_ok") val valvesOk: Boolean = false,
    @SerialName("fully_allocated_valve_count") val fullyAllocatedValveCount: Int = 0,
    @SerialName("allocations_ok") val allocationsOk: Boolean = false,
    @SerialName("valves_with_configured_flow") val valvesWithConfiguredFlow: Int = 0,
)

@Serializable
data class IrrigationSetupRecommended(
    @SerialName("total_active_blocks") val totalActiveBlocks: Int = 0,
    @SerialName("blocks_with_area") val blocksWithArea: Int = 0,
    @SerialName("blocks_with_vine_count") val blocksWithVineCount: Int = 0,
    @SerialName("blocks_with_vine_spacing") val blocksWithVineSpacing: Int = 0,
    @SerialName("blocks_with_dripper_output") val blocksWithDripperOutput: Int = 0,
    @SerialName("blocks_with_dripper_spacing") val blocksWithDripperSpacing: Int = 0,
    @SerialName("blocks_with_efficiency") val blocksWithEfficiency: Int = 0,
)

@Serializable
data class IrrigationValveStatus(
    @SerialName("valve_id") val valveId: String,
    @SerialName("valve_name") val valveName: String,
    @SerialName("block_count") val blockCount: Int = 0,
    @SerialName("allocation_total") val allocationTotal: Double = 0.0,
    @SerialName("allocation_ok") val allocationOk: Boolean = false,
    @SerialName("has_configured_flow") val hasConfiguredFlow: Boolean = false,
)

@Serializable
data class IrrigationSetupStatus(
    val season: IrrigationSetupSeason = IrrigationSetupSeason(),
    val required: IrrigationSetupRequired = IrrigationSetupRequired(),
    val recommended: IrrigationSetupRecommended = IrrigationSetupRecommended(),
    val valves: List<IrrigationValveStatus> = emptyList(),
    @SerialName("is_operational") val isOperational: Boolean = false,
)

/** Resolved allocation config — input shape of the shared allocation maths. */
@Serializable
data class IrrigationAllocationConfig(
    @SerialName("block_id") val blockId: String,
    @SerialName("block_name") val blockName: String? = null,
    @SerialName("variety_name") val varietyName: String? = null,
    @SerialName("allocation_percentage") val allocationPercentage: Double? = null,
    @SerialName("serviced_area_m2") val servicedAreaM2: Double? = null,
    @SerialName("serviced_vine_count") val servicedVineCount: Int? = null,
    @SerialName("efficiency_percent") val efficiencyPercent: Double? = null,
)

@Serializable
data class IrrigationValveValidation(
    @SerialName("valve_id") val valveId: String,
    @SerialName("valve_name") val valveName: String,
    @SerialName("can_record") val canRecord: Boolean = false,
    @SerialName("has_configured_flow") val hasConfiguredFlow: Boolean = false,
    @SerialName("configured_flow_litres_per_hour") val configuredFlowLph: Double? = null,
    @SerialName("requires_volume_entry") val requiresVolumeEntry: Boolean = false,
    val allocations: List<IrrigationAllocationConfig> = emptyList(),
    @SerialName("allocation_total") val allocationTotal: Double = 0.0,
    val issues: List<String> = emptyList(),
)

@Serializable
data class IrrigationBlockResult(
    @SerialName("block_id") val blockId: String,
    @SerialName("block_name") val blockName: String? = null,
    @SerialName("variety_name") val varietyName: String? = null,
    @SerialName("allocation_percentage") val allocationPercentage: Double = 0.0,
    @SerialName("allocated_volume_litres") val allocatedVolumeLitres: Double = 0.0,
    @SerialName("effective_volume_litres") val effectiveVolumeLitres: Double? = null,
    @SerialName("serviced_area_m2") val servicedAreaM2: Double? = null,
    @SerialName("serviced_vine_count") val servicedVineCount: Int? = null,
    @SerialName("water_litres_per_vine") val waterLitresPerVine: Double? = null,
    @SerialName("water_litres_per_hectare") val waterLitresPerHectare: Double? = null,
    @SerialName("irrigation_depth_mm") val irrigationDepthMm: Double? = null,
)

@Serializable
data class IrrigationPreviewResult(
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("effective_volume_litres") val effectiveVolumeLitres: Double? = null,
    @SerialName("irrigation_efficiency_percent") val irrigationEfficiencyPercent: Double? = null,
    val blocks: List<IrrigationBlockResult> = emptyList(),
    val warnings: List<String> = emptyList(),
    @SerialName("valve_name") val valveName: String? = null,
    @SerialName("irrigation_system_name") val irrigationSystemName: String? = null,
    @SerialName("flow_litres_per_hour_used") val flowLphUsed: Double? = null,
    @SerialName("vintage_year") val vintageYear: Int? = null,
)

@Serializable
data class IrrigationSessionBlockRow(
    val id: String,
    @SerialName("block_id") val blockId: String,
    @SerialName("block_name") val blockName: String? = null,
    @SerialName("variety_name") val varietyName: String? = null,
    @SerialName("allocation_percentage") val allocationPercentage: Double = 0.0,
    @SerialName("allocated_volume_litres") val allocatedVolumeLitres: Double = 0.0,
    @SerialName("effective_volume_litres") val effectiveVolumeLitres: Double? = null,
    @SerialName("water_litres_per_vine") val waterLitresPerVine: Double? = null,
    @SerialName("water_litres_per_hectare") val waterLitresPerHectare: Double? = null,
    @SerialName("irrigation_depth_mm") val irrigationDepthMm: Double? = null,
)

@Serializable
data class IrrigationSessionRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("irrigation_system_id") val irrigationSystemId: String,
    @SerialName("valve_id") val valveId: String,
    @SerialName("session_date") val sessionDate: String,
    @SerialName("vintage_year") val vintageYear: Int = 0,
    @SerialName("duration_minutes") val durationMinutes: Int = 0,
    @SerialName("calculation_method") val calculationMethod: String = "configured_flow",
    @SerialName("flow_litres_per_hour") val flowLph: Double? = null,
    @SerialName("meter_start_litres") val meterStartLitres: Double? = null,
    @SerialName("meter_finish_litres") val meterFinishLitres: Double? = null,
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("effective_volume_litres") val effectiveVolumeLitres: Double? = null,
    val status: String = "completed",
    @SerialName("source_type") val sourceType: String = "manual_android",
    val notes: String? = null,
    @SerialName("system_name") val systemName: String? = null,
    @SerialName("valve_name") val valveName: String? = null,
    val blocks: List<IrrigationSessionBlockRow> = emptyList(),
    val duplicate: Boolean? = null,
    val warnings: List<String>? = null,
) {
    val blockNames: String get() = blocks.mapNotNull { it.blockName }.joinToString(", ")
}

@Serializable
data class IrrigationSessionList(
    val sessions: List<IrrigationSessionRow> = emptyList(),
    @SerialName("total_count") val totalCount: Int = 0,
)

@Serializable
data class IrrigationVintageSummary(
    @SerialName("vintage_year") val vintageYear: Int = 0,
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("effective_volume_litres") val effectiveVolumeLitres: Double? = null,
    @SerialName("total_runtime_minutes") val totalRuntimeMinutes: Int = 0,
    @SerialName("session_count") val sessionCount: Int = 0,
    @SerialName("average_session_minutes") val averageSessionMinutes: Double? = null,
    @SerialName("month_volume_litres") val monthVolumeLitres: Double = 0.0,
    @SerialName("month_session_count") val monthSessionCount: Int = 0,
    @SerialName("month_runtime_minutes") val monthRuntimeMinutes: Int = 0,
    @SerialName("water_litres_per_vine") val waterLitresPerVine: Double? = null,
    @SerialName("irrigation_depth_mm") val irrigationDepthMm: Double? = null,
)

@Serializable
data class IrrigationValveSummaryRow(
    @SerialName("valve_id") val valveId: String,
    @SerialName("valve_name") val valveName: String,
    @SerialName("system_name") val systemName: String? = null,
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("total_runtime_minutes") val totalRuntimeMinutes: Int = 0,
    @SerialName("session_count") val sessionCount: Int = 0,
    @SerialName("last_irrigation_date") val lastIrrigationDate: String? = null,
)

@Serializable
data class IrrigationBlockSummaryRow(
    @SerialName("block_id") val blockId: String,
    @SerialName("block_name") val blockName: String? = null,
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("effective_volume_litres") val effectiveVolumeLitres: Double? = null,
    @SerialName("session_count") val sessionCount: Int = 0,
    @SerialName("last_irrigation_date") val lastIrrigationDate: String? = null,
    @SerialName("water_litres_per_vine") val waterLitresPerVine: Double? = null,
    @SerialName("water_litres_per_hectare") val waterLitresPerHectare: Double? = null,
    @SerialName("irrigation_depth_mm") val irrigationDepthMm: Double? = null,
)

@Serializable
data class IrrigationVarietySummaryRow(
    @SerialName("variety_name") val varietyName: String,
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("total_serviced_area_m2") val totalServicedAreaM2: Double? = null,
    @SerialName("total_serviced_vines") val totalServicedVines: Int? = null,
    @SerialName("average_water_litres_per_hectare") val averageWaterLitresPerHectare: Double? = null,
    @SerialName("average_water_litres_per_vine") val averageWaterLitresPerVine: Double? = null,
    @SerialName("irrigation_depth_mm") val irrigationDepthMm: Double? = null,
)

@Serializable
data class IrrigationDailySummaryRow(
    val date: String,
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("runtime_minutes") val runtimeMinutes: Int = 0,
    @SerialName("session_count") val sessionCount: Int = 0,
)

@Serializable
data class IrrigationMonthlySummaryRow(
    val month: String,
    @SerialName("total_volume_litres") val totalVolumeLitres: Double = 0.0,
    @SerialName("runtime_minutes") val runtimeMinutes: Int = 0,
    @SerialName("session_count") val sessionCount: Int = 0,
    @SerialName("irrigation_depth_mm") val irrigationDepthMm: Double? = null,
)

/** Offline pending session queued for idempotent replay (id is client-generated). */
@Serializable
data class PendingIrrigationSession(
    val id: String,
    val vineyardId: String,
    val irrigationSystemId: String,
    val valveId: String,
    val valveName: String = "",
    val sessionDate: String,
    val durationMinutes: Int,
    val calculationMethod: String,
    val flowLph: Double? = null,
    val meterStartLitres: Double? = null,
    val meterFinishLitres: Double? = null,
    val totalVolumeLitres: Double? = null,
    val notes: String? = null,
    val localTotalVolumeLitres: Double? = null,
    val createdAtEpochMs: Long = System.currentTimeMillis(),
)

// =============================================================================
// Local calculator — byte-for-byte mirror of sql/125 irrigation_total_volume
// and _irrigation_allocate. Offline previews only; server values win on sync.
// =============================================================================

object IrrigationLocalCalc {
    class CalcException(message: String) : Exception(message)

    data class BlockResult(
        val blockId: String,
        val blockName: String,
        val allocationPercentage: Double,
        val allocatedVolumeLitres: Double,
        val effectiveVolumeLitres: Double?,
        val waterLitresPerVine: Double?,
        val waterLitresPerHectare: Double?,
        val irrigationDepthMm: Double?,
    )

    data class Result(
        val totalVolumeLitres: Double,
        val effectiveVolumeLitres: Double?,
        val blocks: List<BlockResult>,
        val warnings: List<String>,
    )

    fun round3(value: Double): Double = (value * 1000.0).roundToLong() / 1000.0
    fun round2(value: Double): Double = (value * 100.0).roundToLong() / 100.0

    fun totalVolume(
        method: String,
        flowLph: Double?,
        durationMinutes: Int,
        meterStartLitres: Double?,
        meterFinishLitres: Double?,
        totalVolumeLitres: Double?,
    ): Double {
        if (durationMinutes <= 0) throw CalcException("Duration must be a positive whole number of minutes.")
        return when (method) {
            "configured_flow", "session_flow" -> {
                if (flowLph == null || flowLph <= 0) throw CalcException("Flow rate must be greater than zero.")
                round3(flowLph * durationMinutes / 60.0)
            }
            "meter_readings" -> {
                if (meterStartLitres == null || meterFinishLitres == null ||
                    meterFinishLitres - meterStartLitres <= 0
                ) throw CalcException("The finishing meter reading must be greater than the starting reading.")
                round3(meterFinishLitres - meterStartLitres)
            }
            "total_volume" -> {
                if (totalVolumeLitres == null || totalVolumeLitres <= 0) {
                    throw CalcException("Total volume must be greater than zero.")
                }
                round3(totalVolumeLitres)
            }
            else -> throw CalcException("Unknown calculation method: $method")
        }
    }

    fun allocate(totalVolumeLitres: Double, allocations: List<IrrigationAllocationConfig>): Result {
        val warnings = mutableListOf<String>()
        val blocks = mutableListOf<BlockResult>()
        var effectiveSum = 0.0
        var allHaveEfficiency = true

        val pctSum = allocations.sumOf { it.allocationPercentage ?: 0.0 }
        if (allocations.isEmpty() || abs(pctSum - 100.0) > 0.05) {
            throw CalcException("Block allocations must total 100%.")
        }

        for (alloc in allocations) {
            val pct = alloc.allocationPercentage ?: 0.0
            val name = alloc.blockName ?: "Block"
            val allocated = round3(totalVolumeLitres * pct / 100.0)

            val effective = alloc.efficiencyPercent?.takeIf { it > 0 }?.let { round3(allocated * it / 100.0) }
            if (effective != null) {
                effectiveSum += effective
            } else {
                allHaveEfficiency = false
                warnings.add("Effective water could not be calculated because $name does not have an irrigation efficiency.")
            }

            val perVine = alloc.servicedVineCount?.takeIf { it > 0 }?.let { round3(allocated / it) }
            if (perVine == null) {
                warnings.add("Water per vine could not be calculated because $name does not have a serviced vine count.")
            }

            val area = alloc.servicedAreaM2?.takeIf { it > 0 }
            val perHa = area?.let { round2(allocated / (it / 10000.0)) }
            val depth = area?.let { round3(allocated / it) }
            if (area == null) {
                warnings.add("Water per hectare and irrigation depth could not be calculated because $name does not have a serviced area.")
            }

            blocks.add(
                BlockResult(
                    blockId = alloc.blockId,
                    blockName = name,
                    allocationPercentage = pct,
                    allocatedVolumeLitres = allocated,
                    effectiveVolumeLitres = effective,
                    waterLitresPerVine = perVine,
                    waterLitresPerHectare = perHa,
                    irrigationDepthMm = depth,
                )
            )
        }

        return Result(
            totalVolumeLitres = round3(totalVolumeLitres),
            effectiveVolumeLitres = if (allHaveEfficiency) round3(effectiveSum) else null,
            blocks = blocks,
            warnings = warnings,
        )
    }

    // Display conversion constants (parity with iOS RegionFormatter).
    const val US_GALLONS_PER_LITRE = 0.264172052
    const val IMPERIAL_GALLONS_PER_LITRE = 0.219969157
    const val ACRES_PER_HECTARE = 2.471053814672
    const val MM_PER_INCH = 25.4

    fun litresPerHectareToGallonsPerAcre(litresPerHectare: Double, usGallon: Boolean): Double {
        val gallonsPerLitre = if (usGallon) US_GALLONS_PER_LITRE else IMPERIAL_GALLONS_PER_LITRE
        return litresPerHectare * gallonsPerLitre / ACRES_PER_HECTARE
    }
}

// =============================================================================
// Repository
// =============================================================================

/**
 * Irrigation Records data access — thin layer over the shared SQL 125 RPCs
 * (the server owns all authoritative calculation) plus an offline pending
 * queue whose client-generated UUIDs make retries idempotent.
 */
class IrrigationRepository(private val session: SessionStore, context: Context) {

    private val json = SupabaseClient.json
    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_irrigation", Context.MODE_PRIVATE)
    private val pendingSerializer = ListSerializer(PendingIrrigationSession.serializer())

    // MARK: Feature gate

    suspend fun hasAccess(vineyardId: String): Boolean = withContext(Dispatchers.IO) {
        val text = ensureSuccess(rpc("has_irrigation_records_access", buildJsonObject {
            put("p_vineyard_id", vineyardId)
        }))
        text.trim().equals("true", ignoreCase = true)
    }

    // MARK: Setup

    suspend fun listSystems(vineyardId: String, includeInactive: Boolean = false): List<IrrigationSystemRow> =
        withContext(Dispatchers.IO) {
            decode(ensureSuccess(rpc("list_irrigation_systems", buildJsonObject {
                put("p_vineyard_id", vineyardId)
                put("p_include_inactive", includeInactive)
            })))
        }

    suspend fun createSystem(vineyardId: String, name: String, waterSource: String?, notes: String?): IrrigationSystemRow =
        withContext(Dispatchers.IO) {
            decode(ensureSuccess(rpc("create_irrigation_system", buildJsonObject {
                put("p_id", java.util.UUID.randomUUID().toString())
                put("p_vineyard_id", vineyardId)
                put("p_name", name)
                waterSource?.let { put("p_water_source", it) }
                notes?.let { put("p_notes", it) }
            })))
        }

    suspend fun updateSystem(
        id: String, name: String? = null, waterSource: String? = null,
        notes: String? = null, isActive: Boolean? = null,
    ): IrrigationSystemRow = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("update_irrigation_system", buildJsonObject {
            put("p_id", id)
            name?.let { put("p_name", it) }
            waterSource?.let { put("p_water_source", it) }
            notes?.let { put("p_notes", it) }
            isActive?.let { put("p_is_active", it) }
        })))
    }

    suspend fun listValves(vineyardId: String, includeInactive: Boolean = false): List<IrrigationValveRow> =
        withContext(Dispatchers.IO) {
            decode(ensureSuccess(rpc("list_irrigation_valves", buildJsonObject {
                put("p_vineyard_id", vineyardId)
                put("p_include_inactive", includeInactive)
            })))
        }

    suspend fun createValve(
        vineyardId: String, systemId: String, name: String, valveNumber: String?,
        configuredFlowLph: Double?, measuredFlowLph: Double?, notes: String?,
    ): IrrigationValveRow = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("create_irrigation_valve", buildJsonObject {
            put("p_id", java.util.UUID.randomUUID().toString())
            put("p_vineyard_id", vineyardId)
            put("p_irrigation_system_id", systemId)
            put("p_name", name)
            valveNumber?.let { put("p_valve_number", it) }
            configuredFlowLph?.let { put("p_configured_flow_litres_per_hour", it) }
            measuredFlowLph?.let { put("p_measured_flow_litres_per_hour", it) }
            notes?.let { put("p_notes", it) }
        })))
    }

    suspend fun updateValve(
        id: String, name: String? = null, valveNumber: String? = null,
        configuredFlowLph: Double? = null, measuredFlowLph: Double? = null,
        notes: String? = null, isActive: Boolean? = null,
    ): IrrigationValveRow = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("update_irrigation_valve", buildJsonObject {
            put("p_id", id)
            name?.let { put("p_name", it) }
            valveNumber?.let { put("p_valve_number", it) }
            configuredFlowLph?.let { put("p_configured_flow_litres_per_hour", it) }
            measuredFlowLph?.let { put("p_measured_flow_litres_per_hour", it) }
            notes?.let { put("p_notes", it) }
            isActive?.let { put("p_is_active", it) }
        })))
    }

    suspend fun listValveBlocks(vineyardId: String, valveId: String? = null): List<IrrigationValveBlockRow> =
        withContext(Dispatchers.IO) {
            decode(ensureSuccess(rpc("list_irrigation_valve_blocks", buildJsonObject {
                put("p_vineyard_id", vineyardId)
                valveId?.let { put("p_valve_id", it) }
            })))
        }

    /** Atomically replaces the valve's active block set. Percentages must total 100. */
    suspend fun setValveBlocks(
        vineyardId: String, valveId: String,
        blocks: List<Pair<String, Double>>,
    ): List<IrrigationValveBlockRow> = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("set_irrigation_valve_blocks", buildJsonObject {
            put("p_vineyard_id", vineyardId)
            put("p_valve_id", valveId)
            put("p_blocks", buildJsonArray {
                blocks.forEach { (blockId, pct) ->
                    add(buildJsonObject {
                        put("block_id", blockId)
                        put("allocation_method", "manual_percentage")
                        put("allocation_percentage", pct)
                    })
                }
            })
        })))
    }

    suspend fun setupStatus(vineyardId: String): IrrigationSetupStatus = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("get_irrigation_setup_status", buildJsonObject {
            put("p_vineyard_id", vineyardId)
        })))
    }

    suspend fun validateValve(vineyardId: String, valveId: String): IrrigationValveValidation =
        withContext(Dispatchers.IO) {
            val validation: IrrigationValveValidation = decode(ensureSuccess(
                rpc("validate_irrigation_configuration", buildJsonObject {
                    put("p_vineyard_id", vineyardId)
                    put("p_valve_id", valveId)
                })
            ))
            cacheValidation(vineyardId, validation)
            validation
        }

    // MARK: Recording

    suspend fun preview(
        vineyardId: String, valveId: String, sessionDate: String, durationMinutes: Int,
        method: String, flowLph: Double?, meterStart: Double?, meterFinish: Double?,
        totalVolume: Double?,
    ): IrrigationPreviewResult = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("calculate_irrigation_preview", buildJsonObject {
            put("p_vineyard_id", vineyardId)
            put("p_valve_id", valveId)
            put("p_session_date", sessionDate)
            put("p_duration_minutes", durationMinutes)
            put("p_calculation_method", method)
            flowLph?.let { put("p_flow_litres_per_hour", it) }
            meterStart?.let { put("p_meter_start_litres", it) }
            meterFinish?.let { put("p_meter_finish_litres", it) }
            totalVolume?.let { put("p_total_volume_litres", it) }
        })))
    }

    suspend fun recordSession(pending: PendingIrrigationSession): IrrigationSessionRow =
        withContext(Dispatchers.IO) {
            decode(ensureSuccess(rpc("record_irrigation_session", buildJsonObject {
                put("p_id", pending.id)
                put("p_vineyard_id", pending.vineyardId)
                put("p_irrigation_system_id", pending.irrigationSystemId)
                put("p_valve_id", pending.valveId)
                put("p_session_date", pending.sessionDate)
                put("p_duration_minutes", pending.durationMinutes)
                put("p_calculation_method", pending.calculationMethod)
                pending.flowLph?.let { put("p_flow_litres_per_hour", it) }
                pending.meterStartLitres?.let { put("p_meter_start_litres", it) }
                pending.meterFinishLitres?.let { put("p_meter_finish_litres", it) }
                pending.totalVolumeLitres?.let { put("p_total_volume_litres", it) }
                pending.notes?.let { put("p_notes", it) }
                put("p_source_type", "manual_android")
            })))
        }

    suspend fun updateSession(
        id: String, sessionDate: String? = null, durationMinutes: Int? = null,
        method: String? = null, flowLph: Double? = null, meterStart: Double? = null,
        meterFinish: Double? = null, totalVolume: Double? = null, notes: String? = null,
        useCurrentConfiguration: Boolean = false,
    ): IrrigationSessionRow = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("update_irrigation_session", buildJsonObject {
            put("p_id", id)
            sessionDate?.let { put("p_session_date", it) }
            durationMinutes?.let { put("p_duration_minutes", it) }
            method?.let { put("p_calculation_method", it) }
            flowLph?.let { put("p_flow_litres_per_hour", it) }
            meterStart?.let { put("p_meter_start_litres", it) }
            meterFinish?.let { put("p_meter_finish_litres", it) }
            totalVolume?.let { put("p_total_volume_litres", it) }
            notes?.let { put("p_notes", it) }
            put("p_use_current_configuration", useCurrentConfiguration)
        })))
    }

    suspend fun reverseSession(id: String): IrrigationSessionRow = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("reverse_irrigation_session", buildJsonObject { put("p_id", id) })))
    }

    suspend fun getSession(id: String): IrrigationSessionRow = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("get_irrigation_session", buildJsonObject { put("p_id", id) })))
    }

    suspend fun listSessions(
        vineyardId: String, vintageYear: Int? = null, valveId: String? = null,
        status: String? = null, includeReversed: Boolean = false,
        limit: Int = 50, offset: Int = 0,
    ): IrrigationSessionList = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("list_irrigation_sessions", buildJsonObject {
            put("p_vineyard_id", vineyardId)
            vintageYear?.let { put("p_vintage_year", it) }
            valveId?.let { put("p_valve_id", it) }
            status?.let { put("p_status", it) }
            put("p_include_reversed", includeReversed)
            put("p_limit", limit)
            put("p_offset", offset)
        })))
    }

    // MARK: Reports

    suspend fun vintageSummary(vineyardId: String, vintageYear: Int? = null): IrrigationVintageSummary =
        withContext(Dispatchers.IO) { decode(ensureSuccess(summaryRpc("get_irrigation_vintage_summary", vineyardId, vintageYear))) }

    suspend fun valveSummary(vineyardId: String, vintageYear: Int? = null): List<IrrigationValveSummaryRow> =
        withContext(Dispatchers.IO) { decode(ensureSuccess(summaryRpc("get_irrigation_valve_summary", vineyardId, vintageYear))) }

    suspend fun blockSummary(vineyardId: String, vintageYear: Int? = null): List<IrrigationBlockSummaryRow> =
        withContext(Dispatchers.IO) { decode(ensureSuccess(summaryRpc("get_irrigation_block_summary", vineyardId, vintageYear))) }

    suspend fun varietySummary(vineyardId: String, vintageYear: Int? = null): List<IrrigationVarietySummaryRow> =
        withContext(Dispatchers.IO) { decode(ensureSuccess(summaryRpc("get_irrigation_variety_summary", vineyardId, vintageYear))) }

    suspend fun dailySummary(vineyardId: String, vintageYear: Int? = null): List<IrrigationDailySummaryRow> =
        withContext(Dispatchers.IO) { decode(ensureSuccess(summaryRpc("get_irrigation_daily_summary", vineyardId, vintageYear))) }

    suspend fun monthlySummary(vineyardId: String, vintageYear: Int? = null): List<IrrigationMonthlySummaryRow> =
        withContext(Dispatchers.IO) { decode(ensureSuccess(summaryRpc("get_irrigation_monthly_summary", vineyardId, vintageYear))) }

    private suspend fun summaryRpc(name: String, vineyardId: String, vintageYear: Int?): HttpResponse =
        rpc(name, buildJsonObject {
            put("p_vineyard_id", vineyardId)
            vintageYear?.let { put("p_vintage_year", it) }
        })

    // MARK: Offline pending queue

    fun pendingSessions(vineyardId: String? = null): List<PendingIrrigationSession> {
        val raw = prefs.getString(KEY_PENDING, null) ?: return emptyList()
        val all = runCatching { json.decodeFromString(pendingSerializer, raw) }.getOrDefault(emptyList())
        return if (vineyardId == null) all else all.filter { it.vineyardId == vineyardId }
    }

    fun enqueuePending(pending: PendingIrrigationSession) {
        val all = pendingSessions().toMutableList()
        if (all.none { it.id == pending.id }) {
            all.add(pending)
            prefs.edit().putString(KEY_PENDING, json.encodeToString(pendingSerializer, all)).apply()
        }
    }

    fun removePending(id: String) {
        val all = pendingSessions().filterNot { it.id == id }
        prefs.edit().putString(KEY_PENDING, json.encodeToString(pendingSerializer, all)).apply()
    }

    /** Replays queued offline sessions; server idempotency prevents duplicates. */
    suspend fun flushPending(vineyardId: String): Int {
        var flushed = 0
        for (pending in pendingSessions(vineyardId)) {
            runCatching { recordSession(pending) }
                .onSuccess {
                    removePending(pending.id)
                    flushed += 1
                }
        }
        return flushed
    }

    // Cached validations so the record form works offline.

    fun cachedValidation(vineyardId: String, valveId: String): IrrigationValveValidation? {
        val raw = prefs.getString(cacheKey(vineyardId, valveId), null) ?: return null
        return runCatching { json.decodeFromString<IrrigationValveValidation>(raw) }.getOrNull()
    }

    private fun cacheValidation(vineyardId: String, validation: IrrigationValveValidation) {
        prefs.edit().putString(
            cacheKey(vineyardId, validation.valveId),
            json.encodeToString(IrrigationValveValidation.serializer(), validation),
        ).apply()
    }

    private fun cacheKey(vineyardId: String, valveId: String) = "validation_${vineyardId}_$valveId"

    // MARK: Plumbing (mirrors SystemAdminRepository)

    private suspend fun rpc(name: String, params: JsonObject): HttpResponse {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        return SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(params)
        }
    }

    private inline fun <reified T> decode(text: String): T = json.decodeFromString(text)

    private suspend fun ensureSuccess(response: HttpResponse): String = when {
        response.status.isSuccess() -> response.bodyAsText()
        response.status.value == 401 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, friendlyError(response.bodyAsText()))
    }

    /** Extracts the human sentence from `code: message` SQL errors. */
    private fun friendlyError(body: String): String {
        val message = runCatching {
            json.decodeFromString<JsonObject>(body)["message"]?.toString()?.trim('"')
        }.getOrNull() ?: body
        val idx = message.indexOf(": ")
        return if (idx in 1..40 && message.substring(0, idx).contains('_')) {
            message.substring(idx + 2).replaceFirstChar { it.uppercase() }
        } else message
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }

    private companion object {
        const val KEY_PENDING = "pending_sessions"
    }
}

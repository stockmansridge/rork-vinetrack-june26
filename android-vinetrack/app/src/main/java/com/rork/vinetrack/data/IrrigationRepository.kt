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
    @SerialName("serviced_emitter_count") val servicedEmitterCount: Int? = null,
    @SerialName("row_start") val rowStart: Int? = null,
    @SerialName("row_end") val rowEnd: Int? = null,
    @SerialName("block_name") val blockName: String? = null,
)

/** One selectable vineyard row (from `list_irrigation_available_rows`). */
@Serializable
data class IrrigationAvailableRow(
    @SerialName("row_id") val rowId: String,
    @SerialName("block_id") val blockId: String,
    @SerialName("block_name") val blockName: String,
    @SerialName("row_number") val rowNumber: Int,
    @SerialName("row_label") val rowLabel: String? = null,
    @SerialName("vine_count") val vineCount: Int? = null,
    /** SQL 127 basis: exact | block_total_proportional | row_length_spacing | unavailable. */
    @SerialName("vine_count_basis") val vineCountBasis: String? = null,
    @SerialName("vine_count_is_estimated") val vineCountIsEstimated: Boolean? = null,
    @SerialName("emitter_count") val emitterCount: Int? = null,
    @SerialName("emitter_count_basis") val emitterCountBasis: String? = null,
    @SerialName("emitter_count_is_estimated") val emitterCountIsEstimated: Boolean? = null,
    @SerialName("row_length_metres") val rowLengthMetres: Double? = null,
    @SerialName("geometry_warning") val geometryWarning: String? = null,
    @SerialName("connected_valve_ids") val connectedValveIds: List<String> = emptyList(),
    @SerialName("connected_valve_names") val connectedValveNames: List<String> = emptyList(),
) {
    val displayLabel: String get() = rowLabel ?: "Row $rowNumber"
}

/** One saved valve→row link (from `list_irrigation_valve_rows`). */
@Serializable
data class IrrigationValveRowLink(
    val id: String,
    @SerialName("valve_id") val valveId: String,
    @SerialName("block_id") val blockId: String,
    @SerialName("row_id") val rowId: String? = null,
    @SerialName("row_number") val rowNumber: Int = 0,
    @SerialName("row_label") val rowLabel: String? = null,
    @SerialName("vine_count") val vineCount: Int? = null,
    @SerialName("vine_count_basis") val vineCountBasis: String? = null,
    @SerialName("vine_count_is_estimated") val vineCountIsEstimated: Boolean? = null,
    @SerialName("emitter_count") val emitterCount: Int? = null,
    @SerialName("emitter_count_basis") val emitterCountBasis: String? = null,
    @SerialName("emitter_count_is_estimated") val emitterCountIsEstimated: Boolean? = null,
    @SerialName("row_length_metres") val rowLengthMetres: Double? = null,
    @SerialName("weighting_basis") val weightingBasis: String? = null,
    @SerialName("row_weight") val rowWeight: Double? = null,
    @SerialName("block_name") val blockName: String? = null,
    /** Snapshot timestamp (SQL 127 `saved_at`, ISO string). */
    @SerialName("saved_at") val savedAt: String? = null,
)

/**
 * Per-block coverage vs water-share summary returned by
 * `set_irrigation_valve_rows` (SQL 127 `block_summaries`).
 */
@Serializable
data class IrrigationRowBlockSummary(
    @SerialName("block_id") val blockId: String,
    @SerialName("block_name") val blockName: String? = null,
    @SerialName("selected_row_count") val selectedRowCount: Int = 0,
    @SerialName("total_block_row_count") val totalBlockRowCount: Int? = null,
    @SerialName("selected_row_length_metres") val selectedRowLengthMetres: Double? = null,
    @SerialName("total_block_row_length_metres") val totalBlockRowLengthMetres: Double? = null,
    @SerialName("selected_vine_count") val selectedVineCount: Int? = null,
    @SerialName("selected_emitter_count") val selectedEmitterCount: Int? = null,
    @SerialName("row_coverage_percent") val rowCoveragePercent: Double? = null,
    @SerialName("length_coverage_percent") val lengthCoveragePercent: Double? = null,
    /** Server-authoritative share of the VALVE's water. */
    @SerialName("allocation_percentage") val allocationPercentage: Double? = null,
    @SerialName("weighting_basis") val weightingBasis: String? = null,
    val warnings: List<String> = emptyList(),
)

/** Result of `set_irrigation_valve_rows` — backend percentages are authoritative. */
@Serializable
data class IrrigationValveRowsResult(
    @SerialName("weighting_basis") val weightingBasis: String? = null,
    val blocks: List<IrrigationValveBlockRow> = emptyList(),
    @SerialName("block_summaries") val blockSummaries: List<IrrigationRowBlockSummary> = emptyList(),
    val warnings: List<String> = emptyList(),
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
    // SQL 131 — explicit valve flow OR emitter-derived flow available.
    @SerialName("valves_with_automatic_flow") val valvesWithAutomaticFlow: Int? = null,
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
    // SQL 131 — explicit valve flow OR emitter-derived flow available.
    @SerialName("automatic_flow_ready") val automaticFlowReady: Boolean? = null,
    @SerialName("resolved_flow_litres_per_hour") val resolvedFlowLph: Double? = null,
    @SerialName("resolved_flow_source") val resolvedFlowSource: String? = null,
    @SerialName("resolved_flow_emitter_count") val resolvedFlowEmitterCount: Int? = null,
    @SerialName("uses_rows") val usesRows: Boolean = false,
    @SerialName("row_count") val rowCount: Int = 0,
) {
    /** "Rows · 20 rows · 1 block · 100%", "Manual % · 1 block · 100%" or "Not configured". */
    val configurationSummary: String
        get() {
            if (blockCount == 0) return "Not configured"
            val parts = mutableListOf(if (usesRows) "Rows" else "Manual %")
            if (usesRows) parts += "$rowCount row${if (rowCount == 1) "" else "s"}"
            parts += "$blockCount block${if (blockCount == 1) "" else "s"}"
            parts += if (allocationOk) "100%" else String.format(java.util.Locale.US, "%.1f%%", allocationTotal)
            return parts.joinToString(" · ")
        }
}

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
    // SQL 131 resolved-flow fields (nullable so pre-131 responses and old
    // offline caches still decode).
    @SerialName("configured_flow_available") val configuredFlowAvailable: Boolean? = null,
    @SerialName("resolved_flow_litres_per_hour") val resolvedFlowLph: Double? = null,
    @SerialName("resolved_flow_source") val resolvedFlowSource: String? = null,
    @SerialName("resolved_flow_is_estimated") val resolvedFlowIsEstimated: Boolean? = null,
    @SerialName("resolved_flow_warning") val resolvedFlowWarning: String? = null,
    @SerialName("resolved_flow_emitter_count") val resolvedFlowEmitterCount: Int? = null,
    val allocations: List<IrrigationAllocationConfig> = emptyList(),
    @SerialName("allocation_total") val allocationTotal: Double = 0.0,
    val issues: List<String> = emptyList(),
) {
    /** Server-decided configured-flow availability; pre-131 falls back to the stored flow. */
    val automaticFlowAvailable: Boolean get() = configuredFlowAvailable ?: hasConfiguredFlow

    /** Flow value used for configured-flow calculations and offline previews. */
    val flowForCalculation: Double? get() = resolvedFlowLph ?: configuredFlowLph

    val resolvedFlowSourceLabel: String? get() = IrrigationLocalCalc.flowSourceLabel(resolvedFlowSource)
}

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
    // SQL 131 — how the configured flow was resolved for this preview.
    @SerialName("flow_source") val flowSource: String? = null,
    @SerialName("flow_is_estimated") val flowIsEstimated: Boolean? = null,
    @SerialName("flow_explanation") val flowExplanation: String? = null,
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
    // ISO-8601 timestamps (SQL 130) — kept as strings; parsing happens in the UI.
    @SerialName("started_at") val startedAt: String? = null,
    @SerialName("finished_at") val finishedAt: String? = null,
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
    val startedAt: String? = null,
    val finishedAt: String? = null,
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

    // MARK: Session time parity (SQL 130)

    /**
     * Minutes between two wall-clock times of day. Returns null when the
     * times are equal (a zero-minute session is invalid); an end earlier
     * than the start rolls to the following day (overnight session).
     * Mirrors `_irrigation_validate_session_times` in sql/130.
     */
    fun minutesBetweenTimes(startMinutesOfDay: Int, endMinutesOfDay: Int): Int? {
        val diff = endMinutesOfDay - startMinutesOfDay
        if (diff == 0) return null
        return if (diff > 0) diff else diff + 1440
    }

    data class SessionEnd(val minutesOfDay: Int, val daysLater: Int)

    /** End time of day for a start + duration entry (daysLater > 0 = overnight). */
    fun endOfSession(startMinutesOfDay: Int, durationMinutes: Int): SessionEnd {
        val total = startMinutesOfDay + durationMinutes
        return SessionEnd(total % 1440, total / 1440)
    }

    // MARK: Configured-flow resolution parity (SQL 131)

    /** Shared labels for SQL 131 `resolved_flow_source` values. */
    fun flowSourceLabel(source: String?): String? = when (source) {
        "measured_valve_flow" -> "Measured valve flow"
        "configured_valve_flow" -> "Configured valve flow"
        "row_emitter_flow" -> "Connected row emitters \u00D7 block emitter output"
        "block_emitter_flow" -> "Connected block emitters \u00D7 block emitter output"
        else -> null
    }

    /**
     * One connected block's flow-derivation inputs, mirroring the jsonb
     * components fed to `_irrigation_resolve_flow` in sql/131.
     */
    data class FlowComponent(
        val blockName: String,
        val isRows: Boolean,
        val emitterCount: Double?,
        val flowPerEmitterLph: Double?,
        val blockConfiguredFlowLph: Double? = null,
    )

    data class ResolvedFlow(
        val flowLitresPerHour: Double?,
        val source: String,
        val isEstimated: Boolean?,
        val warning: String?,
        val emitterCount: Int?,
    )

    /**
     * Byte-for-byte mirror of `_irrigation_resolve_flow` (sql/131):
     * measured valve flow -> configured valve flow -> connected emitter flow ->
     * unavailable. A partial total is never returned; missing components
     * resolve to null, never zero. Offline parity only — the server value is
     * always authoritative.
     */
    fun resolveFlow(
        measuredValveFlow: Double?,
        configuredValveFlow: Double?,
        components: List<FlowComponent>,
    ): ResolvedFlow {
        if (measuredValveFlow != null && measuredValveFlow > 0) {
            return ResolvedFlow(measuredValveFlow, "measured_valve_flow", false, null, null)
        }
        if (configuredValveFlow != null && configuredValveFlow > 0) {
            return ResolvedFlow(configuredValveFlow, "configured_valve_flow", false, null, null)
        }

        val warnings = mutableListOf<String>()
        var total = 0.0
        var totalEmitters = 0.0
        var allEmitters = true
        var allRows = true
        var anyResolved = false

        if (components.isEmpty()) {
            warnings.add("Automatic flow is unavailable because this valve has no active block connections.")
        }
        for (component in components) {
            if (!component.isRows) allRows = false
            val blockFlow = component.blockConfiguredFlowLph
            val emitters = component.emitterCount
            val flowPerEmitter = component.flowPerEmitterLph
            when {
                !component.isRows && blockFlow != null && blockFlow > 0 -> {
                    total += round3(blockFlow)
                    allEmitters = false
                    anyResolved = true
                }
                emitters != null && emitters > 0 && flowPerEmitter != null && flowPerEmitter > 0 -> {
                    total += round3(emitters * flowPerEmitter)
                    totalEmitters += emitters
                    anyResolved = true
                }
                else -> {
                    if ((flowPerEmitter ?: 0.0) <= 0) {
                        warnings.add("Automatic flow is unavailable because ${component.blockName} does not have a valid flow-per-emitter value.")
                    }
                    if ((emitters ?: 0.0) <= 0) {
                        warnings.add("Automatic flow is unavailable because ${component.blockName} does not have a complete saved emitter count.")
                    }
                }
            }
        }
        if (warnings.isNotEmpty() || !anyResolved) {
            if (warnings.isEmpty()) {
                warnings.add("Automatic flow is unavailable because the connected blocks cannot be safely calculated.")
            }
            return ResolvedFlow(null, "unavailable", null, warnings.first(), null)
        }
        return ResolvedFlow(
            flowLitresPerHour = round3(total),
            source = if (allRows) "row_emitter_flow" else "block_emitter_flow",
            isEstimated = true,
            warning = null,
            emitterCount = if (allEmitters && totalEmitters > 0) totalEmitters.toInt() else null,
        )
    }

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

    // =========================================================================
    // Row-based weighting — mirror of sql/126 `_irrigation_rows_weighting`.
    // PROVISIONAL previews only; the server result is always authoritative.
    // =========================================================================

    data class RowBlockShare(
        val blockId: String,
        val blockName: String,
        val rowCount: Int,
        val weight: Double,
        val percentage: Double,
    )

    data class RowWeightingResult(
        val basis: String,
        val blocks: List<RowBlockShare>,
    )

    fun basisLabel(basis: String?): String = when (basis) {
        "emitter_count" -> "Emitter count"
        "vine_count" -> "Vine count"
        "row_length" -> "Row length"
        "equal_rows" -> "Equal rows (estimate)"
        else -> basis ?: "—"
    }

    fun round4(value: Double): Double = (value * 10_000.0).roundToLong() / 10_000.0

    /**
     * Compresses ONLY genuinely contiguous runs for display:
     * [1, 2, 5, 8] → "1–2, 5, 8" (never "1–8"). Duplicates are ignored.
     */
    fun rangeSummary(rowNumbers: List<Int>): String {
        val sorted = rowNumbers.toSortedSet().toList()
        if (sorted.isEmpty()) return ""
        val parts = mutableListOf<String>()
        var start = sorted.first()
        var prev = sorted.first()
        for (n in sorted.drop(1)) {
            if (n == prev + 1) { prev = n; continue }
            parts += if (start == prev) "$start" else "$start–$prev"
            start = n
            prev = n
        }
        parts += if (start == prev) "$start" else "$start–$prev"
        return parts.joinToString(", ")
    }

    /**
     * ONE common basis for the whole selection, honouring the SQL 127 basis
     * metadata so estimates never overstate precision (spacing-derived counts
     * are just row-length weighting): emitters (exact only) → vines (exact or
     * reconciled block totals) → length → equal. Missing basis keeps the
     * legacy 'exact' interpretation (SQL 126 parity fixtures).
     */
    fun rowBasis(rows: List<IrrigationAvailableRow>): String = when {
        rows.isEmpty() -> "equal_rows"
        rows.all { (it.emitterCount ?: 0) > 0 && (it.emitterCountBasis ?: "exact") == "exact" } -> "emitter_count"
        rows.all {
            (it.vineCount ?: 0) > 0 &&
                (it.vineCountBasis ?: "exact") in listOf("exact", "block_total_proportional")
        } -> "vine_count"
        rows.all { (it.rowLengthMetres ?: 0.0) > 0 } -> "row_length"
        else -> "equal_rows"
    }

    /**
     * Same maths and rounding as the SQL core: blocks ordered by block id text,
     * 4 dp percentages, the LAST block absorbs the remainder → exactly 100.
     */
    fun rowWeighting(rows: List<IrrigationAvailableRow>): RowWeightingResult {
        if (rows.isEmpty()) return RowWeightingResult("equal_rows", emptyList())
        val basis = rowBasis(rows)

        fun weight(row: IrrigationAvailableRow): Double = when (basis) {
            "emitter_count" -> (row.emitterCount ?: 0).toDouble()
            "vine_count" -> (row.vineCount ?: 0).toDouble()
            "row_length" -> row.rowLengthMetres ?: 0.0
            else -> 1.0
        }

        val total = rows.sumOf { weight(it) }
        if (total <= 0) return RowWeightingResult(basis, emptyList())

        val grouped = rows.groupBy { it.blockId }.entries.sortedBy { it.key.lowercase() }
        var pctSum = 0.0
        val blocks = grouped.mapIndexed { index, entry ->
            val blockWeight = entry.value.sumOf { weight(it) }
            val pct = if (index < grouped.size - 1) {
                round4(blockWeight / total * 100.0).also { pctSum += it }
            } else {
                round4(100.0 - pctSum)
            }
            RowBlockShare(
                blockId = entry.key,
                blockName = entry.value.first().blockName,
                rowCount = entry.value.size,
                weight = blockWeight,
                percentage = pct,
            )
        }
        return RowWeightingResult(basis, blocks)
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

    // MARK: Row-based allocation (SQL 126)

    /** The vineyard's REAL configured rows, grouped/sortable by block. */
    suspend fun listAvailableRows(vineyardId: String, blockId: String? = null): List<IrrigationAvailableRow> =
        withContext(Dispatchers.IO) {
            decode(ensureSuccess(rpc("list_irrigation_available_rows", buildJsonObject {
                put("p_vineyard_id", vineyardId)
                blockId?.let { put("p_block_id", it) }
            })))
        }

    suspend fun listValveRows(vineyardId: String, valveId: String? = null): List<IrrigationValveRowLink> =
        withContext(Dispatchers.IO) {
            decode(ensureSuccess(rpc("list_irrigation_valve_rows", buildJsonObject {
                put("p_vineyard_id", vineyardId)
                valveId?.let { put("p_valve_id", it) }
            })))
        }

    /**
     * Atomically replaces the valve's row links; the server derives the block
     * connections and authoritative percentages (allocation_method = rows).
     */
    suspend fun setValveRows(
        vineyardId: String, valveId: String, rowIds: List<String>,
    ): IrrigationValveRowsResult = withContext(Dispatchers.IO) {
        decode(ensureSuccess(rpc("set_irrigation_valve_rows", buildJsonObject {
            put("p_vineyard_id", vineyardId)
            put("p_valve_id", valveId)
            put("p_row_ids", buildJsonArray { rowIds.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
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
                pending.startedAt?.let { put("p_started_at", it) }
                pending.finishedAt?.let { put("p_finished_at", it) }
                pending.notes?.let { put("p_notes", it) }
                put("p_source_type", "manual_android")
            })))
        }

    suspend fun updateSession(
        id: String, sessionDate: String? = null, durationMinutes: Int? = null,
        method: String? = null, flowLph: Double? = null, meterStart: Double? = null,
        meterFinish: Double? = null, totalVolume: Double? = null,
        startedAt: String? = null, finishedAt: String? = null,
        clearTimes: Boolean = false, notes: String? = null,
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
            startedAt?.let { put("p_started_at", it) }
            finishedAt?.let { put("p_finished_at", it) }
            put("p_clear_times", clearTimes)
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

package com.rork.vinetrack.data.reporting

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.SprayEquipment
import com.rork.vinetrack.data.model.resolveSprayEquipmentName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import java.text.Normalizer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Canonical semantic input for every Spray Report export. */
@Serializable
data class SprayReportPayloadV1(
    val schemaVersion: String,
    val identity: Identity,
    val trip: TripSummary,
    val blocks: List<Block>? = null,
    val equipment: Equipment,
    val rows: List<Row>,
    val tanks: List<Tank>,
    val weather: List<Weather>,
    val route: Route? = null,
    val warnings: List<String>,
) {
    @Serializable data class Identity(val tripId: String, val sprayRecordId: String, val vineyardId: String, val vineyardName: String, val reference: String, val vineyardTimeZone: String)
    @Serializable data class TripSummary(val startUtc: String?, val endUtc: String?, val activeDurationSeconds: Long?, val distanceMetres: Double?, val operatorName: String?, val pinCount: Int)
    @Serializable data class Block(val blockId: String, val name: String, val grossAreaHa: Double? = null, val treatedAreaHa: Double? = null)
    @Serializable data class Equipment(val tractorName: String?, val startEngineHours: Double?, val endEngineHours: Double?, val engineHoursUsed: Double?, val sprayUnitName: String?)
    @Serializable data class Row(val rowNumber: Double, val blockName: String?, val status: String, val source: String, val tank: JsonElement = JsonNull) {
        val tankLabel: String get() = when {
            tank is JsonPrimitive && tank.isString -> tank.content
            tank is JsonPrimitive -> "Tank ${tank.content}"
            else -> "Not recorded"
        }
    }
    @Serializable data class Tank(val tankNumber: Int, val plannedWaterLitres: Double, val actualWaterLitres: Double?, val chemicals: List<Chemical>)
    @Serializable data class Chemical(val plannedChemicalId: String, val savedChemicalId: String?, val name: String, val unit: String, val plannedAmountBase: Double, val actualAmountBase: Double?, val matchSource: String)
    @Serializable data class Weather(val sampleSlot: String, val observedAt: String?, val source: String, val sourceKind: String, val isStale: Boolean, val temperatureC: Double?, val humidityPct: Double?, val windSpeedKmh: Double?, val windGustKmh: Double?, val windDirectionDeg: Double?, val rainMm: Double?)
    @Serializable data class Route(val bucket: String, val objectPath: String, val sha256: String, val routeHash: String, val styleVersion: String)

    fun exportFileName(platform: String): String {
        val zone = runCatching { TimeZone.getTimeZone(identity.vineyardTimeZone) }.getOrDefault(TimeZone.getTimeZone("UTC"))
        val date = trip.startUtc?.let { com.rork.vinetrack.data.model.parseIsoToEpochMs(it) }?.let {
            SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = zone }.format(Date(it))
        } ?: "Not-recorded"
        return "SprayReport_${safe(identity.vineyardName, "Vineyard")}_${date}_${safe(identity.reference, "Record")}_${identity.tripId.take(8).lowercase(Locale.ROOT)}-$platform.pdf"
    }

    companion object {
        const val SCHEMA_VERSION: String = "1.0"
        const val ROUTE_STYLE_VERSION: String = "spray-route-red-green-v1"

        fun isSprayTrip(trip: Trip, linkedRecord: SprayRecord?): Boolean =
            trip.tripFunction == "spraying" || (linkedRecord?.isTemplate == false && linkedRecord.tripId == trip.id)

        fun offlineProjection(
            trip: Trip,
            record: SprayRecord,
            vineyardName: String,
            vineyardTimeZone: String,
            paddocks: List<Paddock>,
            machines: List<VineyardMachine>,
            sprayEquipment: List<SprayEquipment>,
            tankActuals: List<SprayTankActual>,
            pinCount: Int,
        ): SprayReportPayloadV1 {
            val warnings = mutableListOf<String>()
            val blocks = record.applicationGeometry?.blocks?.map { block ->
                Block(block.blockId, block.blockName ?: paddocks.firstOrNull { it.id == block.blockId }?.name ?: "Unnamed block", block.grossAreaHa, null)
            }
            if (blocks == null) warnings += "Blocks treated were not recorded."
            val singleBlockName = blocks?.singleOrNull()?.name
            val rows = trip.rowSequence.sorted().map { rowNumber ->
                val (status, source) = when {
                    trip.completedPaths.orEmpty().contains(rowNumber) -> "Complete" to "completedPaths"
                    trip.skippedPaths.orEmpty().contains(rowNumber) -> "Skipped/Not complete" to "skippedPaths"
                    else -> "Partial" to "incompletePlannedPath"
                }
                val exact = trip.tankSessions.filter { rowNumber in it.pathsCovered }.map { it.tankNumber }.toSet()
                val planned = record.tanks.orEmpty().filter { tank -> tank.rowApplications.any { rowNumber in minOf(it.startRow, it.endRow)..maxOf(it.startRow, it.endRow) } }.map { it.tankNumber }.toSet()
                val legacy = if (exact.isEmpty() && planned.isEmpty()) trip.tankSessions.filter { session ->
                    val start = session.startRow ?: return@filter false
                    val end = session.endRow ?: return@filter false
                    val startIndex = trip.rowSequence.indexOf(start)
                    val endIndex = trip.rowSequence.indexOf(end)
                    val rowIndex = trip.rowSequence.indexOf(rowNumber)
                    startIndex >= 0 && endIndex >= 0 && rowIndex in minOf(startIndex, endIndex)..maxOf(startIndex, endIndex)
                }.map { it.tankNumber }.toSet() else emptySet()
                val matches = exact.ifEmpty { planned.ifEmpty { legacy } }
                val tank: JsonElement = when (matches.size) {
                    0 -> JsonNull
                    1 -> JsonPrimitive(matches.first())
                    else -> JsonPrimitive("Multiple")
                }
                Row(rowNumber, singleBlockName, status, source, tank)
            }
            if (rows.any { it.tank is JsonPrimitive && it.tank.content == "Multiple" }) warnings += "One or more rows overlap multiple tank sessions."
            val tanks = record.tanks.orEmpty().sortedBy { it.tankNumber }.map { plannedTank ->
                val actual = tankActuals.filter { it.tankNumber == plannedTank.tankNumber }.maxByOrNull { it.clientUpdatedAt }
                val chemicals = plannedTank.chemicals.map { planned ->
                    val byPlan = actual?.chemicals.orEmpty().filter { it.plannedChemicalId == planned.id }
                    val bySaved = planned.savedChemicalId?.let { saved -> actual?.chemicals.orEmpty().filter { it.savedChemicalId == saved } }.orEmpty()
                    val byNameUnit = actual?.chemicals.orEmpty().filter { it.name.trim().lowercase() == planned.name.trim().lowercase() && it.unit.equals(planned.unit, true) }
                    val selected: com.rork.vinetrack.data.model.SprayTankActualChemical?
                    val matchSource: String
                    when {
                        byPlan.size == 1 -> { selected = byPlan.first(); matchSource = "plannedChemicalId" }
                        byPlan.size > 1 -> { selected = null; matchSource = "ambiguous" }
                        bySaved.size == 1 -> { selected = bySaved.first(); matchSource = "savedChemicalId" }
                        bySaved.size > 1 -> { selected = null; matchSource = "ambiguous" }
                        byNameUnit.size == 1 -> { selected = byNameUnit.first(); matchSource = "nameUnit" }
                        byNameUnit.size > 1 -> { selected = null; matchSource = "ambiguous" }
                        else -> { selected = null; matchSource = "notRecorded" }
                    }
                    Chemical(planned.id, planned.savedChemicalId, planned.name.ifBlank { "Unnamed chemical" }, planned.unit, planned.volumePerTank, selected?.actualAmountBase, matchSource)
                }
                Tank(plannedTank.tankNumber, plannedTank.waterVolume, actual?.waterVolumeL, chemicals)
            }
            val weather = if (record.temperature != null || record.humidity != null || record.windSpeed != null || !record.windDirection.isNullOrBlank()) {
                warnings += "Hourly weather was not recorded; showing the legacy start snapshot."
                listOf(Weather(record.startTime ?: record.date ?: "", null, "Legacy start snapshot", "manual", true, record.temperature, record.humidity, record.windSpeed, null, null, null))
            } else {
                warnings += "No hourly weather observations were recorded."
                emptyList()
            }
            warnings += "Shared route image is not available yet; this export uses the deterministic v1 route renderer."
            val machineName = record.displayMachine(machines)
            val unitName = resolveSprayEquipmentName(record, sprayEquipment)
            return SprayReportPayloadV1(
                SCHEMA_VERSION,
                Identity(trip.id, record.id, trip.vineyardId, vineyardName, record.sprayReference.orEmpty(), vineyardTimeZone),
                TripSummary(trip.startTime, trip.endTime, trip.activeDurationSeconds, trip.totalDistance, trip.personName?.takeIf { it.isNotBlank() }, pinCount),
                blocks,
                Equipment(machineName, trip.startEngineHours, trip.endEngineHours, trip.engineHoursUsed, unitName),
                rows, tanks, weather, null, warnings.distinct(),
            )
        }

        private fun safe(value: String, fallback: String): String {
            val normalized = Normalizer.normalize(value.trim(), Normalizer.Form.NFC).replace(Regex("\\s+"), "_")
            val filtered = normalized.replace(Regex("[^\\p{L}\\p{N}_-]"), "").replace(Regex("_+"), "_")
            return filtered.ifBlank { fallback }
        }
    }
}

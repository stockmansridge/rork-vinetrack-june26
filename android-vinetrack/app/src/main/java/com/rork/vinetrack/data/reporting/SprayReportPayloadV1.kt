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
    val amendments: List<Amendment> = emptyList(),
    val warnings: List<String>,
    val actualChemicalTotals: List<ChemicalTotal> = emptyList(),
    val plannedChemicalTotals: List<ChemicalTotal> = emptyList(),
    val application: Application? = null,
    val programStep: ProgramStep? = null,
    val tankSessions: List<TankSessionSummary> = emptyList(),
    val cost: Cost? = null,
    val metadataCorrectionVersion: Long = 0,
    val metadataAmendments: List<MetadataAmendment> = emptyList(),
    val provenance: Provenance? = null,
    val recordingEvidence: RecordingEvidence? = null,
) {
    @Serializable data class Identity(val tripId: String, val sprayRecordId: String, val vineyardId: String, val vineyardName: String, val reference: String, val vineyardTimeZone: String)
    @Serializable data class Provenance(val source: String? = null, val manualEntryId: String? = null, val isManualEntry: Boolean, val label: String)
    @Serializable data class RecordingEvidence(val route: String? = null, val rows: String? = null)
    @Serializable data class TripSummary(val startUtc: String?, val endUtc: String?, val activeDurationSeconds: Long?, val distanceMetres: Double?, val operatorName: String?, val pinCount: Int, val operatorId: String? = null, val operatorSource: String? = null, val elapsedDurationSeconds: Long? = null, val pausedDurationSeconds: Long? = null)
    @Serializable data class Block(val blockId: String, val name: String, val grossAreaHa: Double? = null, val treatedAreaHa: Double? = null)
    @Serializable data class Equipment(val tractorName: String?, val startEngineHours: Double?, val endEngineHours: Double?, val engineHoursUsed: Double?, val sprayUnitName: String?, val machineId: String? = null, val tractorId: String? = null, val sprayEquipmentId: String? = null, val equipmentSource: String? = null, val tractorGear: String? = null, val numberOfFansJets: String? = null, val averageSpeedKmh: Double? = null, val fuelConsumptionLPerHour: Double? = null, val fuelConsumptionSource: String? = null, val fuelHours: Double? = null, val fuelHoursSource: String? = null)
    @Serializable data class Application(val operationType: String? = null, val applicationMode: String? = null, val grossAreaHa: Double? = null, val treatedAreaHa: Double? = null, val treatedAreaMethod: String? = null, val geometrySource: String? = null, val geometryQuality: String? = null, val carrierVolumeBasis: String? = null, val totalCarrierLitres: Double? = null, val carrierLitresPerHectare: Double? = null, val diluteLitresPer100m: Double? = null, val appliedLitresPer100m: Double? = null, val concentrationFactor: Double? = null, val notes: String? = null, val actualUseBasis: String? = null)
    @Serializable data class ProgramStep(val linkState: String, val sprayJobId: String? = null, val name: String? = null, val status: String? = null, val plannedDate: String? = null, val operationType: String? = null, val target: String? = null, val notes: String? = null)
    @Serializable data class TankSessionSummary(val tankSessionId: String? = null, val tankNumber: Int, val startedAt: String? = null, val endedAt: String? = null, val startRow: Double? = null, val endRow: Double? = null, val pathsCovered: List<Double> = emptyList(), val status: String, val assignmentSource: String)
    @Serializable data class Cost(val visibility: String, val currencyCode: String, val fuelLitres: Double? = null, val fuelRateLPerHour: Double? = null, val fuelHours: Double? = null, val fuelPricePerLitre: Double? = null, val fuelCost: Double? = null, val chemicalCost: Double? = null, val chemicalCostBasis: String? = null, val labourRatePerHour: Double? = null, val labourRateSource: String? = null, val labourCost: Double? = null, val knownCostSubtotal: Double? = null, val totalCost: Double? = null, val treatedAreaHa: Double? = null, val costPerTreatedHa: Double? = null, val isComplete: Boolean, val incompleteReasons: List<CostReason> = emptyList(), val basis: String)
    @Serializable data class CostReason(val component: String, val code: String, val kind: String)
    @Serializable data class MetadataAmendment(val id: String, val operationId: String, val revision: Long, val previousValue: JsonElement, val newValue: JsonElement, val editedBy: String, val editorName: String, val editedAt: String)
    @Serializable data class Row(val rowNumber: Double, val blockName: String?, val status: String, val source: String, val tank: JsonElement = JsonNull, val rowIdentity: String? = null, val blockId: String? = null, val confidence: Double? = null, val isDerived: Boolean? = null, val tankSessionId: String? = null, val originalEvidence: JsonElement = JsonNull) {
        val tankLabel: String get() = when {
            tank is JsonPrimitive && tank.isString -> tank.content
            tank is JsonPrimitive -> "Tank ${tank.content}"
            else -> "Not recorded"
        }
    }
    @Serializable data class Tank(val tankNumber: Int, val actualId: String? = null, val actualVersion: Long? = null, val plannedWaterLitres: Double?, val actualWaterLitres: Double?, val chemicals: List<Chemical>)
    @Serializable data class Chemical(val actualChemicalId: String? = null, val plannedChemicalId: String? = null, val savedChemicalId: String?, val replacesPlannedChemicalId: String? = null, val usageKind: String = "planned", val name: String, val unit: String, val plannedAmountBase: Double? = null, val actualAmountBase: Double?, val matchSource: String, val productCategory: String? = null, val physicalForm: String? = null, val snapshotAt: String? = null)
    @Serializable data class ChemicalTotal(val identityKey: String, val name: String, val unit: String, val actualAmountBase: Double)
    @Serializable data class Amendment(val id: String, val operationId: String, val tankNumber: Int, val chemicalActualId: String? = null, val plannedChemicalId: String? = null, val savedChemicalId: String? = null, val field: String, val changeKind: String, val previousValue: JsonElement = JsonNull, val newValue: JsonElement = JsonNull, val previousUnit: String? = null, val newUnit: String? = null, val revision: Long, val editedBy: String, val editorName: String, val editedAt: String)
    @Serializable data class Weather(val sampleSlot: String, val observedAt: String?, val source: String, val sourceKind: String, val isStale: Boolean, val temperatureC: Double?, val humidityPct: Double?, val windSpeedKmh: Double?, val windGustKmh: Double?, val windDirectionDeg: Double?, val rainMm: Double?, val provider: String? = null, val stationId: String? = null, val stationName: String? = null, val retrievalMode: String? = null, val providerRecordId: String? = null, val retrievedAt: String? = null, val retrievalHistory: List<WeatherAttempt> = emptyList())
    @Serializable data class WeatherAttempt(val provider: String, val stationId: String? = null, val stationName: String? = null, val retrievalMode: String, val outcome: String, val observedAt: String? = null, val source: String? = null, val temperatureC: Double? = null, val humidityPct: Double? = null, val windSpeedKmh: Double? = null, val windGustKmh: Double? = null, val windDirectionDeg: Double? = null, val rainMm: Double? = null, val isStale: Boolean? = null, val providerRecordId: String? = null, val retrievedAt: String)
    @Serializable data class Route(val bucket: String, val objectPath: String, val sha256: String, val routeHash: String, val styleVersion: String)

    fun exportFileName(platform: String): String {
        val zone = runCatching { TimeZone.getTimeZone(identity.vineyardTimeZone) }.getOrDefault(TimeZone.getTimeZone("UTC"))
        val date = trip.startUtc?.let { com.rork.vinetrack.data.model.parseIsoToEpochMs(it) }?.let {
            SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = zone }.format(Date(it))
        } ?: "Not-recorded"
        return "SprayReport_${safe(identity.vineyardName, "Vineyard")}_${date}_${safe(identity.reference, "Record")}_${identity.tripId.take(8).lowercase(Locale.ROOT)}-$platform.pdf"
    }

    companion object {
        const val SCHEMA_VERSION: String = "1.2"
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
            val isManual = record.entrySource == "manual"
            val rows = (if (isManual) emptyList() else trip.rowSequence.sorted()).map { rowNumber ->
                val (status, source) = when {
                    trip.completedPaths.orEmpty().contains(rowNumber) -> "Complete" to "completedPaths"
                    trip.skippedPaths.orEmpty().contains(rowNumber) -> "Skipped/Not complete" to "skippedPaths"
                    else -> "Not recorded" to "noProgressEvidence"
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
            val trackedTanks = record.tanks.orEmpty().sortedBy { it.tankNumber }.map { plannedTank ->
                val actual = tankActuals.filter { it.tankNumber == plannedTank.tankNumber }.maxByOrNull { it.clientUpdatedAt }
                val chemicals = plannedTank.chemicals.map { planned ->
                    val byPlan = actual?.chemicals.orEmpty().filter { it.plannedChemicalId == planned.id }
                    val bySaved = planned.savedChemicalId?.let { saved -> actual?.chemicals.orEmpty().filter { it.savedChemicalId == saved && (it.usageKind ?: "planned") == "planned" } }.orEmpty()
                    val byNameUnit = actual?.chemicals.orEmpty().filter { it.name.trim().lowercase() == planned.name.trim().lowercase() && it.unit.equals(planned.unit, true) && (it.usageKind ?: "planned") == "planned" }
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
                    Chemical(selected?.id, planned.id, planned.savedChemicalId, null, "planned", planned.name.ifBlank { "Unnamed chemical" }, planned.unit, planned.volumePerTank, selected?.actualAmountBase, matchSource)
                }
                val representedIds = chemicals.mapNotNull { it.actualChemicalId }.toSet()
                val actualOnly = actual?.chemicals.orEmpty().filter { it.id !in representedIds }.map { line ->
                    Chemical(line.id, null, line.savedChemicalId, line.replacesPlannedChemicalId, line.usageKind ?: "additional", line.name, line.unit, null, line.actualAmountBase, "actualOnly")
                }
                Tank(plannedTank.tankNumber, actual?.id, actual?.correctionVersion, plannedTank.waterVolume, actual?.waterVolumeL, chemicals + actualOnly)
            }
            val tanks = if (isManual) tankActuals.sortedBy { it.tankNumber }.map { actual ->
                Tank(actual.tankNumber, actual.id, actual.correctionVersion, null, actual.waterVolumeL, actual.chemicals.map { line ->
                    Chemical(line.id, null, line.savedChemicalId, null, "additional", line.name, line.unit, null, line.actualAmountBase, "actualOnly", line.productCategory, line.physicalForm, line.snapshotAt)
                })
            } else trackedTanks
            val actualChemicalTotals = tanks.flatMap { it.chemicals }.filter { it.actualAmountBase != null }
                .groupBy { it.savedChemicalId ?: "${it.name.trim().lowercase()}|${it.unit.lowercase()}" }
                .map { (key, lines) -> ChemicalTotal(key, lines.first().name, lines.first().unit, lines.sumOf { it.actualAmountBase ?: 0.0 }) }
                .sortedBy { it.name.lowercase() }
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
                schemaVersion = SCHEMA_VERSION,
                identity = Identity(trip.id, record.id, trip.vineyardId, vineyardName, record.sprayReference.orEmpty(), vineyardTimeZone),
                trip = TripSummary(trip.startTime, trip.endTime, trip.activeDurationSeconds, trip.totalDistance, trip.personName?.takeIf { it.isNotBlank() }, pinCount),
                blocks = blocks,
                equipment = Equipment(machineName, trip.startEngineHours, trip.endEngineHours, trip.engineHoursUsed, unitName),
                rows = rows,
                tanks = tanks,
                weather = weather,
                warnings = warnings.distinct(),
                actualChemicalTotals = actualChemicalTotals,
                plannedChemicalTotals = if (isManual) emptyList() else emptyList(),
                application = if (isManual) Application(operationType = record.operationType, carrierVolumeBasis = "manual_actual_total", totalCarrierLitres = tankActuals.mapNotNull { it.waterVolumeL }.sum(), notes = record.notes, actualUseBasis = "manually_recorded_actual_use") else null,
                provenance = Provenance(record.entrySource, record.manualEntryId, isManual, if (isManual) "Manual entry" else if (record.entrySource == "tracked") "Tracked application" else "Origin not recorded"),
                recordingEvidence = if (isManual) RecordingEvidence("Not recorded — manual application", "Not recorded — manual application") else null,
            )
        }

        private fun safe(value: String, fallback: String): String {
            val normalized = Normalizer.normalize(value.trim(), Normalizer.Form.NFC).replace(Regex("\\s+"), "_")
            val filtered = normalized.replace(Regex("[^\\p{L}\\p{N}_-]"), "").replace(Regex("_+"), "_")
            return filtered.ifBlank { fallback }
        }
    }
}

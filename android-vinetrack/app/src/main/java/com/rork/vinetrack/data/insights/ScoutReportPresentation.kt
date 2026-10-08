package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin

/** Read-only location/value projection shared by Scout maps, previews and offline PDFs. */
object ScoutReportPresentation {
    const val LEGEND = "O = measured observation (blue); P = photograph capture (orange); E-R = linked E-L record, E-P = linked E-L pin (green). Boundaries are context, not measured locations. References identify the item and photograph below."

    data class Location(
        val reference: String,
        val observationId: String,
        val photoId: String? = null,
        val block: String,
        val item: String,
        val source: String,
        val latitude: Double,
        val longitude: Double,
    ) {
        val label: String get() = "$reference • $block • $item • $source"
    }

    data class Locations(val markers: List<Location>, val unavailable: List<String>, val photoReferences: Map<String, String>, val boundaryUnavailable: List<String>)

    fun valid(latitude: Double?, longitude: Double?): Boolean = latitude != null && longitude != null &&
        latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0

    private fun record(observation: ScoutObservation, vineyardId: String, records: List<GrowthStageRecord>): GrowthStageRecord? =
        records.firstOrNull { it.id == observation.linkedGrowthStageRecordId && it.vineyardId == vineyardId && it.deletedAt == null }

    fun growthValue(observation: ScoutObservation?, vineyardId: String, records: List<GrowthStageRecord>): String {
        if (observation == null) return "Not assessed"
        record(observation, vineyardId, records)?.let { return "${it.displayStage} (linked canonical record)" }
        val saved = observation.valueLabel?.takeIf { it.isNotBlank() } ?: observation.valueCode?.takeIf { it.isNotBlank() }
        return saved?.let { "$it (saved snapshot — linked canonical record unavailable locally)" }
            ?: if (observation.linkedGrowthStageRecordId != null) "Linked canonical record unavailable locally; saved snapshot unavailable" else "Not assessed"
    }

    fun locations(visit: ScoutVisit, blocks: List<Paddock>, records: List<GrowthStageRecord>, pins: List<Pin>): Locations {
        val markers = mutableListOf<Location>()
        val unavailable = mutableListOf<String>()
        val boundaryUnavailable = mutableListOf<String>()
        val photoReferences = mutableMapOf<String, String>()
        var observationNumber = 0
        var photoNumber = 0
        fun blockName(id: String?): String = blocks.firstOrNull { it.id == id }?.name ?: "Block ${id ?: "unavailable"}"
        visit.assessments.forEach { assessment ->
            val polygon = blocks.firstOrNull { it.id == assessment.paddockId }?.polygonPoints.orEmpty()
            if (polygon.size < 3 || polygon.any { !valid(it.latitude, it.longitude) }) {
                boundaryUnavailable += "Boundary unavailable — ${blockName(assessment.paddockId)}; recorded markers are retained."
            }
            assessment.observations.filter { it.hasContent || it.linkedPinId != null ||
                (it.item == ScoutItem.GROWTH_STAGE && !it.valueLabel.isNullOrBlank()) }.forEach { observation ->
                observationNumber++
                val reference = "O$observationNumber"
                val block = blockName(assessment.paddockId)
                fun add(ref: String, source: String, latitude: Double?, longitude: Double?, actualBlock: String = block, photoId: String? = null): Boolean {
                    if (!valid(latitude, longitude)) return false
                    markers += Location(ref, observation.id, photoId, actualBlock, observation.item.label, source, latitude!!, longitude!!)
                    return true
                }
                if (observation.locationStatus != PhotoLocationStatus.GPS_CONFIRMED ||
                    !add(reference, "Measured observation", observation.latitude, observation.longitude)) {
                    unavailable += "$reference • $block • ${observation.item.label} — measured observation location unavailable"
                }
                observation.photos.forEach { photo ->
                    photoNumber++
                    val photoReference = "P$photoNumber"
                    photoReferences[photo.id] = photoReference
                    if (photo.locationStatus != PhotoLocationStatus.GPS_CONFIRMED ||
                        !add(photoReference, "Photograph capture", photo.latitude, photo.longitude, photoId = photo.id)) {
                        unavailable += "$photoReference • $block • ${observation.item.label} — photograph capture location unavailable"
                    }
                }
                if (observation.item == ScoutItem.GROWTH_STAGE && (observation.linkedGrowthStageRecordId != null || observation.linkedPinId != null)) {
                    val linked = record(observation, visit.vineyardId, records)
                    if (observation.linkedGrowthStageRecordId != null) {
                        val located = linked?.let { add("E-R$observationNumber", "Linked E-L record", it.latitude, it.longitude, blockName(it.paddockId)) } ?: false
                        if (!located) unavailable += "E-R$observationNumber • $block • ${observation.item.label} — linked E-L record location unavailable locally"
                    }
                    val pinIds = listOfNotNull(observation.linkedPinId, linked?.pinId).distinct()
                    pinIds.forEachIndexed { index, id ->
                        val pinReference = "E-P$observationNumber" + if (index == 0) "" else "R"
                        val pin = pins.firstOrNull { it.id == id && it.vineyardId == visit.vineyardId && it.deletedAt == null }
                        val located = pin?.let { add(pinReference, "Linked E-L pin" + if (it.locationScope == "block") " (block-level, not measured)" else "", it.latitude, it.longitude, blockName(it.paddockId)) } ?: false
                        if (!located) unavailable += "$pinReference • $block • ${observation.item.label} — linked E-L pin location unavailable locally"
                    }
                }
            }
        }
        return Locations(markers, unavailable, photoReferences, boundaryUnavailable)
    }
}

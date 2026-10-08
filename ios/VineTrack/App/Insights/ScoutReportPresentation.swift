import CoreLocation
import Foundation

/// Read-only projection shared by Scout maps, previews and the existing offline PDF renderer.
enum ScoutReportPresentation {
    static let legend = "O = measured observation (blue); P = photograph capture (orange); E-R = linked E-L record, E-P = linked E-L pin (green). Boundaries are context, not measured locations. References identify the item and photograph below."

    struct Locations {
        var markers: [ScoutReportMarker] = []
        var unavailable: [String] = []
        var boundaryUnavailable: [String] = []
        var photoReferences: [UUID: String] = [:]
    }

    static func coordinate(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func record(_ observation: ScoutObservation, vineyardID: UUID, records: [GrowthStageRecord]) -> GrowthStageRecord? {
        records.first { $0.id == observation.linkedGrowthStageRecordID && $0.vineyardId == vineyardID }
    }

    static func growthValue(_ observation: ScoutObservation?, vineyardID: UUID, records: [GrowthStageRecord]) -> String {
        guard let observation else { return "Not assessed" }
        if let record = record(observation, vineyardID: vineyardID, records: records) {
            let label = GrowthStage.allStages.first { $0.code == record.stageCode }?.displayName ?? record.stageLabel ?? record.stageCode
            return label + " (linked canonical record)"
        }
        if let saved = [observation.valueLabel, observation.valueCode].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return saved + " (saved snapshot — linked canonical record unavailable locally)"
        }
        return observation.linkedGrowthStageRecordID == nil ? "Not assessed" : "Linked canonical record unavailable locally; saved snapshot unavailable"
    }

    static func locations(visit: ScoutVisit, blocks: [Paddock], records: [GrowthStageRecord], pins: [VinePin]) -> Locations {
        var result = Locations()
        var observationNumber = 0
        var photoNumber = 0
        func blockName(_ id: UUID?) -> String {
            blocks.first { $0.id == id }?.name ?? "Block \(id?.uuidString ?? "unavailable")"
        }
        for assessment in visit.assessments {
            let polygon = blocks.first { $0.id == assessment.paddockID }?.polygonPoints ?? []
            if polygon.count < 3 || polygon.contains(where: { coordinate($0.latitude, $0.longitude) == nil }) {
                result.boundaryUnavailable.append("Boundary unavailable — \(blockName(assessment.paddockID)); recorded markers are retained.")
            }
            for observation in assessment.observations where observation.hasContent || observation.linkedPinID != nil
                || (observation.item == .growthStage && !(observation.valueLabel ?? "").isEmpty) {
                observationNumber += 1
                let reference = "O\(observationNumber)"
                let block = blockName(assessment.paddockID)
                func add(_ ref: String, _ source: String, _ latitude: Double?, _ longitude: Double?, actualBlock: String? = nil, photo: ScoutPhoto? = nil) -> Bool {
                    guard let coordinate = coordinate(latitude, longitude) else { return false }
                    result.markers.append(ScoutReportMarker(id: observation.id.uuidString + ":" + ref,
                        reference: ref, observationID: observation.id, title: observation.item.label,
                        subtitle: (actualBlock ?? block) + " • " + observation.item.label, source: source,
                        coordinate: coordinate, photo: photo))
                    return true
                }
                if observation.locationStatus != .gpsConfirmed || !add(reference, "Measured observation", observation.latitude, observation.longitude) {
                    result.unavailable.append("\(reference) • \(block) • \(observation.item.label) — measured observation location unavailable")
                }
                for photo in observation.photos {
                    photoNumber += 1
                    let photoReference = "P\(photoNumber)"
                    result.photoReferences[photo.id] = photoReference
                    if photo.locationStatus != .gpsConfirmed || !add(photoReference, "Photograph capture", photo.latitude, photo.longitude, photo: photo) {
                        result.unavailable.append("\(photoReference) • \(block) • \(observation.item.label) — photograph capture location unavailable")
                    }
                }
                if observation.item == .growthStage && (observation.linkedGrowthStageRecordID != nil || observation.linkedPinID != nil) {
                    let linked = record(observation, vineyardID: visit.vineyardID, records: records)
                    if observation.linkedGrowthStageRecordID != nil {
                        let located = linked.map { add("E-R\(observationNumber)", "Linked E-L record", $0.latitude, $0.longitude, actualBlock: blockName($0.paddockId)) } ?? false
                        if !located { result.unavailable.append("E-R\(observationNumber) • \(block) • \(observation.item.label) — linked E-L record location unavailable locally") }
                    }
                    var pinIDs: [UUID] = []
                    if let id = observation.linkedPinID { pinIDs.append(id) }
                    if let id = linked?.pinId, !pinIDs.contains(id) { pinIDs.append(id) }
                    for (index, id) in pinIDs.enumerated() {
                        let reference = "E-P\(observationNumber)" + (index == 0 ? "" : "R")
                        let pin = pins.first { $0.id == id && $0.vineyardId == visit.vineyardID }
                        let located = pin.map { add(reference, "Linked E-L pin" + ($0.locationScope == "block" ? " (block-level, not measured)" : ""), $0.latitude, $0.longitude, actualBlock: blockName($0.paddockId)) } ?? false
                        if !located { result.unavailable.append("\(reference) • \(block) • \(observation.item.label) — linked E-L pin location unavailable locally") }
                    }
                }
            }
        }
        return result
    }
}

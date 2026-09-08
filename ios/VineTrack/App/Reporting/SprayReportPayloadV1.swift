import Foundation

/// Canonical semantic input for every Spray Report export.
nonisolated struct SprayReportPayloadV1: Codable, Sendable, Hashable {
    static let currentSchemaVersion: String = "1.0"
    static let routeStyleVersion: String = "spray-route-red-green-v1"

    let schemaVersion: String
    let identity: Identity
    let trip: TripSummary
    let blocks: [Block]?
    let equipment: Equipment
    let rows: [Row]
    let tanks: [Tank]
    let weather: [Weather]
    let route: Route?
    let warnings: [String]

    nonisolated struct Identity: Codable, Sendable, Hashable {
        let tripId: UUID
        let sprayRecordId: UUID
        let vineyardId: UUID
        let vineyardName: String
        let reference: String
        let vineyardTimeZone: String
    }

    nonisolated struct TripSummary: Codable, Sendable, Hashable {
        let startUtc: String?
        let endUtc: String?
        let activeDurationSeconds: Int?
        let distanceMetres: Double?
        let operatorName: String?
        let pinCount: Int
    }

    nonisolated struct Block: Codable, Sendable, Hashable {
        let blockId: String
        let name: String
        let grossAreaHa: Double?
        let treatedAreaHa: Double?
    }

    nonisolated struct Equipment: Codable, Sendable, Hashable {
        let tractorName: String?
        let startEngineHours: Double?
        let endEngineHours: Double?
        let engineHoursUsed: Double?
        let sprayUnitName: String?
    }

    nonisolated struct Row: Codable, Sendable, Hashable {
        let rowNumber: Double
        let blockName: String?
        let status: String
        let source: String
        let tank: TankReference?
    }

    nonisolated enum TankReference: Codable, Sendable, Hashable {
        case number(Int)
        case multiple

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) { self = .number(number); return }
            if try container.decode(String.self) == "Multiple" { self = .multiple; return }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid tank reference")
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let number): try container.encode(number)
            case .multiple: try container.encode("Multiple")
            }
        }

        var displayText: String {
            switch self {
            case .number(let number): "Tank \(number)"
            case .multiple: "Multiple"
            }
        }
    }

    nonisolated struct Tank: Codable, Sendable, Hashable {
        let tankNumber: Int
        let plannedWaterLitres: Double
        let actualWaterLitres: Double?
        let chemicals: [Chemical]
    }

    nonisolated struct Chemical: Codable, Sendable, Hashable {
        let plannedChemicalId: UUID
        let savedChemicalId: UUID?
        let name: String
        let unit: String
        let plannedAmountBase: Double
        let actualAmountBase: Double?
        let matchSource: String
    }

    nonisolated struct Weather: Codable, Sendable, Hashable {
        let sampleSlot: String
        let observedAt: String?
        let source: String
        let sourceKind: String
        let isStale: Bool
        let temperatureC: Double?
        let humidityPct: Double?
        let windSpeedKmh: Double?
        let windGustKmh: Double?
        let windDirectionDeg: Double?
        let rainMm: Double?
    }

    nonisolated struct Route: Codable, Sendable, Hashable {
        let bucket: String
        let objectPath: String
        let sha256: String
        let routeHash: String
        let styleVersion: String
    }

    static func isSprayTrip(_ trip: Trip, linkedRecord: SprayRecord?) -> Bool {
        trip.tripFunction == TripFunction.spraying.rawValue || (linkedRecord?.isTemplate == false && linkedRecord?.tripId == trip.id)
    }

    static func offlineProjection(
        trip: Trip,
        record: SprayRecord,
        vineyardName: String,
        timeZone: TimeZone,
        paddocks: [Paddock],
        tractorName: String,
        sprayUnitName: String,
        tankActuals: [SprayTankActual]
    ) -> SprayReportPayloadV1 {
        let iso = ISO8601DateFormatter()
        let blockSnapshots = record.applicationGeometry?.blocks
        let canonicalBlocks: [Block]? = blockSnapshots?.map { block in
            Block(
                blockId: block.blockId,
                name: block.blockName ?? paddocks.first(where: { $0.id.uuidString == block.blockId })?.name ?? "Unnamed block",
                grossAreaHa: block.grossAreaHa,
                treatedAreaHa: nil
            )
        }
        let singleBlockName = canonicalBlocks?.count == 1 ? canonicalBlocks?.first?.name : nil
        var warnings: [String] = []
        if canonicalBlocks == nil { warnings.append("Blocks treated were not recorded.") }

        let rows: [Row] = trip.rowSequence.sorted().map { rowNumber in
            let status: String
            let source: String
            if trip.completedPaths.contains(rowNumber) {
                status = "Complete"; source = "completedPaths"
            } else if trip.skippedPaths.contains(rowNumber) {
                status = "Skipped/Not complete"; source = "skippedPaths"
            } else {
                status = "Partial"; source = "incompletePlannedPath"
            }
            let exact = Set(trip.tankSessions.filter { $0.pathsCovered.contains(rowNumber) }.map(\.tankNumber))
            let planned = Set(record.tanks.filter { tank in
                tank.rowApplications.contains { rowNumber >= min($0.startRow, $0.endRow) && rowNumber <= max($0.startRow, $0.endRow) }
            }.map(\.tankNumber))
            let legacy = Set(trip.tankSessions.filter { session in
                guard exact.isEmpty, planned.isEmpty, let start = session.startRow, let end = session.endRow,
                      let startIndex = trip.rowSequence.firstIndex(of: start), let endIndex = trip.rowSequence.firstIndex(of: end),
                      let rowIndex = trip.rowSequence.firstIndex(of: rowNumber) else { return false }
                return rowIndex >= min(startIndex, endIndex) && rowIndex <= max(startIndex, endIndex)
            }.map(\.tankNumber))
            let matches = !exact.isEmpty ? exact : (!planned.isEmpty ? planned : legacy)
            let tank: TankReference? = matches.count > 1 ? .multiple : matches.first.map(TankReference.number)
            return Row(rowNumber: rowNumber, blockName: singleBlockName, status: status, source: source, tank: tank)
        }
        if rows.contains(where: { $0.tank == .multiple }) { warnings.append("One or more rows overlap multiple tank sessions.") }

        let tanks: [Tank] = record.tanks.sorted(by: { $0.tankNumber < $1.tankNumber }).map { planned in
            let actual = tankActuals.filter { $0.tankNumber == planned.tankNumber }.max(by: { $0.clientUpdatedAt < $1.clientUpdatedAt })
            let chemicals: [Chemical] = planned.chemicals.map { line in
                let byPlan = actual?.chemicals.filter { $0.plannedChemicalId == line.id } ?? []
                let bySaved = line.savedChemicalId.map { id in actual?.chemicals.filter { $0.savedChemicalId == id } ?? [] } ?? []
                let byNameUnit = actual?.chemicals.filter {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == line.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.unit == line.unit
                } ?? []
                let match: SprayTankActualChemical?
                let source: String
                if byPlan.count == 1 { match = byPlan[0]; source = "plannedChemicalId" }
                else if byPlan.count > 1 { match = nil; source = "ambiguous" }
                else if bySaved.count == 1 { match = bySaved[0]; source = "savedChemicalId" }
                else if bySaved.count > 1 { match = nil; source = "ambiguous" }
                else if byNameUnit.count == 1 { match = byNameUnit[0]; source = "nameUnit" }
                else if byNameUnit.count > 1 { match = nil; source = "ambiguous" }
                else { match = nil; source = "notRecorded" }
                return Chemical(plannedChemicalId: line.id, savedChemicalId: line.savedChemicalId, name: line.name.isEmpty ? "Unnamed chemical" : line.name, unit: line.unit.rawValue, plannedAmountBase: line.volumePerTank, actualAmountBase: match?.actualAmountBase, matchSource: source)
            }
            return Tank(tankNumber: planned.tankNumber, plannedWaterLitres: planned.waterVolume, actualWaterLitres: actual?.waterVolumeL, chemicals: chemicals)
        }

        var weather: [Weather] = []
        if record.temperature != nil || record.humidity != nil || record.windSpeed != nil || !record.windDirection.isEmpty {
            weather = [Weather(sampleSlot: iso.string(from: record.startTime), observedAt: nil, source: "Legacy start snapshot", sourceKind: "manual", isStale: true, temperatureC: record.temperature, humidityPct: record.humidity, windSpeedKmh: record.windSpeed, windGustKmh: nil, windDirectionDeg: nil, rainMm: nil)]
            warnings.append("Hourly weather was not recorded; showing the legacy start snapshot.")
        } else {
            warnings.append("No hourly weather observations were recorded.")
        }
        warnings.append("Shared route image is not available yet; this export uses the deterministic v1 route renderer.")
        let engineDelta = trip.startEngineHours.flatMap { start in trip.endEngineHours.flatMap { end in end > start ? end - start : nil } }
        return SprayReportPayloadV1(
            schemaVersion: currentSchemaVersion,
            identity: Identity(tripId: trip.id, sprayRecordId: record.id, vineyardId: trip.vineyardId, vineyardName: vineyardName, reference: record.sprayReference, vineyardTimeZone: timeZone.identifier),
            trip: TripSummary(startUtc: iso.string(from: trip.startTime), endUtc: trip.endTime.map(iso.string), activeDurationSeconds: Int(trip.activeDuration), distanceMetres: trip.totalDistance, operatorName: trip.personName.isEmpty ? nil : trip.personName, pinCount: trip.pinIds.count),
            blocks: canonicalBlocks,
            equipment: Equipment(tractorName: tractorName.isEmpty ? nil : tractorName, startEngineHours: trip.startEngineHours, endEngineHours: trip.endEngineHours, engineHoursUsed: engineDelta, sprayUnitName: sprayUnitName.isEmpty ? nil : sprayUnitName),
            rows: rows, tanks: tanks, weather: weather, route: nil, warnings: warnings
        )
    }

    func exportFileName(platform: String) -> String {
        let date: String = trip.startUtc.flatMap { ISO8601DateFormatter().date(from: $0) }.map { date in
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: identity.vineyardTimeZone) ?? .gmt
            formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
        } ?? "Not-recorded"
        func safe(_ value: String, fallback: String) -> String {
            let normalized = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            let underscored = normalized.replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
            let filtered = underscored.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
            let filteredString = String(String.UnicodeScalarView(filtered))
            let result = filteredString.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            return result.isEmpty ? fallback : result
        }
        return "SprayReport_\(safe(identity.vineyardName, fallback: "Vineyard"))_\(date)_\(safe(identity.reference, fallback: "Record"))_\(identity.tripId.uuidString.prefix(8).lowercased())-\(platform).pdf"
    }
}

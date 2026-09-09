import Foundation

/// Canonical semantic input for every Spray Report export.
nonisolated struct SprayReportPayloadV1: Codable, Sendable, Hashable {
    static let currentSchemaVersion: String = "1.2"
    static let routeStyleVersion: String = "spray-route-red-green-v1"

    let schemaVersion: String
    let identity: Identity
    var provenance: Provenance? = nil
    var recordingEvidence: RecordingEvidence? = nil
    let trip: TripSummary
    let blocks: [Block]?
    let equipment: Equipment
    let rows: [Row]
    let tanks: [Tank]
    let actualChemicalTotals: [ChemicalTotal]
    let plannedChemicalTotals: [ChemicalTotal]?
    let application: Application?
    let programStep: ProgramStep?
    let tankSessions: [TankSessionSummary]?
    let cost: Cost?
    let metadataCorrectionVersion: Int?
    let metadataAmendments: [MetadataAmendment]?
    let weather: [Weather]
    let route: Route?
    let amendments: [Amendment]
    let warnings: [String]

    nonisolated struct Identity: Codable, Sendable, Hashable {
        let tripId: UUID
        let sprayRecordId: UUID
        let vineyardId: UUID
        let vineyardName: String
        let reference: String
        let vineyardTimeZone: String
    }

    nonisolated struct Provenance: Codable, Sendable, Hashable {
        let source: String?
        let manualEntryId: UUID?
        let isManualEntry: Bool
        let label: String
    }

    nonisolated struct RecordingEvidence: Codable, Sendable, Hashable {
        let route: String?
        let rows: String?
    }

    nonisolated struct TripSummary: Codable, Sendable, Hashable {
        let startUtc: String?
        let endUtc: String?
        let activeDurationSeconds: Int?
        let distanceMetres: Double?
        let operatorName: String?
        let pinCount: Int
        let operatorId: UUID?
        let operatorSource: String?
        let elapsedDurationSeconds: Int?
        let pausedDurationSeconds: Int?
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
        let machineId: UUID?
        let tractorId: UUID?
        let sprayEquipmentId: UUID?
        let equipmentSource: String?
        let tractorGear: String?
        let numberOfFansJets: String?
        let averageSpeedKmh: Double?
        let fuelConsumptionLPerHour: Double?
        let fuelConsumptionSource: String?
        let fuelHours: Double?
        let fuelHoursSource: String?
    }

    nonisolated struct Application: Codable, Sendable, Hashable {
        let operationType: String?
        let applicationMode: String?
        let grossAreaHa: Double?
        let treatedAreaHa: Double?
        let treatedAreaMethod: String?
        let geometrySource: String?
        let geometryQuality: String?
        let carrierVolumeBasis: String?
        let totalCarrierLitres: Double?
        let carrierLitresPerHectare: Double?
        let diluteLitresPer100m: Double?
        let appliedLitresPer100m: Double?
        let concentrationFactor: Double?
        let notes: String?
        var actualUseBasis: String? = nil
    }

    nonisolated struct ProgramStep: Codable, Sendable, Hashable {
        let linkState: String
        let sprayJobId: UUID?
        let name: String?
        let status: String?
        let plannedDate: String?
        let operationType: String?
        let target: String?
        let notes: String?
    }

    nonisolated struct TankSessionSummary: Codable, Sendable, Hashable {
        let tankSessionId: String?
        let tankNumber: Int
        let startedAt: String?
        let endedAt: String?
        let startRow: Double?
        let endRow: Double?
        let pathsCovered: [Double]
        let status: String
        let assignmentSource: String
    }

    nonisolated struct Cost: Codable, Sendable, Hashable {
        let visibility: String
        let currencyCode: String
        let fuelLitres: Double?
        let fuelRateLPerHour: Double?
        let fuelHours: Double?
        let fuelPricePerLitre: Double?
        let fuelCost: Double?
        let chemicalCost: Double?
        let chemicalCostBasis: String?
        let labourRatePerHour: Double?
        let labourRateSource: String?
        let labourCost: Double?
        let knownCostSubtotal: Double?
        let totalCost: Double?
        let treatedAreaHa: Double?
        let costPerTreatedHa: Double?
        let isComplete: Bool
        let incompleteReasons: [CostReason]
        let basis: String
    }

    nonisolated struct CostReason: Codable, Sendable, Hashable {
        let component: String
        let code: String
        let kind: String
    }

    nonisolated struct MetadataAmendment: Codable, Sendable, Hashable {
        let id: UUID
        let operationId: UUID
        let revision: Int
        let previousValue: [String: JSONValue]
        let newValue: [String: JSONValue]
        let editedBy: UUID
        let editorName: String
        let editedAt: String
    }

    nonisolated enum JSONValue: Codable, Sendable, Hashable {
        case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null } else if let value = try? c.decode(Bool.self) { self = .bool(value) } else if let value = try? c.decode(Double.self) { self = .number(value) } else if let value = try? c.decode(String.self) { self = .string(value) } else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) } else { self = .array(try c.decode([JSONValue].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() }
        }
    }

    nonisolated struct Row: Codable, Sendable, Hashable {
        let rowNumber: Double
        let blockName: String?
        let status: String
        let source: String
        let tank: TankReference?
        var rowIdentity: String? = nil
        var blockId: UUID? = nil
        var confidence: Double? = nil
        var isDerived: Bool? = nil
        var tankSessionId: String? = nil
        var originalEvidence: [String: JSONValue]? = nil
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
        let actualId: UUID?
        let actualVersion: Int?
        let plannedWaterLitres: Double?
        let actualWaterLitres: Double?
        let chemicals: [Chemical]
    }

    nonisolated struct Chemical: Codable, Sendable, Hashable {
        let actualChemicalId: UUID?
        let plannedChemicalId: UUID?
        let savedChemicalId: UUID?
        let replacesPlannedChemicalId: UUID?
        let usageKind: String
        let name: String
        let unit: String
        let plannedAmountBase: Double?
        let actualAmountBase: Double?
        let matchSource: String
        var productCategory: String? = nil
        var physicalForm: String? = nil
        var snapshotAt: String? = nil
    }

    nonisolated struct ChemicalTotal: Codable, Sendable, Hashable {
        let identityKey: String
        let name: String
        let unit: String
        let actualAmountBase: Double
    }

    nonisolated struct Amendment: Codable, Sendable, Hashable {
        let id: UUID
        let operationId: UUID
        let tankNumber: Int
        let chemicalActualId: UUID?
        let plannedChemicalId: UUID?
        let savedChemicalId: UUID?
        let field: String
        let changeKind: String
        let previousValue: AmendmentValue?
        let newValue: AmendmentValue?
        let previousUnit: String?
        let newUnit: String?
        let revision: Int
        let editedBy: UUID
        let editorName: String
        let editedAt: String
    }

    nonisolated enum AmendmentValue: Codable, Sendable, Hashable {
        case number(Double)
        case chemical(SprayTankActualChemical)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { self = .number(number); return }
            self = .chemical(try container.decode(SprayTankActualChemical.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .chemical(let value): try container.encode(value)
            }
        }

        var displayText: String {
            switch self {
            case .number(let value): return String(format: "%.3f", value)
            case .chemical(let value): return "\(value.name) · \(String(format: "%.3f", value.displayAmount)) \(value.unit.rawValue)"
            }
        }
    }

    nonisolated struct Weather: Codable, Sendable, Hashable {
        let sampleSlot: String
        let observedAt: String?
        let source: String
        let sourceKind: String
        let provider: String?
        let stationName: String?
        let isStale: Bool
        let temperatureC: Double?
        let humidityPct: Double?
        let windSpeedKmh: Double?
        let windGustKmh: Double?
        let windDirectionDeg: Double?
        let rainMm: Double?
        let stationId: String?
        let retrievalMode: String?
        let providerRecordId: String?
        let retrievedAt: String?
        let retrievalHistory: [WeatherAttempt]
    }

    nonisolated struct WeatherAttempt: Codable, Sendable, Hashable {
        let provider: String
        let stationId: String?
        let stationName: String?
        let retrievalMode: String
        let outcome: String
        let observedAt: String?
        let source: String?
        let temperatureC: Double?
        let humidityPct: Double?
        let windSpeedKmh: Double?
        let windGustKmh: Double?
        let windDirectionDeg: Double?
        let rainMm: Double?
        let isStale: Bool?
        let providerRecordId: String?
        let retrievedAt: String
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

        let isManual = record.entrySource == "manual"
        let rows: [Row] = (isManual ? [] : trip.rowSequence.sorted()).map { rowNumber in
            let status: String
            let source: String
            if trip.completedPaths.contains(rowNumber) {
                status = "Complete"; source = "completedPaths"
            } else if trip.skippedPaths.contains(rowNumber) {
                status = "Skipped/Not complete"; source = "skippedPaths"
            } else {
                status = "Not recorded"; source = "noProgressEvidence"
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

        let trackedTanks: [Tank] = record.tanks.sorted(by: { $0.tankNumber < $1.tankNumber }).map { planned in
            let actual = tankActuals.filter { $0.tankNumber == planned.tankNumber }.max(by: { $0.clientUpdatedAt < $1.clientUpdatedAt })
            let chemicals: [Chemical] = planned.chemicals.map { line in
                let byPlan = actual?.chemicals.filter { $0.plannedChemicalId == line.id } ?? []
                let bySaved = line.savedChemicalId.map { id in actual?.chemicals.filter { $0.savedChemicalId == id && ($0.usageKind ?? "planned") == "planned" } ?? [] } ?? []
                let byNameUnit = actual?.chemicals.filter {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == line.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.unit == line.unit && ($0.usageKind ?? "planned") == "planned"
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
                return Chemical(actualChemicalId: match?.id, plannedChemicalId: line.id, savedChemicalId: line.savedChemicalId, replacesPlannedChemicalId: nil, usageKind: "planned", name: line.name.isEmpty ? "Unnamed chemical" : line.name, unit: line.unit.rawValue, plannedAmountBase: line.volumePerTank, actualAmountBase: match?.actualAmountBase, matchSource: source)
            }
            let representedIds = Set(chemicals.compactMap(\.actualChemicalId))
            let actualOnly = actual?.chemicals.filter { !representedIds.contains($0.id) }.map { line in
                Chemical(actualChemicalId: line.id, plannedChemicalId: nil, savedChemicalId: line.savedChemicalId, replacesPlannedChemicalId: line.replacesPlannedChemicalId, usageKind: line.usageKind ?? "additional", name: line.name, unit: line.unit.rawValue, plannedAmountBase: nil, actualAmountBase: line.actualAmountBase, matchSource: "actualOnly")
            } ?? []
            return Tank(tankNumber: planned.tankNumber, actualId: actual?.id, actualVersion: actual?.correctionVersion, plannedWaterLitres: planned.waterVolume, actualWaterLitres: actual?.waterVolumeL, chemicals: chemicals + actualOnly)
        }

        let tanks: [Tank] = isManual ? tankActuals.sorted(by: { $0.tankNumber < $1.tankNumber }).map { actual in
            Tank(tankNumber: actual.tankNumber, actualId: actual.id, actualVersion: actual.correctionVersion, plannedWaterLitres: nil, actualWaterLitres: actual.waterVolumeL, chemicals: actual.chemicals.map { line in
                Chemical(actualChemicalId: line.id, plannedChemicalId: nil, savedChemicalId: line.savedChemicalId, replacesPlannedChemicalId: nil, usageKind: "additional", name: line.name, unit: line.unit.rawValue, plannedAmountBase: nil, actualAmountBase: line.actualAmountBase, matchSource: "actualOnly")
            })
        } : trackedTanks

        let totalGroups = Dictionary(grouping: tanks.flatMap(\.chemicals).filter { $0.actualAmountBase != nil }) { line in
            line.savedChemicalId?.uuidString ?? "\(line.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(line.unit.lowercased())"
        }
        let actualChemicalTotals = totalGroups.map { key, lines in
            ChemicalTotal(identityKey: key, name: lines.first?.name ?? "Unnamed chemical", unit: lines.first?.unit ?? "", actualAmountBase: lines.compactMap(\.actualAmountBase).reduce(0, +))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var weather: [Weather] = []
        if record.temperature != nil || record.humidity != nil || record.windSpeed != nil || !record.windDirection.isEmpty {
            weather = [Weather(sampleSlot: iso.string(from: record.startTime), observedAt: nil, source: "Legacy start snapshot", sourceKind: "manual", provider: nil, stationName: nil, isStale: true, temperatureC: record.temperature, humidityPct: record.humidity, windSpeedKmh: record.windSpeed, windGustKmh: nil, windDirectionDeg: nil, rainMm: nil, stationId: nil, retrievalMode: "legacy_snapshot", providerRecordId: nil, retrievedAt: nil, retrievalHistory: [])]
            warnings.append("Hourly weather was not recorded; showing the legacy start snapshot.")
        } else {
            warnings.append("No hourly weather observations were recorded.")
        }
        warnings.append("Shared route image is not available yet; this export uses the deterministic v1 route renderer.")
        let engineDelta = trip.startEngineHours.flatMap { start in trip.endEngineHours.flatMap { end in end > start ? end - start : nil } }
        return SprayReportPayloadV1(
            schemaVersion: currentSchemaVersion,
            identity: Identity(tripId: trip.id, sprayRecordId: record.id, vineyardId: trip.vineyardId, vineyardName: vineyardName, reference: record.sprayReference, vineyardTimeZone: timeZone.identifier),
            provenance: Provenance(source: record.entrySource, manualEntryId: record.manualEntryId, isManualEntry: isManual, label: isManual ? "Manual entry" : (record.entrySource == "tracked" ? "Tracked application" : "Origin not recorded")),
            recordingEvidence: isManual ? RecordingEvidence(route: "Not recorded — manual application", rows: "Not recorded — manual application") : nil,
            trip: TripSummary(startUtc: iso.string(from: trip.startTime), endUtc: trip.endTime.map(iso.string), activeDurationSeconds: Int(trip.activeDuration), distanceMetres: trip.totalDistance, operatorName: trip.personName.isEmpty ? nil : trip.personName, pinCount: trip.pinIds.count, operatorId: trip.operatorUserId, operatorSource: trip.operatorUserId == nil ? "recorded_snapshot" : "recorded_identity", elapsedDurationSeconds: Int((trip.endTime ?? Date()).timeIntervalSince(trip.startTime)), pausedDurationSeconds: max(0, Int((trip.endTime ?? Date()).timeIntervalSince(trip.startTime) - trip.activeDuration))),
            blocks: canonicalBlocks,
            equipment: Equipment(tractorName: tractorName.isEmpty ? nil : tractorName, startEngineHours: trip.startEngineHours, endEngineHours: trip.endEngineHours, engineHoursUsed: engineDelta, sprayUnitName: sprayUnitName.isEmpty ? nil : sprayUnitName, machineId: trip.machineId, tractorId: trip.tractorId, sprayEquipmentId: record.sprayEquipmentId, equipmentSource: "offline_projection", tractorGear: record.tractorGear, numberOfFansJets: record.numberOfFansJets, averageSpeedKmh: record.averageSpeed, fuelConsumptionLPerHour: nil, fuelConsumptionSource: nil, fuelHours: engineDelta ?? trip.activeDuration / 3600, fuelHoursSource: engineDelta == nil ? "pause_adjusted_duration" : "engine_hours"),
            rows: rows, tanks: tanks, actualChemicalTotals: actualChemicalTotals, plannedChemicalTotals: isManual ? [] : nil,
            application: isManual ? Application(operationType: record.operationType.rawValue, applicationMode: nil, grossAreaHa: nil, treatedAreaHa: nil, treatedAreaMethod: nil, geometrySource: nil, geometryQuality: nil, carrierVolumeBasis: "manual_actual_total", totalCarrierLitres: tankActuals.compactMap(\.waterVolumeL).reduce(0,+), carrierLitresPerHectare: nil, diluteLitresPer100m: nil, appliedLitresPer100m: nil, concentrationFactor: nil, notes: record.notes, actualUseBasis: "manually_recorded_actual_use") : nil,
            programStep: nil, tankSessions: nil, cost: nil, metadataCorrectionVersion: nil, metadataAmendments: nil, weather: weather, route: nil, amendments: [], warnings: warnings
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

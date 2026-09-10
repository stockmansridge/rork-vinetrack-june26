import Foundation

nonisolated enum ManualSprayPhysicalForm: String, Codable, Sendable {
    case liquid
    case solid
}

nonisolated struct ManualSprayChemical: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let savedChemicalId: UUID
    var name: String
    var actualAmountBase: Double
    var unit: ChemicalUnit
    var productCategory: String
    var physicalForm: ManualSprayPhysicalForm
    let snapshotAt: Date

    var isDimensionCompatible: Bool {
        switch physicalForm {
        case .liquid: unit == .litres || unit == .millilitres
        case .solid: unit == .kilograms || unit == .grams
        }
    }
}

nonisolated struct ManualSprayTank: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let actualId: UUID
    var tankNumber: Int
    var waterVolumeLitres: Double
    var chemicals: [ManualSprayChemical]

    func copied(number: Int) -> ManualSprayTank {
        ManualSprayTank(
            id: UUID(),
            actualId: UUID(),
            tankNumber: number,
            waterVolumeLitres: waterVolumeLitres,
            chemicals: chemicals.map {
                ManualSprayChemical(
                    id: UUID(), savedChemicalId: $0.savedChemicalId, name: $0.name,
                    actualAmountBase: $0.actualAmountBase, unit: $0.unit,
                    productCategory: $0.productCategory, physicalForm: $0.physicalForm,
                    snapshotAt: $0.snapshotAt
                )
            }
        )
    }
}

nonisolated struct ManualSprayBlock: Codable, Identifiable, Sendable, Hashable {
    let blockId: UUID
    let blockName: String
    var id: UUID { blockId }
}

nonisolated struct ManualSprayWeather: Codable, Sendable, Hashable {
    var observedAt: Date
    var source: String
    var temperatureC: Double?
    var humidityPct: Double?
    var windSpeedKmh: Double?
    var windGustKmh: Double?
    var windDirectionDeg: Double?
    var rainMm: Double?
}

nonisolated struct ManualSprayPayload: Codable, Sendable, Hashable {
    let vineyardId: UUID
    let manualEntryId: UUID
    let sprayRecordId: UUID
    let tripId: UUID
    var reference: String
    var operationType: String
    var startUtc: Date
    var endUtc: Date
    var vineyardTimeZone: String
    var tractorId: UUID?
    var operatorUserId: UUID?
    var sprayEquipmentId: UUID?
    var startEngineHours: Double?
    var endEngineHours: Double?
    var notes: String?
    var clientUpdatedAt: Date
    var blocks: [ManualSprayBlock]
    var tanks: [ManualSprayTank]
    var manualWeather: ManualSprayWeather?

    static func empty(vineyardId: UUID, timeZone: TimeZone) -> ManualSprayPayload {
        let start = Date()
        return ManualSprayPayload(
            vineyardId: vineyardId, manualEntryId: UUID(), sprayRecordId: UUID(), tripId: UUID(),
            reference: "", operationType: OperationType.foliarSpray.rawValue,
            startUtc: start, endUtc: start.addingTimeInterval(3600),
            vineyardTimeZone: timeZone.identifier, tractorId: nil, operatorUserId: nil,
            sprayEquipmentId: nil, startEngineHours: nil, endEngineHours: nil,
            notes: nil, clientUpdatedAt: start, blocks: [],
            tanks: [ManualSprayTank(id: UUID(), actualId: UUID(), tankNumber: 1, waterVolumeLitres: 0, chemicals: [])],
            manualWeather: nil
        )
    }

    static func existing(
        record: SprayRecord,
        trip: Trip,
        report: SprayReportPayloadV1,
        actuals: [SprayTankActual],
        timeZone: TimeZone
    ) throws -> ManualSprayPayload {
        guard record.isManualEntry, let manualEntryId = record.manualEntryId,
              record.vineyardId == trip.vineyardId, record.tripId == trip.id,
              report.identity.vineyardId == record.vineyardId,
              report.identity.sprayRecordId == record.id, report.identity.tripId == trip.id,
              report.provenance?.source == "manual", report.provenance?.manualEntryId == manualEntryId
        else { throw ManualSprayValidationError.invalidIdentity }
        let iso = ISO8601DateFormatter()
        let tanks: [ManualSprayTank] = try report.tanks.sorted { $0.tankNumber < $1.tankNumber }.map { tank in
            guard let actualId = tank.actualId,
                  let actual = actuals.first(where: { $0.id == actualId && $0.vineyardId == record.vineyardId && $0.sprayRecordId == record.id && $0.tripId == trip.id }),
                  let tankId = UUID(uuidString: actual.tankSessionId), actual.tankNumber == tank.tankNumber else {
                throw ManualSprayValidationError.missingActuals
            }
            let chemicals: [ManualSprayChemical] = try tank.chemicals.map { chemical in
                guard let id = chemical.actualChemicalId, let savedChemicalId = chemical.savedChemicalId,
                      let amount = chemical.actualAmountBase, let unit = ChemicalUnit(rawValue: chemical.unit),
                      let category = chemical.productCategory, let formRaw = chemical.physicalForm,
                      let form = ManualSprayPhysicalForm(rawValue: formRaw), let snapshotRaw = chemical.snapshotAt,
                      let snapshotAt = iso.date(from: snapshotRaw) else { throw ManualSprayValidationError.missingActuals }
                return ManualSprayChemical(id: id, savedChemicalId: savedChemicalId, name: chemical.name, actualAmountBase: amount, unit: unit, productCategory: category, physicalForm: form, snapshotAt: snapshotAt)
            }
            return ManualSprayTank(id: tankId, actualId: actualId, tankNumber: tank.tankNumber, waterVolumeLitres: tank.actualWaterLitres ?? actual.waterVolumeL ?? 0, chemicals: chemicals)
        }
        let weather = report.weather.first(where: { $0.provider == "manual_entry" && $0.sourceKind == "manual" }).map { item in
            ManualSprayWeather(observedAt: item.observedAt.flatMap(iso.date) ?? trip.startTime, source: item.source, temperatureC: item.temperatureC, humidityPct: item.humidityPct, windSpeedKmh: item.windSpeedKmh, windGustKmh: item.windGustKmh, windDirectionDeg: item.windDirectionDeg, rainMm: item.rainMm)
        }
        return ManualSprayPayload(
            vineyardId: record.vineyardId, manualEntryId: manualEntryId, sprayRecordId: record.id, tripId: trip.id,
            reference: record.sprayReference, operationType: report.application?.operationType ?? record.operationType.rawValue,
            startUtc: trip.startTime, endUtc: trip.endTime ?? record.endTime ?? record.startTime,
            vineyardTimeZone: TimeZone(identifier: report.identity.vineyardTimeZone)?.identifier ?? timeZone.identifier,
            tractorId: report.equipment.tractorId ?? trip.tractorId, operatorUserId: report.trip.operatorId ?? trip.operatorUserId,
            sprayEquipmentId: report.equipment.sprayEquipmentId ?? record.sprayEquipmentId,
            startEngineHours: report.equipment.startEngineHours ?? trip.startEngineHours,
            endEngineHours: report.equipment.endEngineHours ?? trip.endEngineHours, notes: report.application?.notes ?? record.notes,
            clientUpdatedAt: Date(), blocks: report.blocks?.compactMap { guard let id = UUID(uuidString: $0.blockId) else { return nil }; return ManualSprayBlock(blockId: id, blockName: $0.name) } ?? [],
            tanks: tanks, manualWeather: weather
        )
    }

    func validated() throws -> ManualSprayPayload {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManualSprayValidationError.missingReference }
        guard TimeZone(identifier: vineyardTimeZone) != nil else { throw ManualSprayValidationError.invalidTimeZone }
        guard endUtc > startUtc else { throw ManualSprayValidationError.invalidInterval }
        guard tractorId != nil else { throw ManualSprayValidationError.missingTractor }
        guard operatorUserId != nil else { throw ManualSprayValidationError.missingOperator }
        guard sprayEquipmentId != nil else { throw ManualSprayValidationError.missingSprayUnit }
        guard !blocks.isEmpty else { throw ManualSprayValidationError.missingBlocks }
        guard !tanks.isEmpty else { throw ManualSprayValidationError.missingTanks }
        if let startEngineHours, !startEngineHours.isFinite || startEngineHours < 0 { throw ManualSprayValidationError.invalidEngineHours }
        if let endEngineHours, !endEngineHours.isFinite || endEngineHours < 0 { throw ManualSprayValidationError.invalidEngineHours }
        if let startEngineHours, let endEngineHours, endEngineHours < startEngineHours { throw ManualSprayValidationError.invalidEngineHours }
        if let manualWeather, [manualWeather.temperatureC, manualWeather.humidityPct, manualWeather.windSpeedKmh, manualWeather.windGustKmh, manualWeather.windDirectionDeg, manualWeather.rainMm].allSatisfy({ $0 == nil }) { throw ManualSprayValidationError.emptyWeather }
        for tank in tanks {
            guard tank.tankNumber > 0, tank.waterVolumeLitres.isFinite, tank.waterVolumeLitres >= 0 else { throw ManualSprayValidationError.invalidTank }
            guard !tank.chemicals.isEmpty else { throw ManualSprayValidationError.missingChemicals(tank.tankNumber) }
            for chemical in tank.chemicals {
                guard chemical.actualAmountBase.isFinite, chemical.actualAmountBase >= 0,
                      !chemical.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !chemical.productCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      chemical.isDimensionCompatible else { throw ManualSprayValidationError.invalidChemical(tank.tankNumber) }
            }
        }
        return self
    }
}

nonisolated enum ManualSprayValidationError: LocalizedError, Sendable, Equatable {
    case missingReference, invalidInterval, missingTractor, missingOperator, missingSprayUnit
    case missingBlocks, missingTanks, invalidEngineHours, invalidTank, missingChemicals(Int), invalidChemical(Int)
    case invalidIdentity, missingActuals, emptyWeather, invalidTimeZone

    var errorDescription: String? {
        switch self {
        case .missingReference: "Enter a name or reference."
        case .invalidInterval: "End time must be after start time."
        case .missingTractor: "Select one tractor."
        case .missingOperator: "Select one operator."
        case .missingSprayUnit: "Select one spray unit."
        case .missingBlocks: "Select at least one block."
        case .missingTanks: "Add at least one tank."
        case .invalidEngineHours: "Engine-hour readings must be finite, nonnegative, and end cannot be below start."
        case .invalidTank: "Each tank needs a valid water amount."
        case .missingChemicals(let tank): "Tank \(tank) needs at least one chemical."
        case .invalidChemical(let tank): "Tank \(tank) has an invalid chemical amount, unit, category, or form."
        case .invalidIdentity: "This manual application does not have a valid shared identity."
        case .missingActuals: "The saved actual tank quantities could not be reloaded. Sync and try again."
        case .emptyWeather: "Enter at least one weather measurement or turn manual weather off."
        case .invalidTimeZone: "The vineyard timezone is invalid. Reload this application and try again."
        }
    }
}

nonisolated struct ManualSpraySaveResponse: Codable, Sendable, Hashable {
    let operationId: UUID
    let manualEntryId: UUID
    let sprayRecordId: UUID
    let tripId: UUID
    let source: String
    let status: String
    let syncVersion: Int
    let serverConfirmed: Bool
}

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

    func validated() throws -> ManualSprayPayload {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManualSprayValidationError.missingReference }
        guard endUtc > startUtc else { throw ManualSprayValidationError.invalidInterval }
        guard tractorId != nil else { throw ManualSprayValidationError.missingTractor }
        guard operatorUserId != nil else { throw ManualSprayValidationError.missingOperator }
        guard sprayEquipmentId != nil else { throw ManualSprayValidationError.missingSprayUnit }
        guard !blocks.isEmpty else { throw ManualSprayValidationError.missingBlocks }
        guard !tanks.isEmpty else { throw ManualSprayValidationError.missingTanks }
        if let startEngineHours, !startEngineHours.isFinite || startEngineHours < 0 { throw ManualSprayValidationError.invalidEngineHours }
        if let endEngineHours, !endEngineHours.isFinite || endEngineHours < 0 { throw ManualSprayValidationError.invalidEngineHours }
        if let startEngineHours, let endEngineHours, endEngineHours < startEngineHours { throw ManualSprayValidationError.invalidEngineHours }
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

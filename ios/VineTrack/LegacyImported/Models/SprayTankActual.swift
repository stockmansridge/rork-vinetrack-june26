import Foundation

/// Frozen confirmation of what was actually placed in one started spray tank.
nonisolated struct SprayTankActualChemical: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let plannedChemicalId: UUID?
    let savedChemicalId: UUID?
    let name: String
    let actualAmountBase: Double
    let unit: ChemicalUnit

    init(
        id: UUID = UUID(),
        plannedChemicalId: UUID?,
        savedChemicalId: UUID?,
        name: String,
        actualAmountBase: Double,
        unit: ChemicalUnit
    ) throws {
        guard actualAmountBase.isFinite, actualAmountBase >= 0 else { throw SprayTankActualValidationError.invalidAmount }
        self.id = id
        self.plannedChemicalId = plannedChemicalId
        self.savedChemicalId = savedChemicalId
        self.name = name
        self.actualAmountBase = actualAmountBase
        self.unit = unit
    }

    var displayAmount: Double { unit.fromBase(actualAmountBase) }
}

nonisolated struct SprayTankActual: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let sprayRecordId: UUID
    let tripId: UUID
    let tankSessionId: String
    let tankNumber: Int
    let waterVolumeL: Double
    let chemicals: [SprayTankActualChemical]
    let confirmedAt: Date
    let confirmedBy: UUID
    let clientUpdatedAt: Date

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        sprayRecordId: UUID,
        tripId: UUID,
        tankSessionId: String,
        tankNumber: Int,
        waterVolumeL: Double,
        chemicals: [SprayTankActualChemical],
        confirmedAt: Date,
        confirmedBy: UUID,
        clientUpdatedAt: Date? = nil
    ) throws {
        guard tankNumber >= 1, !tankSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              waterVolumeL.isFinite, waterVolumeL >= 0,
              chemicals.allSatisfy({ $0.actualAmountBase.isFinite && $0.actualAmountBase >= 0 })
        else { throw SprayTankActualValidationError.invalidAmount }
        self.id = id
        self.vineyardId = vineyardId
        self.sprayRecordId = sprayRecordId
        self.tripId = tripId
        self.tankSessionId = tankSessionId
        self.tankNumber = tankNumber
        self.waterVolumeL = waterVolumeL
        self.chemicals = chemicals
        self.confirmedAt = confirmedAt
        self.confirmedBy = confirmedBy
        self.clientUpdatedAt = clientUpdatedAt ?? confirmedAt
    }
}

nonisolated enum SprayTankActualValidationError: LocalizedError, Sendable {
    case invalidAmount
    case unavailablePlan
    case localSaveFailed

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter zero or a positive finite amount for every field."
        case .unavailablePlan: "Planned tank mix unavailable."
        case .localSaveFailed: "The tank was not started because its actual mix could not be saved locally."
        }
    }
}

import Foundation

/// Frozen confirmation of what was actually placed in one started spray tank.
nonisolated struct SprayTankActualChemical: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let plannedChemicalId: UUID?
    let savedChemicalId: UUID?
    let replacesPlannedChemicalId: UUID?
    let usageKind: String?
    let name: String
    let actualAmountBase: Double
    let unit: ChemicalUnit

    init(
        id: UUID = UUID(),
        plannedChemicalId: UUID?,
        savedChemicalId: UUID?,
        replacesPlannedChemicalId: UUID? = nil,
        usageKind: String? = nil,
        name: String,
        actualAmountBase: Double,
        unit: ChemicalUnit
    ) throws {
        guard actualAmountBase.isFinite, actualAmountBase >= 0 else { throw SprayTankActualValidationError.invalidAmount }
        self.id = id
        self.plannedChemicalId = plannedChemicalId
        self.savedChemicalId = savedChemicalId
        self.replacesPlannedChemicalId = replacesPlannedChemicalId
        self.usageKind = usageKind
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
    let waterVolumeL: Double?
    let chemicals: [SprayTankActualChemical]
    let confirmedAt: Date
    let confirmedBy: UUID
    let clientUpdatedAt: Date
    let correctionVersion: Int?
    let lastCorrectedAt: Date?

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        sprayRecordId: UUID,
        tripId: UUID,
        tankSessionId: String,
        tankNumber: Int,
        waterVolumeL: Double?,
        chemicals: [SprayTankActualChemical],
        confirmedAt: Date,
        confirmedBy: UUID,
        clientUpdatedAt: Date? = nil,
        correctionVersion: Int? = nil,
        lastCorrectedAt: Date? = nil
    ) throws {
        guard tankNumber >= 1, !tankSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              waterVolumeL.map({ $0.isFinite && $0 >= 0 }) ?? true,
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
        self.correctionVersion = correctionVersion
        self.lastCorrectedAt = lastCorrectedAt
    }
}

nonisolated func resolveSprayTankActual(
    plannedTank: SprayTank,
    actuals: [SprayTankActual],
    vineyardId: UUID,
    sprayRecordId: UUID,
    tripId: UUID,
    tankSessionIds: Set<String>? = nil
) -> SprayTankActual? {
    if let tankSessionIds, tankSessionIds.isEmpty { return nil }
    let scoped = actuals.filter { actual in
        actual.vineyardId == vineyardId && actual.sprayRecordId == sprayRecordId &&
            actual.tripId == tripId && actual.tankNumber == plannedTank.tankNumber &&
            (tankSessionIds == nil || tankSessionIds!.contains(actual.tankSessionId))
    }
    let bySession = Dictionary(grouping: scoped, by: \.tankSessionId)
    guard bySession.count == 1, let revisions = bySession.values.first,
          let highestVersion = revisions.map({ $0.correctionVersion ?? 0 }).max()
    else { return nil }
    let highest = revisions.filter { ($0.correctionVersion ?? 0) == highestVersion }
    return highest.count == 1 ? highest[0] : nil
}

nonisolated func areSprayTankActualsComplete(
    plannedTanks: [SprayTank],
    actuals: [SprayTankActual],
    vineyardId: UUID,
    sprayRecordId: UUID,
    tripId: UUID,
    tankSessionIdsByNumber: [Int: Set<String>]? = nil
) -> Bool {
    guard !plannedTanks.isEmpty else { return false }
    return plannedTanks.allSatisfy { tank in
        guard let actual = resolveSprayTankActual(
            plannedTank: tank, actuals: actuals, vineyardId: vineyardId,
            sprayRecordId: sprayRecordId, tripId: tripId,
            tankSessionIds: tankSessionIdsByNumber?[tank.tankNumber]
        ), let water = actual.waterVolumeL, water.isFinite, water >= 0
        else { return false }
        let plannedIds = Set(tank.chemicals.map(\.id))
        guard actual.chemicals.allSatisfy({ line in
            guard line.actualAmountBase.isFinite, line.actualAmountBase >= 0 else { return false }
            switch line.usageKind ?? "planned" {
            case "planned": return line.plannedChemicalId.map(plannedIds.contains) == true && line.replacesPlannedChemicalId == nil
            case "additional": return line.plannedChemicalId == nil && line.replacesPlannedChemicalId == nil
            case "substitution": return line.plannedChemicalId == nil && line.replacesPlannedChemicalId.map(plannedIds.contains) == true
            default: return false
            }
        }) else { return false }
        return tank.chemicals.allSatisfy { planned in
            let direct = actual.chemicals.filter { ($0.usageKind ?? "planned") == "planned" && $0.plannedChemicalId == planned.id }.count
            let substitutions = actual.chemicals.filter { $0.usageKind == "substitution" && $0.replacesPlannedChemicalId == planned.id }.count
            return direct + substitutions == 1
        }
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

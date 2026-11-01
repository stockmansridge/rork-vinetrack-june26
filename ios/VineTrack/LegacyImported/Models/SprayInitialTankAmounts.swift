import Foundation

/// Explicit operator-entered contents of the first physical tank. These are
/// canonical amounts, separate from the immutable calculated tank recipe.
nonisolated struct SprayInitialTankAmounts: Codable, Hashable, Sendable {
    let tankId: UUID
    let tankNumber: Int
    let waterLitres: Double
    let chemicalBaseAmounts: [UUID: Double]

    static func firstTank(in tanks: [SprayTank]) -> SprayTank? {
        guard !tanks.isEmpty, tanks.allSatisfy({ $0.tankNumber >= 1 }),
              Set(tanks.map(\.id)).count == tanks.count,
              Set(tanks.map(\.tankNumber)).count == tanks.count else { return nil }
        return tanks.min { $0.tankNumber < $1.tankNumber }
    }

    /// Chemical snapshot dates are persisted at millisecond precision. Compare
    /// that one timestamp at its codec precision, but keep every other field
    /// (including optional classification, rates and identities) exact.
    static func samePersistedRecipe(_ left: SprayTank?, _ right: SprayTank) -> Bool {
        guard let left else { return false }
        if left == right { return true }
        func atPersistedPrecision(_ source: SprayTank) -> SprayTank? {
            var copy = source
            for index in copy.chemicals.indices {
                if let date = copy.chemicals[index].chemicalSnapshot?.capturedAt {
                    guard date.timeIntervalSince1970.isFinite,
                          let saved = ChemicalLineSnapshot.parseCapturedAt(
                            ChemicalLineSnapshot.capturedAtFormatter.string(from: date)) else { return nil }
                    copy.chemicals[index].chemicalSnapshot?.capturedAt = saved
                }
            }
            return copy
        }
        guard let savedLeft = atPersistedPrecision(left),
              let savedRight = atPersistedPrecision(right) else { return false }
        return savedLeft == savedRight
    }

    func isValid(for tank: SprayTank) -> Bool {
        let productIds = Set(tank.chemicals.map(\.id))
        return tankId == tank.id && tankNumber == tank.tankNumber && tankNumber >= 1 &&
            waterLitres.isFinite && waterLitres > 0 && !tank.chemicals.isEmpty &&
            productIds.count == tank.chemicals.count &&
            Set(chemicalBaseAmounts.keys) == productIds &&
            chemicalBaseAmounts.values.allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

/// Retained handoff across Trip activation. A draft is not an actual-use row
/// and cannot make a tank complete; the existing tank commit establishes that.
nonisolated struct SprayInitialTankDraft: Codable, Hashable, Sendable {
    let ownerId: UUID
    let vineyardId: UUID
    let tripId: UUID
    let sprayRecordId: UUID
    let tank: SprayTank
    let amounts: SprayInitialTankAmounts

    func matchesPersistedHandoff(_ other: SprayInitialTankDraft) -> Bool {
        ownerId == other.ownerId && vineyardId == other.vineyardId && tripId == other.tripId &&
            sprayRecordId == other.sprayRecordId && amounts == other.amounts &&
            SprayInitialTankAmounts.samePersistedRecipe(tank, other.tank)
    }

    /// Clear only after the exact entered amounts are attached to this Trip's
    /// real session. Planned values, another owner and another session cannot
    /// acknowledge the retained handoff.
    func isRecorded(in actuals: [SprayTankActual], trip: Trip) -> Bool {
        guard amounts.isValid(for: tank), trip.id == tripId, trip.vineyardId == vineyardId else { return false }
        let sessions = trip.tankSessions.filter { $0.tankNumber == tank.tankNumber }
        guard sessions.count == 1, let session = sessions.first,
              let actual = resolveSprayTankActual(
                plannedTank: tank, actuals: actuals, vineyardId: vineyardId,
                sprayRecordId: sprayRecordId, tripId: tripId,
                tankSessionIds: [session.id.uuidString]
              ),
              actual.confirmedBy == ownerId,
              actual.waterVolumeL == amounts.waterLitres,
              actual.chemicals.count == tank.chemicals.count,
              Set(actual.chemicals.map(\.id)).count == actual.chemicals.count
        else { return false }
        return tank.chemicals.allSatisfy { product in
            let matches = actual.chemicals.filter { $0.plannedChemicalId == product.id }
            guard matches.count == 1, let line = matches.first else { return false }
            return (line.usageKind ?? "planned") == "planned" && line.replacesPlannedChemicalId == nil &&
                line.savedChemicalId == product.savedChemicalId && line.name == product.name &&
                line.unit == product.unit && line.actualAmountBase == amounts.chemicalBaseAmounts[product.id]
        }
    }
}

nonisolated enum SprayInitialTankError: LocalizedError, Sendable {
    case invalidAmounts
    case retainedMixConflict
    case actualNotRecorded

    var errorDescription: String? {
        switch self {
        case .invalidAmounts:
            "Enter the actual water and an amount for every chemical in this tank."
        case .retainedMixConflict:
            "The original entered tank amounts are retained. Return to that saved spray to finish starting it."
        case .actualNotRecorded:
            "The entered tank amounts are still retained because their tank record has not been saved completely."
        }
    }
}

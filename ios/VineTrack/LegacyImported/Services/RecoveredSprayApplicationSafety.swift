import Foundation

/// Historical identity/link acceptance is not chemical application authority.
/// There is no exact-recipe quantity + applicable-label verification receipt in
/// recovered legacy data. Until that contract exists, review cannot unlock spraying.
/// This gate deliberately does not alter shared save/sync validation or originals.
nonisolated enum RecoveredSprayApplicationSafety {
    static let reasonCode = "RECOVERED_MIX_QUANTITY_LABEL_UNVERIFIED"
    static func blocker(_ record: SprayRecord) -> String? {
        guard record.recoveredFromServerOrphan else { return nil }
        return "Application blocked: original chemical quantities, units and applicable label-rate basis are not verified. Saved tanks and trip are retained."
    }

    static func diagnostic(_ record: SprayRecord) -> String {
        var lines = [reasonCode, "spray=\(record.id) trip=\(record.tripId)",
                     "linkAccepted=\(record.recoveredOrphanLinkAccepted); review is not label verification",
                     "Stored amounts/rates use base mL or g. 1000 mL = 1 L; 1000 g = 1 kg. No mass/volume conversion; no per-ha/per-100 L substitution."]
        for tank in record.tanks {
            lines.append("tank=\(tank.id) number=\(tank.tankNumber) waterL=\(tank.waterVolume) carrierLPerHa=\(tank.sprayRatePerHa)")
            for chemical in tank.chemicals {
                lines.append("line=\(chemical.id) amountBase=\(chemical.volumePerTank) \(chemical.unit.baseLabel); display=\(chemical.unit.fromBase(chemical.volumePerTank)) \(chemical.unit.rawValue); per100LBase=\(chemical.ratePer100L); perHaBase=\(chemical.ratePerHa); basis=\(chemical.rateBasis?.rawValue ?? "MISSING")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

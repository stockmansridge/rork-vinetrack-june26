import Foundation

/// Display-only resolver for equipment names across the two identity systems
/// that coexist in the app:
///
/// - Trips and Spray Records use `machineId` / `tractorId` / `sprayEquipmentId`.
/// - Maintenance Logs and Work Task Machine Lines use `equipmentSource` +
///   `equipmentRefId` + a name snapshot.
///
/// This helper centralises the name-resolution logic that was previously
/// duplicated across the store and individual views. It is strictly read-only:
/// it never mutates records, never infers or backfills IDs, never creates
/// equipment, and never affects costing. When a stable link cannot be
/// resolved it falls back to the supplied text snapshot, and only then to a
/// final "Unknown equipment" sentinel.
nonisolated struct EquipmentResolver: Sendable {
    let vineyardMachines: [VineyardMachine]
    let tractors: [Tractor]
    let sprayEquipment: [SprayEquipmentItem]
    let equipmentItems: [EquipmentItem]

    /// Wording shown for a trip that has no linked machine/tractor. Matches the
    /// existing copy used in the Work Task linked-trip list.
    static let noMachineLinked = "No machine linked"
    /// Final fallback when neither a stable link nor a usable text snapshot is
    /// available.
    static let unknownEquipment = "Unknown equipment"

    /// Resolve a trip's machine/tractor display name, preferring the linked
    /// vineyard machine, then the legacy tractor (directly or via its backfilled
    /// machine), with a safe "No machine linked" fallback.
    func tripMachineName(_ trip: Trip) -> String {
        if let mid = trip.machineId,
           let m = vineyardMachines.first(where: { $0.id == mid }) {
            return m.displayName
        }
        if let tid = trip.tractorId {
            if let m = vineyardMachines.first(where: { $0.legacyTractorId == tid && $0.vineyardId == trip.vineyardId }) {
                return m.displayName
            }
            if let t = tractors.first(where: { $0.id == tid }) {
                return t.displayName
            }
        }
        return Self.noMachineLinked
    }

    /// Resolve a spray record's tractor/machine name, preferring the stable
    /// `machineId` → `tractorId` link and falling back to the stored `tractor`
    /// text snapshot.
    func sprayTractorName(_ record: SprayRecord) -> String {
        if let mid = record.machineId,
           let m = vineyardMachines.first(where: { $0.id == mid }) {
            return m.displayName
        }
        if let tid = record.tractorId,
           let t = tractors.first(where: { $0.id == tid }) {
            return t.displayName
        }
        return record.tractor
    }

    /// Resolve a spray record's spray-equipment name, preferring the stable
    /// `sprayEquipmentId` link and falling back to the `equipmentType` snapshot.
    func sprayEquipmentName(_ record: SprayRecord) -> String {
        if let eid = record.sprayEquipmentId,
           let e = sprayEquipment.first(where: { $0.id == eid }) {
            return e.name
        }
        return record.equipmentType
    }

    /// Resolve a maintenance-pattern equipment name from
    /// `equipmentSource` + `equipmentRefId`, falling back to the supplied text
    /// snapshot and finally to "Unknown equipment" when the snapshot is empty.
    /// Shared by maintenance logs and Work Task machine lines.
    func sourceRefName(source: String?, refId: UUID?, snapshot: String) -> String {
        if let source, let refId, source != "free_text" {
            switch source {
            case "vineyard_machine":
                if let m = vineyardMachines.first(where: { $0.id == refId }) { return m.displayName }
            case "tractor":
                if let t = tractors.first(where: { $0.id == refId }) { return t.displayName }
            case "spray_equipment":
                if let e = sprayEquipment.first(where: { $0.id == refId }) { return e.name }
            case "equipment_item":
                if let i = equipmentItems.first(where: { $0.id == refId }) { return i.displayName }
            default:
                break
            }
        }
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.unknownEquipment : trimmed
    }
}

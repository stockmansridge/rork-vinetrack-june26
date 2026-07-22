import Foundation

/// The kind of vineyard machine. Backs the `machine_type` column on
/// `public.vineyard_machines`. Raw values must match the SQL CHECK
/// constraint in `sql/097_vineyard_machines.sql`.
nonisolated enum VineyardMachineType: String, Codable, Sendable, Hashable, CaseIterable {
    case tractor
    case atv
    case sideBySide = "side_by_side"
    case harvester
    case utilityVehicle = "utility_vehicle"
    case otherVineyardMachine = "other_vineyard_machine"

    /// User-facing label for pickers and lists.
    var displayName: String {
        switch self {
        case .tractor: return "Tractor"
        case .atv: return "ATV"
        case .sideBySide: return "Side-by-side"
        case .harvester: return "Harvester"
        case .utilityVehicle: return "Utility vehicle"
        case .otherVineyardMachine: return "Other vineyard machine"
        }
    }
}

/// A vineyard machine used for fuel tracking and (later) job costing. This is
/// the successor to the tractor-only model — existing tractors are backfilled
/// into this table with `machineType == .tractor` and a `legacyTractorId`.
///
/// Phase 1 is data-foundation only: this model is synced and persisted but
/// trip costing still uses `trips.tractor_id`. A machine's
/// `fuelUsageLPerHour` of 0 is treated as "not set" rather than a real rate —
/// see `hasFuelUsageRate`.
nonisolated struct VineyardMachine: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var machineType: VineyardMachineType
    var fuelTrackingEnabled: Bool
    var availableForJobCosting: Bool
    /// Hourly fuel usage in litres/hour. A value of 0 means "not set" — use
    /// `hasFuelUsageRate` before treating it as a real rate. The default
    /// machine rate must only be changed when the user deliberately applies
    /// it; calculated usage is never auto-applied.
    var fuelUsageLPerHour: Double
    var notes: String?
    /// Optional manufacturer serial number. Free text, nullable.
    var serialNumber: String?
    /// Optional vehicle identification number (VIN). Free text, nullable.
    var vinNumber: String?
    /// The originating tractor id when this machine was backfilled from
    /// `public.tractors`. Nil for natively-created machines.
    var legacyTractorId: UUID?

    /// Whether a real, usable hourly fuel rate has been set. 0 is treated as
    /// "not set" so costing never silently uses a zero rate.
    var hasFuelUsageRate: Bool { fuelUsageLPerHour > 0 }

    /// Display name, falling back to the machine type label when unnamed.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? machineType.displayName : trimmed
    }

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        machineType: VineyardMachineType = .tractor,
        fuelTrackingEnabled: Bool = true,
        availableForJobCosting: Bool = false,
        fuelUsageLPerHour: Double = 0,
        notes: String? = nil,
        serialNumber: String? = nil,
        vinNumber: String? = nil,
        legacyTractorId: UUID? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.machineType = machineType
        self.fuelTrackingEnabled = fuelTrackingEnabled
        self.availableForJobCosting = availableForJobCosting
        self.fuelUsageLPerHour = fuelUsageLPerHour
        self.notes = notes
        self.serialNumber = serialNumber
        self.vinNumber = vinNumber
        self.legacyTractorId = legacyTractorId
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, machineType, fuelTrackingEnabled
        case availableForJobCosting, fuelUsageLPerHour, notes
        case serialNumber, vinNumber, legacyTractorId
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        machineType = try container.decodeIfPresent(VineyardMachineType.self, forKey: .machineType) ?? .tractor
        fuelTrackingEnabled = try container.decodeIfPresent(Bool.self, forKey: .fuelTrackingEnabled) ?? true
        availableForJobCosting = try container.decodeIfPresent(Bool.self, forKey: .availableForJobCosting) ?? false
        fuelUsageLPerHour = try container.decodeIfPresent(Double.self, forKey: .fuelUsageLPerHour) ?? 0
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        vinNumber = try container.decodeIfPresent(String.self, forKey: .vinNumber)
        legacyTractorId = try container.decodeIfPresent(UUID.self, forKey: .legacyTractorId)
    }
}

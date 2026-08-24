import Foundation

/// Vineyard-scoped equipment access.
///
/// **The contract.** The on-disk blobs (`vinetrack_tractors`,
/// `vinetrack_vineyard_machines`, `vinetrack_fuel_purchases`,
/// `vinetrack_tractor_fuel_logs`) are deliberately MULTI-vineyard: one device
/// syncs several vineyards and each vineyard's slice must survive a save of a
/// different vineyard. The IN-MEMORY operational state, by contrast, must only
/// ever represent the SELECTED vineyard.
///
/// **Two read classes exist and must never be confused:**
///
/// 1. *Operational* — "what equipment may this grower pick right now?".
///    Always goes through `currentTractors`, `currentVineyardMachines`,
///    `currentFuelPurchases`, `currentTractorFuelLogs` (or the sorted
///    variants). They require a selected vineyard and never fall back to
///    another one — an empty list is the correct answer when nothing is
///    selected. A Vineyard B job must never be offered Vineyard A equipment.
///
/// 2. *Historical / reference* — "what equipment does this saved Trip, Spray,
///    Fuel Log, Maintenance Log or Cost row point at?". Always resolved
///    against the RECORD's own `vineyardId` plus its own saved equipment id,
///    never against whatever happens to be selected, so history keeps
///    rendering the correct names after a vineyard switch.
///
/// Soft-delete/tombstone handling is unchanged: deleted rows are removed by
/// the sync layer (`applyRemote*Delete`), so anything still present here is
/// live equipment.
extension MigratedDataStore {

    // MARK: - Operational reads (selected vineyard only)

    /// Tractors belonging to the currently selected vineyard.
    ///
    /// Empty when no vineyard is selected — deliberately, so a picker can
    /// never silently offer another vineyard's machinery.
    var currentTractors: [Tractor] {
        guard let vineyardId = selectedVineyardId else { return [] }
        return tractors.filter { $0.vineyardId == vineyardId }
    }

    /// `currentTractors`, ordered for display.
    var currentTractorsSorted: [Tractor] {
        currentTractors.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Vineyard machines belonging to the currently selected vineyard.
    var currentVineyardMachines: [VineyardMachine] {
        guard let vineyardId = selectedVineyardId else { return [] }
        return vineyardMachines.filter { $0.vineyardId == vineyardId }
    }

    /// `currentVineyardMachines`, ordered for display. Equivalent to
    /// `machines()`, kept as a named accessor for symmetry with the other
    /// three collections.
    var currentVineyardMachinesSorted: [VineyardMachine] {
        currentVineyardMachines.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Bulk fuel purchases belonging to the currently selected vineyard.
    var currentFuelPurchases: [FuelPurchase] {
        guard let vineyardId = selectedVineyardId else { return [] }
        return fuelPurchases.filter { $0.vineyardId == vineyardId }
    }

    /// Machine fuel fills belonging to the currently selected vineyard.
    var currentTractorFuelLogs: [TractorFuelLog] {
        guard let vineyardId = selectedVineyardId else { return [] }
        return tractorFuelLogs.filter { $0.vineyardId == vineyardId }
    }

    /// Whether the selected vineyard has any operational machinery at all —
    /// legacy tractor rows or canonical machines. Used by setup checklists.
    var currentVineyardHasMachinery: Bool {
        !currentTractors.isEmpty || !currentVineyardMachines.isEmpty
    }

    // MARK: - Historical / reference resolution (record's own vineyard)

    /// Resolves a tractor referenced by a saved record.
    ///
    /// Scoped by the RECORD's vineyard, not the selected one, so a Trip or
    /// Spray keeps resolving its equipment name correctly and can never bind
    /// to a same-id row in a different vineyard.
    func historicalTractor(id: UUID?, inVineyard vineyardId: UUID) -> Tractor? {
        guard let id else { return nil }
        return tractors.first { $0.id == id && $0.vineyardId == vineyardId }
    }

    /// Resolves a tractor referenced by a saved record by free-text name.
    /// Legacy Spray Records stored the tractor as text before ids existed.
    func historicalTractor(named name: String?, inVineyard vineyardId: UUID) -> Tractor? {
        guard let name, !name.isEmpty else { return nil }
        return tractors.first {
            $0.vineyardId == vineyardId && ($0.displayName == name || $0.name == name)
        }
    }

    /// Resolves a vineyard machine referenced by a saved record.
    func historicalMachine(id: UUID?, inVineyard vineyardId: UUID) -> VineyardMachine? {
        guard let id else { return nil }
        return vineyardMachines.first { $0.id == id && $0.vineyardId == vineyardId }
    }

    /// Resolves the machine that superseded a legacy tractor, constrained to
    /// the record's own vineyard so a legacy id can never cross-bind to
    /// another vineyard's machine.
    func historicalMachine(legacyTractorId: UUID?, inVineyard vineyardId: UUID) -> VineyardMachine? {
        guard let legacyTractorId else { return nil }
        return vineyardMachines.first {
            $0.legacyTractorId == legacyTractorId && $0.vineyardId == vineyardId
        }
    }

    /// Preferred equipment resolution for a saved record that may carry a
    /// machine id, a legacy tractor id, or both — always inside the record's
    /// own vineyard. Returns the canonical machine when one exists.
    func historicalEquipment(
        machineId: UUID?,
        tractorId: UUID?,
        inVineyard vineyardId: UUID
    ) -> (machine: VineyardMachine?, tractor: Tractor?) {
        let machine = historicalMachine(id: machineId, inVineyard: vineyardId)
            ?? historicalMachine(legacyTractorId: tractorId, inVineyard: vineyardId)
        let tractor = historicalTractor(id: tractorId, inVineyard: vineyardId)
        return (machine, tractor)
    }
}

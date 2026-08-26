import Foundation

/// Which equipment identities a spray picker is allowed to offer, and what a
/// selection must persist.
///
/// # The invariant this type exists to hold
///
/// > **"Tractor" means a row from `public.tractors`.**
///
/// A Vineyard Machine may be supported only through a machine-aware workflow
/// that stores `machine_id` separately. The Portal regression came from
/// merging `tractors` and `vineyard_machines` into one control labelled
/// *Tractor* and writing the result to `spray_jobs.tractor_id`, which is a
/// foreign key into `tractors` — so a vineyard machine id was being written
/// into a column that cannot hold one.
///
/// iOS never made that write, because `spray_records` genuinely carries BOTH
/// columns. But the same merged control existed, under the same wrong label,
/// and the rules for it lived inside a SwiftUI view where nothing could assert
/// them. They live here instead so the tests can.
///
/// # The two workflows, deliberately different
///
/// ```text
/// spray_jobs     (planned/Program Step)  tractor_id ONLY   → .tractorOnly
/// spray_records  (completed spray)       tractor_id OR machine_id → .powerUnit
/// ```
///
/// That asymmetry is the current architecture, not an oversight, and it is
/// preserved explicitly. Nothing here adds machine support to `spray_jobs`;
/// doing so would need a deliberate schema change first.
nonisolated enum SprayEquipmentPickerKind: Sendable, Hashable {
    /// Genuine tractors only. The selected id populates `tractor_id`.
    ///
    /// Used wherever the write target is `spray_jobs.tractor_id`, whose FK
    /// admits nothing else.
    case tractorOnly
    /// Tractors AND vineyard machines, kept as separate identities.
    ///
    /// Used only where the write target has both columns.
    case powerUnit

    /// The control's user-facing label.
    ///
    /// A picker that accepts an ATV must not call itself "Tractor". That
    /// wording is what teaches an operator the two words are interchangeable,
    /// which is the habit that produced the Portal defect.
    nonisolated var fieldLabel: String {
        switch self {
        case .tractorOnly: return "Tractor"
        case .powerUnit: return "Power unit"
        }
    }

    /// Whether this picker may offer vineyard machines at all.
    nonisolated var allowsVineyardMachines: Bool {
        self == .powerUnit
    }
}

/// The equipment identity a spray record or job carries.
///
/// Exactly one of the two ids is ever set. Modelling it as an enum rather than
/// two optionals is what makes "both set" and "a machine in the tractor field"
/// unrepresentable rather than merely discouraged.
nonisolated enum SprayPowerUnitSelection: Sendable, Hashable {
    case tractor(UUID)
    case vineyardMachine(UUID)

    /// The value for a `tractor_id` column. `nil` for a vineyard machine.
    nonisolated var tractorId: UUID? {
        switch self {
        case .tractor(let id): return id
        case .vineyardMachine: return nil
        }
    }

    /// The value for a `machine_id` column. `nil` for a tractor.
    nonisolated var machineId: UUID? {
        switch self {
        case .tractor: return nil
        case .vineyardMachine(let id): return id
        }
    }

    /// Whether this selection may be written by the given picker.
    ///
    /// The gate that makes the Portal's defect impossible here: a vineyard
    /// machine offered to a tractor-only workflow is refused, not coerced.
    nonisolated func isPermitted(by kind: SprayEquipmentPickerKind) -> Bool {
        switch self {
        case .tractor: return true
        case .vineyardMachine: return kind.allowsVineyardMachines
        }
    }
}

/// Builds the option lists a spray equipment picker may show.
nonisolated enum SprayEquipmentOptions {

    /// The vineyard machines a user may pick.
    ///
    /// Excludes the internal mirrors: a tractor created under Equipment →
    /// Tractors also writes a `vineyard_machines` row linked back through
    /// `legacyTractorId`, so machine-aware features can address it. That row is
    /// plumbing, not a second asset, and listing it puts one tractor in the
    /// menu twice under two different identities.
    ///
    /// Mirrors the filter every other equipment screen already applies.
    static func selectableMachines(_ machines: [VineyardMachine]) -> [VineyardMachine] {
        machines.filter { $0.legacyTractorId == nil }
    }

    /// The machines a picker of the given kind may offer.
    ///
    /// A tractor-only picker offers none — not "none after filtering", but
    /// none by construction.
    static func machines(
        for kind: SprayEquipmentPickerKind,
        from machines: [VineyardMachine]
    ) -> [VineyardMachine] {
        guard kind.allowsVineyardMachines else { return [] }
        return selectableMachines(machines)
    }
}

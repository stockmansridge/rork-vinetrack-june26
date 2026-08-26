import Foundation
import Testing
@testable import VineTrack

/// Equipment identity parity: "Tractor" means a row from `public.tractors`.
///
/// The Portal regression these lock down: the Spray Job wizard merged
/// `public.tractors` and `public.vineyard_machines` into one control labelled
/// *Tractor*, then wrote the chosen id to `spray_jobs.tractor_id` — a foreign
/// key into `tractors`, on a table with no `machine_id` column at all.
///
/// iOS never made that write, because `spray_records` genuinely carries both
/// columns and the two branches set them correctly. But iOS had the same
/// merged control under the same wrong label, and its rules lived inside a
/// SwiftUI view where nothing could assert them.
struct SprayPowerUnitSelectionTests {

    private static let vineyardId = UUID(uuidString: "AA000000-0000-0000-0000-0000000000AA")!

    private func machine(
        _ type: VineyardMachineType,
        name: String,
        legacyTractorId: UUID? = nil
    ) -> VineyardMachine {
        VineyardMachine(
            id: UUID(),
            vineyardId: Self.vineyardId,
            name: name,
            machineType: type,
            legacyTractorId: legacyTractorId
        )
    }

    /// A realistic fleet: four genuine vineyard machines, plus the internal
    /// mirror row that Equipment → Tractors creates alongside a real tractor.
    private func fleet(mirrorFor tractorId: UUID) -> [VineyardMachine] {
        [
            machine(.atv, name: "Honda ATV"),
            machine(.sideBySide, name: "Polaris Ranger"),
            machine(.harvester, name: "Gregoire G8"),
            machine(.utilityVehicle, name: "Kubota RTV"),
            machine(.otherVineyardMachine, name: "Mulcher rig"),
            // The mirror. A real tractor to the user, addressed here only so
            // machine-aware features can reach it.
            machine(.tractor, name: "John Deere 5090", legacyTractorId: tractorId),
        ]
    }

    // MARK: - A. A Tractor-labelled picker offers no vineyard machines

    @Test("A tractor-only picker contains no vineyard machine of any type")
    func tractorPickerExcludesEveryMachineType() {
        let tractorId = UUID()
        let offered = SprayEquipmentOptions.machines(
            for: .tractorOnly,
            from: fleet(mirrorFor: tractorId)
        )

        // Not "empty after filtering" — empty by construction. A tractor-only
        // workflow has no column that could hold a machine id.
        #expect(offered.isEmpty)
        #expect(!SprayEquipmentPickerKind.tractorOnly.allowsVineyardMachines)

        for type in [
            VineyardMachineType.atv, .sideBySide, .harvester,
            .utilityVehicle, .otherVineyardMachine,
        ] {
            let single = SprayEquipmentOptions.machines(
                for: .tractorOnly,
                from: [machine(type, name: "Anything")]
            )
            #expect(single.isEmpty)
        }
    }

    @Test("The label states what the field actually accepts")
    func labelsMatchWhatIsOffered() {
        // A picker offering ATVs must not call itself "Tractor". That wording
        // is what teaches an operator the two words are interchangeable.
        #expect(SprayEquipmentPickerKind.tractorOnly.fieldLabel == "Tractor")
        #expect(SprayEquipmentPickerKind.powerUnit.fieldLabel == "Power unit")
        #expect(SprayEquipmentPickerKind.powerUnit.fieldLabel != "Tractor")
    }

    // MARK: - B. A genuine tractor selection

    @Test("Selecting a tractor sets tractorId and clears machineId")
    func tractorSelectionIdentity() {
        let id = UUID()
        let selection = SprayPowerUnitSelection.tractor(id)

        #expect(selection.tractorId == id)
        #expect(selection.machineId == nil)
    }

    // MARK: - C. A vineyard machine under the general picker

    @Test("Selecting a vineyard machine sets machineId and clears tractorId")
    func machineSelectionIdentity() {
        let id = UUID()
        let selection = SprayPowerUnitSelection.vineyardMachine(id)

        #expect(selection.machineId == id)
        #expect(selection.tractorId == nil)
    }

    @Test("Exactly one identity is ever populated")
    func onlyOneIdentityIsEverSet() {
        // Modelled as an enum precisely so "both set" is unrepresentable
        // rather than merely discouraged.
        for selection: SprayPowerUnitSelection in [
            .tractor(UUID()), .vineyardMachine(UUID()),
        ] {
            let populated = [selection.tractorId, selection.machineId]
                .compactMap { $0 }
            #expect(populated.count == 1)
        }
    }

    // MARK: - D. No vineyard machine can reach spray_jobs.tractor_id

    @Test("A vineyard machine is refused by a tractor-only workflow")
    func machineIsRefusedBySprayJobs() {
        let machineSelection = SprayPowerUnitSelection.vineyardMachine(UUID())
        let tractorSelection = SprayPowerUnitSelection.tractor(UUID())

        // The Portal defect, made impossible: refused, never coerced into the
        // tractor field.
        #expect(!machineSelection.isPermitted(by: .tractorOnly))
        #expect(machineSelection.isPermitted(by: .powerUnit))

        // And a genuine tractor is welcome in both.
        #expect(tractorSelection.isPermitted(by: .tractorOnly))
        #expect(tractorSelection.isPermitted(by: .powerUnit))

        // Whatever a tractor-only picker yields, its machineId is nil — so
        // nothing a spray_jobs write could read is ever a machine id.
        #expect(tractorSelection.machineId == nil)
    }

    // MARK: - E. Linked tractor mirrors are not duplicate tractors

    @Test("Tractor mirrors never appear as user-facing vineyard machines")
    func mirrorsAreHiddenFromTheMachineList() {
        let tractorId = UUID()
        let all = fleet(mirrorFor: tractorId)
        let offered = SprayEquipmentOptions.machines(for: .powerUnit, from: all)

        // Five genuine machines out of six rows.
        #expect(all.count == 6)
        #expect(offered.count == 5)

        // The mirror is gone.
        #expect(!offered.contains { $0.legacyTractorId != nil })
        #expect(!offered.contains { $0.machineType == .tractor })
        #expect(!offered.contains { $0.name == "John Deere 5090" })

        // The real machines all survive — filtering mirrors must not cost the
        // ATV workflow this picker exists to support.
        #expect(Set(offered.map(\.name)) == [
            "Honda ATV", "Polaris Ranger", "Gregoire G8",
            "Kubota RTV", "Mulcher rig",
        ])
    }

    @Test("A tractor appears exactly once across both menu sections")
    func tractorIsNotListedTwice() {
        // The defect: `currentVineyardMachines` unfiltered listed the mirror
        // beside the real tractor, so one asset appeared twice under two
        // different identities — and which id the record carried depended on
        // which identical-looking row the operator tapped.
        let tractorId = UUID()
        let tractor = Tractor(id: tractorId, vineyardId: Self.vineyardId, name: "John Deere 5090")

        let machineSection = SprayEquipmentOptions.machines(
            for: .powerUnit,
            from: fleet(mirrorFor: tractorId)
        )
        let tractorSection = [tractor]

        let allNames = machineSection.map(\.displayName) + tractorSection.map(\.displayName)
        #expect(allNames.count(where: { $0 == "John Deere 5090" }) == 1)

        // And the one entry that remains is the tractor, carrying the tractor
        // identity — not the mirror carrying a machine id.
        #expect(tractorSection.first?.id == tractorId)
        #expect(!machineSection.contains { $0.legacyTractorId == tractorId })
    }

    @Test("An unlinked tractor-typed machine is still offered")
    func unlinkedTractorMachineIsNotSilentlyHidden() {
        // A legacy orphan: tractor-typed with NO backing tractors row. It is
        // invisible under Tractors, so hiding it here too would strand the
        // asset entirely. It is not a mirror — there is nothing to mirror.
        let orphan = machine(.tractor, name: "Old Massey", legacyTractorId: nil)
        #expect(orphan.isUnlinkedTractorMachine)

        let offered = SprayEquipmentOptions.machines(for: .powerUnit, from: [orphan])
        #expect(offered.count == 1)
    }
}

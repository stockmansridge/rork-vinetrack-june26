import Foundation
import Testing
@testable import VineTrack

/// The three device defects from the last TestFlight build.
///
/// 1. A Program Step that prefilled the spray unit made Equipment complete
///    before the screen was ever shown, so the guided flow skipped it and the
///    operator never saw the tractor decision.
/// 2. A resolved canopy spray-volume decision still produced "Spray volume
///    unavailable — row geometry is incomplete", on a block whose geometry was
///    displayed complete and correct two panels above.
/// 3. "Edit block details" opened the block *picker*, which cannot edit a row
///    spacing.
struct SprayEquipmentAndCarrierHandoffTests {

    private let tolerance = 0.0001

    /// The exact device block: Cab Franc.
    ///
    /// 1,750 m of row at 2.8 m spacing is 4,900 m² — 0.49 ha — so the three
    /// figures are mutually consistent and every expected total below can be
    /// reached from either direction.
    private func cabFranc() -> SprayBlockInput {
        SprayBlockInput(
            blockId: "cab-franc",
            grossAreaHectares: 0.49,
            mappedRowLengthMetres: 1_750,
            rowSpacingMetres: 2.8
        )
    }

    /// VSP · Medium · Low = 20 L/100 m on the AWRI table.
    private func canopy(
        type: CanopyType = .vsp,
        size: CanopySize = .medium,
        density: CanopyDensity = .low
    ) -> SprayCanopySelection {
        var selection = SprayCanopySelection.unconfirmed
        selection.choose(type: type)
        selection.choose(size: size)
        selection.choose(density: density)
        return selection
    }

    /// A complete foliar job up to and including Equipment.
    private func inputs(
        basis: SprayCarrierBasis,
        choice: SprayVolumeChoice = .useRecommended,
        customRate: Double? = nil,
        equipmentConfirmed: Bool = true
    ) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = [cabFranc()]
        inputs.targets = [.powderyMildew]
        inputs.sprayHeadTarget = .fullCanopy
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.isEquipmentConfirmed = equipmentConfirmed
        inputs.tankCapacityLitres = 2_000
        inputs.canopy = canopy()
        inputs.canopyWaterRates = .defaults
        inputs.carrierBasis = basis
        inputs.customSprayerBasis = basis
        inputs.sprayVolumeChoice = choice
        inputs.customSprayerRate = customRate
        return inputs
    }

    // MARK: - 1. Equipment must be confirmed, not merely prefilled

    /// The device defect. A Program Step supplies the spray unit; Equipment
    /// must still be the next decision the operator makes.
    @Test("A prefilled spray unit does not complete Equipment")
    func prefilledEquipmentDoesNotSkipTheStep() {
        var prefilled = inputs(basis: .litresPerHectare, equipmentConfirmed: false)
        // Exactly the Program Step case: unit present, no tractor.
        prefilled.isEquipmentSelected = true

        let flow = SprayGuidedFlow(inputs: prefilled)
        #expect(flow.blocker(for: .equipment) == .equipmentConfirmationRequired)
        #expect(flow.isComplete(.equipment) == false)
        // Equipment is where the operator lands after Growth Stage...
        #expect(flow.activeStep == .equipment)
        // ...and Canopy & Spray Volume stays locked behind it.
        #expect(flow.isUnlocked(.carrier) == false)
    }

    @Test("Confirming equipment completes the step and unlocks Canopy")
    func confirmingEquipmentUnlocksCanopy() {
        let flow = SprayGuidedFlow(inputs: inputs(basis: .litresPerHectare))
        #expect(flow.blocker(for: .equipment) == nil)
        #expect(flow.isComplete(.equipment))
        #expect(flow.isUnlocked(.carrier))
    }

    /// A tractor is optional. Not Set is a valid answer and must never be the
    /// thing standing between the operator and the rest of the flow.
    @Test("Equipment completes with no tractor selected")
    func tractorRemainsOptional() {
        // `SprayGuidedInputs` carries no tractor at all, so a flow that
        // completes here proves a tractor was never required.
        let flow = SprayGuidedFlow(inputs: inputs(basis: .litresPerHectare))
        #expect(flow.isComplete(.equipment))
    }

    /// Missing spray unit is still the stronger, more specific blocker.
    @Test("No spray unit reports selection, not confirmation")
    func missingUnitReportsSelection() {
        var noUnit = inputs(basis: .litresPerHectare, equipmentConfirmed: false)
        noUnit.isEquipmentSelected = false
        #expect(SprayGuidedFlow(inputs: noUnit).blocker(for: .equipment) == .equipmentRequired)
    }

    // MARK: - 2. The foliar carrier handoff

    /// Cab Franc, L/100 m, Use recommended: 20 × 1,750 ÷ 100 = 350 L.
    @Test("L/100 m recommended resolves to 350 L with CF 1.00")
    func cabFrancRowLengthRecommended() throws {
        let flow = SprayGuidedFlow(inputs: inputs(basis: .litresPer100Metres))
        let carrier = try #require(flow.carrier)

        #expect(abs(carrier.totalLitres - 350) < tolerance)
        #expect(abs(carrier.concentrationFactor - 1.0) < tolerance)
        #expect(abs((carrier.appliedLitresPer100Metres ?? 0) - 20) < tolerance)
        // Resolved, and NOT reported as a geometry failure.
        #expect(flow.isCarrierResolved)
        #expect(flow.blocker(for: .carrier) == nil)
        #expect(flow.isUnlocked(.products))
    }

    /// Same physical spray, hectare mode: 714.285714 × 0.49 = 350 L.
    @Test("L/ha recommended resolves to 350 L with CF 1.00")
    func cabFrancHectareRecommended() throws {
        let flow = SprayGuidedFlow(inputs: inputs(basis: .litresPerHectare))
        let carrier = try #require(flow.carrier)

        #expect(abs((carrier.litresPerHectare ?? 0) - 714.285714) < 0.001)
        #expect(abs(carrier.totalLitres - 350) < 0.001)
        #expect(abs(carrier.concentrationFactor - 1.0) < tolerance)
        #expect(flow.isCarrierResolved)
        #expect(flow.blocker(for: .carrier) == nil)
        #expect(flow.isUnlocked(.products))
    }

    /// THE invariant. Both bases describe one spray, so both must carry the
    /// same water.
    @Test("Both bases give the same total water for the same spray")
    func bothBasesAgreeOnTotalWater() throws {
        let rowMode = try #require(SprayGuidedFlow(inputs: inputs(basis: .litresPer100Metres)).carrier)
        let areaMode = try #require(SprayGuidedFlow(inputs: inputs(basis: .litresPerHectare)).carrier)
        #expect(abs(rowMode.totalLitres - areaMode.totalLitres) < 0.001)
        #expect(abs(rowMode.totalLitres - 350) < 0.001)
    }

    /// 600 L/ha over 0.49 ha = 294 L; CF = 714.285714 ÷ 600 = 1.19.
    @Test("Custom 600 L/ha resolves to 294 L with CF 1.19")
    func cabFrancCustomHectareRate() throws {
        let flow = SprayGuidedFlow(inputs: inputs(
            basis: .litresPerHectare,
            choice: .useCustomSprayerRate,
            customRate: 600
        ))
        let carrier = try #require(flow.carrier)

        #expect(abs(carrier.totalLitres - 294) < tolerance)
        #expect(abs(carrier.concentrationFactor - 1.190476) < 0.00001)
        #expect(flow.blocker(for: .carrier) == nil)
        #expect(flow.isUnlocked(.products))
    }

    /// 15 L/100 m over 1,750 m = 262.5 L; CF = 20 ÷ 15 = 1.333333.
    @Test("Custom 15 L/100 m resolves to 262.5 L with CF 1.33")
    func cabFrancCustomRowRate() throws {
        let flow = SprayGuidedFlow(inputs: inputs(
            basis: .litresPer100Metres,
            choice: .useCustomSprayerRate,
            customRate: 15
        ))
        let carrier = try #require(flow.carrier)

        #expect(abs(carrier.totalLitres - 262.5) < tolerance)
        #expect(abs(carrier.concentrationFactor - 1.333333) < 0.00001)
        #expect(flow.blocker(for: .carrier) == nil)
        #expect(flow.isUnlocked(.products))
    }

    /// The contradiction that produced the bug: decision resolved, carrier nil.
    /// It must now be impossible for the foliar path.
    @Test("A resolved volume decision always yields a carrier")
    func resolvedDecisionNeverYieldsNilCarrier() {
        let cases: [(SprayCarrierBasis, SprayVolumeChoice, Double?)] = [
            (.litresPer100Metres, .useRecommended, nil),
            (.litresPerHectare, .useRecommended, nil),
            (.litresPer100Metres, .useCustomSprayerRate, 15),
            (.litresPerHectare, .useCustomSprayerRate, 600)
        ]
        for (basis, choice, rate) in cases {
            let flow = SprayGuidedFlow(inputs: inputs(
                basis: basis,
                choice: choice,
                customRate: rate
            ))
            #expect(flow.volumeDecision?.isResolved == true)
            #expect(flow.carrier != nil, "\(basis) \(choice) lost its carrier")
            #expect(flow.blocker(for: .carrier) == nil)
        }
    }

    /// The legacy fields must play no part in the foliar decision. They stay
    /// empty throughout, proving the fix is a handoff change and not a quiet
    /// mirror of the resolved values into a second home.
    @Test("The foliar path never reads or writes the legacy carrier fields")
    func legacyFieldsAreNotASecondDecision() throws {
        let flow = SprayGuidedFlow(inputs: inputs(basis: .litresPerHectare))
        #expect(flow.inputs.litresPerHectare == nil)
        #expect(flow.inputs.appliedLitresPer100Metres == nil)
        let carrier = try #require(flow.carrier)
        #expect(abs(carrier.totalLitres - 350) < 0.001)
    }

    // MARK: - 3. Geometry present means no geometry error

    /// The invariant the device screenshot violated: a block showing complete
    /// geometry must not also produce a block-setup error.
    @Test("Complete geometry produces no block-setup blocker")
    func completeGeometryRaisesNoSetupError() {
        for basis in [SprayCarrierBasis.litresPer100Metres, .litresPerHectare] {
            let flow = SprayGuidedFlow(inputs: inputs(basis: basis))
            // The geometry the calculation itself uses.
            #expect(flow.geometry.grossAreaHectares > 0)
            #expect(flow.geometry.totalRowLengthMetres != nil)
            #expect(flow.geometry.uniformRowSpacingMetres != nil)
            #expect(flow.geometry.unresolvedBlocks.isEmpty)

            // Therefore no step may claim geometry is incomplete.
            for step in SprayGuidedStep.allCases {
                let blocker = flow.blocker(for: step)
                #expect(blocker?.needsBlockEditor != true, "\(step) raised a geometry error")
            }
        }
    }

    /// Terminology: the operator chose a "Spray volume basis", so the failure
    /// must not be reported to them as a "carrier" problem.
    @Test("The unavailable blocker is worded as spray volume")
    func blockerUsesSprayVolumeWording() {
        #expect(SprayGuidedBlocker.carrierNotCalculable.title == "Spray volume unavailable")
    }

    /// Blockers that genuinely need block setup still offer the editor, so the
    /// re-wired action has something to act on.
    @Test("Genuine geometry blockers still request the block editor")
    func genuineGeometryBlockersOfferTheEditor() {
        #expect(SprayGuidedBlocker.carrierNotCalculable.needsBlockEditor)
        #expect(SprayGuidedBlocker.treatedAreaUnavailable.needsBlockEditor)
        #expect(
            SprayGuidedBlocker.blockSetupRequired(message: "x", blockIds: ["a"]).needsBlockEditor
        )
        // Confirmation prompts are not geometry problems and must not offer it.
        #expect(SprayGuidedBlocker.equipmentConfirmationRequired.needsBlockEditor == false)
        #expect(SprayGuidedBlocker.canopyConfirmationRequired.needsBlockEditor == false)
    }

    /// A blocker that names its offending blocks is what lets the editor open
    /// the RIGHT one rather than guessing.
    @Test("A block-setup blocker carries the offending block ids")
    func blockSetupBlockerNamesItsBlocks() throws {
        var broken = inputs(basis: .litresPer100Metres)
        broken.blocks = [
            SprayBlockInput(
                blockId: "no-geometry",
                grossAreaHectares: 0.49,
                mappedRowLengthMetres: nil,
                rowSpacingMetres: nil
            )
        ]
        let blocker = try #require(SprayGuidedFlow(inputs: broken).blocker(for: .blocks))
        guard case let .blockSetupRequired(_, blockIds) = blocker else {
            Issue.record("expected blockSetupRequired, got \(blocker)")
            return
        }
        #expect(blockIds == ["no-geometry"])
    }

    // MARK: - Full guided transition

    /// The whole journey the device test walked: Program Step prefill through
    /// to Products unlocked.
    @Test("Program prefill → confirm equipment → canopy → products unlocked")
    func endToEndGuidedTransition() throws {
        // Arrives from a Program Step: unit prefilled, nothing confirmed.
        var state = inputs(basis: .litresPerHectare, equipmentConfirmed: false)
        state.canopy = .unconfirmed
        state.sprayVolumeChoice = .undecided

        var flow = SprayGuidedFlow(inputs: state)
        #expect(flow.activeStep == .equipment)
        #expect(flow.blocker(for: .equipment) == .equipmentConfirmationRequired)
        #expect(flow.isUnlocked(.carrier) == false)

        // Confirm Equipment.
        state.isEquipmentConfirmed = true
        flow = SprayGuidedFlow(inputs: state)
        #expect(flow.isComplete(.equipment))
        #expect(flow.isUnlocked(.carrier))
        // Canopy is now the outstanding question — not the spray volume.
        #expect(flow.blocker(for: .carrier) == .canopyConfirmationRequired)

        // Canopy: VSP · Medium · Low.
        state.canopy = canopy()
        flow = SprayGuidedFlow(inputs: state)
        #expect(flow.blocker(for: .carrier) == .sprayVolumeChoiceRequired)

        // Use recommended.
        state.sprayVolumeChoice = .useRecommended
        flow = SprayGuidedFlow(inputs: state)

        let decision = try #require(flow.volumeDecision)
        #expect(abs((decision.recommendedLitresPer100Metres ?? 0) - 20) < tolerance)
        #expect(abs((decision.recommendedLitresPerHectare ?? 0) - 714.285714) < 0.001)

        let carrier = try #require(flow.carrier)
        #expect(abs(carrier.totalLitres - 350) < 0.001)
        #expect(abs(carrier.concentrationFactor - 1.0) < tolerance)

        #expect(flow.blocker(for: .carrier) == nil)
        #expect(flow.isUnlocked(.products))
        #expect(flow.blocker(for: .products) == .noProductsAdded)
    }
}

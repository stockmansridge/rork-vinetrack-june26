import Foundation
import Testing
@testable import VineTrack

/// Parity contract for the guided Spray Workflow's application INTENT and
/// per-product rate bases.
///
/// The Android suite `SprayGuidedWorkflowParityTest` asserts the same fixtures
/// and the same numbers, so an operator moving between platforms meets identical
/// decisions and identical quantities.
///
/// Everything here protects one rule: a figure the operator sees came out of
/// `SprayApplicationPlanner.plan`, and the record that is persisted is a
/// projection of that same plan. Nothing is recomputed by a screen, and nothing
/// about a historical record is silently restated.
struct SprayGuidedWorkflowParityTests {

    private let tolerance = 0.0001

    // MARK: - Fixtures

    /// THE worked example, shared verbatim with Android: 10 ha gross, 31,250 m
    /// of row, 3.2 m spacing. A 0.8 m band treats exactly 2.50 ha, and 20 L/100 m
    /// over that row length is exactly 6,250 L of carrier.
    private func block(id: String = "block-a") -> SprayBlockInput {
        SprayBlockInput(
            blockId: id,
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
    }

    private func product(
        _ name: String,
        _ basis: SprayProductRateBasis,
        rate: Double,
        unit: String = "L",
        explicit: Bool = true
    ) -> SprayProductLineInput {
        SprayProductLineInput(
            productId: name.lowercased(),
            name: name,
            unit: unit,
            basis: basis,
            rate: rate,
            isAreaBasisExplicit: explicit
        )
    }

    /// The three-basis banded tank mix from the specification.
    private func mixedBasisProducts() -> [SprayProductLineInput] {
        [
            product("Kelp", .wholeBlockArea, rate: 2),
            product("Herbicide", .treatedArea, rate: 2),
            product("Adjuvant", .per100Litres, rate: 100, unit: "mL")
        ]
    }

    /// A complete BANDED pass on the worked example, carried on L/100 m so the
    /// carrier volume is exactly 6,250 L with no concentration.
    private func bandedInputs(
        appliedPer100m: Double = 20,
        bandWidth: Double = 0.8,
        products: [SprayProductLineInput]? = nil
    ) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .bandedSpray
        inputs.blocks = [block()]
        inputs.targets = [.weeds]
        inputs.bandWidthTotalMetres = bandWidth
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .litresPer100Metres
        inputs.appliedLitresPer100Metres = appliedPer100m
        inputs.products = products ?? mixedBasisProducts()
        return inputs
    }

    private func foliarInputs(
        head: SprayHeadTarget? = .fullCanopy,
        targets: Set<SprayTarget> = [.powderyMildew],
        products: [SprayProductLineInput]? = nil
    ) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = [block()]
        inputs.targets = targets
        inputs.sprayHeadTarget = head
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .litresPerHectare
        inputs.litresPerHectare = 625
        inputs.products = products ?? [product("Sulphur", .wholeBlockArea, rate: 2)]
        return inputs
    }

    /// A persist → reload round trip through the snapshot's own coding, which is
    /// what the sql/193 columns are written from and read back into.
    private func roundTrip(_ snapshot: SprayApplicationSnapshot) throws -> SprayApplicationSnapshot {
        let data = try JSONEncoder().encode(snapshot)
        return try JSONDecoder().decode(SprayApplicationSnapshot.self, from: data)
    }

    // MARK: - Targets

    @Test("A single target persists and reloads as the same stable identifier")
    func singleTargetPersists() throws {
        let flow = SprayGuidedFlow(inputs: foliarInputs(targets: [.botrytis]))
        let snapshot = try #require(flow.snapshot)

        #expect(snapshot.targets == [.botrytis])
        #expect(snapshot.targets?.map(\.rawValue) == ["botrytis"])
        #expect(try roundTrip(snapshot).targets == [.botrytis])
    }

    @Test("Multiple targets persist in presentation order regardless of tap order")
    func multipleTargetsAreOrdered() throws {
        let a = SprayGuidedFlow(inputs: foliarInputs(targets: [.botrytis, .powderyMildew]))
        let b = SprayGuidedFlow(inputs: foliarInputs(targets: [.powderyMildew, .botrytis]))

        let expected: [SprayTarget] = [.powderyMildew, .botrytis]
        #expect(a.snapshot?.targets == expected)
        // Two sprays with the same selection must serialise identically, or the
        // Resistance Planner would see two different-looking histories.
        #expect(a.snapshot?.targets == b.snapshot?.targets)
        #expect(try roundTrip(#require(a.snapshot)).targets == expected)
    }

    @Test("Editing the targets replaces them rather than accumulating")
    func editingTargetsReplaces() {
        let before = SprayGuidedFlow(inputs: foliarInputs(targets: [.powderyMildew]))
        let after = SprayGuidedFlow(inputs: foliarInputs(targets: [.downyMildew, .botrytis]))

        #expect(before.snapshot?.targets == [.powderyMildew])
        #expect(after.snapshot?.targets == [.downyMildew, .botrytis])
    }

    @Test("A record with no recorded targets stays nil and is never inferred")
    func historicalTargetsStayNil() {
        // A pre-sql/193 record replayed through the engine: geometry present,
        // intent absent entirely. nil = never recorded. NOT an empty list, and
        // never guessed from the chemistry in the tank.
        let plan = SprayGuidedFlow(inputs: bandedInputs()).plan
        let snapshot = SprayApplicationSnapshot(plan: plan, targets: nil, sprayHeadTarget: nil)

        #expect(snapshot.targets == nil)
        #expect(snapshot.hasRecordedTargets == false)
        #expect(snapshot.treatedAreaHa != nil)
    }

    // MARK: - Spray head target

    @Test("Each foliar spray head target persists and reloads")
    func headTargetsPersist() throws {
        for head in SprayHeadTarget.allCases {
            let snapshot = try #require(SprayGuidedFlow(inputs: foliarInputs(head: head)).snapshot)
            #expect(snapshot.sprayHeadTarget == head)
            #expect(try roundTrip(snapshot).sprayHeadTarget == head)
        }
    }

    @Test("Switching foliar to banded clears the spray head target at flow level")
    func bandedClearsHeadTarget() {
        // The screen may still be holding Bunch Line in its own state; the flow
        // must refuse to carry it, so a banded record can never claim the spray
        // was aimed at the bunch line.
        var stale = bandedInputs()
        stale.sprayHeadTarget = .bunchLine
        let flow = SprayGuidedFlow(inputs: stale)

        #expect(flow.effectiveSprayHeadTarget == nil)
        #expect(flow.snapshot?.sprayHeadTarget == nil)
    }

    @Test("Switching banded to foliar drops the band width and treats the whole block")
    func foliarClearsBandWidth() {
        var stale = foliarInputs()
        stale.bandWidthTotalMetres = 0.8
        let flow = SprayGuidedFlow(inputs: stale)

        #expect(flow.bandWidth == nil)
        #expect(abs((flow.plan.treatedAreaHectares ?? 0) - 10) < tolerance)
        #expect(flow.snapshot?.bandWidthTotalMetres == nil)
    }

    // MARK: - Vineyard spray profile

    @Test("A stored AU profile allowing either basis leaves the choice with the operator")
    func storedEitherPolicy() {
        let profile = SprayVineyardProfile(
            storedProfile: .australia,
            storedPolicy: .either,
            countryCode: "AU"
        )
        let flow = SprayGuidedFlow(inputs: foliarInputs(), profile: profile)

        #expect(flow.isCarrierBasisLocked == false)
        #expect(flow.effectiveCarrierBasis == .litresPerHectare)
        #expect(flow.carrierPolicy.allows(.litresPer100Metres))
    }

    @Test("A stored L/ha-only policy locks the basis to hectares")
    func storedHectaresOnly() {
        var inputs = foliarInputs()
        inputs.carrierBasis = .litresPer100Metres
        let flow = SprayGuidedFlow(
            inputs: inputs,
            profile: SprayVineyardProfile(storedPolicy: .litresPerHectareOnly, countryCode: "AU")
        )

        #expect(flow.isCarrierBasisLocked)
        #expect(flow.effectiveCarrierBasis == .litresPerHectare)
    }

    @Test("A stored L/100 m-only policy locks the basis to row length")
    func storedRowLengthOnly() {
        let flow = SprayGuidedFlow(
            inputs: bandedInputs(),
            profile: SprayVineyardProfile(storedPolicy: .litresPer100MetresOnly, countryCode: "AU")
        )

        #expect(flow.isCarrierBasisLocked)
        #expect(flow.effectiveCarrierBasis == .litresPer100Metres)
    }

    @Test("An NZ/SWNZ vineyard cannot be switched onto L/ha")
    func swnzLocksToRowLength() {
        var inputs = bandedInputs()
        // Even if the screen state says L/ha, the profile overrides it: the UI
        // renders no L/ha option and no "allow either" selector for SWNZ.
        inputs.carrierBasis = .litresPerHectare
        let flow = SprayGuidedFlow(
            inputs: inputs,
            profile: SprayVineyardProfile(storedProfile: .newZealandSWNZ, countryCode: "NZ")
        )

        #expect(flow.isCarrierBasisLocked)
        #expect(flow.effectiveCarrierBasis == .litresPer100Metres)
        #expect(flow.carrierPolicy.allows(.litresPerHectare) == false)
        // L/ha is still DERIVED and stored internally — hidden, not discarded.
        #expect(abs((flow.plan.carrier.litresPerHectare ?? 0) - 625) < tolerance)
    }

    @Test("Country fallback applies only when no profile is stored")
    func countryFallbackOnlyWhenUnset() {
        let unset = SprayVineyardProfile(countryCode: "NZ")
        #expect(unset.resolvedProfile == .newZealandSWNZ)
        #expect(unset.isCarrierBasisLocked)

        // A vineyard that has deliberately chosen AU is NOT overridden by its
        // own address — resolution reads the stored value first.
        let stored = SprayVineyardProfile(storedProfile: .australia, countryCode: "NZ")
        #expect(stored.resolvedProfile == .australia)
        #expect(stored.isCarrierBasisLocked == false)
    }

    // MARK: - Per-product rate basis

    @Test("One banded mix calculates whole block, treated band and per-100 L independently")
    func mixedBasisQuantities() {
        let flow = SprayGuidedFlow(inputs: bandedInputs())
        #expect(flow.isComplete)

        let plan = flow.plan
        #expect(abs(plan.grossAreaHectares - 10) < tolerance)
        #expect(abs((plan.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        #expect(abs(plan.totalCarrierLitres - 6_250) < tolerance)
        #expect(abs(plan.concentrationFactor - 1) < tolerance)

        // 2 L/ha × 10 ha whole block
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 20) < tolerance)
        #expect(abs((plan.productLines[0].basisInput ?? 0) - 10) < tolerance)
        // 2 L/ha × 2.5 ha treated band
        #expect(abs((plan.productLines[1].totalQuantity ?? 0) - 5) < tolerance)
        #expect(abs((plan.productLines[1].basisInput ?? 0) - 2.5) < tolerance)
        // 100 mL/100 L × 6,250 L carrier = 6,250 mL = 6.25 L
        #expect(abs((plan.productLines[2].totalQuantity ?? 0) - 6_250) < tolerance)
        #expect(abs((plan.productLines[2].basisInput ?? 0) - 6_250) < tolerance)
    }

    @Test("Product measurements survive persist and reload unchanged")
    func measurementsSurviveReload() throws {
        let snapshot = try #require(SprayGuidedFlow(inputs: bandedInputs()).snapshot)
        let reloaded = try roundTrip(snapshot)

        // The measured inputs each basis multiplies against are what must
        // survive: gross, treated and carrier all reload verbatim, so replaying
        // the record reproduces 20 L, 5 L and 6.25 L exactly.
        #expect(abs((reloaded.grossAreaHa ?? 0) - 10) < tolerance)
        #expect(abs((reloaded.treatedAreaHa ?? 0) - 2.5) < tolerance)
        #expect(abs((reloaded.totalCarrierLitres ?? 0) - 6_250) < tolerance)
        #expect(reloaded.targets == [.weeds])
        #expect(reloaded.sprayHeadTarget == nil)
    }

    @Test("A new banded area product will not proceed on an unconfirmed area basis")
    func bandedAreaBasisMustBeExplicit() {
        let flow = SprayGuidedFlow(
            inputs: bandedInputs(
                products: [product("Kelp", .wholeBlockArea, rate: 2, explicit: false)]
            )
        )

        guard case let .productAreaBasisRequired(names) = flow.blocker(for: .products) else {
            Issue.record("expected the area-basis question to block the Products step")
            return
        }
        #expect(names == ["Kelp"])
        #expect(flow.isComplete == false)
        // Nothing may be frozen into a record until the operator answers.
        #expect(flow.snapshot == nil)
    }

    @Test("A per-100 L product is never asked the area question")
    func per100LNeverAsked() {
        let flow = SprayGuidedFlow(
            inputs: bandedInputs(
                products: [product("Adjuvant", .per100Litres, rate: 100, unit: "mL", explicit: false)]
            )
        )

        // Its basis comes from the product's own label, not from how the block
        // was covered, so there is nothing ambiguous to confirm.
        #expect(flow.blocker(for: .products) == nil)
        #expect(flow.isComplete)
    }

    @Test("A whole-block pass never asks the area question")
    func wholeBlockNeverAsked() {
        let flow = SprayGuidedFlow(
            inputs: foliarInputs(
                products: [product("Sulphur", .wholeBlockArea, rate: 2, explicit: false)]
            )
        )

        // Treated and gross are the same thing here, so there is no decision.
        #expect(flow.blocker(for: .products) == nil)
        #expect(flow.isComplete)
    }

    @Test("A treated-area product without band geometry names the missing input")
    func treatedAreaProductNamesItsBlocker() {
        let flow = SprayGuidedFlow(inputs: bandedInputs(bandWidth: 0))
        let herbicide = flow.plan.productLines[1]

        #expect(herbicide.isUnresolved)
        #expect(herbicide.unresolvedReason == .treatedAreaUnavailable)
        // Never dosed against gross hectares as a fallback.
        #expect(herbicide.totalQuantity == nil)
        #expect(herbicide.basisInput == nil)
    }

    @Test("A per-100 L product without a carrier names the carrier step")
    func per100LProductNamesItsBlocker() {
        let flow = SprayGuidedFlow(inputs: bandedInputs(appliedPer100m: 0))
        let adjuvant = flow.plan.productLines[2]

        #expect(adjuvant.isUnresolved)
        #expect(adjuvant.unresolvedReason == .carrierUnavailable)
        // Never dosed against zero litres.
        #expect(adjuvant.totalQuantity == nil)
    }

    // MARK: - Recalculation isolation

    @Test("Changing the band width moves only the treated-area product")
    func bandWidthIsolation() {
        let before = SprayGuidedFlow(inputs: bandedInputs()).plan
        let after = SprayGuidedFlow(inputs: bandedInputs(bandWidth: 1.6)).plan

        #expect(abs((before.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        #expect(abs((after.treatedAreaHectares ?? 0) - 5) < tolerance)
        #expect(abs((after.productLines[1].totalQuantity ?? 0) - 10) < tolerance)

        // Whole block and per-100 L are untouched: the band says nothing about
        // gross hectares, and nothing about how much water went out.
        #expect(before.productLines[0].totalQuantity == after.productLines[0].totalQuantity)
        #expect(before.productLines[2].totalQuantity == after.productLines[2].totalQuantity)
        #expect(abs(before.totalCarrierLitres - after.totalCarrierLitres) < tolerance)
    }

    @Test("Changing the applied L/100 m moves only carrier-dependent quantities")
    func carrierIsolation() {
        let before = SprayGuidedFlow(inputs: bandedInputs()).plan
        let after = SprayGuidedFlow(inputs: bandedInputs(appliedPer100m: 40)).plan

        #expect(abs(before.totalCarrierLitres - 6_250) < tolerance)
        #expect(abs(after.totalCarrierLitres - 12_500) < tolerance)
        #expect(abs((after.productLines[2].totalQuantity ?? 0) - 12_500) < tolerance)

        // Area-based products do not care how much water carried them.
        #expect(abs((after.productLines[0].totalQuantity ?? 0) - 20) < tolerance)
        #expect(abs((after.productLines[1].totalQuantity ?? 0) - 5) < tolerance)
        #expect(before.treatedAreaHectares == after.treatedAreaHectares)
    }

    @Test("Changing the selected blocks recalculates every derived figure")
    func blockChangeRecalculatesEverything() {
        var inputs = bandedInputs()
        inputs.blocks = [block(), block(id: "block-b")]
        let plan = SprayGuidedFlow(inputs: inputs).plan

        #expect(abs(plan.grossAreaHectares - 20) < tolerance)
        #expect(abs((plan.geometry.totalRowLengthMetres ?? 0) - 62_500) < tolerance)
        #expect(abs((plan.treatedAreaHectares ?? 0) - 5) < tolerance)
        #expect(abs(plan.totalCarrierLitres - 12_500) < tolerance)
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 40) < tolerance)
        #expect(abs((plan.productLines[1].totalQuantity ?? 0) - 10) < tolerance)
        #expect(abs((plan.productLines[2].totalQuantity ?? 0) - 12_500) < tolerance)
    }

    // MARK: - Review parity & progressive disclosure

    @Test("The review the operator signs off is the record that gets persisted")
    func reviewEqualsPersistedRecord() throws {
        let flow = SprayGuidedFlow(inputs: bandedInputs())
        let plan = flow.plan
        let snapshot = try #require(flow.snapshot)

        // Review reads `plan`; persistence writes `snapshot`. They must be the
        // same projection — there is no second review-side calculation.
        #expect(
            snapshot == SprayApplicationSnapshot(
                plan: plan,
                targets: flow.orderedTargets,
                sprayHeadTarget: flow.effectiveSprayHeadTarget
            )
        )
        #expect(abs((snapshot.grossAreaHa ?? 0) - plan.grossAreaHectares) < tolerance)
        #expect(snapshot.treatedAreaHa == plan.treatedAreaHectares)
        #expect(abs((snapshot.totalCarrierLitres ?? 0) - plan.totalCarrierLitres) < tolerance)
    }

    @Test("The decision order is Application → Blocks → Target → Growth → Equipment → Carrier → Products → Review")
    func decisionOrderIsFixed() {
        #expect(
            SprayGuidedStep.allCases == [
                .application, .blocks, .target, .growthStage,
                .equipment, .carrier, .products, .review
            ]
        )

        // Target sits behind Blocks: it cannot be answered before the ground it
        // applies to is known.
        var noBlocks = bandedInputs()
        noBlocks.blocks = []
        let blocked = SprayGuidedFlow(inputs: noBlocks)
        #expect(blocked.isUnlocked(.target) == false)
        #expect(blocked.activeStep == .blocks)

        // And Products sits behind Carrier, so a per-100 L line is never dosed
        // against a carrier volume that does not exist yet.
        let noCarrier = SprayGuidedFlow(inputs: bandedInputs(appliedPer100m: 0))
        #expect(noCarrier.isUnlocked(.products) == false)
        #expect(noCarrier.activeStep == .carrier)
    }
}

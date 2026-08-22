import Foundation
import Testing
@testable import VineTrack

/// Contract for the guided Spray Calculator flow.
///
/// Two things are under test:
///
///  1. **Guided-state logic** — progressive disclosure. A step unlocks only when
///     every step before it is complete, and incomplete block geometry stops
///     progression instead of silently calculating against a guess.
///  2. **Calculation integration** — every displayed figure comes from ONE
///     `SprayApplicationPlan` produced by `SprayApplicationPlanner.plan`, and the
///     snapshot that gets persisted is a projection of that same plan.
///
/// The Android suite `SprayGuidedFlowTest` asserts the same fixtures, so a user
/// moving between platforms meets identical decisions and identical numbers.
struct SprayGuidedFlowTests {

    private let tolerance = 0.0001

    // MARK: - Fixtures

    /// THE worked example: 10 ha gross, 31,250 m of row, 3.2 m spacing.
    /// A 0.8 m band over that geometry treats exactly 2.50 ha.
    private func block(
        id: String = "block-a",
        grossHectares: Double? = 10,
        rowLengthMetres: Double? = 31_250,
        rowSpacing: Double? = 3.2
    ) -> SprayBlockInput {
        SprayBlockInput(
            blockId: id,
            grossAreaHectares: grossHectares,
            mappedRowLengthMetres: rowLengthMetres,
            rowSpacingMetres: rowSpacing
        )
    }

    private func product(
        _ name: String,
        _ basis: SprayProductRateBasis,
        rate: Double,
        unit: String = "L"
    ) -> SprayProductLineInput {
        SprayProductLineInput(
            productId: name.lowercased(),
            name: name,
            unit: unit,
            basis: basis,
            rate: rate
        )
    }

    /// A flow that satisfies every gated step, so an individual test can break
    /// exactly one thing and assert the consequence.
    private func completeInputs(
        operationType: OperationType = .foliarSpray
    ) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = operationType
        inputs.blocks = [block()]
        inputs.targets = [.powderyMildew]
        inputs.sprayHeadTarget = operationType == .foliarSpray ? .fullCanopy : nil
        inputs.bandWidthTotalMetres = operationType == .bandedSpray ? 0.8 : nil
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .litresPerHectare
        inputs.litresPerHectare = 625
        inputs.products = [product("Sulphur", .wholeBlockArea, rate: 2)]
        return inputs
    }

    // MARK: - 1. Foliar + L/ha

    @Test("Foliar L/ha: whole-block treated area and hectare-based carrier")
    func foliarLitresPerHectarePath() {
        let flow = SprayGuidedFlow(inputs: completeInputs())

        #expect(flow.mode == .wholeBlock)
        #expect(flow.requiresSprayHeadTarget)
        #expect(!flow.requiresBandWidth)
        #expect(flow.isComplete)

        let plan = flow.plan
        #expect(abs(plan.grossAreaHectares - 10) < tolerance)
        // A foliar pass treats the whole block: treated == gross, never nil.
        #expect(abs((plan.treatedAreaHectares ?? 0) - 10) < tolerance)
        #expect(plan.treatedArea.method == .wholeBlock)
        #expect(abs(plan.totalCarrierLitres - 6_250) < tolerance)
        #expect(plan.carrier.basis == .litresPerHectare)
        // No dilute reference entered, so no concentration.
        #expect(abs(plan.concentrationFactor - 1.0) < tolerance)
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 20) < tolerance)
    }

    @Test("Foliar L/ha: a dilute reference above the applied rate concentrates")
    func foliarConcentrationFromDiluteReference() {
        var inputs = completeInputs()
        inputs.litresPerHectare = 500
        inputs.diluteLitresPerHectare = 1_000
        let plan = SprayGuidedFlow(inputs: inputs).plan

        #expect(abs(plan.concentrationFactor - 2.0) < tolerance)
        #expect(abs(plan.totalCarrierLitres - 5_000) < tolerance)
    }

    // MARK: - 2. Foliar + L/100 m

    @Test("Foliar L/100 m: spec example — 2.00x, 6,250 L, 625 L/ha derived")
    func foliarLitresPer100MetresPath() {
        var inputs = completeInputs()
        inputs.carrierBasis = .litresPer100Metres
        inputs.litresPerHectare = nil
        inputs.diluteLitresPer100Metres = 40
        inputs.appliedLitresPer100Metres = 20

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isComplete)

        let plan = flow.plan
        #expect(plan.carrier.basis == .litresPer100Metres)
        // dilute ÷ applied = 40 ÷ 20
        #expect(abs(plan.concentrationFactor - 2.0) < tolerance)
        // 31,250 m ÷ 100 × 20 L
        #expect(abs(plan.totalCarrierLitres - 6_250) < tolerance)
        // 20 L/100 m × 100 ÷ 3.2 m spacing
        #expect(abs((plan.carrier.litresPerHectare ?? 0) - 625) < tolerance)
        // The operator never types derived L/ha — it comes back from the engine.
        #expect(plan.carrier.appliedLitresPer100Metres == 20)
        #expect(plan.carrier.diluteLitresPer100Metres == 40)
    }

    @Test("L/100 m without row spacing: carrier still resolves, derived L/ha does not")
    func litresPer100MetresWithoutSpacing() {
        var inputs = completeInputs()
        inputs.blocks = [block(rowSpacing: nil)]
        inputs.carrierBasis = .litresPer100Metres
        inputs.litresPerHectare = nil
        inputs.appliedLitresPer100Metres = 20

        let plan = SprayGuidedFlow(inputs: inputs).plan
        // Mapped rows give the row length, so total litres are known...
        #expect(abs(plan.totalCarrierLitres - 6_250) < tolerance)
        // ...but L/ha cannot be derived without a real spacing, and is NOT guessed.
        #expect(plan.carrier.litresPerHectare == nil)
    }

    // MARK: - 3/4/5. Banded product bases

    @Test("Banded: whole-block product doses against gross hectares")
    func bandedWholeBlockProduct() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.products = [product("Kelp", .wholeBlockArea, rate: 2)]

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.mode == .banded)
        #expect(flow.isComplete)

        let plan = flow.plan
        #expect(abs(plan.grossAreaHectares - 10) < tolerance)
        #expect(abs((plan.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        // 2 L/ha × 10 ha gross
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 20) < tolerance)
    }

    @Test("Banded: treated-area product doses against the 2.5 ha band")
    func bandedTreatedAreaProduct() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.products = [product("Herbicide", .treatedArea, rate: 2)]

        let plan = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs((plan.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        // 2 L/ha × 2.5 ha treated
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 5) < tolerance)
        // Gross survives alongside treated — it is never overwritten.
        #expect(abs(plan.grossAreaHectares - 10) < tolerance)
    }

    @Test("Banded: per-100 L product doses against carrier litres")
    func bandedPer100LitresProduct() {
        var inputs = completeInputs(operationType: .bandedSpray)
        // 625 L/ha × 10 ha gross = 6,250 L, no concentration.
        inputs.products = [product("Adjuvant", .per100Litres, rate: 100, unit: "mL")]

        let plan = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs(plan.totalCarrierLitres - 6_250) < tolerance)
        // 100 mL per 100 L × 6,250 L = 6,250 mL = 6.25 L
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 6_250) < tolerance)
    }

    @Test("Per-100 L label rates are written against dilute, so concentrating does not cut the dose")
    func per100LitresHonoursConcentration() {
        var inputs = completeInputs()
        inputs.carrierBasis = .litresPer100Metres
        inputs.litresPerHectare = nil
        inputs.diluteLitresPer100Metres = 40
        inputs.appliedLitresPer100Metres = 20
        inputs.products = [product("Adjuvant", .per100Litres, rate: 100, unit: "mL")]

        let plan = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs(plan.concentrationFactor - 2.0) < tolerance)
        // 100 × 6,250 ÷ 100 × 2.0 — the dilute-equivalent volume.
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 12_500) < tolerance)
    }

    // MARK: - 6. Mixed bases in ONE spray

    @Test("Mixed bases in one tank: 20 L, 5 L and 6.25 L from a single plan")
    func mixedProductBasesInOneSpray() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.products = [
            product("Kelp", .wholeBlockArea, rate: 2),
            product("Herbicide", .treatedArea, rate: 2),
            product("Adjuvant", .per100Litres, rate: 100, unit: "mL")
        ]

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isComplete)

        let plan = flow.plan
        #expect(plan.productLines.count == 3)
        // All three come out of the SAME plan — no per-line recalculation.
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 20) < tolerance)
        #expect(abs((plan.productLines[1].totalQuantity ?? 0) - 5) < tolerance)
        #expect(abs((plan.productLines[2].totalQuantity ?? 0) - 6_250) < tolerance)
        #expect(plan.unresolvedProductLines.isEmpty)
        // Each line keeps its own basis; there is no job-level rate basis.
        #expect(plan.productLines.map(\.basis) == [.wholeBlockArea, .treatedArea, .per100Litres])
    }

    // MARK: - 7. Missing geometry blocks progression

    @Test("Banded with no spacing and no rows: blocks step blocks progression")
    func missingGeometryBlocksProgression() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.blocks = [block(rowLengthMetres: nil, rowSpacing: nil)]

        let flow = SprayGuidedFlow(inputs: inputs)

        let blocker = flow.blocker(for: .blocks)
        #expect(blocker != nil)
        if case let .blockSetupRequired(_, blockIds) = blocker {
            #expect(blockIds == ["block-a"])
        } else {
            Issue.record("expected blockSetupRequired, got \(String(describing: blocker))")
        }
        #expect(blocker?.needsBlockEditor == true)

        // Progression stops: nothing after Blocks is reachable.
        #expect(flow.isUnlocked(.blocks))
        #expect(!flow.isUnlocked(.target))
        #expect(!flow.isUnlocked(.carrier))
        #expect(!flow.isUnlocked(.review))
        #expect(!flow.isComplete)
        #expect(flow.activeStep == .blocks)
        // And no snapshot may be persisted from an incomplete flow.
        #expect(flow.snapshot == nil)
    }

    @Test("Whole-block L/ha does NOT require row geometry")
    func wholeBlockLitresPerHectareToleratesMissingRowGeometry() {
        var inputs = completeInputs()
        // Area only: no mapped rows, no spacing.
        inputs.blocks = [block(rowLengthMetres: nil, rowSpacing: nil)]

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(!flow.requiresCanonicalRowLength)
        #expect(flow.blocker(for: .blocks) == nil)
        #expect(flow.isComplete)
        // 625 L/ha × 10 ha still works without any row metres.
        #expect(abs(flow.plan.totalCarrierLitres - 6_250) < tolerance)
    }

    @Test("Switching to L/100 m makes row geometry required and blocks progression")
    func carrierBasisChangeCanIntroduceGeometryRequirement() {
        var inputs = completeInputs()
        inputs.blocks = [block(rowLengthMetres: nil, rowSpacing: nil)]
        inputs.carrierBasis = .litresPer100Metres
        inputs.litresPerHectare = nil
        inputs.appliedLitresPer100Metres = 20

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.requiresCanonicalRowLength)
        #expect(flow.blocker(for: .blocks)?.needsBlockEditor == true)
        #expect(!flow.isComplete)
    }

    // MARK: - 8. Explicit 2.5 m spacing stays valid

    @Test("An explicitly entered 2.5 m spacing is a real measurement, not the old fallback")
    func explicitTwoPointFiveSpacingRemainsValid() {
        var inputs = completeInputs()
        // Area + explicit 2.5 m spacing, no mapped rows: row length is DERIVED.
        inputs.blocks = [block(rowLengthMetres: nil, rowSpacing: 2.5)]
        inputs.carrierBasis = .litresPer100Metres
        inputs.litresPerHectare = nil
        inputs.appliedLitresPer100Metres = 20

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.blocker(for: .blocks) == nil)
        #expect(flow.isComplete)

        let plan = flow.plan
        // 10 ha × 10,000 ÷ 2.5 = 40,000 m
        #expect(abs((plan.geometry.totalRowLengthMetres ?? 0) - 40_000) < tolerance)
        #expect(plan.geometry.source == .derivedFromAreaAndSpacing)
        #expect(plan.geometry.quality == .derived)
        // 40,000 ÷ 100 × 20 = 8,000 L
        #expect(abs(plan.totalCarrierLitres - 8_000) < tolerance)
        // 20 × 100 ÷ 2.5 = 800 L/ha
        #expect(abs((plan.carrier.litresPerHectare ?? 0) - 800) < tolerance)
    }

    // MARK: - 9. NZ / SWNZ locked L/100 m

    @Test("SWNZ profile locks carrier entry to L/100 m with no L/ha choice offered")
    func newZealandProfileLocksToLitresPer100Metres() {
        var inputs = completeInputs()
        inputs.litresPerHectare = nil
        inputs.appliedLitresPer100Metres = 20
        // The operator's stored preference says L/ha, but the profile forbids it.
        inputs.carrierBasis = .litresPerHectare

        let flow = SprayGuidedFlow(
            inputs: inputs,
            profile: SprayVineyardProfile(countryCode: "NZ")
        )

        #expect(flow.carrierPolicy == .litresPer100MetresOnly)
        #expect(flow.isCarrierBasisLocked)
        // The forbidden basis is overridden, not obeyed.
        #expect(flow.effectiveCarrierBasis == .litresPer100Metres)
        #expect(flow.isComplete)
        #expect(flow.plan.carrier.basis == .litresPer100Metres)
        #expect(abs(flow.plan.totalCarrierLitres - 6_250) < tolerance)
    }

    @Test("Australian profile allows either basis and offers the choice")
    func australianProfileAllowsEitherBasis() {
        let flow = SprayGuidedFlow(
            inputs: completeInputs(),
            profile: SprayVineyardProfile(countryCode: "AU")
        )
        #expect(flow.carrierPolicy == .either)
        #expect(!flow.isCarrierBasisLocked)
        #expect(flow.effectiveCarrierBasis == .litresPerHectare)
    }

    // MARK: - 10. Changing blocks recalculates everything downstream

    @Test("Adding a block recalculates geometry, carrier and every product total")
    func changingBlocksRecalculatesDependentTotals() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.products = [
            product("Kelp", .wholeBlockArea, rate: 2),
            product("Herbicide", .treatedArea, rate: 2)
        ]

        let before = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs(before.grossAreaHectares - 10) < tolerance)
        #expect(abs((before.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        #expect(abs(before.totalCarrierLitres - 6_250) < tolerance)

        // Add a second identical block: everything doubles.
        inputs.blocks = [block(), block(id: "block-b")]
        let after = SprayGuidedFlow(inputs: inputs).plan

        #expect(abs(after.grossAreaHectares - 20) < tolerance)
        #expect(abs((after.treatedAreaHectares ?? 0) - 5) < tolerance)
        #expect(abs((after.geometry.totalRowLengthMetres ?? 0) - 62_500) < tolerance)
        #expect(abs(after.totalCarrierLitres - 12_500) < tolerance)
        #expect(abs((after.productLines[0].totalQuantity ?? 0) - 40) < tolerance)
        #expect(abs((after.productLines[1].totalQuantity ?? 0) - 10) < tolerance)
    }

    @Test("Mixed row spacings refuse a uniform spacing rather than averaging")
    func mixedSpacingsRefuseUniformSpacing() {
        var inputs = completeInputs()
        inputs.blocks = [block(rowSpacing: 3.2), block(id: "block-b", rowSpacing: 2.5)]

        let plan = SprayGuidedFlow(inputs: inputs).plan
        #expect(plan.geometry.uniformRowSpacingMetres == nil)
        // Row length still totals, because both blocks resolved individually.
        #expect(abs((plan.geometry.totalRowLengthMetres ?? 0) - 62_500) < tolerance)
    }

    // MARK: - 11. Changing band width recalculates treated area + products

    @Test("Changing band width recalculates treated area and treated-area products")
    func changingBandWidthRecalculates() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.products = [
            product("Herbicide", .treatedArea, rate: 2),
            product("Kelp", .wholeBlockArea, rate: 2)
        ]

        inputs.bandWidthTotalMetres = 0.8
        let narrow = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs((narrow.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        #expect(abs((narrow.productLines[0].totalQuantity ?? 0) - 5) < tolerance)

        // Widen the band: 31,250 × 1.6 ÷ 10,000 = 5.0 ha treated.
        inputs.bandWidthTotalMetres = 1.6
        let wide = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs((wide.treatedAreaHectares ?? 0) - 5.0) < tolerance)
        #expect(abs((wide.productLines[0].totalQuantity ?? 0) - 10) < tolerance)
        // The whole-block product is unaffected by band width.
        #expect(abs((wide.productLines[1].totalQuantity ?? 0) - 20) < tolerance)
        // Gross never moves.
        #expect(abs(wide.grossAreaHectares - 10) < tolerance)
    }

    @Test("Banded without a band width: target step blocks and treated area stays nil")
    func bandedWithoutBandWidthBlocks() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.bandWidthTotalMetres = nil

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.blocker(for: .target) == .bandWidthRequired)
        #expect(flow.plan.treatedAreaHectares == nil)
        #expect(!flow.isUnlocked(.growthStage))
        #expect(flow.snapshot == nil)
    }

    @Test("A treated-area product with no band width is unresolved, never silently zero")
    func treatedAreaProductWithoutBandWidthIsUnresolved() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.bandWidthTotalMetres = nil
        inputs.products = [product("Herbicide", .treatedArea, rate: 2)]

        let plan = SprayGuidedFlow(inputs: inputs).plan
        #expect(plan.productLines[0].totalQuantity == nil)
        #expect(plan.productLines[0].isUnresolved)
    }

    // MARK: - 12. Changing applied L/100 m recalculates carrier + /100 L products

    @Test("Changing applied L/100 m recalculates carrier, concentration and /100 L dose")
    func changingAppliedLitresPer100MetresRecalculates() {
        var inputs = completeInputs()
        inputs.carrierBasis = .litresPer100Metres
        inputs.litresPerHectare = nil
        inputs.diluteLitresPer100Metres = 40
        inputs.products = [product("Adjuvant", .per100Litres, rate: 100, unit: "mL")]

        inputs.appliedLitresPer100Metres = 20
        let concentrated = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs(concentrated.totalCarrierLitres - 6_250) < tolerance)
        #expect(abs(concentrated.concentrationFactor - 2.0) < tolerance)
        #expect(abs((concentrated.carrier.litresPerHectare ?? 0) - 625) < tolerance)
        #expect(abs((concentrated.productLines[0].totalQuantity ?? 0) - 12_500) < tolerance)

        // Spray dilute instead: same water as the reference rate.
        inputs.appliedLitresPer100Metres = 40
        let dilute = SprayGuidedFlow(inputs: inputs).plan
        #expect(abs(dilute.totalCarrierLitres - 12_500) < tolerance)
        #expect(abs(dilute.concentrationFactor - 1.0) < tolerance)
        #expect(abs((dilute.carrier.litresPerHectare ?? 0) - 1_250) < tolerance)
        // Twice the water, no concentration → same dilute-equivalent dose.
        #expect(abs((dilute.productLines[0].totalQuantity ?? 0) - 12_500) < tolerance)
    }

    // MARK: - 13. Saved snapshot == displayed Review calculation

    @Test("The persisted snapshot is a projection of the plan the Review step displays")
    func snapshotMatchesReviewCalculation() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.carrierBasis = .litresPer100Metres
        inputs.litresPerHectare = nil
        inputs.diluteLitresPer100Metres = 40
        inputs.appliedLitresPer100Metres = 20
        inputs.products = [
            product("Kelp", .wholeBlockArea, rate: 2),
            product("Herbicide", .treatedArea, rate: 2)
        ]

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isComplete)

        // What Review displays.
        let plan = flow.plan
        // What gets written.
        let snapshot = flow.snapshot
        #expect(snapshot != nil)
        guard let snapshot else { return }

        #expect(abs((snapshot.grossAreaHa ?? 0) - plan.grossAreaHectares) < tolerance)
        #expect(abs((snapshot.treatedAreaHa ?? 0) - (plan.treatedAreaHectares ?? 0)) < tolerance)
        #expect(snapshot.applicationMode == plan.mode)
        #expect(snapshot.treatedAreaMethod == plan.treatedArea.method)
        #expect(abs((snapshot.bandWidthTotalMetres ?? 0) - 0.8) < tolerance)
        #expect(
            abs((snapshot.canonicalRowLengthMetres ?? 0) - (plan.geometry.totalRowLengthMetres ?? 0))
                < tolerance
        )
        #expect(abs((snapshot.rowSpacingMetres ?? 0) - 3.2) < tolerance)
        #expect(snapshot.geometrySource == plan.geometry.source)
        #expect(snapshot.geometryQuality == plan.geometry.quality)
        #expect(snapshot.carrierVolumeBasis == plan.carrier.basis)
        #expect(abs((snapshot.totalCarrierLitres ?? 0) - plan.totalCarrierLitres) < tolerance)
        #expect(
            abs((snapshot.carrierLitresPerHectare ?? 0) - (plan.carrier.litresPerHectare ?? 0))
                < tolerance
        )
        #expect(abs((snapshot.diluteLitresPer100m ?? 0) - 40) < tolerance)
        #expect(abs((snapshot.appliedLitresPer100m ?? 0) - 20) < tolerance)
        #expect(abs((snapshot.concentrationFactor ?? 0) - plan.concentrationFactor) < tolerance)
        #expect(snapshot.hasGenuineTreatedArea)
    }

    // MARK: - Progressive disclosure gating

    @Test("Steps unlock strictly in order as each decision is made")
    func stepsUnlockInOrder() {
        var inputs = SprayGuidedInputs()

        // Nothing entered: only Application is open.
        var flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.activeStep == .blocks) // application needs no input
        #expect(flow.isUnlocked(.blocks))
        #expect(!flow.isUnlocked(.target))
        #expect(flow.blocker(for: .blocks) == .noBlocksSelected)

        // Blocks selected → Target opens.
        inputs.blocks = [block()]
        flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isUnlocked(.target))
        #expect(!flow.isUnlocked(.growthStage))
        #expect(flow.blocker(for: .target) == .noTargetSelected)

        // Target needs the head target too for a foliar spray.
        inputs.targets = [.powderyMildew]
        flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.blocker(for: .target) == .sprayHeadTargetRequired)
        #expect(!flow.isUnlocked(.growthStage))

        inputs.sprayHeadTarget = .fullCanopy
        flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isUnlocked(.growthStage))
        #expect(!flow.isUnlocked(.equipment))

        inputs.isGrowthStageResolved = true
        flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isUnlocked(.equipment))
        #expect(!flow.isUnlocked(.carrier))

        inputs.isEquipmentSelected = true
        flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isUnlocked(.carrier))
        #expect(!flow.isUnlocked(.products))
        #expect(flow.blocker(for: .carrier) == .carrierRateRequired)

        inputs.litresPerHectare = 625
        inputs.tankCapacityLitres = 2_000
        flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isUnlocked(.products))
        #expect(!flow.isUnlocked(.review))
        #expect(flow.blocker(for: .products) == .noProductsAdded)

        inputs.products = [product("Sulphur", .wholeBlockArea, rate: 2)]
        flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.isUnlocked(.review))
        #expect(flow.isComplete)
        #expect(flow.activeStep == .review)
    }

    @Test("Completed steps behind the active step collapse to summaries")
    func completedStepsCollapse() {
        var inputs = completeInputs()
        inputs.products = []
        let flow = SprayGuidedFlow(inputs: inputs)

        #expect(flow.activeStep == .products)
        #expect(flow.isCollapsible(.application))
        #expect(flow.isCollapsible(.blocks))
        #expect(flow.isCollapsible(.target))
        #expect(flow.isCollapsible(.equipment))
        #expect(flow.isCollapsible(.carrier))
        // The active step itself stays expanded.
        #expect(!flow.isCollapsible(.products))
    }

    @Test("Spreader shows neither a spray head target nor a band width")
    func spreaderSkipsCanopyAndBandQuestions() {
        var inputs = completeInputs(operationType: .spreader)
        inputs.sprayHeadTarget = nil
        inputs.bandWidthTotalMetres = nil

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(!flow.requiresSprayHeadTarget)
        #expect(!flow.requiresBandWidth)
        #expect(!flow.supportsCanopySettings)
        #expect(flow.mode == .wholeBlock)
        // A target is still required, but nothing canopy- or band-specific.
        #expect(flow.blocker(for: .target) == nil)
        #expect(flow.isComplete)
    }

    @Test("Progress fraction reflects completed gated steps")
    func progressFractionTracksCompletion() {
        var empty = SprayGuidedInputs()
        empty.operationType = .foliarSpray
        #expect(SprayGuidedFlow(inputs: empty).progressFraction < 0.3)
        #expect(abs(SprayGuidedFlow(inputs: completeInputs()).progressFraction - 1.0) < tolerance)
    }

    // MARK: - Resistance Check reservation

    @Test("Resistance Check applicability is flagged but ships no rules or warnings")
    func resistanceCheckReservation() {
        var inputs = completeInputs()

        inputs.targets = [.powderyMildew]
        #expect(SprayGuidedFlow(inputs: inputs).isResistanceCheckApplicable)

        inputs.targets = [.downyMildew]
        #expect(SprayGuidedFlow(inputs: inputs).isResistanceCheckApplicable)

        inputs.targets = [.weeds]
        #expect(!SprayGuidedFlow(inputs: inputs).isResistanceCheckApplicable)

        inputs.targets = [.nutritionBiostimulant]
        #expect(!SprayGuidedFlow(inputs: inputs).isResistanceCheckApplicable)
    }

    // MARK: - Stable target identifiers

    @Test("Targets persist as stable identifiers, not display text")
    func targetsUseStableIdentifiers() {
        #expect(SprayTarget.powderyMildew.rawValue == "powdery_mildew")
        #expect(SprayTarget.downyMildew.rawValue == "downy_mildew")
        #expect(SprayTarget.nutritionBiostimulant.rawValue == "nutrition_biostimulant")
        #expect(SprayTarget.from("Powdery Mildew") == .powderyMildew)
        #expect(SprayTarget.from("powdery") == .powderyMildew)
        #expect(SprayTarget.from("unknown-target") == nil)
        #expect(SprayTarget.from(nil) == nil)
        #expect(SprayTarget.presentationOrder.count == SprayTarget.allCases.count)

        #expect(SprayHeadTarget.fullCanopy.rawValue == "full_canopy")
        #expect(SprayHeadTarget.bunchLine.rawValue == "bunch_line")
        #expect(SprayHeadTarget.from("Bunch Line") == .bunchLine)
        #expect(SprayHeadTarget.from("nope") == nil)
    }

    // MARK: - Zero-litre placeholder cannot fabricate a dose

    @Test("Before a carrier exists, treated area previews but /100 L products stay unresolved")
    func placeholderCarrierNeverFabricatesADose() {
        var inputs = completeInputs(operationType: .bandedSpray)
        inputs.litresPerHectare = nil
        inputs.products = [product("Adjuvant", .per100Litres, rate: 100, unit: "mL")]

        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(!flow.isCarrierResolved)

        let plan = flow.plan
        // Treated area does not depend on carrier, so it previews correctly.
        #expect(abs((plan.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        #expect(abs(plan.grossAreaHectares - 10) < tolerance)
        // The per-100 L line is unresolved rather than dosed against zero.
        #expect(plan.productLines[0].totalQuantity == nil)
        #expect(flow.snapshot == nil)
    }
}

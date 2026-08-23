import Foundation
import Testing
@testable import VineTrack

/// The canopy → recommended volume → actual sprayer output → concentration
/// factor decision path.
///
/// Every figure comes from the device acceptance case: S = 2.8 m, R = 1,750 m
/// (so A = 0.49 ha), a canopy recommending 20 L/100 m, and a sprayer calibrated
/// to 600 L/ha.
struct SprayVolumeDecisionTests {

    private let spacing: Double = 2.8
    private let rowLength: Double = 1_750
    /// R × S ÷ 10,000 = 0.49 ha.
    private var areaHectares: Double { rowLength * spacing / 10_000 }

    private var blocks: [SprayBlockInput] {
        [
            SprayBlockInput(
                blockId: "b1",
                grossAreaHectares: areaHectares,
                mappedRowLengthMetres: rowLength,
                rowSpacingMetres: spacing
            )
        ]
    }

    private func isClose(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.000_01) -> Bool {
        guard let lhs, lhs.isFinite else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    /// A canopy that recommends 20 L/100 m: VSP · Medium · High.
    private func canopy(
        type: CanopyType = .vsp,
        size: CanopySize = .medium,
        density: CanopyDensity = .high
    ) -> SprayCanopySelection {
        var selection = SprayCanopySelection.unconfirmed
        selection.choose(type: type)
        selection.choose(size: size)
        selection.choose(density: density)
        return selection
    }

    private func decision(
        canopy: SprayCanopySelection,
        choice: SprayVolumeChoice,
        custom: Double? = nil,
        customBasis: SprayCarrierBasis = .litresPerHectare
    ) -> SprayVolumeDecision {
        SprayVolumeDecisionResolver.decide(
            canopy: canopy,
            settings: .defaults,
            rowSpacingMetres: spacing,
            choice: choice,
            customRate: custom,
            customBasis: customBasis
        )
    }

    private func flow(
        canopy: SprayCanopySelection,
        choice: SprayVolumeChoice,
        custom: Double? = nil,
        products: [SprayProductLineInput] = [],
        basis: SprayCarrierBasis = .litresPerHectare
    ) -> SprayGuidedFlow {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = blocks
        inputs.canopy = canopy
        inputs.canopyWaterRates = .defaults
        inputs.sprayVolumeChoice = choice
        inputs.customSprayerRate = custom
        inputs.customSprayerBasis = basis
        inputs.carrierBasis = basis
        inputs.products = products
        return SprayGuidedFlow(inputs: inputs)
    }

    // MARK: - A. Recommended rate conversion

    @Test("20 L/100 m at 2.8 m spacing recommends 714.2857 L/ha")
    func recommendedConversion() {
        let result = decision(canopy: canopy(), choice: .undecided)
        #expect(result.recommendedLitresPer100Metres == 20)
        #expect(isClose(result.recommendedLitresPerHectare, 714.285714, tolerance: 0.000_1))
    }

    // MARK: - B. Use recommended

    @Test("Use recommended sets actual output to the recommendation, CF 1.00")
    func useRecommended() {
        let result = decision(canopy: canopy(), choice: .useRecommended)
        #expect(isClose(result.actualLitresPerHectare, 714.285714, tolerance: 0.000_1))
        #expect(result.concentrationFactor == 1.0)
        #expect(result.isResolved)
        #expect(!result.isConcentrated)
    }

    // MARK: - C. Custom sprayer output

    @Test("A 600 L/ha sprayer against a 714.2857 recommendation gives CF 1.190476")
    func customSprayerOutput() {
        let result = decision(canopy: canopy(), choice: .useCustomSprayerRate, custom: 600)
        #expect(result.actualLitresPerHectare == 600)
        #expect(isClose(result.concentrationFactor, 1.190_476, tolerance: 0.000_01))
        #expect(result.isConcentrated)
        // The recommendation is NOT overwritten by the operator's figure. Both
        // values survive, which is the whole point of asking separately.
        #expect(isClose(result.recommendedLitresPerHectare, 714.285714, tolerance: 0.000_1))
    }

    // MARK: - D. Actual above recommended

    @Test("Spraying MORE water than recommended holds CF at 1.00")
    func actualAboveRecommended() {
        let result = decision(canopy: canopy(), choice: .useCustomSprayerRate, custom: 800)
        #expect(result.actualLitresPerHectare == 800)
        // 714.2857 ÷ 800 = 0.893. A per-100 L label does not weaken because the
        // vine got wetter than the label assumed, so the floor holds.
        #expect(result.concentrationFactor == 1.0)
    }

    // MARK: - E. Total water

    @Test("Total water is actual L/ha × treated area")
    func totalWater() {
        let recommended = flow(canopy: canopy(), choice: .useRecommended)
        // 714.2857 × 0.49 — and equally 20 L/100 m × 1,750 m ÷ 100.
        #expect(isClose(recommended.plan.carrier.totalLitres, 350, tolerance: 0.000_1))

        let custom = flow(canopy: canopy(), choice: .useCustomSprayerRate, custom: 600)
        #expect(isClose(custom.plan.carrier.totalLitres, 294, tolerance: 0.000_1))
    }

    // MARK: - F. VSP values unchanged

    @Test("Every VSP canopy combination returns its existing rate")
    func vspTableUnchanged() {
        let expected: [CanopySize: (low: Double, high: Double)] = [
            .small: (10, 20),
            .medium: (20, 40),
            .large: (30, 45),
            .full: (45, 75)
        ]
        for (size, rates) in expected {
            #expect(CanopyWaterRate.litresPer100m(type: .vsp, size: size, density: .low) == rates.low)
            #expect(CanopyWaterRate.litresPer100m(type: .vsp, size: size, density: .high) == rates.high)
            // The pre-existing VSP-only entry point still answers identically.
            #expect(CanopyWaterRate.litresPer100m(size: size, density: .low) == rates.low)
            #expect(CanopyWaterRate.litresPer100m(size: size, density: .high) == rates.high)
        }
    }

    // MARK: - G. Sprawl values

    @Test("Every Sprawl canopy combination returns its source-backed rate")
    func sprawlTable() {
        let expected: [CanopySize: (low: Double, high: Double)] = [
            .small: (10, 20),
            .medium: (20, 40),
            .large: (45, 60),
            .full: (60, 90)
        ]
        for (size, rates) in expected {
            #expect(CanopyWaterRate.litresPer100m(type: .sprawl, size: size, density: .low) == rates.low)
            #expect(CanopyWaterRate.litresPer100m(type: .sprawl, size: size, density: .high) == rates.high)
        }
    }

    /// Small and Medium are identical in both systems because neither is
    /// "Wires Up" — before vertical positioning the two canopies are the same
    /// shape. They diverge exactly where the VSP wording starts saying Wires Up.
    @Test("Sprawl matches VSP below wires-up, and exceeds it above")
    func sprawlDivergesOnlyAtWiresUp() {
        for density in CanopyDensity.allCases {
            for size in [CanopySize.small, .medium] {
                #expect(
                    CanopyWaterRate.litresPer100m(type: .sprawl, size: size, density: density)
                        == CanopyWaterRate.litresPer100m(type: .vsp, size: size, density: density)
                )
            }
            for size in [CanopySize.large, .full] {
                #expect(
                    CanopyWaterRate.litresPer100m(type: .sprawl, size: size, density: density)
                        > CanopyWaterRate.litresPer100m(type: .vsp, size: size, density: density)
                )
            }
        }
    }

    // MARK: - H. Canopy type switch

    @Test("Switching VSP to Sprawl recalculates the recommendation")
    func canopyTypeSwitchRecalculates() {
        var selection = canopy(type: .vsp, size: .full, density: .high)
        let vsp = decision(canopy: selection, choice: .useRecommended)
        #expect(vsp.recommendedLitresPer100Metres == 75)

        selection.choose(type: .sprawl)
        let sprawl = decision(canopy: selection, choice: .useRecommended)
        #expect(sprawl.recommendedLitresPer100Metres == 90)
        #expect(isClose(sprawl.recommendedLitresPerHectare, 90 * 100 / 2.8, tolerance: 0.000_1))
    }

    // MARK: - I. Recommended mode tracks canopy changes

    @Test("Under Use recommended, changing canopy moves the actual output too")
    func recommendedTracksCanopy() {
        var selection = canopy(size: .medium, density: .high)
        let before = decision(canopy: selection, choice: .useRecommended)
        #expect(isClose(before.actualLitresPerHectare, 714.285714, tolerance: 0.000_1))

        selection.choose(size: .full)
        let after = decision(canopy: selection, choice: .useRecommended)
        #expect(after.recommendedLitresPer100Metres == 75)
        #expect(isClose(after.actualLitresPerHectare, 75 * 100 / 2.8, tolerance: 0.000_1))
        #expect(after.concentrationFactor == 1.0)
    }

    // MARK: - J. Custom mode survives canopy changes

    @Test("A custom 600 L/ha survives a canopy change, and CF recalculates")
    func customSurvivesCanopyChange() {
        var selection = canopy(size: .medium, density: .high)
        let before = decision(canopy: selection, choice: .useCustomSprayerRate, custom: 600)
        #expect(isClose(before.concentrationFactor, 1.190_476, tolerance: 0.000_01))

        selection.choose(size: .full)
        let after = decision(canopy: selection, choice: .useCustomSprayerRate, custom: 600)
        // The operator's figure is untouched...
        #expect(after.actualLitresPerHectare == 600)
        // ...and only the comparison against it moved. 75 × 100 ÷ 2.8 = 2678.57.
        #expect(isClose(after.recommendedLitresPerHectare, 2_678.571_4, tolerance: 0.001))
        #expect(isClose(after.concentrationFactor, 2_678.571_4 / 600, tolerance: 0.001))
    }

    // MARK: - K, L, M. Product bases

    private func per100LProduct(rate: Double = 150) -> SprayProductLineInput {
        SprayProductLineInput(
            productId: "per100L",
            name: "DITHANE",
            unit: "Kg",
            basis: .per100Litres,
            rate: rate,
            labelRate: SprayLabelRateDescriptor(value: rate, unit: "g", basis: .per100Litres),
            unitDisplay: SprayProductUnitDisplay(displayUnit: "Kg", baseUnitsPerDisplayUnit: 1000)
        )
    }

    private func perHaProduct(rate: Double = 2000) -> SprayProductLineInput {
        SprayProductLineInput(
            productId: "perHa",
            name: "PER HA PRODUCT",
            unit: "L",
            basis: .wholeBlockArea,
            rate: rate,
            labelRate: SprayLabelRateDescriptor(value: 2, unit: "L", basis: .wholeBlockArea),
            unitDisplay: SprayProductUnitDisplay(displayUnit: "L", baseUnitsPerDisplayUnit: 1000)
        )
    }

    /// The invariant that matters: concentrating the water does not change how
    /// much chemical reaches the vine.
    @Test("A per-100 L product applies CF, preserving the dilute-equivalent dose")
    func per100LUsesConcentrationFactor() {
        let dilute = flow(
            canopy: canopy(),
            choice: .useRecommended,
            products: [per100LProduct()]
        )
        // 150 g/100 L × 350 L ÷ 100 × 1.00
        #expect(isClose(dilute.plan.productLines[0].totalQuantity, 525, tolerance: 0.000_1))

        let concentrated = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 600,
            products: [per100LProduct()]
        )
        // 150 × 294 ÷ 100 × 1.190476 — the SAME 525 g, carried in less water.
        #expect(isClose(concentrated.plan.productLines[0].totalQuantity, 525, tolerance: 0.001))
    }

    @Test("A per-hectare product is untouched by water volume or CF")
    func perHaIgnoresConcentration() {
        let recommended = flow(
            canopy: canopy(),
            choice: .useRecommended,
            products: [perHaProduct()]
        )
        let concentrated = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 600,
            products: [perHaProduct()]
        )
        // 2 L/ha × 0.49 ha = 0.98 L, both times.
        #expect(isClose(recommended.plan.productLines[0].totalQuantity, 980, tolerance: 0.000_1))
        #expect(isClose(concentrated.plan.productLines[0].totalQuantity, 980, tolerance: 0.000_1))
        #expect(concentrated.plan.carrier.concentrationFactor > 1.0)
    }

    @Test("A mixed tank calculates both bases from one sprayer output")
    func mixedBases() {
        let mixed = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 600,
            products: [per100LProduct(), perHaProduct()]
        )
        let lines = mixed.plan.productLines
        #expect(lines.count == 2)
        #expect(isClose(lines[0].totalQuantity, 525, tolerance: 0.001))
        #expect(isClose(lines[1].totalQuantity, 980, tolerance: 0.000_1))
    }

    // MARK: - N. Calculation reference

    @Test("The Calculation Reference reports the planner's own operands")
    func calculationReferenceMatchesEngine() throws {
        let built = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 600,
            products: [per100LProduct(), perHaProduct()]
        )
        let reference = SprayCalculationReferenceBuilder.make(flow: built)

        #expect(reference.canopy.first { $0.id == "canopyType" }?.value == "VSP")
        #expect(reference.canopy.first { $0.id == "recommendedPer100m" }?.value == "20 L/100 m")
        #expect(reference.canopy.first { $0.id == "rowSpacing" }?.value == "2.8 m")

        let perArea = try #require(reference.canopy.first { $0.id == "recommendedPerHa" })
        #expect(perArea.value == "714.3 L/ha")
        #expect(perArea.workings == "20 L/100 m × 100 ÷ 2.8 m")

        let cf = try #require(reference.volume.first { $0.id == "concentrationFactor" })
        #expect(cf.value == "1.19×")
        #expect(cf.workings == "max(1.00, 714.3 ÷ 600.0)")
        #expect(reference.volume.first { $0.id == "actualOutput" }?.value == "600.0 L/ha")

        // The per-100 L product shows the concentrated tank strength...
        let dithane = try #require(reference.products.first { $0.name == "DITHANE" })
        #expect(dithane.lines.first { $0.id == "labelRate" }?.value == "150 g/100 L")
        #expect(dithane.lines.first { $0.id == "tankConcentration" }?.value == "178.57 g/100 L")
        // ...and the per-ha product explicitly says CF does not apply to it.
        let perHa = try #require(reference.products.first { $0.name == "PER HA PRODUCT" })
        #expect(perHa.lines.first { $0.id == "cfNotApplied" }?.value == "Not applied")
    }

    // MARK: - O. No hidden defaults

    @Test("A new session confirms nothing on the operator's behalf")
    func noHiddenDefaults() {
        let fresh = SprayCanopySelection.unconfirmed
        // No training system — the question every canopy control used to answer
        // silently by being headed "VSP".
        #expect(fresh.type == nil)
        #expect(!fresh.isConfirmed)
        #expect(!fresh.isSizeAndDensityConfirmed)
        #expect(fresh.litresPer100m() == 0)

        let built = flow(canopy: fresh, choice: .undecided)
        #expect(built.isCanopyOutstanding)
        #expect(built.isCanopyTypeOutstanding)
        #expect(built.blocker(for: .carrier) == .canopyConfirmationRequired)
        #expect(!built.isUnlocked(.products))

        // Choosing a type alone is not a confirmed canopy.
        var typedOnly = SprayCanopySelection.unconfirmed
        typedOnly.choose(type: .sprawl)
        #expect(!typedOnly.isConfirmed)

        // And with the canopy answered, the sprayer question is still open.
        let answered = flow(canopy: canopy(), choice: .undecided)
        #expect(answered.isSprayVolumeChoiceOutstanding)
        #expect(answered.blocker(for: .carrier) == .sprayVolumeChoiceRequired)
        #expect(!answered.isUnlocked(.products))
    }

    /// A stored canopy came from the VSP control and produced a VSP rate, so it
    /// decodes as VSP. That is reproducing the past, not assuming the future.
    @Test("A legacy stored canopy reads back as the VSP canopy it was")
    func legacyCanopyDecodesAsVSP() throws {
        let json = Data(#"{"size":"Large","density":"High"}"#.utf8)
        let decoded = try JSONDecoder().decode(SprayCanopySelection.self, from: json)
        #expect(decoded.type == .vsp)
        #expect(decoded.size == .large)
        #expect(decoded.density == .high)
        #expect(decoded.isConfirmed)
        #expect(decoded.litresPer100m() == 45)
    }

    // MARK: - AWRI matrices, derived at 2.8 m

    /// The AWRI L/100 m table is the ONLY lookup. Every hectare figure below is
    /// derived from this vineyard's own 2.8 m spacing, not read from the
    /// diagram's printed L/ha ranges — those assume roughly 3 m rows and are
    /// rounded, so at 2.8 m they would carry the wrong water.
    @Test("VSP: every combination derives the expected L/ha at 2.8 m")
    func vspDerivedHectareMatrix() {
        let expected: [(CanopySize, CanopyDensity, Double, Double)] = [
            (.small, .low, 10, 357.142857),
            (.small, .high, 20, 714.285714),
            (.medium, .low, 20, 714.285714),
            (.medium, .high, 40, 1_428.571429),
            (.large, .low, 30, 1_071.428571),
            (.large, .high, 45, 1_607.142857),
            (.full, .low, 45, 1_607.142857),
            (.full, .high, 75, 2_678.571429)
        ]
        for (size, density, per100m, perHa) in expected {
            let result = decision(
                canopy: canopy(type: .vsp, size: size, density: density),
                choice: .useRecommended
            )
            #expect(result.recommendedLitresPer100Metres == per100m)
            #expect(isClose(result.recommendedLitresPerHectare, perHa, tolerance: 0.000_1))
        }
    }

    @Test("Sprawl: every combination derives the expected L/ha at 2.8 m")
    func sprawlDerivedHectareMatrix() {
        let expected: [(CanopySize, CanopyDensity, Double, Double)] = [
            (.small, .low, 10, 357.142857),
            (.small, .high, 20, 714.285714),
            (.medium, .low, 20, 714.285714),
            (.medium, .high, 40, 1_428.571429),
            (.large, .low, 45, 1_607.142857),
            (.large, .high, 60, 2_142.857143),
            (.full, .low, 60, 2_142.857143),
            (.full, .high, 90, 3_214.285714)
        ]
        for (size, density, per100m, perHa) in expected {
            let result = decision(
                canopy: canopy(type: .sprawl, size: size, density: density),
                choice: .useRecommended
            )
            #expect(result.recommendedLitresPer100Metres == per100m)
            #expect(isClose(result.recommendedLitresPerHectare, perHa, tolerance: 0.000_1))
        }
    }

    /// A second, spacing-independent lookup would show the same L/ha at every
    /// row spacing. Changing the spacing must change the answer.
    @Test("No printed L/ha table drives the calculation")
    func hectareFiguresAreDerivedNotLookedUp() {
        let at2point8 = SprayVolumeDecisionResolver.decide(
            canopy: canopy(),
            settings: .defaults,
            rowSpacingMetres: 2.8,
            choice: .useRecommended,
            customRate: nil,
            customBasis: .litresPerHectare
        )
        let at3 = SprayVolumeDecisionResolver.decide(
            canopy: canopy(),
            settings: .defaults,
            rowSpacingMetres: 3.0,
            choice: .useRecommended,
            customRate: nil,
            customBasis: .litresPerHectare
        )
        // Same canopy, same 20 L/100 m — different vineyards.
        #expect(at2point8.recommendedLitresPer100Metres == at3.recommendedLitresPer100Metres)
        #expect(isClose(at2point8.recommendedLitresPerHectare, 714.285714, tolerance: 0.000_1))
        #expect(isClose(at3.recommendedLitresPerHectare, 666.666667, tolerance: 0.000_1))
    }

    // MARK: - Test case 2. Canopy type reaches the water-rate engine

    @Test("VSP Large Low → Sprawl Large Low changes the recommendation")
    func canopyTypeReachesTheEngine() {
        var selection = canopy(type: .vsp, size: .large, density: .low)
        let vsp = decision(canopy: selection, choice: .useRecommended)
        #expect(vsp.recommendedLitresPer100Metres == 30)
        #expect(isClose(vsp.recommendedLitresPerHectare, 1_071.428571, tolerance: 0.000_1))

        // ONLY the training system changes.
        selection.choose(type: .sprawl)
        let sprawl = decision(canopy: selection, choice: .useRecommended)
        #expect(sprawl.recommendedLitresPer100Metres == 45)
        #expect(isClose(sprawl.recommendedLitresPerHectare, 1_607.142857, tolerance: 0.000_1))

        #expect(CanopyWaterRate.litresPer100m(type: .vsp, size: .full, density: .high) == 75)
        #expect(CanopyWaterRate.litresPer100m(type: .sprawl, size: .full, density: .high) == 90)
    }

    // MARK: - Test case 1. The false "Enter carrier volume" blocker

    /// The TestFlight defect: the calculation accepted 600 L/ha and rendered
    /// CF 1.19×, while validation still demanded a carrier volume and kept
    /// Products locked — because it fell through to the legacy
    /// `litresPerHectare` field the new path never fills.
    @Test("A custom sprayer rate resolves Step 6 and unlocks Products")
    func customRateResolvesStepSix() throws {
        let built = flow(canopy: canopy(), choice: .useCustomSprayerRate, custom: 600)
        let decided = try #require(built.volumeDecision)

        #expect(decided.actualLitresPerHectare == 600)
        #expect(isClose(decided.actualLitresPer100Metres, 16.8, tolerance: 0.000_1))
        #expect(isClose(decided.concentrationFactor, 1.190_476, tolerance: 0.000_01))
        #expect(decided.isResolved)

        // The step is DONE, with no lingering carrier prompt...
        #expect(built.blocker(for: .carrier) == nil)
        #expect(built.isComplete(.carrier))
        // ...and the legacy fields are still empty, proving the fix is not a
        // quiet copy of the value into a second home.
        #expect(built.inputs.litresPerHectare == nil)
        #expect(built.inputs.appliedLitresPer100Metres == nil)
        // Products unlock.
        #expect(built.isUnlocked(.products))
        #expect(built.blocker(for: .products) == .noProductsAdded)
    }

    /// 600 L/ha and 16.8 L/100 m at 2.8 m are the SAME sprayer output, so
    /// entering either must produce the same job.
    @Test("The sprayer output is one value, expressible in either basis")
    func sprayerOutputIsOneValue() throws {
        let perHa = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 600,
            basis: .litresPerHectare
        )
        let per100m = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 16.8,
            basis: .litresPer100Metres
        )
        let a = try #require(perHa.volumeDecision)
        let b = try #require(per100m.volumeDecision)

        #expect(isClose(a.actualLitresPer100Metres, 16.8, tolerance: 0.000_1))
        #expect(isClose(b.actualLitresPerHectare, 600, tolerance: 0.000_1))
        #expect(isClose(a.concentrationFactor, b.concentrationFactor, tolerance: 0.000_001))
        #expect(isClose(
            perHa.plan.carrier.totalLitres,
            per100m.plan.carrier.totalLitres,
            tolerance: 0.01
        ))
        #expect(perHa.isComplete(.carrier))
        #expect(per100m.isComplete(.carrier))
    }

    /// Non-canopy flows still genuinely need the explicit carrier fields, and
    /// must keep asking for them.
    @Test("A non-canopy flow still requires its explicit carrier volume")
    func nonCanopyFlowsStillRequireCarrier() {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .spreader
        inputs.blocks = blocks
        inputs.carrierBasis = .litresPerHectare
        #expect(SprayGuidedFlow(inputs: inputs).blocker(for: .carrier) == .carrierRateRequired)
    }

    // MARK: - Section navigation

    /// Completion and expansion are separate concerns. The flow reports what is
    /// complete and what is unlocked; it deliberately has no say in which
    /// section is on screen, which is what stopped the calculator collapsing a
    /// section under the operator the instant they finished answering it.
    @Test("Completing a step unlocks the next without demanding focus")
    func completionDoesNotMoveTheOperator() {
        let built = flow(canopy: canopy(), choice: .useCustomSprayerRate, custom: 600)
        #expect(built.isComplete(.carrier))
        #expect(built.isUnlocked(.products))
        // `activeStep` still reports the next outstanding step — it is advice
        // for the initial seed, and the view no longer follows it on every
        // change.
        #expect(built.activeStep == .products)
        #expect(!built.isComplete)
    }

    /// Existing users have a persisted settings blob with the eight VSP keys and
    /// none of the Sprawl ones. A throw here would take their ENTIRE settings
    /// record, not just the canopy table.
    @Test("A settings blob without Sprawl keys still decodes")
    func legacySettingsDecode() throws {
        let json = Data("""
        {"smallLow":10,"smallHigh":20,"mediumLow":20,"mediumHigh":40,
         "largeLow":30,"largeHigh":45,"fullLow":45,"fullHigh":75}
        """.utf8)
        let decoded = try JSONDecoder().decode(CanopyWaterRateEntry.self, from: json)
        #expect(decoded.largeHigh == 45)
        #expect(decoded.sprawlLargeLow == 45)
        #expect(decoded.sprawlFullHigh == 90)
    }

    // MARK: - P. One definition of the arithmetic

    @Test("The decision, the carrier and the shared conversion agree on CF")
    func oneConcentrationDefinition() throws {
        let built = flow(canopy: canopy(), choice: .useCustomSprayerRate, custom: 600)
        let decided = try #require(built.volumeDecision)
        let shared = SprayCarrierConversion.concentrationFactor(
            dilute: decided.recommendedLitresPerHectare,
            actual: decided.actualLitresPerHectare
        )
        #expect(built.plan.carrier.concentrationFactor == decided.concentrationFactor)
        #expect(decided.concentrationFactor == shared)
    }

    /// Both carrier bases read the same decision, so they cannot report
    /// different concentrations for one job.
    @Test("Both carrier bases produce the same concentration factor")
    func bothBasesAgree() {
        let perHa = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 600,
            basis: .litresPerHectare
        )
        let per100m = flow(
            canopy: canopy(),
            choice: .useCustomSprayerRate,
            custom: 600,
            basis: .litresPer100Metres
        )
        #expect(isClose(
            perHa.plan.carrier.concentrationFactor,
            per100m.plan.carrier.concentrationFactor,
            tolerance: 0.000_001
        ))
        #expect(isClose(perHa.plan.carrier.totalLitres, 294, tolerance: 0.000_1))
        #expect(isClose(per100m.plan.carrier.totalLitres, 294, tolerance: 0.001))
    }

    // MARK: - Step naming and order

    @Test("Canopy & Spray Volume is step 6, before Products")
    func stepNamingAndOrder() {
        #expect(SprayGuidedStep.carrier.title == "Canopy & Spray Volume")
        #expect(SprayGuidedStep.carrier < SprayGuidedStep.products)
        #expect(SprayGuidedStep.allCases.firstIndex(of: .carrier) == 5)
        #expect(SprayGuidedStep.allCases.firstIndex(of: .products) == 6)
    }

    /// Only two answers, and neither is a default.
    @Test("The spray volume question has exactly two answers plus undecided")
    func choiceVocabulary() {
        #expect(SprayVolumeChoice.allCases.count == 3)
        #expect(SprayVolumeChoice.allCases.contains(.undecided))
        #expect(SprayVolumeChoice.allCases.contains(.useRecommended))
        #expect(SprayVolumeChoice.allCases.contains(.useCustomSprayerRate))
    }

    /// Opening the custom field is not the same as answering it.
    @Test("Custom mode with an empty field is not resolved")
    func emptyCustomIsNotAnAnswer() {
        let result = decision(canopy: canopy(), choice: .useCustomSprayerRate, custom: nil)
        #expect(!result.isResolved)
        #expect(result.actualLitresPerHectare == nil)
        #expect(result.concentrationFactor == 1.0)
    }

    /// Only a foliar pass is gated: a spreader has no canopy and a banded pass
    /// is governed by its band width.
    @Test("Only foliar sprays are gated on the canopy decision")
    func onlyFoliarIsGated() {
        for type in [OperationType.spreader, .bandedSpray] {
            var inputs = SprayGuidedInputs()
            inputs.operationType = type
            inputs.blocks = blocks
            inputs.canopy = .unconfirmed
            #expect(!SprayGuidedFlow(inputs: inputs).requiresCanopyConfirmation)
        }
    }
}

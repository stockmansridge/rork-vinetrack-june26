import Foundation
import Testing
@testable import VineTrack

/// Manual spray volume — the third path, and the one that must ask the fewest
/// questions.
///
/// # What this path is for
///
/// A knapsack, a hand-gun or a small tank job has no calibrated output per
/// hectare and no meaningful row length. It has a drum with a known number of
/// litres in it. Before this path existed the operator had to reverse-engineer
/// their 400 L into an L/ha or L/100 m figure through a canopy model, which
/// meant VineTrack derived a total the operator already knew exactly — and
/// blocked them for row spacing they had no use for while doing it.
///
/// # The two failure modes these tests exist to prevent
///
/// 1. **Manual quietly acquiring the canopy path's requirements.** Any blocker,
///    any required canopy confirmation, any dependence on row spacing or row
///    length defeats the entire point. The tests assert manual resolves with no
///    geometry whatsoever.
/// 2. **Manual presenting derived numbers as though they were inputs.** The
///    implied L/ha is arithmetic on the operator's own total, not a calibration.
///    A concentration factor of 1.0 is a placeholder, not a finding. Both must
///    be labelled as such, because a per-hectare figure that looks calculated is
///    a figure someone will plan a future job from.
struct SprayManualVolumeTests {

    private let tolerance = 0.0001

    /// The shared worked example: 10 ha gross, 31,250 m of row, 3.2 m spacing.
    private func block() -> SprayBlockInput {
        SprayBlockInput(
            blockId: "block-a",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
    }

    /// A manual job. `blocks` is deliberately variable — the headline claim is
    /// that manual works with none.
    private func inputs(
        totalLitres: Double?,
        blocks: [SprayBlockInput] = [],
        products: [SprayProductLineInput] = []
    ) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = blocks
        inputs.targets = [.powderyMildew]
        inputs.sprayHeadTarget = .fullCanopy
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .manualTotalVolume
        inputs.manualTotalLitres = totalLitres
        inputs.products = products
        return inputs
    }

    // MARK: - Manual resolves on its own

    /// The headline contract. No blocks, no canopy, no row spacing, no row
    /// length — and a fully resolved carrier volume.
    @Test("Manual resolves the carrier from the total alone, with no geometry")
    func manualResolvesWithoutGeometry() {
        let flow = SprayGuidedFlow(inputs: inputs(totalLitres: 400))

        #expect(flow.isCarrierResolved)
        let carrier = try? #require(flow.carrier)
        #expect(carrier?.basis == .manualTotalVolume)
        #expect(abs((carrier?.totalLitres ?? 0) - 400) < tolerance)
        // Nothing to derive them FROM, and nothing that needed them.
        #expect(carrier?.litresPerHectare == nil)
        #expect(carrier?.appliedLitresPer100Metres == nil)
        #expect(carrier?.rowSpacingMetres == nil)
    }

    /// A part-typed figure must never be read as a volume, and zero is not a
    /// job. Both leave the carrier unresolved rather than producing a 0 L plan.
    @Test("A missing or zero total leaves the carrier unresolved")
    func manualRejectsNonPositiveTotals() {
        #expect(SprayGuidedFlow(inputs: inputs(totalLitres: nil)).carrier == nil)
        #expect(SprayGuidedFlow(inputs: inputs(totalLitres: 0)).carrier == nil)
        #expect(SprayGuidedFlow(inputs: inputs(totalLitres: -5)).carrier == nil)
    }

    /// Geometry, when it exists, is reference only. It must not move the total
    /// the operator typed by even a litre.
    @Test("Geometry adds reference figures without altering the stated total")
    func manualDerivesReferenceFiguresOnly() {
        let flow = SprayGuidedFlow(inputs: inputs(totalLitres: 400, blocks: [block()]))
        let carrier = try? #require(flow.carrier)

        #expect(abs((carrier?.totalLitres ?? 0) - 400) < tolerance)
        // 400 L ÷ 10 ha
        #expect(abs((carrier?.litresPerHectare ?? 0) - 40) < tolerance)
        // 400 L ÷ 31,250 m × 100
        #expect(abs((carrier?.appliedLitresPer100Metres ?? 0) - 1.28) < tolerance)
    }

    // MARK: - Manual asks no canopy questions

    /// Manual is a deliberate bypass of the canopy model. Requiring a canopy
    /// confirmation would demand three answers that cannot change a single
    /// number on the job.
    @Test("Manual never requires canopy confirmation, even for a foliar spray")
    func manualSkipsCanopyConfirmation() {
        let manual = SprayGuidedFlow(inputs: inputs(totalLitres: 400, blocks: [block()]))
        #expect(manual.requiresCanopyConfirmation == false)

        // Same job, calibrated path — the canopy requirement is still in force,
        // so the exemption is manual's and not a blanket regression.
        var calibrated = inputs(totalLitres: nil, blocks: [block()])
        calibrated.carrierBasis = .litresPer100Metres
        calibrated.appliedLitresPer100Metres = 30
        #expect(SprayGuidedFlow(inputs: calibrated).requiresCanopyConfirmation)
    }

    /// A canopy left over from a previous basis must not leak a recommendation —
    /// or worse, a concentration factor — into a manual job.
    @Test("A stale confirmed canopy produces no volume decision in manual")
    func manualIgnoresStaleCanopy() {
        var stale = inputs(totalLitres: 400, blocks: [block()])
        stale.isCanopyConfirmed = true
        stale.canopy = SprayCanopySelection()
        stale.sprayVolumeChoice = .useRecommended

        let flow = SprayGuidedFlow(inputs: stale)
        #expect(flow.volumeDecision == nil)
        #expect(abs((flow.carrier?.totalLitres ?? 0) - 400) < tolerance)
    }

    /// 1.0 is the arithmetic identity the tank maths needs, not a claim that a
    /// comparison was run and came back neutral.
    @Test("Manual carries CF 1.0 and reports it as no canopy comparison")
    func manualHasNoCanopyConcentration() {
        let carrier = try? #require(SprayGuidedFlow(inputs: inputs(totalLitres: 400)).carrier)

        #expect(abs((carrier?.concentrationFactor ?? 0) - 1.0) < tolerance)
        #expect(carrier?.hasCanopyConcentration == false)
        // Dilute-equivalent collapses to the stated total: a per-100 L label
        // rate is dosed against the drum, which is what the operator expects.
        #expect(abs((carrier?.diluteEquivalentLitres ?? 0) - 400) < tolerance)
    }

    // MARK: - Blockers

    /// Manual has exactly ONE requirement. If it ever gains a second, this
    /// fails — which is the point.
    @Test("Manual blocks only on the missing total, and clears once entered")
    func manualBlocksOnlyOnTotal() {
        let empty = SprayGuidedFlow(inputs: inputs(totalLitres: nil, blocks: [block()]))
        #expect(empty.blocker(for: .carrier) == .manualTotalWaterRequired)

        let filled = SprayGuidedFlow(inputs: inputs(totalLitres: 400, blocks: [block()]))
        #expect(filled.blocker(for: .carrier) == nil)
    }

    /// The regression that would hurt most: a hand-spray blocked for row
    /// spacing it does not use.
    @Test("Manual does not block on absent row geometry")
    func manualDoesNotBlockOnGeometry() {
        let flow = SprayGuidedFlow(inputs: inputs(totalLitres: 400))
        #expect(flow.blocker(for: .carrier) == nil)
    }

    // MARK: - Profile policy

    /// An SWNZ vineyard is locked to L/100 m for its CALIBRATED workflow. That
    /// lock says nothing about a grower hand-spraying a few vines, and must not
    /// silently redirect them back into the canopy path.
    @Test("A locked NZ/SWNZ profile still permits manual")
    func lockedProfileAllowsManual() {
        let profile = SprayVineyardProfile(countryCode: "NZ")
        #expect(profile.resolvedPolicy == .litresPer100MetresOnly)
        #expect(profile.allows(.manualTotalVolume))
        // The lock itself is intact.
        #expect(profile.allows(.litresPerHectare) == false)

        let flow = SprayGuidedFlow(
            inputs: inputs(totalLitres: 400, blocks: [block()]),
            profile: profile
        )
        #expect(flow.effectiveCarrierBasis == .manualTotalVolume)
        #expect(abs((flow.carrier?.totalLitres ?? 0) - 400) < tolerance)
    }

    // MARK: - Calculation reference honesty

    /// The reference panel explains how a number was reached. In manual the
    /// total is the INPUT, so it must not be shown as the product of a rate and
    /// an area — that derivation runs the other way and never happened.
    @Test("Total water is reported as entered, not as rate × area")
    func referenceReportsTotalAsEntered() {
        let flow = SprayGuidedFlow(inputs: inputs(totalLitres: 400, blocks: [block()]))
        let reference = SprayCalculationReference.make(flow: flow)

        let total = try? #require(reference.water.first { $0.id == "totalWater" })
        #expect(total?.value == "400 L")
        #expect(total?.workings?.contains("Entered directly") == true)
        #expect(total?.workings?.contains("L/ha ×") == false)

        // The implied rate appears, but labelled as reference and derived FROM
        // the total rather than the other way round.
        let implied = try? #require(reference.water.first { $0.id == "impliedPerHa" })
        #expect(implied?.value == "40.0 L/ha")
        #expect(implied?.workings?.contains("400 L ÷") == true)
        #expect(implied?.workings?.contains("for reference only") == true)
    }

    /// No canopy was chosen, so the canopy and sprayer-selection sections must
    /// be empty rather than showing defaults nobody picked.
    @Test("Manual contributes no canopy or sprayer-selection reference lines")
    func referenceOmitsCanopySections() {
        let flow = SprayGuidedFlow(inputs: inputs(totalLitres: 400, blocks: [block()]))
        let reference = SprayCalculationReference.make(flow: flow)

        #expect(reference.canopy.isEmpty)
        #expect(reference.volume.isEmpty)
    }

    /// A per-100 L product is dosed against the stated total, and the panel
    /// says the concentration factor was not used rather than printing "1.00×"
    /// as though a canopy comparison had been made.
    @Test("A per-100 L product doses against the total with CF reported unused")
    func referenceReportsConcentrationNotUsed() {
        let product = SprayProductLineInput(
            productId: "fungicide",
            name: "Fungicide",
            unit: "mL",
            basis: .per100Litres,
            rate: 150
        )
        let flow = SprayGuidedFlow(
            inputs: inputs(totalLitres: 400, blocks: [block()], products: [product])
        )
        let reference = SprayCalculationReference.make(flow: flow)
        let productReference = try? #require(reference.products.first)

        let cf = try? #require(productReference?.lines.first { $0.id == "cf" })
        #expect(cf?.value == "Not used")
        #expect(cf?.workings?.contains("canopy recommendation") == true)

        // No inflated "tank concentration" line, because there is no
        // concentration to present.
        #expect(productReference?.lines.contains { $0.id == "tankConcentration" } == false)

        // The dose is measured against the operator's own 400 L.
        let carrier = try? #require(productReference?.lines.first { $0.id == "carrier" })
        #expect(carrier?.value == "400 L")
    }

    // MARK: - Switching away

    /// Manual must not be sticky. Switching back to a calibrated basis restores
    /// the canopy requirement in full.
    @Test("Switching off manual restores the calibrated path's requirements")
    func switchingAwayRestoresCanopyPath() {
        var switched = inputs(totalLitres: 400, blocks: [block()])
        switched.carrierBasis = .litresPer100Metres
        switched.appliedLitresPer100Metres = nil

        let flow = SprayGuidedFlow(inputs: switched)
        #expect(flow.requiresCanopyConfirmation)
        // The stale manual total is not smuggled into the calibrated carrier.
        #expect(flow.carrier == nil)
        #expect(flow.blocker(for: .carrier) != nil)
        #expect(flow.blocker(for: .carrier) != .manualTotalWaterRequired)
    }
}

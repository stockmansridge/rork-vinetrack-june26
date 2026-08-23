import Foundation
import Testing
@testable import VineTrack

/// The canopy model must drive the dilute / runoff reference in BOTH carrier
/// bases.
///
/// # The defect these tests pin down
///
/// The canopy size / density table has always existed, but it was wired only
/// into the L/ha carrier screen. A vineyard on the row-length workflow — every
/// NZ/SWNZ grower, who is *locked* to L/100 m by their profile — never saw a
/// canopy control at all. `diluteLitresPer100Metres` therefore stayed `nil`,
/// the concentration factor fell back to 1.0, and a genuine 1.5× concentrate
/// pass dosed its per-100 L products as though it were spraying to full runoff.
///
/// That is a systematic under-dose on exactly the workflow the profile makes
/// mandatory, and nothing on screen said so: the number the operator was
/// missing was the one the app already knew.
///
/// These assert the ENGINE contract the screen now feeds. The view's routing
/// (canopy → dilute, operator override wins) is asserted through the same
/// values the view is forced to hand the flow.
struct SprayCanopyCarrierRoutingTests {

    private let tolerance = 0.0001

    /// The worked example shared with `SprayGuidedFlowTests`: 10 ha gross,
    /// 31,250 m of row, 3.2 m spacing.
    private func block() -> SprayBlockInput {
        SprayBlockInput(
            blockId: "block-a",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
    }

    /// A complete row-length job. `dilute` is what the canopy (or the
    /// operator's override) supplies; `applied` is what actually goes on.
    private func inputs(
        dilute: Double?,
        applied: Double? = 30,
        operationType: OperationType = .foliarSpray,
        products: [SprayProductLineInput] = []
    ) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = operationType
        inputs.blocks = [block()]
        inputs.targets = [.powderyMildew]
        inputs.sprayHeadTarget = operationType == .foliarSpray ? .fullCanopy : nil
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .litresPer100Metres
        inputs.appliedLitresPer100Metres = applied
        inputs.diluteLitresPer100Metres = dilute
        inputs.products = products
        return inputs
    }

    private func per100LitreProduct(rate: Double) -> SprayProductLineInput {
        SprayProductLineInput(
            productId: "fungicide",
            name: "Fungicide",
            unit: "mL",
            basis: .per100Litres,
            rate: rate
        )
    }

    // MARK: - The canopy table is already a per-100 m table

    /// The canopy answer needs no row spacing, which is precisely why it can
    /// drive the row-length workflow. The L/ha figure is the *derived* one.
    @Test("Canopy rate is per-100 m and independent of row spacing")
    func canopyRateIsRowSpacingIndependent() {
        let full = CanopyWaterRate.litresPer100m(size: .full, density: .low)
        #expect(full == 45)

        // Same canopy, two different vineyards: the per-100 m answer does not
        // move, so a block with no spacing recorded still has a dilute rate.
        let wide = CanopyWaterRate.rate(size: .full, density: .low, rowSpacingMetres: 3.2)
        let narrow = CanopyWaterRate.rate(size: .full, density: .low, rowSpacingMetres: 2.0)
        #expect(wide.litresPer100m == narrow.litresPer100m)
        #expect(wide.litresPerHa != narrow.litresPerHa)
    }

    /// Every canopy/density combination yields a usable dilute reference, so
    /// routing the canopy into L/100 m can never produce a zero rate.
    @Test("Every canopy combination supplies a positive dilute reference")
    func everyCanopyCombinationIsUsable() {
        for size in CanopySize.allCases {
            for density in CanopyDensity.allCases {
                let rate = CanopyWaterRate.litresPer100m(size: size, density: density)
                #expect(rate > 0, "\(size) / \(density) produced \(rate)")
            }
        }
    }

    // MARK: - Canopy-derived dilute reaches the concentration factor

    /// THE regression. A full canopy wets out at 45 L/100 m; applying 30 is a
    /// 1.5× concentrate, and the engine must say so.
    @Test("Canopy dilute drives the concentration factor on the L/100 m path")
    func canopyDiluteProducesConcentrationFactor() {
        let flow = SprayGuidedFlow(inputs: inputs(dilute: 45, applied: 30))
        let carrier = flow.plan.carrier

        #expect(carrier.basis == .litresPer100Metres)
        #expect(abs(carrier.concentrationFactor - 1.5) < tolerance)
        #expect(carrier.diluteLitresPer100Metres == 45)
        // 31,250 m ÷ 100 × 30 L
        #expect(abs(carrier.totalLitres - 9_375) < tolerance)
        // Derived from spacing, never entered: 30 × 100 ÷ 3.2
        #expect(abs((carrier.litresPerHectare ?? 0) - 937.5) < tolerance)
    }

    /// The behaviour BEFORE this change, preserved as the contrast case: with
    /// no dilute reference the same job silently reports itself as dilute.
    @Test("Without a dilute reference the factor collapses to 1.0")
    func missingDiluteUnderstatesConcentration() {
        let flow = SprayGuidedFlow(inputs: inputs(dilute: nil, applied: 30))
        #expect(flow.plan.carrier.concentrationFactor == 1.0)
    }

    /// The consequence that actually reaches the tank: the same product, the
    /// same carrier, dosed 1.5× differently depending on whether the canopy
    /// was routed through. This is the under-dose the defect caused.
    @Test("Canopy dilute changes the per-100 L product dose")
    func canopyDiluteChangesProductQuantity() {
        let product = per100LitreProduct(rate: 100)

        let withCanopy = SprayGuidedFlow(
            inputs: inputs(dilute: 45, applied: 30, products: [product])
        ).plan
        let withoutCanopy = SprayGuidedFlow(
            inputs: inputs(dilute: nil, applied: 30, products: [product])
        ).plan

        let dosed = withCanopy.productLines.first?.totalQuantity ?? 0
        let underDosed = withoutCanopy.productLines.first?.totalQuantity ?? 0

        // 100 mL/100 L × 9,375 L ÷ 100 × 1.5
        #expect(abs(dosed - 14_062.5) < tolerance)
        #expect(abs(underDosed - 9_375) < tolerance)
        #expect(abs(dosed / underDosed - 1.5) < tolerance)
    }

    // MARK: - The operator still owns the number

    /// An override is a different number, not a different mechanism: it lands
    /// on the same input the canopy would have filled.
    @Test("An operator override replaces the canopy figure")
    func operatorOverrideWins() {
        let overridden = SprayGuidedFlow(inputs: inputs(dilute: 60, applied: 30))
        #expect(abs(overridden.plan.carrier.concentrationFactor - 2.0) < tolerance)
        #expect(overridden.plan.carrier.diluteLitresPer100Metres == 60)
    }

    /// Concentrating means applying LESS than runoff. A dilute reference below
    /// the applied rate is not a negative concentration, and must never scale a
    /// per-100 L dose downwards.
    @Test("A dilute below the applied rate floors the factor at 1.0")
    func factorNeverReducesADose() {
        let flow = SprayGuidedFlow(inputs: inputs(dilute: 20, applied: 40))
        #expect(flow.plan.carrier.concentrationFactor == 1.0)
    }

    // MARK: - Spreader has no canopy

    /// A granular pass is not a concentration of anything. The screen supplies
    /// no canopy dilute for it, and the engine must then report a plain 1.0
    /// rather than scaling a dose against a canopy that was never sprayed.
    @Test("Spreader carries no canopy-derived concentration")
    func spreaderHasNoConcentration() {
        let flow = SprayGuidedFlow(
            inputs: inputs(dilute: nil, applied: 30, operationType: .spreader)
        )
        #expect(flow.plan.carrier.concentrationFactor == 1.0)
    }

    // MARK: - Parity with the hectare path

    /// Both bases must reach the same factor from the same canopy, otherwise
    /// the profile an operator happens to be on changes the chemistry.
    @Test("Both carrier bases derive the same factor from one canopy")
    func bothBasesAgreeOnConcentration() {
        // Full / low canopy = 45 L/100 m, which over 3.2 m spacing is the
        // 1,406.25 L/ha the hectare screen shows.
        let canopyPer100m = CanopyWaterRate.litresPer100m(size: .full, density: .low)
        let canopyPerHa = CanopyWaterRate.litresPerHa(
            litresPer100m: canopyPer100m,
            rowSpacingMetres: 3.2
        )

        let rowLength = SprayGuidedFlow(inputs: inputs(dilute: canopyPer100m, applied: 30))

        var hectareInputs = inputs(dilute: nil, applied: nil)
        hectareInputs.carrierBasis = .litresPerHectare
        hectareInputs.diluteLitresPerHectare = canopyPerHa
        // 30 L/100 m over 3.2 m spacing is 937.5 L/ha — the same job.
        hectareInputs.litresPerHectare = 937.5
        let hectare = SprayGuidedFlow(inputs: hectareInputs)

        #expect(
            abs(rowLength.plan.carrier.concentrationFactor
                - hectare.plan.carrier.concentrationFactor) < tolerance
        )
    }
}

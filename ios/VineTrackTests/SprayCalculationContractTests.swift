import Foundation
import Testing
@testable import VineTrack

/// The one calculation contract, pinned.
///
/// Every number here comes from the device regression: S = 2.8 m, R = 1,750 m,
/// A = 0.49 ha, dilute 10 L/100 m, applied 20 L/100 m, carrier 351 L, Dithane
/// at 150–200 g/100 L. They are asserted as arithmetic rather than as screen
/// text so a future refactor of the UI cannot quietly move them.
struct SprayCalculationContractTests {

    private let spacing: Double = 2.8
    private let rowLength: Double = 1_750
    /// R × S ÷ 10,000 — the hectares those 1,750 m of row actually cover.
    private var areaHectares: Double { rowLength * spacing / 10_000 }

    private var geometry: SprayApplicationGeometry {
        SprayApplicationGeometry(
            grossAreaHectares: areaHectares,
            totalRowLengthMetres: rowLength,
            uniformRowSpacingMetres: spacing,
            source: .mappedRows,
            unresolvedBlocks: []
        )
    }

    private func isClose(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
        guard let lhs, lhs.isFinite else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    // MARK: - C. Geometry / carrier conversions

    @Test("10 L/100 m at 2.8 m spacing is 357.142857 L/ha")
    func diluteConvertsToHectares() {
        #expect(isClose(
            SprayCarrierConversion.litresPerHectare(litresPer100Metres: 10, rowSpacingMetres: spacing),
            357.142857
        ))
    }

    @Test("20 L/100 m at 2.8 m spacing is 714.285714 L/ha")
    func appliedConvertsToHectares() {
        #expect(isClose(
            SprayCarrierConversion.litresPerHectare(litresPer100Metres: 20, rowSpacingMetres: spacing),
            714.285714
        ))
    }

    @Test("20 L/100 m over 1,750 m is 350 L")
    func rowModeTotalCarrier() {
        #expect(SprayCarrierConversion.totalLitres(
            appliedLitresPer100Metres: 20,
            rowLengthMetres: rowLength
        ) == 350)
    }

    /// The two bases describe one application, so they must agree on the water.
    @Test("The hectare path reaches the same total carrier")
    func hectarePathAgrees() throws {
        let perHa = try #require(SprayCarrierConversion.litresPerHectare(
            litresPer100Metres: 20,
            rowSpacingMetres: spacing
        ))
        let total = try #require(SprayCarrierConversion.totalLitres(
            appliedLitresPerHectare: perHa,
            areaHectares: areaHectares
        ))
        #expect(abs(total - 350) < 0.000_001)
    }

    @Test("The conversions are exact inverses")
    func conversionsRoundTrip() {
        let toHa = SprayCarrierConversion.litresPerHectare(
            litresPer100Metres: 37.5,
            rowSpacingMetres: spacing
        )
        #expect(isClose(
            SprayCarrierConversion.litresPer100Metres(
                litresPerHectare: toHa ?? 0,
                rowSpacingMetres: spacing
            ),
            37.5
        ))
        #expect(isClose(
            SprayCarrierConversion.rowMetresPerHectare(rowSpacingMetres: spacing),
            10_000 / 2.8
        ))
    }

    /// A spacing VineTrack had to guess would silently scale every hectare
    /// figure on the job, so an unknown spacing yields nothing.
    @Test("An unknown row spacing converts to nothing, never to a default")
    func unknownSpacingRefusesToConvert() {
        #expect(SprayCarrierConversion.litresPerHectare(litresPer100Metres: 10, rowSpacingMetres: nil) == nil)
        #expect(SprayCarrierConversion.litresPerHectare(litresPer100Metres: 10, rowSpacingMetres: 0) == nil)
        #expect(SprayCarrierConversion.rowMetresPerHectare(rowSpacingMetres: nil) == nil)
    }

    // MARK: - D. One canopy answer, two ways of writing it

    @Test("The same canopy states the same dilute demand in either basis")
    func canopyIsOneRequirement() throws {
        var canopy = SprayCanopySelection.unconfirmed
        canopy.choose(size: .small)
        canopy.choose(density: .low)
        let per100m = canopy.litresPer100m()
        #expect(per100m == 10)

        let rowCarrier = try #require(SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: per100m,
            geometry: geometry
        ))
        let perHaDilute = try #require(SprayCarrierConversion.litresPerHectare(
            litresPer100Metres: per100m,
            rowSpacingMetres: spacing
        ))
        let hectareCarrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 714.285714,
            areaHectares: areaHectares,
            concentrationFactor: SprayCarrierConversion.concentrationFactor(
                dilute: perHaDilute,
                actual: 714.285714
            ),
            diluteLitresPerHectare: perHaDilute,
            rowSpacingMetres: spacing
        )

        // Both carriers now report the canopy in BOTH units, and agree.
        #expect(isClose(rowCarrier.diluteLitresPer100Metres, 10))
        #expect(isClose(rowCarrier.diluteLitresPerHectare, 357.142857))
        #expect(isClose(hectareCarrier.diluteLitresPer100Metres, 10, tolerance: 0.000_01))
        #expect(isClose(hectareCarrier.diluteLitresPerHectare, 357.142857))
    }

    // MARK: - E. One concentration definition

    /// The device defect: dilute 357 vs actual 714 read as CF 0.50 on the L/ha
    /// screen, while dilute 10 vs actual 20 read as CF 1.00 on the L/100 m
    /// screen. Same relationship, two answers.
    @Test("Both branches give the same concentration factor for the same job")
    func concentrationIsIdenticalInBothBranches() throws {
        let rowCarrier = try #require(SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: 10,
            geometry: geometry
        ))
        let hectareCarrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 714.285714,
            areaHectares: areaHectares,
            concentrationFactor: SprayCarrierConversion.concentrationFactor(
                dilute: 357.142857,
                actual: 714.285714
            ),
            diluteLitresPerHectare: 357.142857,
            rowSpacingMetres: spacing
        )
        #expect(rowCarrier.concentrationFactor == 1.0)
        #expect(hectareCarrier.concentrationFactor == 1.0)
        #expect(rowCarrier.concentrationFactor == hectareCarrier.concentrationFactor)
    }

    @Test("CF = max(1.0, dilute / actual)")
    func concentrationRule() {
        #expect(SprayCarrierConversion.concentrationFactor(dilute: 50, actual: 50) == 1.0)
        #expect(SprayCarrierConversion.concentrationFactor(dilute: 50, actual: 25) == 2.0)
        // The floor. Not 0.5 — a per-100 L label does not weaken because the
        // vine got wetter than the label assumed.
        #expect(SprayCarrierConversion.concentrationFactor(dilute: 10, actual: 20) == 1.0)
        #expect(SprayCarrierConversion.concentrationFactor(dilute: nil, actual: 20) == 1.0)
        #expect(SprayCarrierConversion.concentrationFactor(dilute: 50, actual: nil) == 1.0)
        #expect(SprayCarrierConversion.concentrationFactor(dilute: 50, actual: 0) == 1.0)
    }

    // MARK: - F. Per-100 L product dosing

    private func per100LContext(carrierLitres: Double, factor: Double = 1.0) -> SprayQuantityContext {
        SprayQuantityContext(
            grossAreaHectares: areaHectares,
            carrierLitres: carrierLitres,
            concentrationFactor: factor
        )
    }

    @Test("150 g/100 L against 351 L is 526.5 g")
    func dithaneMinimum() {
        #expect(SprayProductQuantityCalculator.totalQuantity(
            rate: 150,
            basis: .per100Litres,
            context: per100LContext(carrierLitres: 351)
        ) == 526.5)
    }

    @Test("175 g/100 L against 351 L is 614.25 g")
    func dithaneMidpoint() {
        #expect(SprayProductQuantityCalculator.totalQuantity(
            rate: 175,
            basis: .per100Litres,
            context: per100LContext(carrierLitres: 351)
        ) == 614.25)
    }

    @Test("200 g/100 L against 351 L is 702 g")
    func dithaneMaximum() {
        #expect(SprayProductQuantityCalculator.totalQuantity(
            rate: 200,
            basis: .per100Litres,
            context: per100LContext(carrierLitres: 351)
        ) == 702)
    }

    // MARK: - G. The concentrate invariant

    /// Concentrating the carrier must not change how much chemical goes on the
    /// vine. If this ever fails, a concentrate spray is being under- or
    /// over-dosed, which is the failure mode with real consequences.
    @Test("Concentrating the carrier leaves the chemical amount unchanged")
    func concentrateInvariant() {
        // Dilute: 50 L/100 m, CF 1.0.
        let dilute = SprayProductQuantityCalculator.totalQuantity(
            rate: 200,
            basis: .per100Litres,
            context: SprayQuantityContext(
                grossAreaHectares: 1,
                carrierLitres: 50,
                concentrationFactor: 1.0
            )
        )
        // Concentrated 2×: 25 L/100 m, CF 2.0.
        let concentrated = SprayProductQuantityCalculator.totalQuantity(
            rate: 200,
            basis: .per100Litres,
            context: SprayQuantityContext(
                grossAreaHectares: 1,
                carrierLitres: 25,
                concentrationFactor: 2.0
            )
        )
        #expect(dilute == 100)
        #expect(concentrated == 100)
        #expect(dilute == concentrated)
    }

    // MARK: - H. Genuine per-hectare rates

    @Test("A genuine per-hectare product ignores carrier volume entirely")
    func perHectareIgnoresCarrier() {
        let rate = 2.0
        let quantities = [0.0, 351, 10_000].map { litres in
            SprayProductQuantityCalculator.totalQuantity(
                rate: rate,
                basis: .wholeBlockArea,
                context: SprayQuantityContext(
                    grossAreaHectares: 10,
                    carrierLitres: litres,
                    concentrationFactor: 3.0
                )
            )
        }
        // 2 × 10 ha, whatever the water is doing.
        #expect(quantities.allSatisfy { $0 == 20 })
    }

    // MARK: - I. Derived per-hectare equivalent

    private func dithaneLine(
        totalQuantity: Double?,
        labelValue: Double = 150
    ) -> SprayProductLineResult {
        SprayProductLineResult(
            productId: "dithane",
            name: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
            unit: "Kg",
            basis: .per100Litres,
            rate: labelValue,
            totalQuantity: totalQuantity,
            quantityPerFullTank: nil,
            quantityInLastTank: nil,
            costPerUnit: nil,
            basisInput: 351,
            labelRate: SprayLabelRateDescriptor(
                value: labelValue,
                unit: "g",
                basis: .per100Litres
            ),
            unitDisplay: SprayProductUnitDisplay(displayUnit: "Kg", baseUnitsPerDisplayUnit: 1000),
            grossAreaHectares: 0.49
        )
    }

    @Test("The per-hectare equivalent is derived, and labelled as derived")
    func derivedPerHectareIsMarked() throws {
        let line = dithaneLine(totalQuantity: 526.5)
        let perHectare = try #require(line.derivedQuantityPerHectare)
        #expect(abs(perHectare - 1_074.489_795) < 0.001)

        let text = try #require(SprayGuidedFormat.productDerivedPerHectare(line))
        #expect(text == "Derived equivalent: 1.07 Kg/ha")
        // The wording carries the qualifier itself, so a layout change cannot
        // drop a caption and leave a derived figure reading as authority.
        #expect(text.hasPrefix("Derived"))
        #expect(!text.contains("Registered"))
        // And the authority on screen is still the label's own rate.
        #expect(SprayGuidedFormat.productRate(line) == "150 g/100 L")
    }

    // MARK: - J. Label unit vs stock unit

    /// The exact device defect: `150 g/100 L` rendering as `150 Kg/100 L`.
    @Test("The label rate is never formatted with the stock unit")
    func labelRateKeepsItsOwnUnit() {
        let line = dithaneLine(totalQuantity: 526.5)
        #expect(SprayGuidedFormat.productRate(line) == "150 g/100 L")
        #expect(SprayGuidedFormat.productRate(line) != "150 Kg/100 L")
        #expect(line.labelRate?.unit == "g")
        // The stock unit is still there — it is simply not the label's unit.
        #expect(line.unit == "Kg")
        #expect(line.unitDisplay.displayUnit == "Kg")
    }

    @Test("526.5 g of a Kg-stocked product displays as 0.53 Kg")
    func totalConvertsToTheStockUnit() {
        let line = dithaneLine(totalQuantity: 526.5)
        #expect(line.unitDisplay.display(526.5) == 0.5265)
        #expect(SprayGuidedFormat.productQuantity(526.5, line: line) == "0.53 Kg")
        #expect(SprayGuidedFormat.productRequirement(line) == "0.53 Kg required")
        // Never the raw base number wearing the stock unit's name.
        #expect(SprayGuidedFormat.productRequirement(line) != "526.5 Kg required")
    }

    @Test("The full calculation line states label rate × carrier, correctly")
    func calculationLineIsCoherent() throws {
        let line = dithaneLine(totalQuantity: 526.5)
        let calculation = try #require(SprayGuidedFormat.productCalculation(line))
        #expect(calculation == "150 g/100 L × 351 L carrier")
    }

    @Test("A product stocked in grams needs no conversion")
    func gramStockedProductIsUnconverted() {
        let display = SprayProductUnitDisplay(displayUnit: "g", baseUnitsPerDisplayUnit: 1)
        #expect(display.display(526.5) == 526.5)
        #expect(SprayProductUnitDisplay.base("g").baseUnitsPerDisplayUnit == 1)
    }

    // MARK: - Products and Review read one plan

    @Test("Review and Products read the same plan, not two calculations")
    func onePlanForBothSteps() {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.isCanopyConfirmed = true
        inputs.carrierBasis = .litresPer100Metres
        inputs.blocks = [
            SprayBlockInput(
                blockId: "b1",
                grossAreaHectares: areaHectares,
                mappedRowLengthMetres: rowLength,
                rowSpacingMetres: spacing
            )
        ]
        inputs.diluteLitresPer100Metres = 10
        inputs.appliedLitresPer100Metres = 20
        inputs.products = [
            SprayProductLineInput(
                productId: "dithane",
                name: "DITHANE",
                unit: "Kg",
                basis: .per100Litres,
                rate: 150,
                labelRate: SprayLabelRateDescriptor(value: 150, unit: "g", basis: .per100Litres),
                unitDisplay: SprayProductUnitDisplay(displayUnit: "Kg", baseUnitsPerDisplayUnit: 1000)
            )
        ]
        let flow = SprayGuidedFlow(inputs: inputs)

        // The Products step and the Review step both read `flow.plan`. Same
        // inputs, same plan, every time it is evaluated.
        #expect(flow.plan.productLines == flow.plan.productLines)
        #expect(flow.plan.carrier.totalLitres == 350)

        let line = flow.plan.productLines[0]
        // 150 × 350 / 100 × 1.0
        #expect(line.totalQuantity == 525)
        #expect(SprayGuidedFormat.productRate(line) == "150 g/100 L")
        #expect(SprayGuidedFormat.productRequirement(line) == "0.53 Kg required")
    }

    @Test("Several products stay independently calculable")
    func multipleProductsCoexist() {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.isCanopyConfirmed = true
        inputs.carrierBasis = .litresPer100Metres
        inputs.blocks = [
            SprayBlockInput(
                blockId: "b1",
                grossAreaHectares: areaHectares,
                mappedRowLengthMetres: rowLength,
                rowSpacingMetres: spacing
            )
        ]
        inputs.diluteLitresPer100Metres = 10
        inputs.appliedLitresPer100Metres = 20
        inputs.products = [
            SprayProductLineInput(
                productId: "a",
                name: "PER 100 L PRODUCT",
                unit: "Kg",
                basis: .per100Litres,
                rate: 150,
                unitDisplay: SprayProductUnitDisplay(displayUnit: "Kg", baseUnitsPerDisplayUnit: 1000)
            ),
            SprayProductLineInput(
                productId: "b",
                name: "PER HA PRODUCT",
                unit: "L",
                basis: .wholeBlockArea,
                rate: 2000,
                unitDisplay: SprayProductUnitDisplay(displayUnit: "L", baseUnitsPerDisplayUnit: 1000)
            )
        ]
        let lines = SprayGuidedFlow(inputs: inputs).plan.productLines
        #expect(lines.count == 2)
        #expect(lines[0].totalQuantity == 525)
        // 2 L/ha × 0.49 ha, untouched by the 350 L of carrier beside it.
        #expect(abs((lines[1].totalQuantity ?? 0) - 980) < 0.000_001)
    }

    // MARK: - P9 / P10 surfaces unchanged

    /// The snapshot layer reads these carrier fields. They are additive-only in
    /// this pass: nothing existing was renamed, removed or re-meaning-ed.
    @Test("The carrier fields P10 snapshots read are unchanged")
    func snapshotSurfaceIsIntact() throws {
        let carrier = try #require(SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: 10,
            geometry: geometry
        ))
        #expect(carrier.basis == .litresPer100Metres)
        #expect(carrier.totalLitres == 350)
        #expect(carrier.appliedLitresPer100Metres == 20)
        #expect(carrier.diluteLitresPer100Metres == 10)
        #expect(carrier.concentrationFactor == 1.0)
        #expect(carrier.rowLengthMetres == rowLength)
        #expect(carrier.rowSpacingMetres == spacing)
        #expect(carrier.diluteEquivalentLitres == 350)
    }
}

/// A Program Step names the product. It does not set today's dose.
struct SprayProgramStepRateRemovalTests {

    private func chemical(unit: ChemicalUnit = .kilograms) -> SavedChemical {
        SavedChemical(
            vineyardId: UUID(),
            name: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
            unit: unit,
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "DOWNY MILDEW",
                    rates: [ChemicalLabelRate(basis: .per100Litres, value: 200, unit: "g")]
                )
            ])
        )
    }

    @Test("Choosing a product on a new step writes no rate at all")
    func newStepWritesNoRate() {
        var draft = SprayProgramProductDraft(basis: .per100Litres)
        // The editor passes no seed: the dose belongs to the spray, not the
        // programme, and a rate written months early is the one least likely to
        // be re-read.
        draft.replaceProduct(with: chemical(), seedRate: nil)

        #expect(draft.savedChemicalId != nil)
        #expect(draft.name == "DITHANE RAINSHIELD NEO TEC FUNGICIDE")
        // Not an artificial zero standing in for a decision — simply no rate.
        #expect(draft.rate == 0)
        #expect(draft.baseRate == 0)
    }

    /// Backward compatibility: a template or portal row that genuinely carries
    /// a rate keeps it, and keeps reporting it.
    @Test("An existing stored rate still reads back")
    func legacyRatesStillDecode() {
        var draft = SprayProgramProductDraft(
            name: "LEGACY PRODUCT",
            rate: 2,
            unit: .litres,
            basis: .wholeBlockArea
        )
        #expect(draft.rate == 2)
        #expect(draft.baseRate == 2000)

        // Restated in the new product's unit rather than silently changing
        // meaning from 2 L to 2 kg.
        draft.replaceProduct(with: chemical(), seedRate: nil)
        #expect(draft.unit == .kilograms)
        #expect(draft.baseRate == 2000)
    }

    /// Plan Spray reads TODAY's Chemical Store, so a label corrected since the
    /// programme was written is the label the operator is offered.
    @Test("Plan Spray re-resolves rates from the current Chemical Store")
    func planSprayReResolvesRates() throws {
        let product = chemical()
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: product, carrier: .litresPer100Metres)
        )
        // Resolved from the product record at plan time — not from anything a
        // Program Step froze.
        #expect(selection.seed.seedableValue == 200)
        #expect(selection.labelUnit == "g")
        #expect(selection.basis == .per100Litres)
    }
}

import Foundation
import Testing
@testable import VineTrack

/// Two device decisions, both about refusing to answer a question on the
/// operator's behalf.
///
/// **The canopy.** `canopySize = .medium` and `canopyDensity = .low` were plain
/// Swift defaults. A segmented picker always shows a selection, so the carrier
/// step counted as complete without anyone looking at it — and a canopy nobody
/// chose set the dilute rate, which set the concentration factor, which
/// multiplied every per-100 L product in the tank.
///
/// **The label band.** `150–200 g/100 L` was displayed and then the operator
/// was left to work out a number and type it before anything calculated at all.
/// The band is the regulator's; the point inside it is the operator's; the
/// arithmetic between them is VineTrack's job and it was not doing it.
struct SprayCanopyAndRatePresetTests {

    // MARK: - Fixtures

    private static let vineyardId = UUID()

    /// Dithane: stocked in Kg, label band written in grams per 100 L.
    private func rangeProduct(
        minimum: Double = 150,
        maximum: Double = 200,
        unit: String = "g",
        basis: ChemicalLabelRateBasis = .rangePer100Litres
    ) -> SavedChemical {
        SavedChemical(
            vineyardId: Self.vineyardId,
            name: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
            unit: .kilograms,
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "DOWNY MILDEW",
                    rates: [
                        ChemicalLabelRate(
                            basis: basis,
                            minValue: minimum,
                            maxValue: maximum,
                            unit: unit
                        )
                    ]
                )
            ])
        )
    }

    private func fixedRateProduct() -> SavedChemical {
        SavedChemical(
            vineyardId: Self.vineyardId,
            name: "FIXED RATE FUNGICIDE",
            unit: .kilograms,
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "POWDERY MILDEW",
                    rates: [ChemicalLabelRate(basis: .per100Litres, value: 200, unit: "g")]
                )
            ])
        )
    }

    /// A label that prints DIFFERENT bands against named conditions. The
    /// operator chooses by reading the condition, not by picking a midpoint.
    private func namedConditionProduct() -> SavedChemical {
        SavedChemical(
            vineyardId: Self.vineyardId,
            name: "PRESSURE BANDED FUNGICIDE",
            unit: .kilograms,
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "BOTRYTIS",
                    rates: [
                        ChemicalLabelRate(
                            label: "Low disease pressure",
                            basis: .rangePer100Litres,
                            minValue: 150,
                            maxValue: 200,
                            unit: "g"
                        ),
                        ChemicalLabelRate(
                            label: "High disease pressure",
                            basis: .rangePer100Litres,
                            minValue: 200,
                            maxValue: 250,
                            unit: "g"
                        )
                    ]
                )
            ])
        )
    }

    private func foliarInputs(canopyConfirmed: Bool) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.isCanopyConfirmed = canopyConfirmed
        inputs.carrierBasis = .litresPer100Metres
        inputs.blocks = [
            SprayBlockInput(
                blockId: "b1",
                grossAreaHectares: 10,
                mappedRowLengthMetres: 25_000,
                rowSpacingMetres: 3
            )
        ]
        inputs.diluteLitresPer100Metres = 45
        inputs.appliedLitresPer100Metres = 30
        return inputs
    }

    // MARK: - 1, 2. Canopy is a required step, and it comes before Products

    @Test("A foliar spray will not complete the carrier step on an unconfirmed canopy")
    func foliarRequiresCanopyConfirmation() {
        let flow = SprayGuidedFlow(inputs: foliarInputs(canopyConfirmed: false))
        #expect(flow.requiresCanopyConfirmation)
        #expect(flow.isCanopyOutstanding)
        #expect(flow.blocker(for: .carrier) == .canopyConfirmationRequired)
        #expect(!flow.isComplete(.carrier))
        // The exact words the operator sees.
        #expect(SprayGuidedBlocker.canopyConfirmationRequired.title
            == "Select canopy size and density")
    }

    /// The canopy is asked BEFORE the volume, because the volume is derived
    /// from it. Naming the second question first hides the first.
    @Test("The canopy blocker outranks the carrier-volume blocker")
    func canopyIsReportedBeforeVolume() {
        var inputs = foliarInputs(canopyConfirmed: false)
        inputs.appliedLitresPer100Metres = nil
        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.blocker(for: .carrier) == .canopyConfirmationRequired)
    }

    @Test("Confirming the canopy completes the step and unlocks Products")
    func confirmationCompletesTheStep() {
        let flow = SprayGuidedFlow(inputs: foliarInputs(canopyConfirmed: true))
        #expect(!flow.isCanopyOutstanding)
        #expect(flow.blocker(for: .carrier) == nil)
        #expect(flow.isComplete(.carrier))
    }

    @Test("Canopy & Carrier is step 6, before Products")
    func canopyStepPrecedesProducts() {
        #expect(SprayGuidedStep.carrier < SprayGuidedStep.products)
        #expect(SprayGuidedStep.allCases.firstIndex(of: .carrier) == 5)
        #expect(SprayGuidedStep.allCases.firstIndex(of: .products) == 6)
        #expect(SprayGuidedStep.carrier.title == "Canopy & Carrier")
        // Products is structurally unreachable while the canopy is outstanding.
        let flow = SprayGuidedFlow(inputs: foliarInputs(canopyConfirmed: false))
        #expect(!flow.isUnlocked(.products))
        #expect(!flow.isUnlocked(.review))
        #expect(!flow.isComplete)
    }

    /// A spreader has no canopy and a banded pass is governed by its band
    /// width. A prompt raised where it cannot change the arithmetic is a prompt
    /// operators learn to dismiss.
    @Test("Only a foliar spray is gated on the canopy")
    func onlyFoliarIsGated() {
        for type in [OperationType.spreader, .bandedSpray] {
            var inputs = foliarInputs(canopyConfirmed: false)
            inputs.operationType = type
            #expect(!SprayGuidedFlow(inputs: inputs).requiresCanopyConfirmation)
        }
    }

    // MARK: - 3, 4, 5. The existing canopy model is reused, not replaced

    @Test("All four canopy sizes and both densities exist")
    func canopyVocabularyIsIntact() {
        #expect(CanopySize.allCases == [.small, .medium, .large, .full])
        #expect(CanopyDensity.allCases == [.low, .high])
    }

    @Test("Every canopy size keeps its reference image")
    func canopyImageryIsIntact() {
        for size in CanopySize.allCases {
            #expect(size.referenceImageURL != nil, "\(size.rawValue) lost its reference image")
            #expect(!size.description.isEmpty)
        }
    }

    /// One canopy model. The selection reads the SAME `CanopyWaterRate` table
    /// both carrier bases already use.
    @Test("The selection resolves through the existing CanopyWaterRate table")
    func selectionUsesTheExistingTable() {
        var selection = SprayCanopySelection.unconfirmed
        selection.choose(size: .full)
        selection.choose(density: .high)
        #expect(selection.litresPer100m() == CanopyWaterRate.litresPer100m(size: .full, density: .high))
        #expect(selection.litresPer100m() == 75)
    }

    // MARK: - 2 (defaults). Medium / Low is a starting position, not an answer

    @Test("The opening position is unconfirmed")
    func defaultsAreNotAnAnswer() {
        let selection = SprayCanopySelection.unconfirmed
        #expect(selection.size == .medium)
        #expect(selection.density == .low)
        #expect(!selection.isConfirmed)
    }

    @Test("Touching either picker confirms the canopy")
    func touchingAPickerConfirms() {
        var bySize = SprayCanopySelection.unconfirmed
        bySize.choose(size: .large)
        #expect(bySize.isConfirmed)

        var byDensity = SprayCanopySelection.unconfirmed
        byDensity.choose(density: .high)
        #expect(byDensity.isConfirmed)
    }

    /// The operator whose canopy really IS Medium / Low needs a way to say so
    /// without changing a picker and changing it back.
    @Test("Confirming the shown values counts, and changes nothing else")
    func confirmingUnchangedValuesCounts() {
        var selection = SprayCanopySelection.unconfirmed
        selection.confirm()
        #expect(selection.isConfirmed)
        #expect(selection.size == .medium)
        #expect(selection.density == .low)
    }

    @Test("A program prefill arrives already confirmed")
    func prefillIsAnIntentionalAnswer() {
        let selection = SprayCanopySelection.prefilled(size: .large, density: .high)
        #expect(selection.isConfirmed)
        #expect(selection.size == .large)
        #expect(selection.density == .high)
    }

    // MARK: - 6, 7, 9. A band becomes selectable points

    @Test("150–200 g/100 L offers 150, 175 and 200")
    func bandGeneratesThreePoints() {
        let rates = SprayRegisteredUseRates.vineyardRates(for: rangeProduct())
        let presets = rates.filter(\.isRangePreset)
        #expect(presets.count == 3)
        #expect(presets.compactMap(\.seed.seedableValue) == [150, 175, 200])
        #expect(presets.map(\.preset) == [.minimum, .midpoint, .maximum])
    }

    /// The spec's second worked example, and the reason the points are computed
    /// in base units and converted back for display.
    @Test("1.0–1.5 L offers 1.0, 1.25 and 1.5")
    func litreBandGeneratesFractionalMidpoint() {
        let points = SprayRegisteredUseRates.presetPoints(minimum: 1000, maximum: 1500)
        #expect(points.map(\.value) == [1000, 1250, 1500])
    }

    @Test("Points keep the label's own unit and basis — never the store's")
    func pointsKeepTheLabelUnit() {
        let rates = SprayRegisteredUseRates.vineyardRates(for: rangeProduct())
        let presets = rates.filter(\.isRangePreset)
        // The drum is stocked in Kg. The label says grams, so the choices say
        // grams: nobody should have to read 0.175 Kg and think "175 g".
        #expect(presets.allSatisfy { $0.labelUnit == "g" })
        #expect(presets.allSatisfy { $0.basis == .per100Litres })
        #expect(presets.map(\.displayText) == ["150 g/100 L", "175 g/100 L", "200 g/100 L"])
    }

    /// The midpoint is arithmetic and says so. Calling it "recommended" would
    /// attribute a choice to the regulator that the regulator left open.
    @Test("The midpoint is never presented as a recommendation")
    func midpointIsNotDressedUpAsAuthority() {
        let rates = SprayRegisteredUseRates.vineyardRates(for: rangeProduct())
        let midpoint = rates.first { $0.preset == .midpoint }
        #expect(midpoint?.menuText == "175 g/100 L (mid-range)")
        #expect(midpoint?.menuText.localizedCaseInsensitiveContains("recommend") == false)
        #expect(SprayRatePreset.midpoint.qualifier == "mid-range")
        #expect(SprayRatePreset.minimum.qualifier == "label minimum")
        #expect(SprayRatePreset.maximum.qualifier == "label maximum")
    }

    @Test("No point inside a band is ever selected automatically")
    func noPointIsAutoSelected() throws {
        let product = rangeProduct()
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: product, carrier: .litresPer100Metres)
        )
        // The BAND is seeded — it fixes the basis and leaves the line honestly
        // unresolved — and nothing inside it is chosen for the operator.
        #expect(!selection.isRangePreset)
        #expect(selection.requiresOperatorRate)
        #expect(selection.seed.seedableValue == nil)
        #expect(SprayRegisteredUseRates.seedValue(
            for: product,
            rateId: selection.id,
            basis: .per100Litres
        ) == nil)
    }

    // MARK: - 4 (named conditions). Discrete label choices are left alone

    @Test("A label with named conditions gets no synthesised midpoints")
    func namedConditionsAreNotExpanded() {
        let rates = SprayRegisteredUseRates.vineyardRates(for: namedConditionProduct())
        #expect(rates.filter(\.isRangePreset).isEmpty)
        // The label's own two choices, with the conditions that decide between
        // them still attached.
        #expect(rates.count == 2)
        #expect(rates.map(\.label) == ["Low disease pressure", "High disease pressure"])
    }

    // MARK: - 5. A fixed rate has no choice in it

    @Test("A single fixed rate may be selected automatically")
    func fixedRateAutoSelects() throws {
        let product = fixedRateProduct()
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: product, carrier: .litresPer100Metres)
        )
        #expect(selection.seed.seedableValue == 200)
        #expect(!selection.requiresOperatorRate)
        #expect(selection.labelRange == nil)
        #expect(SprayRegisteredUseRates.vineyardRates(for: product).filter(\.isRangePreset).isEmpty)
    }

    // MARK: - 7 (validation). The band is never rewritten

    @Test("A manual 180 inside 150–200 is valid")
    func manualInsideTheBandIsValid() throws {
        let rate = try #require(
            SprayRegisteredUseRates.vineyardRates(for: rangeProduct()).first { $0.preset == .midpoint }
        )
        #expect(SprayLabelRangeCheck.warning(appliedBaseValue: 180, rate: rate) == nil)
        #expect(SprayLabelRangeCheck.warning(appliedBaseValue: 150, rate: rate) == nil)
        #expect(SprayLabelRangeCheck.warning(appliedBaseValue: 200, rate: rate) == nil)
    }

    @Test("A manual rate outside the band is flagged, quoting the label")
    func manualOutsideTheBandIsFlagged() throws {
        let rate = try #require(
            SprayRegisteredUseRates.vineyardRates(for: rangeProduct()).first { $0.preset == .minimum }
        )
        let low = SprayLabelRangeCheck.warning(appliedBaseValue: 120, rate: rate)
        let high = SprayLabelRangeCheck.warning(appliedBaseValue: 260, rate: rate)
        #expect(low == "Outside the registered label range of 150–200 g/100 L.")
        #expect(high == low)
        // The band quoted back is the LABEL's, verbatim — not one widened to
        // accommodate what was typed.
        #expect(rate.labelRangeText == "150–200 g/100 L")
        #expect(rate.labelRange == 150...200)
    }

    @Test("A fixed rate has no band, so nothing is ever flagged against it")
    func fixedRateIsNeverFlagged() throws {
        let rate = try #require(
            SprayRegisteredUseRates.defaultSelection(for: fixedRateProduct(), carrier: .litresPer100Metres)
        )
        #expect(SprayLabelRangeCheck.warning(appliedBaseValue: 999, rate: rate) == nil)
    }

    // MARK: - 10, 13, 18. Selecting a point calculates, immediately

    @Test("Selecting a point resolves the applied rate with no typing")
    func selectingAPointResolvesTheRate() throws {
        let product = rangeProduct()
        let rates = SprayRegisteredUseRates.vineyardRates(for: product)
        let chosen = try #require(rates.first { $0.preset == .midpoint })
        #expect(SprayRegisteredUseRates.seedValue(
            for: product,
            rateId: chosen.id,
            basis: .per100Litres
        ) == 175)
    }

    /// The device acceptance example, to the gram.
    @Test("150 / 175 / 200 g/100 L against 351 L of carrier")
    func deviceAcceptanceTotals() {
        let context = SprayQuantityContext(
            grossAreaHectares: 1,
            carrierLitres: 351,
            concentrationFactor: 1.0
        )
        let expected: [(rate: Double, grams: Double)] = [
            (150, 526.5),
            (175, 614.25),
            (200, 702)
        ]
        for case let (rate, grams) in expected {
            let total = SprayProductQuantityCalculator.totalQuantity(
                rate: rate,
                basis: .per100Litres,
                context: context
            )
            #expect(total == grams)
            // What the operator reads on the card, in the store's own unit.
            #expect(ChemicalUnit.kilograms.fromBase(grams) == grams / 1000)
        }
        #expect(ChemicalUnit.kilograms.fromBase(526.5) == 0.5265)
    }

    @Test("A manual entry overrides a selected point")
    func manualOverridesThePoint() throws {
        let product = rangeProduct()
        let chosen = try #require(
            SprayRegisteredUseRates.vineyardRates(for: product).first { $0.preset == .midpoint }
        )
        let seeded = SprayRegisteredUseRates.seedValue(
            for: product,
            rateId: chosen.id,
            basis: .per100Litres
        )
        #expect(seeded == 175)

        // The card resolves `line.overrideRate ?? seededRate`, so a typed 180
        // wins — and is stored in the same BASE units the seeded value uses, so
        // the two can never mean different things by the same number.
        let manualBase = SprayRegisteredUseRates.baseValue(180, labelUnit: "g", chemical: product)
        #expect(manualBase == 180)
        let applied = manualBase ?? seeded
        #expect(applied == 180)
        #expect(SprayRegisteredUseRates.displayValue(180, labelUnit: "g", chemical: product) == 180)
    }

    // MARK: - 14, 15. Products is left when the operator leaves it

    /// Products validating is exactly the moment the old screen collapsed the
    /// section out from under the operator: `activeStep` moved to Review after
    /// a single tap on a rate. The flow is right to report Review as next; the
    /// SCREEN is what must not act on it, which is why `SprayCalculatorView`
    /// pins `openedStep` to `.products` until Continue is pressed.
    @Test("Completing Products makes Review the next step, never the current one")
    func completingProductsDoesNotEndTheStep() {
        var inputs = foliarInputs(canopyConfirmed: true)
        inputs.products = [
            SprayProductLineInput(
                productId: "p1",
                name: "DITHANE",
                unit: "Kg",
                basis: .per100Litres,
                rate: 175
            )
        ]
        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.blocker(for: .products) == nil)
        #expect(flow.isUnlocked(.review))
    }

    @Test("Adding a chemical with no rate keeps Products unfinished")
    func addingAnUnratedChemicalKeepsProductsOpen() {
        var inputs = foliarInputs(canopyConfirmed: true)
        inputs.products = [
            SprayProductLineInput(
                productId: "p1",
                name: "DITHANE",
                unit: "Kg",
                basis: .per100Litres,
                rate: 175
            ),
            SprayProductLineInput(
                productId: "p2",
                name: "SECOND PRODUCT",
                unit: "L",
                basis: .per100Litres,
                rate: 0
            )
        ]
        let flow = SprayGuidedFlow(inputs: inputs)
        #expect(flow.blocker(for: .products) == .unresolvedProducts(names: ["SECOND PRODUCT"]))
        #expect(!flow.isComplete)
    }

    // MARK: - 16, 17. The band and the carrier basis stay independent

    @Test("A per-100 L band is valid under an L/ha carrier")
    func bandIsValidUnderHectareCarrier() {
        let product = rangeProduct()
        let rates = SprayRegisteredUseRates.vineyardRates(for: product)
        // Same label, same points, whichever way the vineyard measures water.
        for carrier in SprayCarrierBasis.allCases {
            let selection = SprayRegisteredUseRates.defaultSelection(for: product, carrier: carrier)
            #expect(selection?.basis == .per100Litres)
        }
        #expect(rates.filter(\.isRangePreset).allSatisfy { $0.basis == .per100Litres })
    }

    /// The rule the whole separation exists to protect.
    @Test("No per-hectare rate is invented for a per-100 L label")
    func noFakePerHectareRateIsCreated() {
        let rates = SprayRegisteredUseRates.vineyardRates(for: rangeProduct())
        #expect(rates.allSatisfy { $0.basis == .per100Litres })
        #expect(!rates.contains { $0.basis == .perHectare })
        #expect(rates.allSatisfy { $0.displayText.contains("/100 L") })
        // And the reverse: a per-hectare label is not reinterpreted either.
        let perHa = rangeProduct(minimum: 2, maximum: 3, unit: "kg", basis: .rangePerHectare)
        let perHaRates = SprayRegisteredUseRates.vineyardRates(for: perHa)
        #expect(perHaRates.allSatisfy { $0.basis == .perHectare })
    }
}

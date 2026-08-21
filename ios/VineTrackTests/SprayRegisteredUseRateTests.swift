import Foundation
import Testing
@testable import VineTrack

/// P6A.1 — structured registered-use rates in the Spray Tool rate picker.
///
/// The Spray Tool used to offer only the legacy `saved_chemicals.rates` array,
/// so a product matched against a register exposed none of the rates its own
/// label actually carries. `SprayRegisteredUseRates` closes that gap.
///
/// Fixtures are decoded through `BackendSavedChemical` — the real sync path —
/// so these assert the same JSON the portal writes, not a hand-built model.
struct SprayRegisteredUseRateTests {

    private func chemical(_ json: String) throws -> SavedChemical {
        try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    // MARK: - Fixtures

    /// Custodia Forte 91636 — the P6A.1 reference product. ONE registered use
    /// carrying TWO rates on different bases: a 35–54 mL/100 L band and a
    /// single 540 mL/ha rate. Both must reach the picker.
    private let custodiaForteJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Custodia Forte Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "91636",
      "registered_product_name": "CUSTODIA FORTE FUNGICIDE",
      "verification_status": "partially_verified",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "POWDERY MILDEW",
          "rates": [
            {
              "label": "Dilute",
              "basis": "range_per_100_litres",
              "min_value": 35,
              "max_value": 54,
              "unit": "mL",
              "raw_text": "35–54 mL/100 L"
            },
            {
              "label": "Concentrate",
              "basis": "per_hectare",
              "value": 540,
              "unit": "mL",
              "raw_text": "540 mL/ha"
            }
          ],
          "withholding_period_days": 28
        }
      ],
      "label_rate_bases": ["range_per_100_litres", "per_hectare"],
      "intelligence_schema_version": 1
    }
    """

    /// Prosaro 63243 — the reference-only contract fixture.
    private let prosaroJSON = """
    {
      "id": "55555555-5555-5555-5555-555555555555",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Prosaro 420 SC Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_number": "63243",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "BOTRYTIS",
          "rates": [
            {
              "label": "",
              "basis": "other",
              "unit": "",
              "raw_text": "Refer to the approved label for grapevine rates"
            }
          ]
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    /// A legacy record: no structured intelligence at all, two saved rates.
    /// Values are stored in BASE units (mL), so 500 mL = 0.5 L/ha.
    private let legacyJSON = """
    {
      "id": "88888888-8888-8888-8888-888888888888",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Old Bordeaux Mix",
      "unit": "Litres",
      "rate_per_ha": 2.5,
      "active_ingredient": "Copper",
      "chemical_group": "M1",
      "rates": [
        { "label": "Standard", "value": 500, "basis": "per_hectare" },
        { "label": "Dilute", "value": 100, "basis": "per_100_litres" }
      ]
    }
    """

    // MARK: - Custodia Forte: multi-rate selection

    @Test func custodiaForteExposesBothLabelRates() throws {
        let chem = try chemical(custodiaForteJSON)
        let rates = SprayRegisteredUseRates.rates(for: chem)

        #expect(rates.count == 2)
        #expect(rates.allSatisfy { $0.origin == .registeredUse })
        // Both rates stay tied to the registered use they came from.
        #expect(rates.allSatisfy { $0.crop == "GRAPEVINE" })
        #expect(rates.allSatisfy { $0.targetRaw == "POWDERY MILDEW" })
        #expect(rates.allSatisfy { $0.useTitle == "GRAPEVINE · POWDERY MILDEW" })

        let dilute = try #require(rates.first { $0.label == "Dilute" })
        let concentrate = try #require(rates.first { $0.label == "Concentrate" })

        // The label's own wording, verbatim — both are offered.
        #expect(dilute.displayText == "35–54 mL/100 L")
        #expect(concentrate.displayText == "540 mL/ha")
        #expect(dilute.menuText == "Dilute: 35–54 mL/100 L")

        // Two different bases on ONE use, each preserved.
        #expect(dilute.basis == .per100Litres)
        #expect(concentrate.basis == .perHectare)

        // Both are pickable; only the single rate can seed a calculation.
        #expect(dilute.isSelectable)
        #expect(concentrate.isSelectable)
        #expect(dilute.requiresOperatorRate)
        #expect(!concentrate.requiresOperatorRate)

        // 540 mL on a Litres product converts to 540 base units (mL).
        #expect(concentrate.seed == .value(540))
    }

    @Test func custodiaForteRatesHaveStableDistinctIdentities() throws {
        let chem = try chemical(custodiaForteJSON)
        let first = SprayRegisteredUseRates.rates(for: chem)
        let second = SprayRegisteredUseRates.rates(for: try chemical(custodiaForteJSON))

        // Deterministic ids, so a persisted selection survives a redraw or a
        // relaunch instead of silently detaching from its rate.
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == 2)
    }

    // MARK: - Range preservation

    @Test func rangeIsPreservedAndNeverCollapsed() throws {
        let chem = try chemical(custodiaForteJSON)
        let dilute = try #require(
            SprayRegisteredUseRates.rates(for: chem).first { $0.label == "Dilute" }
        )
        // Both ends survive, in base units.
        #expect(dilute.seed == .range(minimum: 35, maximum: 54))
        // A band is NOT an application rate: it cannot seed the calculator, so
        // the operator's own input establishes what is actually applied.
        #expect(dilute.seed.seedableValue == nil)
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: dilute.id, basis: .per100Litres) == nil)
        // Selecting it is still allowed — it fixes the basis and shows the band.
        #expect(dilute.isSelectable)
        #expect(dilute.requiresOperatorRate)
    }

    @Test func defaultSelectionPrefersASingleRateOverARange() throws {
        let chem = try chemical(custodiaForteJSON)
        // Opening the product should not immediately demand a manual entry when
        // the label also states a plain rate.
        let fallback = try #require(SprayRegisteredUseRates.defaultSelection(for: chem))
        #expect(fallback.label == "Concentrate")

        // But an explicit basis preference is honoured, even when the only rate
        // on that basis is a band.
        let per100L = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, preferring: .per100Litres)
        )
        #expect(per100L.label == "Dilute")
        #expect(per100L.basis == .per100Litres)
    }

    // MARK: - Basis isolation

    @Test func perHectareAndPer100LitresNeverCrossFallback() throws {
        let chem = try chemical(custodiaForteJSON)
        let perHa = try #require(
            SprayRegisteredUseRates.rates(for: chem).first { $0.label == "Concentrate" }
        )
        // The per-hectare rate seeds a per-hectare line…
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: perHa.id, basis: .perHectare) == 540)
        // …and refuses a per-100 L line outright. Dosing 540 mL/ha against
        // carrier volume would be a completely different quantity.
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: perHa.id, basis: .per100Litres) == nil)
    }

    @Test func legacyRatesAlsoRefuseACrossBasisSeed() throws {
        let chem = try chemical(legacyJSON)
        let perHa = try #require(
            SprayRegisteredUseRates.rates(for: chem).first { $0.basis == .perHectare }
        )
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: perHa.id, basis: .perHectare) == 500)
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: perHa.id, basis: .per100Litres) == nil)
    }

    @Test func unitConversionRespectsTheProductsOwnDimension() throws {
        let liquid = try chemical(custodiaForteJSON) // Litres → base mL
        // 0.54 L is the same dose as 540 mL.
        #expect(SprayRegisteredUseRates.baseValue(0.54, labelUnit: "L", chemical: liquid) == 540)
        #expect(SprayRegisteredUseRates.baseValue(540, labelUnit: "mL", chemical: liquid) == 540)
        // A solid unit on a liquid product is refused rather than converted:
        // guessing here would mis-dose by 1000×.
        #expect(SprayRegisteredUseRates.baseValue(1, labelUnit: "kg", chemical: liquid) == nil)
        #expect(SprayRegisteredUseRates.baseValue(1, labelUnit: "per vine", chemical: liquid) == nil)
        #expect(SprayRegisteredUseRates.baseValue(1, labelUnit: "", chemical: liquid) == nil)
    }

    // MARK: - basis:"other" is reference only

    @Test func referenceOnlyRateIsShownButNeverApplied() throws {
        let chem = try chemical(prosaroJSON)
        let rates = SprayRegisteredUseRates.rates(for: chem)
        let reference = try #require(rates.first)

        #expect(rates.count == 1)
        // It IS offered, so the operator can read what the label says…
        #expect(reference.displayText == "Refer to the approved label for grapevine rates")
        #expect(reference.crop == "GRAPEVINE")
        // …but it is not an application rate on any basis.
        #expect(reference.basis == nil)
        #expect(reference.seed == .referenceOnly)
        #expect(!reference.isSelectable)
        #expect(reference.seed.seedableValue == nil)
        #expect(SprayRegisteredUseRates.selectableRates(for: chem).isEmpty)
        // And nothing can be seeded from it, on either basis.
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: reference.id, basis: .perHectare) == nil)
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: reference.id, basis: .per100Litres) == nil)
        // With nothing selectable there is no default selection to make.
        #expect(SprayRegisteredUseRates.defaultSelection(for: chem) == nil)
    }

    // MARK: - Unresolved rates

    @Test func numberlessRateCannotSeedACalculation() throws {
        let chem = try chemical("""
        {
          "id": "66666666-6666-6666-6666-666666666666",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Custodia 320SC",
          "unit": "Litres",
          "rate_per_ha": 0,
          "rates": [],
          "registration_country": "AU",
          "registered_uses": [
            {
              "crop": "GRAPEVINE",
              "target_raw": "POWDERY MILDEW",
              "rates": [
                { "label": "Foliar", "basis": "per_hectare", "unit": "mL" },
                { "label": "Odd unit", "basis": "per_hectare", "value": 3, "unit": "per vine" }
              ]
            }
          ],
          "intelligence_schema_version": 1
        }
        """)
        let rates = SprayRegisteredUseRates.rates(for: chem)
        #expect(rates.count == 2)
        // A rate with a basis but NO number is unresolved — never zero.
        let numberless = try #require(rates.first { $0.label == "Foliar" })
        #expect(numberless.seed == .unresolved)
        #expect(!numberless.isSelectable)
        // A unit this build cannot convert is equally unresolved: it fails
        // closed rather than assuming the product's own unit.
        let oddUnit = try #require(rates.first { $0.label == "Odd unit" })
        #expect(oddUnit.seed == .unresolved)
        #expect(!oddUnit.isSelectable)

        #expect(SprayRegisteredUseRates.selectableRates(for: chem).isEmpty)
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: numberless.id, basis: .perHectare) == nil)
    }

    // MARK: - Legacy fallback

    @Test func legacyRatesAreUsedOnlyWhenStructuredRatesAreAbsent() throws {
        let legacy = try chemical(legacyJSON)
        #expect(!SprayRegisteredUseRates.hasStructuredRates(legacy))

        let rates = SprayRegisteredUseRates.rates(for: legacy)
        #expect(rates.count == 2)
        #expect(rates.allSatisfy { $0.origin == .legacy })
        // Legacy rates carry no registered use, so they group on their own.
        #expect(rates.allSatisfy { $0.useTitle == nil })

        let perHa = try #require(rates.first { $0.basis == .perHectare })
        #expect(perHa.seed == .value(500))
        // Stored base units are displayed in the product's own unit: 500 mL = 0.5 L.
        #expect(perHa.displayText == "0.5 Litres/ha")
        #expect(perHa.isSelectable)

        // A structured record NEVER mixes the legacy array in beside its label
        // rates — that would offer a stale hand-typed rate next to the label's
        // own with nothing to say which one the register agrees with.
        let structured = try chemical(custodiaForteJSON)
        #expect(SprayRegisteredUseRates.hasStructuredRates(structured))
        #expect(SprayRegisteredUseRates.rates(for: structured)
            .allSatisfy { $0.origin == .registeredUse })
    }

    @Test func structuredRecordWithNoRatesStillFallsBackToLegacy() throws {
        // Registered uses exist, but none of them carries a rate — the record
        // has no structured rate information, so the legacy array is genuinely
        // the only thing available.
        let chem = try chemical("""
        {
          "id": "77777777-7777-7777-7777-777777777777",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Partly matched product",
          "unit": "Litres",
          "rate_per_ha": 0,
          "rates": [ { "label": "Standard", "value": 250, "basis": "per_hectare" } ],
          "registration_country": "AU",
          "registration_number": "12345",
          "registered_uses": [
            { "crop": "GRAPEVINE", "target_raw": "DOWNY MILDEW", "rates": [] }
          ],
          "intelligence_schema_version": 1
        }
        """)
        #expect(!SprayRegisteredUseRates.hasStructuredRates(chem))
        let rates = SprayRegisteredUseRates.rates(for: chem)
        #expect(rates.count == 1)
        #expect(rates[0].origin == .legacy)
        #expect(rates[0].seed == .value(250))
    }

    @Test func aProductWithNoRatesAtAllOffersNothing() throws {
        let chem = try chemical("""
        {
          "id": "99999999-9999-9999-9999-999999999999",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Bare product",
          "unit": "Litres",
          "rate_per_ha": 0,
          "rates": []
        }
        """)
        #expect(SprayRegisteredUseRates.rates(for: chem).isEmpty)
        #expect(SprayRegisteredUseRates.defaultSelection(for: chem) == nil)
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: UUID(), basis: .perHectare) == nil)
    }

    // MARK: - End to end through the calculation engine

    @Test func selectedStructuredRateFlowsIntoTheSprayCalculation() throws {
        let chem = try chemical(custodiaForteJSON)
        let concentrate = try #require(
            SprayRegisteredUseRates.rates(for: chem).first { $0.label == "Concentrate" }
        )
        let seeded = try #require(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: concentrate.id, basis: .perHectare))

        let plan = SprayApplicationPlanner.plan(
            blocks: [SprayBlockInput(
                blockId: "b1", grossAreaHectares: 10,
                mappedRowLengthMetres: 31_250, rowSpacingMetres: 3.2
            )],
            mode: .wholeBlock,
            carrier: SprayCarrierVolumeCalculator.perHectare(
                litresPerHectare: 500, areaHectares: 10
            ),
            tankCapacityLitres: 2_000,
            productLines: [SprayProductLineInput(
                productId: "custodia", name: "Custodia Forte", unit: "mL",
                basis: .wholeBlockArea, rate: seeded
            )]
        )
        // 540 mL/ha × 10 ha = 5,400 mL
        #expect(plan.productLines.first?.totalQuantity == 5_400)
    }

    @Test func aRangeSelectionLeavesTheLineUnresolvedUntilTheOperatorEntersARate() throws {
        let chem = try chemical(custodiaForteJSON)
        let dilute = try #require(
            SprayRegisteredUseRates.rates(for: chem).first { $0.label == "Dilute" }
        )
        // The picker offers the band, but seeds nothing…
        let seeded = SprayRegisteredUseRates.seedValue(
            for: chem, rateId: dilute.id, basis: .per100Litres)
        #expect(seeded == nil)

        let plan = SprayApplicationPlanner.plan(
            blocks: [SprayBlockInput(blockId: "b1", grossAreaHectares: 10, rowSpacingMetres: 3.2)],
            mode: .wholeBlock,
            carrier: SprayCarrierVolumeCalculator.perHectare(
                litresPerHectare: 500, areaHectares: 10
            ),
            tankCapacityLitres: 2_000,
            productLines: [SprayProductLineInput(
                productId: "custodia", name: "Custodia Forte", unit: "mL",
                basis: .per100Litres, rate: seeded ?? 0
            )]
        )
        // …so the line reports itself unresolved, naming the RATE as the gap.
        let result = try #require(plan.productLines.first)
        #expect(result.totalQuantity == nil)
        #expect(result.unresolvedReason == .rateUnavailable)

        // Once the operator supplies the rate, the same line calculates:
        // 45 mL × 5,000 L ÷ 100 = 2,250 mL
        let resolved = SprayApplicationPlanner.plan(
            blocks: [SprayBlockInput(blockId: "b1", grossAreaHectares: 10, rowSpacingMetres: 3.2)],
            mode: .wholeBlock,
            carrier: SprayCarrierVolumeCalculator.perHectare(
                litresPerHectare: 500, areaHectares: 10
            ),
            tankCapacityLitres: 2_000,
            productLines: [SprayProductLineInput(
                productId: "custodia", name: "Custodia Forte", unit: "mL",
                basis: .per100Litres, rate: 45
            )]
        )
        #expect(resolved.productLines.first?.totalQuantity == 2_250)
    }
}

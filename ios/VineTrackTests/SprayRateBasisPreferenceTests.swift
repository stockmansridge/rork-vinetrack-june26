import Foundation
import Testing
@testable import VineTrack

/// Which LABEL rate a carrier workflow starts from — and what must never
/// happen to the label rates themselves.
///
/// The defect these tests lock down: a vineyard running the 100 m runoff
/// workflow was seeded with the per-hectare label rate even when the product
/// carried a perfectly good per-100 L rate. The preference was inferred, at
/// each call site separately, from the legacy `ratePer100L` scalar — a column
/// the consolidated Chemical Store no longer edits and now projects from the
/// structured record. A per-100 L-only product projects 0 into it, so every
/// call site read "no per-100 L rate" and fell through to per hectare.
///
/// The other half of the contract is what the fix must NOT do: every rate the
/// label states is stored, none is converted into the other basis, and none is
/// invented to satisfy a preference.
struct SprayRateBasisPreferenceTests {

    private func chemical(_ json: String) throws -> SavedChemical {
        try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    // MARK: - Fixtures

    /// Dithane-shaped: a solid product whose label states BOTH a dilute
    /// per-100 L rate and a concentrate per-hectare rate for the same use.
    private let bothBasesJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Dithane Rainshield Neotec",
      "unit": "Kg",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "34540",
      "registered_uses": [
        {
          "crop": "GRAPES",
          "target_raw": "DOWNY MILDEW",
          "rates": [
            {
              "label": "Dilute spraying",
              "basis": "per_100_litres",
              "value": 200,
              "unit": "g",
              "raw_text": "200 g/100 L"
            },
            {
              "label": "Concentrate",
              "basis": "per_hectare",
              "value": 2.5,
              "unit": "kg",
              "raw_text": "2.5 kg/ha"
            }
          ],
          "withholding_period_days": 21,
          "re_entry_period_hours": 0
        }
      ],
      "label_rate_bases": ["per_100_litres", "per_hectare"],
      "intelligence_schema_version": 1
    }
    """

    /// Per-hectare ONLY. A 100 m vineyard must keep this exactly as stated.
    private let perHectareOnlyJSON = """
    {
      "id": "33333333-3333-3333-3333-333333333333",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Area Only Fungicide",
      "unit": "Kg",
      "rate_per_ha": 0,
      "rates": [],
      "registered_uses": [
        {
          "crop": "GRAPES",
          "target_raw": "DOWNY MILDEW",
          "rates": [
            { "label": "", "basis": "per_hectare", "value": 2.5, "unit": "kg",
              "raw_text": "2.5 kg/ha" }
          ]
        }
      ],
      "label_rate_bases": ["per_hectare"],
      "intelligence_schema_version": 1
    }
    """

    /// Per-100 L ONLY. An L/ha vineyard must keep this exactly as stated.
    private let per100LitresOnlyJSON = """
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Dilute Only Fungicide",
      "unit": "Kg",
      "rate_per_ha": 0,
      "rates": [],
      "registered_uses": [
        {
          "crop": "GRAPES",
          "target_raw": "DOWNY MILDEW",
          "rates": [
            { "label": "Dilute", "basis": "per_100_litres", "value": 200, "unit": "g",
              "raw_text": "200 g/100 L" }
          ]
        }
      ],
      "label_rate_bases": ["per_100_litres"],
      "intelligence_schema_version": 1
    }
    """

    /// A per-100 L BAND alongside a plain per-hectare rate. The band must still
    /// win in a runoff workflow: a range on the right basis beats a single rate
    /// on the wrong one.
    private let rangePer100LitresJSON = """
    {
      "id": "55555555-5555-5555-5555-555555555555",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Custodia Forte Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "POWDERY MILDEW",
          "rates": [
            { "label": "Concentrate", "basis": "per_hectare", "value": 540, "unit": "mL",
              "raw_text": "540 mL/ha" },
            { "label": "Dilute", "basis": "range_per_100_litres", "min_value": 35,
              "max_value": 54, "unit": "mL", "raw_text": "35–54 mL/100 L" }
          ]
        }
      ],
      "label_rate_bases": ["per_hectare", "range_per_100_litres"],
      "intelligence_schema_version": 1
    }
    """

    private func profile(_ code: String) -> SprayVineyardProfile {
        SprayVineyardProfile(countryCode: code)
    }

    // MARK: - 1, 2, 3. Every stated rate is stored, in its own basis

    @Test("A per-hectare-only product keeps its per-hectare rate")
    func perHectareOnlyIsKept() throws {
        let chem = try chemical(perHectareOnlyJSON)
        let rates = SprayRegisteredUseRates.rates(for: chem)
        #expect(rates.count == 1)
        #expect(rates[0].basis == .perHectare)
        #expect(rates[0].displayText == "2.5 kg/ha")

        // Even in the runoff workflow, which would PREFER per-100 L. There is
        // no per-100 L rate on this label, so the preference finds nothing and
        // the rate that actually exists is used — never a converted one.
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, carrier: .litresPer100Metres)
        )
        #expect(selection.basis == .perHectare)
        #expect(selection.displayText == "2.5 kg/ha")
    }

    @Test("A per-100 L-only product keeps its per-100 L rate")
    func per100LitresOnlyIsKept() throws {
        let chem = try chemical(per100LitresOnlyJSON)
        let rates = SprayRegisteredUseRates.rates(for: chem)
        #expect(rates.count == 1)
        #expect(rates[0].basis == .per100Litres)
        #expect(rates[0].displayText == "200 g/100 L")

        // And the L/ha workflow does not restate it as a hectare rate.
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, carrier: .litresPerHectare)
        )
        #expect(selection.basis == .per100Litres)
        #expect(selection.displayText == "200 g/100 L")
    }

    @Test("A product stating both rates keeps BOTH")
    func bothRatesAreStored() throws {
        let chem = try chemical(bothBasesJSON)
        let rates = SprayRegisteredUseRates.rates(for: chem)

        // Two rates on one registered use. Neither is dropped because the other
        // was encountered first.
        #expect(rates.count == 2)
        let dilute = try #require(rates.first { $0.basis == .per100Litres })
        let concentrate = try #require(rates.first { $0.basis == .perHectare })
        #expect(dilute.displayText == "200 g/100 L")
        #expect(concentrate.displayText == "2.5 kg/ha")
        #expect(dilute.useTitle == "GRAPES · DOWNY MILDEW")
        #expect(concentrate.useTitle == "GRAPES · DOWNY MILDEW")

        // The structured record — not a flattened scalar — remains the source.
        let uses = try #require(chem.chemicalIntelligence?.registeredUses)
        #expect(uses.count == 1)
        #expect(uses[0].rates.count == 2)
        #expect(uses[0].rates.map(\.basis) == [.per100Litres, .perHectare])
    }

    // MARK: - 4. No rate is ever converted into another basis

    @Test("No label rate is converted into another basis")
    func noRateIsConverted() throws {
        let chem = try chemical(bothBasesJSON)
        let rates = SprayRegisteredUseRates.rates(for: chem)

        // 200 g/100 L stays 200 g in base units; 2.5 kg/ha stays 2,500 g.
        // Neither number is derived from the other — 2.5 kg/ha is NOT
        // 200 g/100 L restated, and nothing here pretends it is.
        let dilute = try #require(rates.first { $0.basis == .per100Litres })
        let concentrate = try #require(rates.first { $0.basis == .perHectare })
        #expect(dilute.seed.seedableValue == 200)
        #expect(concentrate.seed.seedableValue == 2_500)

        // A seed is refused outright when the line's basis disagrees with the
        // rate's, rather than being converted to fit.
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: dilute.id, basis: .perHectare) == nil)
        #expect(SprayRegisteredUseRates.seedValue(
            for: chem, rateId: concentrate.id, basis: .per100Litres) == nil)

        // The per-hectare-only product gains no per-100 L rate by being opened
        // in a runoff vineyard.
        let areaOnly = try chemical(perHectareOnlyJSON)
        #expect(SprayRegisteredUseRates.rates(for: areaOnly)
            .contains { $0.basis == .per100Litres } == false)
        // And the reverse.
        let diluteOnly = try chemical(per100LitresOnlyJSON)
        #expect(SprayRegisteredUseRates.rates(for: diluteOnly)
            .contains { $0.basis == .perHectare } == false)
    }

    // MARK: - 5, 6, 7. The preference is contextual

    @Test("100 m runoff mode prefers the per-100 L label rate")
    func runoffPrefersPer100Litres() throws {
        #expect(SprayRateBasisPreference.order(for: .litresPer100Metres)
                == [.per100Litres, .perHectare])

        let chem = try chemical(bothBasesJSON)
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, carrier: .litresPer100Metres)
        )
        // THE regression: this used to come back as 2.5 kg/ha.
        #expect(selection.basis == .per100Litres)
        #expect(selection.displayText == "200 g/100 L")

        // An NZ/SWNZ vineyard is locked to the runoff workflow, so its profile
        // alone produces the same preference.
        #expect(SprayRateBasisPreference.order(for: profile("NZ"))
                == [.per100Litres, .perHectare])
        #expect(SprayRateBasisPreference.fallbackBasis(for: profile("NZ")) == .per100Litres)
    }

    @Test("100 m runoff mode prefers a per-100 L BAND over a per-hectare single rate")
    func runoffPrefersRangePer100Litres() throws {
        let chem = try chemical(rangePer100LitresJSON)
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, carrier: .litresPer100Metres)
        )
        // The band is on the right basis for this workflow, so it wins even
        // though the per-hectare rate is a single number and would otherwise be
        // the more convenient seed.
        #expect(selection.basis == .per100Litres)
        #expect(selection.displayText == "35–54 mL/100 L")
        // A band still fixes only the basis — the operator picks the number.
        #expect(selection.requiresOperatorRate)
        #expect(selection.seed.seedableValue == nil)
    }

    @Test("L/ha mode prefers the per-hectare label rate")
    func hectareModePrefersPerHectare() throws {
        #expect(SprayRateBasisPreference.order(for: .litresPerHectare)
                == [.perHectare, .per100Litres])

        let chem = try chemical(bothBasesJSON)
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, carrier: .litresPerHectare)
        )
        #expect(selection.basis == .perHectare)
        #expect(selection.displayText == "2.5 kg/ha")

        // An AU vineyard defaults to the L/ha workflow, so per-100 L is NOT
        // made the global default by this change.
        #expect(SprayRateBasisPreference.order(for: profile("AU"))
                == [.perHectare, .per100Litres])
        #expect(SprayRateBasisPreference.fallbackBasis(for: profile("AU")) == .perHectare)
    }

    // MARK: - 8, 9. Program Steps

    @Test("An explicit Program Step rate basis is never overridden by the preference")
    func explicitProgramStepBasisSurvives() throws {
        // A step saved with an explicit per-hectare product line. The vineyard
        // later moves to the 100 m workflow; the saved decision still stands.
        var line = SprayChemical(name: "Dithane Rainshield Neotec")
        line.unit = .kilograms
        line.ratePerHa = 2_500
        line.rateBasis = .wholeBlockArea
        #expect(line.reportedRateBasis == .wholeBlockArea)
        #expect(line.reportedRateBaseValue == 2_500)

        // This is the branch the calculator's prefill takes: an explicit basis
        // collapses the preference to that one basis, so the runoff preference
        // cannot reach the selection.
        let explicit: ChemicalRateBasis = .perHectare
        let chem = try chemical(bothBasesJSON)
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, preferring: [explicit])
        )
        #expect(selection.basis == .perHectare)
        #expect(selection.displayText == "2.5 kg/ha")

        // And a step loaded from storage reports the basis it was saved with,
        // never one re-derived from the vineyard.
        var per100LLine = SprayChemical(name: "Dilute Only Fungicide")
        per100LLine.unit = .kilograms
        per100LLine.ratePer100L = 200
        per100LLine.rateBasis = .per100Litres
        #expect(per100LLine.reportedRateBasis == .per100Litres)
        #expect(per100LLine.reportedRateBaseValue == 200)
    }

    @Test("A NEW Program Step product in a 100 m vineyard seeds the per-100 L rate")
    func newProgramStepProductSeedsPer100Litres() throws {
        let chem = try chemical(bothBasesJSON)
        // The seeding call `SprayProgramStepEditView.applyReplacement` makes.
        let seed = try #require(
            SprayRegisteredUseRates.defaultSelection(
                for: chem, preferring: SprayRateBasisPreference.order(for: profile("NZ"))
            )
        )
        #expect(seed.basis == .per100Litres)

        var draft = SprayProgramProductDraft()
        draft.replaceProduct(with: chem, seedRate: seed)
        #expect(draft.basis == .per100Litres)
        #expect(draft.savedChemicalId == chem.id)
        // 200 g in base units on a Kilograms product reads as 0.2 kg.
        #expect(abs(draft.rate - 0.2) < 0.0001)

        // The same product in an L/ha vineyard seeds the per-hectare rate.
        let auSeed = try #require(
            SprayRegisteredUseRates.defaultSelection(
                for: chem, preferring: SprayRateBasisPreference.order(for: profile("AU"))
            )
        )
        var auDraft = SprayProgramProductDraft()
        auDraft.replaceProduct(with: chem, seedRate: auSeed)
        #expect(auDraft.basis == .wholeBlockArea)
        #expect(abs(auDraft.rate - 2.5) < 0.0001)
    }

    // MARK: - 10, 11. What the calculator actually receives

    @Test("The Spray Calculator receives the selected per-100 L basis")
    func calculatorReceivesPer100LitresBasis() throws {
        let chem = try chemical(bothBasesJSON)
        let selection = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, carrier: .litresPer100Metres)
        )
        let basis = try #require(selection.basis)
        #expect(basis == .per100Litres)

        // The seed resolves only against the SELECTED basis — this is the value
        // that reaches the engine, so a UI-only ordering fix would fail here.
        let seeded = try #require(
            SprayRegisteredUseRates.seedValue(for: chem, rateId: selection.id, basis: basis)
        )
        #expect(seeded == 200)

        // And the planner runs it as a per-100 L line against runoff carrier.
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = [SprayBlockInput(
            blockId: "block-a",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )]
        inputs.targets = [.downyMildew]
        inputs.sprayHeadTarget = .fullCanopy
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .litresPer100Metres
        inputs.diluteLitresPer100Metres = 40
        inputs.appliedLitresPer100Metres = 40
        inputs.products = [SprayProductLineInput(
            productId: chem.id.uuidString,
            name: chem.name,
            unit: chem.unit.rawValue,
            basis: .per100Litres,
            rate: seeded
        )]

        let plan = SprayGuidedFlow(inputs: inputs, profile: profile("NZ")).plan
        #expect(plan.productLines[0].basis == .per100Litres)
        // 40 L/100 m over 31,250 m = 12,500 L carrier.
        #expect(abs(plan.totalCarrierLitres - 12_500) < 0.0001)
        // 200 g per 100 L × 12,500 L = 25,000 g. The planner derived it; the
        // label still says 200 g/100 L.
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 25_000) < 0.0001)
    }

    @Test("Derived per-hectare figures never become stored label rates")
    func derivedFiguresAreNotLabelRates() throws {
        let chem = try chemical(per100LitresOnlyJSON)

        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = [SprayBlockInput(
            blockId: "block-a",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )]
        inputs.targets = [.downyMildew]
        inputs.sprayHeadTarget = .fullCanopy
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .litresPer100Metres
        inputs.diluteLitresPer100Metres = 40
        inputs.appliedLitresPer100Metres = 40
        inputs.products = [SprayProductLineInput(
            productId: chem.id.uuidString,
            name: chem.name,
            unit: chem.unit.rawValue,
            basis: .per100Litres,
            rate: 200
        )]

        let plan = SprayGuidedFlow(inputs: inputs, profile: profile("NZ")).plan
        // The planner produced a real quantity — a DERIVED figure.
        #expect((plan.productLines[0].totalQuantity ?? 0) > 0)

        // The Chemical Store record is untouched by it. Still one label rate,
        // still per-100 L, still 200 g. A derived /ha number is an output of a
        // job, never a label instruction.
        let uses = try #require(chem.chemicalIntelligence?.registeredUses)
        #expect(uses.flatMap(\.rates).count == 1)
        #expect(uses[0].rates[0].basis == .per100Litres)
        #expect(uses[0].rates[0].value == 200)
        #expect(SprayRegisteredUseRates.rates(for: chem)
            .contains { $0.basis == .perHectare } == false)
    }

    // MARK: - 12. The preference never suppresses a rate

    @Test("A preference orders the rates on offer; it never removes one")
    func preferenceNeverRemovesARate() throws {
        let chem = try chemical(bothBasesJSON)
        // Whatever the workflow, the operator can still SEE and choose both
        // rates — the preference only decides which one is selected first.
        for carrier in [SprayCarrierBasis.litresPer100Metres, .litresPerHectare] {
            let offered = SprayRegisteredUseRates.rates(for: chem)
            #expect(offered.count == 2)
            #expect(SprayRegisteredUseRates.selectableRates(for: chem).count == 2)
            let selection = try #require(
                SprayRegisteredUseRates.defaultSelection(for: chem, carrier: carrier)
            )
            #expect(offered.contains { $0.id == selection.id })
        }

        // Both bases always appear in the order, so a preference can never
        // strand a product whose label uses only the non-preferred one.
        #expect(Set(SprayRateBasisPreference.order(for: .litresPer100Metres))
                == Set([.per100Litres, .perHectare]))
        #expect(Set(SprayRateBasisPreference.order(for: .litresPerHectare))
                == Set([.per100Litres, .perHectare]))
    }
}

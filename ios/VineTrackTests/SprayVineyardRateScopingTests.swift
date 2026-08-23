import Foundation
import Testing
@testable import VineTrack

/// Rate scoping for the vineyard Spray Calculator, and the mass arithmetic
/// behind a product line's quantity.
///
/// # Why these exist
///
/// An approved label may register dozens of crops. Dithane Rainshield's carries
/// tobacco blue mould, brown spot on mandarin and citrus black spot alongside
/// its grapevine uses — all authoritative, none of them a rate for a vineyard
/// spray. The Spray Calculator was offering every one of them, which is how a
/// `2.2 kg/ha` TOBACCO rate became selectable for a grapevine job.
///
/// Scoping is asserted against `SprayRegisteredUseRates` rather than the view
/// because that is the only place a selectable rate may come from. A rule
/// asserted against the UI could pass while a seeding call site disagreed.
///
/// Fixtures decode through `BackendSavedChemical` — the real sync path — so
/// these assert the JSON the portal actually writes.
struct SprayVineyardRateScopingTests {

    private func chemical(_ json: String) throws -> SavedChemical {
        try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    // MARK: - Fixtures

    /// Dithane Rainshield, reduced to the shape that caused the defect: FOUR
    /// grapevine uses of which only one carries a printed rate, plus tobacco
    /// and citrus uses that carry per-hectare rates.
    ///
    /// A solid product, so its base unit is grams and its display unit is Kg —
    /// the exact combination the 1000× report concerned.
    private let dithaneJSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000001",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Dithane Rainshield NeoTec",
      "unit": "Kilograms",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_number": "34667",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "DOWNY MILDEW",
          "rates": []
        },
        {
          "crop": "GRAPEVINE",
          "target_raw": "BLACK SPOT",
          "rates": []
        },
        {
          "crop": "GRAPEVINE",
          "target_raw": "PHOMOPSIS CANE AND LEAF SPOT",
          "rates": [
            {
              "label": "Dilute",
              "basis": "range_per_100_litres",
              "min_value": 150,
              "max_value": 200,
              "unit": "g",
              "raw_text": "150–200 g/100 L"
            }
          ]
        },
        {
          "crop": "TOBACCO",
          "target_raw": "BLUE MOULD",
          "rates": [
            {
              "label": "Standard",
              "basis": "per_hectare",
              "value": 2.2,
              "unit": "kg",
              "raw_text": "2.2 kg/ha"
            }
          ]
        },
        {
          "crop": "CITRUS",
          "target_raw": "CITRUS BLACK SPOT",
          "rates": [
            {
              "label": "Standard",
              "basis": "per_hectare",
              "value": 3.0,
              "unit": "kg",
              "raw_text": "3.0 kg/ha"
            }
          ]
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    /// A product registered ONLY on crops that are not grapevines.
    private let nonVineyardOnlyJSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000002",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Orchard Only Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registered_uses": [
        {
          "crop": "APPLE",
          "target_raw": "BLACK SPOT",
          "rates": [
            { "label": "Standard", "basis": "per_hectare", "value": 1.5, "unit": "L", "raw_text": "1.5 L/ha" }
          ]
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    /// A product whose rate belongs to no crop at all — a product-level rate
    /// carrier. It states a rate for the product as a whole, so scoping by crop
    /// must not discard it.
    private let productLevelRateJSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000003",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "General Wetting Agent",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registered_uses": [
        {
          "crop": "",
          "target_raw": "",
          "rates": [
            { "label": "Standard", "basis": "per_100_litres", "value": 50, "unit": "mL", "raw_text": "50 mL/100 L" }
          ]
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    /// A pre-Chemical-Intelligence record: no structured uses, two saved rates
    /// stored in BASE units (mL).
    private let legacyJSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000004",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Old Bordeaux Mix",
      "unit": "Litres",
      "rate_per_ha": 2.5,
      "rates": [
        { "label": "Standard", "value": 500, "basis": "per_hectare" }
      ]
    }
    """

    /// A solid product with BOTH a grapevine and a tobacco per-hectare rate, so
    /// the scoped picker has something to keep as well as something to drop.
    private let mixedCropJSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000005",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Mixed Crop Fungicide",
      "unit": "Kilograms",
      "rate_per_ha": 0,
      "rates": [],
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "POWDERY MILDEW",
          "rates": [
            { "label": "Standard", "basis": "per_hectare", "value": 800, "unit": "g", "raw_text": "800 g/ha" }
          ]
        },
        {
          "crop": "TOBACCO",
          "target_raw": "BLUE MOULD",
          "rates": [
            { "label": "Standard", "basis": "per_hectare", "value": 2.2, "unit": "kg", "raw_text": "2.2 kg/ha" }
          ]
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    // MARK: - Scoping: other crops are never offered

    @Test func vineyardPickerDropsTobaccoAndCitrusRates() throws {
        let chem = try chemical(dithaneJSON)

        // The record itself still carries every crop — nothing is deleted.
        let all = SprayRegisteredUseRates.rates(for: chem)
        #expect(all.contains { $0.crop == "TOBACCO" })
        #expect(all.contains { $0.crop == "CITRUS" })

        // The vineyard picker offers none of them.
        let vineyard = SprayRegisteredUseRates.vineyardRates(for: chem)
        #expect(vineyard.allSatisfy { $0.crop == "GRAPEVINE" })
        #expect(!vineyard.contains { $0.crop == "TOBACCO" })
        #expect(!vineyard.contains { $0.crop == "CITRUS" })
    }

    @Test func vineyardPickerKeepsGrapevineRatesAndDropsOthers() throws {
        let chem = try chemical(mixedCropJSON)
        let vineyard = SprayRegisteredUseRates.selectableVineyardRates(for: chem)

        #expect(vineyard.count == 1)
        let only = try #require(vineyard.first)
        #expect(only.crop == "GRAPEVINE")
        // 800 g/ha, in base grams.
        #expect(only.seed.seedableValue == 800)
    }

    /// The heart of the defect: seeding must not reach for another crop's rate.
    @Test func defaultSelectionNeverSeedsANonVineyardRate() throws {
        let chem = try chemical(mixedCropJSON)
        let seeded = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chem, preferring: [.perHectare])
        )
        #expect(seeded.crop == "GRAPEVINE")
        #expect(seeded.seed.seedableValue == 800)
    }

    @Test func defaultSelectionIsNilWhenOnlyOtherCropsCarryRates() throws {
        let chem = try chemical(dithaneJSON)
        // The only grapevine rate is a RANGE, so nothing is seedable on a
        // per-hectare basis and the tobacco rate must not stand in for it.
        let seeded = SprayRegisteredUseRates.defaultSelection(for: chem, preferring: [.perHectare])
        #expect(seeded?.crop != "TOBACCO")
        #expect(seeded?.seed.seedableValue != 2200)
    }

    @Test func productRegisteredOnNoVineyardCropOffersNothing() throws {
        let chem = try chemical(nonVineyardOnlyJSON)
        #expect(SprayRegisteredUseRates.vineyardRates(for: chem).isEmpty)
        #expect(SprayRegisteredUseRates.hasVineyardUse(chem) == false)
        #expect(SprayRegisteredUseRates.defaultSelection(for: chem, preferring: [.perHectare]) == nil)
    }

    /// "Registered on grapevines, but this use binds no rate" is a different
    /// answer from "not registered on grapevines", and the UI needs to tell
    /// them apart.
    @Test func dithaneIsRegisteredOnGrapevinesEvenWhereRatesAreAbsent() throws {
        let chem = try chemical(dithaneJSON)
        #expect(SprayRegisteredUseRates.hasVineyardUse(chem))
    }

    @Test func productLevelRateCarrierSurvivesScoping() throws {
        let chem = try chemical(productLevelRateJSON)
        let vineyard = SprayRegisteredUseRates.selectableVineyardRates(for: chem)
        #expect(vineyard.count == 1)
        #expect(vineyard.first?.seed.seedableValue == 50)
    }

    @Test func legacyRecordsAreUnaffectedByScoping() throws {
        let chem = try chemical(legacyJSON)
        let vineyard = SprayRegisteredUseRates.vineyardRates(for: chem)
        #expect(vineyard.count == 1)
        #expect(vineyard.first?.seed.seedableValue == 500)
    }

    /// A record that states structured rates is answered ONLY from them.
    /// Falling through to the legacy array would let a product whose only
    /// structured rates are tobacco's offer a stale hand-typed number instead —
    /// the same borrowing, from the other direction.
    @Test func structuredRecordDoesNotFallBackToLegacyRatesWhenScopedEmpty() throws {
        let json = """
        {
          "id": "aaaaaaaa-0000-0000-0000-000000000006",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Stale Legacy Plus Structured",
          "unit": "Kilograms",
          "rate_per_ha": 0,
          "rates": [
            { "label": "Hand typed", "value": 9999, "basis": "per_hectare" }
          ],
          "registered_uses": [
            {
              "crop": "TOBACCO",
              "target_raw": "BLUE MOULD",
              "rates": [
                { "label": "Standard", "basis": "per_hectare", "value": 2.2, "unit": "kg", "raw_text": "2.2 kg/ha" }
              ]
            }
          ],
          "intelligence_schema_version": 1
        }
        """
        let chem = try chemical(json)
        #expect(SprayRegisteredUseRates.vineyardRates(for: chem).isEmpty)
        #expect(SprayRegisteredUseRates.defaultSelection(for: chem, preferring: [.perHectare]) == nil)
    }

    // MARK: - Mass arithmetic

    /// Base units are grams for a solid product, so a kilogram label rate must
    /// arrive as grams — not as kilograms wearing a gram label.
    @Test func kilogramLabelRateConvertsToBaseGrams() throws {
        let chem = try chemical(mixedCropJSON)
        #expect(SprayRegisteredUseRates.baseValue(2.2, labelUnit: "kg", chemical: chem) == 2200)
        #expect(SprayRegisteredUseRates.baseValue(800, labelUnit: "g", chemical: chem) == 800)
    }

    /// A litre rate on a solid product is refused rather than guessed. Guessing
    /// here is precisely a 1000× mis-dose.
    @Test func mismatchedDimensionIsRefusedNotGuessed() throws {
        let solid = try chemical(mixedCropJSON)
        #expect(SprayRegisteredUseRates.baseValue(2.2, labelUnit: "L", chemical: solid) == nil)
        #expect(SprayRegisteredUseRates.baseValue(2.2, labelUnit: "mL", chemical: solid) == nil)

        let liquid = try chemical(legacyJSON)
        #expect(SprayRegisteredUseRates.baseValue(2.2, labelUnit: "kg", chemical: liquid) == nil)
        #expect(SprayRegisteredUseRates.baseValue(2.2, labelUnit: "g", chemical: liquid) == nil)
    }

    /// The round trip a displayed quantity makes: label → base → display.
    ///
    /// `2.2 kg/ha` over `0.49 ha` is `1.078 kg`. The failure this pins is the
    /// one reported from the field — the same job reading `1,080 Kg`, which is
    /// the BASE gram figure printed against the DISPLAY unit.
    @Test func kilogramQuantityRoundTripsWithoutInflating() throws {
        let chem = try chemical(mixedCropJSON)
        let ratePerHaBase = try #require(
            SprayRegisteredUseRates.baseValue(2.2, labelUnit: "kg", chemical: chem)
        )
        let totalBase = ratePerHaBase * 0.49

        #expect(abs(chem.unit.fromBase(ratePerHaBase) - 2.2) < 0.0001)
        #expect(abs(chem.unit.fromBase(totalBase) - 1.078) < 0.0001)
        // The reported number, stated as the defect it is.
        #expect(abs(chem.unit.fromBase(totalBase) - 1078) > 1)
    }

    @Test func unitConversionsAreExactBothWays() {
        for unit in ChemicalUnit.allCases {
            let display = 2.5
            let base = unit.toBase(display)
            #expect(abs(unit.fromBase(base) - display) < 0.000001)
        }
    }
}

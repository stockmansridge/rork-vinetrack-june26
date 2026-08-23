import Foundation
import Testing
@testable import VineTrack

/// Regressions for the Spray Calculator / chemical-lookup UX pass.
///
/// These assert the RULES rather than the pixels. A SwiftUI body cannot be
/// meaningfully asserted in a unit test, so anything that would only be
/// testable by rendering is instead expressed as a value the view is forced to
/// read — which is also what stops the rule and the view drifting apart.
struct SprayCalculatorUXPassTests {

    private func chemical(_ json: String) throws -> SavedChemical {
        try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    // MARK: - P3: one lookup notice, one wording

    /// The notice exists as a single shared constant.
    ///
    /// Five screens start the same slow lookup. The moment each owns its own
    /// sentence they drift, and the screen that drifts into silence is where an
    /// operator backs out and cancels a request that was about to succeed.
    @Test func lookupNoticeStatesDurationAndAsksTheOperatorToStay() {
        let text = ChemicalLookupDurationNotice.primaryText
        #expect(text.contains("a few minutes"))
        #expect(text.contains("Keep this screen open"))
        // Not framed as a fault: nothing has gone wrong.
        #expect(!text.lowercased().contains("error"))
        #expect(!text.lowercased().contains("failed"))
        #expect(!text.lowercased().contains("problem"))
    }

    @Test func repeatHintIsSeparateSoItCanBeOmitted() {
        #expect(ChemicalLookupDurationNotice.repeatHintText.contains("faster"))
        #expect(!ChemicalLookupDurationNotice.primaryText
            .contains(ChemicalLookupDurationNotice.repeatHintText))
    }

    // MARK: - P4: two deadlines, not one

    /// Discovery and full resolution are different jobs with different costs.
    /// Collapsing them onto one number either makes search feel broken or makes
    /// resolution impossible; the Dithane timeout was the second of those.
    @Test func fullDetailLookupHasItsOwnLongerDeadline() {
        #expect(ChemicalInfoService.searchTimeout == 30)
        #expect(ChemicalInfoService.structuredLookupTimeout == 180)
        #expect(ChemicalInfoService.structuredLookupTimeout
            > ChemicalInfoService.searchTimeout)
    }

    /// A timeout is its own outcome, distinguishable from a network fault, so
    /// the UI can offer "try again" instead of "check your connection".
    @Test func timeoutIsADistinctErrorWithItsOwnGuidance() {
        let message = ChemicalLookupError.timedOut.errorDescription ?? ""
        #expect(!message.isEmpty)
        #expect(message.lowercased().contains("longer than expected"))
    }

    // MARK: - P6: the 100 m recommendation rule

    /// 100 m is recommended ONLY where the label states a per-100 L grapevine
    /// rate. That rate is what carries concentration; a per-hectare rate does
    /// not, so deriving a per-100 L figure from one invents a label rate the
    /// regulator never approved.
    @Test func genuinePer100LVineyardRateExists() throws {
        let chem = try chemical("""
        {
          "id": "bbbbbbbb-0000-0000-0000-000000000001",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Dilute Fungicide",
          "unit": "Kilograms",
          "rate_per_ha": 0,
          "rates": [],
          "registered_uses": [
            {
              "crop": "GRAPEVINE",
              "target_raw": "POWDERY MILDEW",
              "rates": [
                { "label": "Dilute", "basis": "per_100_litres", "value": 200,
                  "unit": "g", "raw_text": "200 g/100 L" }
              ]
            }
          ],
          "intelligence_schema_version": 1
        }
        """)
        let rates = SprayRegisteredUseRates.selectableVineyardRates(for: chem)
        #expect(rates.contains { $0.basis == .per100Litres })
        #expect(!rates.contains { $0.basis == .perHectare })
    }

    /// The mirror case: a per-ha-only label must leave Per ha as the answer.
    @Test func perHectareOnlyVineyardRateOffersNoPer100L() throws {
        let chem = try chemical("""
        {
          "id": "bbbbbbbb-0000-0000-0000-000000000002",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Banded Herbicide",
          "unit": "Litres",
          "rate_per_ha": 0,
          "rates": [],
          "registered_uses": [
            {
              "crop": "GRAPEVINE",
              "target_raw": "ANNUAL WEEDS",
              "rates": [
                { "label": "Standard", "basis": "per_hectare", "value": 2,
                  "unit": "L", "raw_text": "2 L/ha" }
              ]
            }
          ],
          "intelligence_schema_version": 1
        }
        """)
        let rates = SprayRegisteredUseRates.selectableVineyardRates(for: chem)
        #expect(rates.contains { $0.basis == .perHectare })
        #expect(!rates.contains { $0.basis == .per100Litres })
    }

    /// A tobacco per-100 L rate must not make 100 m look available for a
    /// grapevine spray. The basis control reads the SCOPED list precisely so
    /// the P1 fix cannot be undone by the P6 redesign.
    @Test func nonVineyardPer100LRateDoesNotEnableHundredMetres() throws {
        let chem = try chemical("""
        {
          "id": "bbbbbbbb-0000-0000-0000-000000000003",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Other Crop Dilute",
          "unit": "Kilograms",
          "rate_per_ha": 0,
          "rates": [],
          "registered_uses": [
            {
              "crop": "TOBACCO",
              "target_raw": "BLUE MOULD",
              "rates": [
                { "label": "Dilute", "basis": "per_100_litres", "value": 200,
                  "unit": "g", "raw_text": "200 g/100 L" }
              ]
            }
          ],
          "intelligence_schema_version": 1
        }
        """)
        let rates = SprayRegisteredUseRates.selectableVineyardRates(for: chem)
        #expect(rates.isEmpty)
    }

    // MARK: - P7: the canopy engine still drives L/100 m

    /// The canopy → litres/100 m → litres/ha chain is the existing authority.
    /// Changing canopy size must change the carrier volume, or the 100 m
    /// workflow is decorative.
    @Test func canopySizeChangesCarrierVolume() {
        let small = CanopyWaterRate.rate(
            size: .small, density: .low, rowSpacingMetres: 3.0
        )
        let full = CanopyWaterRate.rate(
            size: .full, density: .low, rowSpacingMetres: 3.0
        )
        #expect(small.litresPer100m == 10)
        #expect(full.litresPer100m == 45)
        #expect(full.litresPerHa > small.litresPerHa)
    }

    /// Density is a second, independent axis — not a relabelling of size.
    @Test func canopyDensityChangesCarrierVolumeIndependently() {
        let low = CanopyWaterRate.litresPer100m(size: .medium, density: .low)
        let high = CanopyWaterRate.litresPer100m(size: .medium, density: .high)
        #expect(low == 20)
        #expect(high == 40)
    }

    /// Row spacing converts L/100 m into L/ha. 40 L/100 m at 3 m spacing is
    /// 40 × (10000 / 3) / 100 = 1333.33 L/ha.
    @Test func rowSpacingDerivesHectareVolumeFromRowVolume() {
        let perHa = CanopyWaterRate.litresPerHa(
            litresPer100m: 40, rowSpacingMetres: 3.0
        )
        #expect(abs(perHa - 1333.333) < 0.01)
        // Narrower rows mean more row per hectare, so more litres per hectare.
        let narrower = CanopyWaterRate.litresPerHa(
            litresPer100m: 40, rowSpacingMetres: 2.0
        )
        #expect(narrower > perHa)
    }

    @Test func zeroRowSpacingYieldsNoVolumeRatherThanInfinity() {
        #expect(CanopyWaterRate.litresPerHa(litresPer100m: 40, rowSpacingMetres: 0) == 0)
    }

    // MARK: - P10: the tank handoff crosses the unit boundary

    /// The defect this pins: Tank Mixing stores base units and must display the
    /// product's own unit.
    ///
    /// `2.2 kg/ha × 0.49 ha = 1.078 kg`, held internally as `1078 g`. The tank
    /// screen must read ~1.08 Kg. It must NEVER read 1078 against a Kg label —
    /// which is exactly what the raw binding produced.
    @Test func solidTankQuantityDisplaysInKilogramsNotGrams() {
        let chem = SprayChemical(
            name: "Dithane Rainshield NeoTec",
            volumePerTank: 1078,      // base grams
            ratePerHa: 2200,          // base grams per hectare
            unit: .kilograms
        )
        #expect(abs(chem.displayVolume - 1.078) < 0.0001)
        #expect(abs(chem.displayRate - 2.2) < 0.0001)
        // The reported readings, stated as the defects they are.
        #expect(abs(chem.displayVolume - 1078) > 1)
        #expect(abs(chem.displayRate - 2200) > 1)
        #expect(chem.unitLabel == "Kg")
    }

    /// The liquid regression: litres are already the base unit, so the same
    /// boundary must be a no-op rather than a second conversion.
    ///
    /// `2 L/ha × 0.49 ha = 0.98 L`.
    @Test func liquidTankQuantityIsUnchangedByTheBoundary() {
        let chem = SprayChemical(
            name: "Liquid Fungicide",
            volumePerTank: 0.98,
            ratePerHa: 2.0,
            unit: .litres
        )
        #expect(abs(chem.displayVolume - 0.98) < 0.0001)
        #expect(abs(chem.displayRate - 2.0) < 0.0001)
        #expect(chem.unitLabel == "L")
    }

    /// A per-100 L product carries its rate in the other field, and that field
    /// crosses the same boundary.
    @Test func per100LitreRateAlsoCrossesTheUnitBoundary() {
        let chem = SprayChemical(
            name: "Dilute Product",
            volumePerTank: 400,
            ratePer100L: 200,   // base grams per 100 L
            unit: .kilograms
        )
        #expect(abs(chem.displayRatePer100L - 0.2) < 0.0001)
        #expect(abs(chem.displayVolume - 0.4) < 0.0001)
    }

    /// Editing a tank quantity must round-trip: what the operator types in Kg
    /// is stored as grams and reads back as the same Kg figure.
    @Test func editingATankQuantityRoundTripsThroughBaseUnits() {
        let unit = ChemicalUnit.kilograms
        let typed = 1.08
        let stored = unit.toBase(typed)
        #expect(abs(stored - 1080) < 0.0001)
        #expect(abs(unit.fromBase(stored) - typed) < 0.0001)
    }

    /// Cost is computed against the BASE quantity, so the display fix must not
    /// have moved the cost basis.
    @Test func tankCostStillUsesBaseQuantity() {
        let chem = SprayChemical(
            name: "Dithane",
            volumePerTank: 1078,
            costPerUnit: 0.02,   // per base gram
            unit: .kilograms
        )
        #expect(abs(chem.costPerTank - 21.56) < 0.0001)
    }
}

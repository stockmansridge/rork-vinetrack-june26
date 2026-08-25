import Foundation
import Testing

@testable import VineTrack

/// Task §4/§5 — multiple independent label rates, and the identity fixes that
/// make them survivable in a list.
///
/// A grapevine label reached the app as `"2 L / 100 L 3 L / 100 L 3 L / 100 L…"`
/// because the server collapsed every same-basis rate into one unusable
/// entry. Repairing that on the server means the app now routinely receives
/// several rates per use — which turned two latent identity collisions into
/// everyday conditions.
struct ChemicalMultiRateTests {

    private func decodeUse(_ json: String) throws -> ChemicalRegisteredUse {
        try JSONDecoder().decode(ChemicalRegisteredUse.self, from: Data(json.utf8))
    }

    // MARK: - Decoding the multi-rate contract

    @Test("Multiple /100 L rates decode as independent records with their conditions")
    func multipleVolumeRatesDecode() throws {
        let use = try decodeUse("""
        {
          "crop": "Grapevines",
          "target_raw": "Powdery mildew",
          "rates": [
            { "label": "Dilute spraying", "basis": "per_100_litres",
              "value": 2, "unit": "L", "raw_text": "Dilute spraying: 2 L/100 L" },
            { "label": "Concentrate spraying", "basis": "per_100_litres",
              "value": 3, "unit": "L", "raw_text": "Concentrate spraying: 3 L/100 L" }
          ]
        }
        """)
        #expect(use.rates.count == 2)
        #expect(use.rates.map(\.value) == [2, 3])
        #expect(use.rates.map(\.label) == ["Dilute spraying", "Concentrate spraying"])
        #expect(use.ratesPer100L.count == 2)
        #expect(use.ratesPerHectare.isEmpty)
    }

    @Test("A /100 L rate and a /ha rate coexist, both retained")
    func bothBasesCoexist() throws {
        let use = try decodeUse("""
        {
          "crop": "Grapevines",
          "target_raw": "Grapevine scale",
          "rates": [
            { "label": "", "basis": "per_100_litres", "value": 2, "unit": "L" },
            { "label": "", "basis": "per_hectare", "value": 4, "unit": "L" }
          ]
        }
        """)
        #expect(use.hasBothRateBases)
        #expect(use.ratesPer100L.first?.value == 2)
        #expect(use.ratesPerHectare.first?.value == 4)
        // Neither is discarded, and neither is derived from the other.
        #expect(use.rates.count == 2)
    }

    @Test("Range rates keep both bounds and never collapse to one value")
    func rangesSurvive() throws {
        let use = try decodeUse("""
        {
          "crop": "Grapevines", "target_raw": "Botrytis",
          "rates": [
            { "label": "", "basis": "range_per_100_litres",
              "min_value": 150, "max_value": 200, "unit": "mL" }
          ]
        }
        """)
        let rate = try #require(use.rates.first)
        #expect(rate.minValue == 150)
        #expect(rate.maxValue == 200)
        #expect(rate.value == nil)
        // A range proposes its LOW end, so a suggestion can never inflate a dose.
        #expect(rate.proposedValue == 150)
    }

    @Test("The ambiguity flag decodes, and its absence means the association is sound")
    func ambiguityFlagDecodes() throws {
        let ambiguous = try decodeUse("""
        {
          "crop": "Grapevines", "target_raw": "Scale",
          "rates": [
            { "label": "", "basis": "per_100_litres", "value": 2, "unit": "L",
              "condition_ambiguous": true },
            { "label": "", "basis": "per_100_litres", "value": 3, "unit": "L",
              "condition_ambiguous": true }
          ]
        }
        """)
        #expect(ambiguous.hasAmbiguousRateCondition)

        // A record written before the multi-rate contract existed.
        let legacy = try decodeUse("""
        {
          "crop": "Grapevines", "target_raw": "Scale",
          "rates": [{ "label": "", "basis": "per_100_litres", "value": 2, "unit": "L" }]
        }
        """)
        #expect(!legacy.hasAmbiguousRateCondition)
    }

    // MARK: - /100 L preference (presentation, not extraction)

    @Test("/100 L leads when both bases exist, and /ha is still available")
    func volumeIsPreferred() throws {
        let use = try decodeUse("""
        {
          "crop": "Grapevines", "target_raw": "Grapevine scale",
          "rates": [
            { "label": "", "basis": "per_hectare", "value": 4, "unit": "L" },
            { "label": "", "basis": "per_100_litres", "value": 2, "unit": "L" }
          ]
        }
        """)
        // Preference is applied at the point of use…
        #expect(use.preferredRates.map(\.value) == [2])
        // …and never costs the hectare rate.
        #expect(use.ratesPerHectare.map(\.value) == [4])
        #expect(use.rates.count == 2)
    }

    @Test("A hectare-only label leads with hectare — nothing is invented")
    func hectareOnlyIsHonest() throws {
        let use = try decodeUse("""
        {
          "crop": "Grapevines", "target_raw": "Weeds",
          "rates": [{ "label": "", "basis": "per_hectare", "value": 4, "unit": "L" }]
        }
        """)
        #expect(use.ratesPer100L.isEmpty, "a /100 L rate must never be manufactured")
        #expect(use.preferredRates.map(\.value) == [4])
        #expect(!use.hasBothRateBases)
    }

    @Test("One clear rate is auto-usable; several or ambiguous ones are not")
    func autoSelectionIsConservative() throws {
        let single = try decodeUse("""
        { "crop": "Grapevines", "target_raw": "Scale",
          "rates": [{ "label": "", "basis": "per_100_litres", "value": 2, "unit": "L" }] }
        """)
        #expect(single.unambiguousPreferredRate?.value == 2)

        // Two candidates on the preferred basis — the operator chooses.
        let several = try decodeUse("""
        { "crop": "Grapevines", "target_raw": "Scale", "rates": [
          { "label": "Dilute", "basis": "per_100_litres", "value": 2, "unit": "L" },
          { "label": "Concentrate", "basis": "per_100_litres", "value": 3, "unit": "L" }
        ] }
        """)
        #expect(several.unambiguousPreferredRate == nil)

        // One candidate, but the label never proved when it applies.
        let ambiguous = try decodeUse("""
        { "crop": "Grapevines", "target_raw": "Scale", "rates": [
          { "label": "", "basis": "per_100_litres", "value": 2, "unit": "L",
            "condition_ambiguous": true }
        ] }
        """)
        #expect(ambiguous.unambiguousPreferredRate == nil)
    }

    @Test("Verbatim-only wording is not a usable rate")
    func otherBasisIsNotUsable() throws {
        let use = try decodeUse("""
        { "crop": "Grapevines", "target_raw": "Scale", "rates": [
          { "label": "", "basis": "other", "unit": "",
            "raw_text": "Apply as directed by an agronomist" }
        ] }
        """)
        // The save contract needs this: registered on grapevines, but with no
        // rate any calculation could run.
        #expect(!use.hasUsableRate)
        #expect(use.ratesOtherBasis.count == 1)
        #expect(use.rates.first?.displayRate == "Apply as directed by an agronomist")
    }

    // MARK: - ChemicalLabelRate identity

    @Test("Rates differing only by UNIT no longer collide")
    func rateIdDistinguishesUnit() {
        let litres = ChemicalLabelRate(basis: .per100Litres, value: 2, unit: "L")
        let kilos = ChemicalLabelRate(basis: .per100Litres, value: 2, unit: "kg")
        #expect(litres.id != kilos.id)
    }

    @Test("Ranges sharing a lower bound no longer collide")
    func rateIdDistinguishesUpperBound() {
        // The old id used `minValue ?? value ?? 0` and ignored the upper bound.
        let narrow = ChemicalLabelRate(basis: .rangePerHectare, minValue: 1, maxValue: 2, unit: "L")
        let wide = ChemicalLabelRate(basis: .rangePerHectare, minValue: 1, maxValue: 5, unit: "L")
        #expect(narrow.id != wide.id)
    }

    @Test("The same number under different conditions no longer collides")
    func rateIdDistinguishesCondition() {
        let dilute = ChemicalLabelRate(label: "Dilute", basis: .per100Litres, value: 3, unit: "L")
        let concentrate = ChemicalLabelRate(
            label: "Concentrate", basis: .per100Litres, value: 3, unit: "L"
        )
        #expect(dilute.id != concentrate.id)
    }

    @Test("Ambiguity is part of identity")
    func rateIdDistinguishesAmbiguity() {
        let known = ChemicalLabelRate(basis: .per100Litres, value: 2, unit: "L")
        let unproven = ChemicalLabelRate(
            basis: .per100Litres, value: 2, unit: "L", conditionIsAmbiguous: true
        )
        #expect(known.id != unproven.id)
    }

    @Test("Identity is content-addressed, so it survives reordering")
    func rateIdIsStable() {
        let rate = ChemicalLabelRate(label: "Dilute", basis: .per100Litres, value: 2, unit: "L")
        let same = ChemicalLabelRate(label: "Dilute", basis: .per100Litres, value: 2, unit: "L")
        // A positional id would change when a sibling was added or removed,
        // breaking selection and animation for a rate that did not change.
        #expect(rate.id == same.id)
    }

    @Test("Every rate in a realistic multi-rate use has a distinct id")
    func multiRateIdsAreUnique() throws {
        let use = try decodeUse("""
        { "crop": "Grapevines", "target_raw": "Grapevine scale", "rates": [
          { "label": "Dilute spraying", "basis": "per_100_litres", "value": 2, "unit": "L" },
          { "label": "Concentrate spraying", "basis": "per_100_litres", "value": 3, "unit": "L" },
          { "label": "Airblast", "basis": "per_hectare", "value": 4, "unit": "L" },
          { "label": "", "basis": "range_per_hectare",
            "min_value": 4, "max_value": 6, "unit": "L" }
        ] }
        """)
        let ids = Set(use.rates.map(\.id))
        #expect(ids.count == use.rates.count, "colliding ids drop rows from a SwiftUI ForEach")
    }

    // MARK: - ChemicalRegisteredUse identity

    @Test("Same crop and target under different conditional rates no longer collide")
    func useIdDistinguishesRates() {
        let early = ChemicalRegisteredUse(
            crop: "Grapevines",
            targetRaw: "Powdery mildew",
            rates: [ChemicalLabelRate(label: "Early", basis: .per100Litres, value: 2, unit: "L")]
        )
        let late = ChemicalRegisteredUse(
            crop: "Grapevines",
            targetRaw: "Powdery mildew",
            rates: [ChemicalLabelRate(label: "Late", basis: .per100Litres, value: 3, unit: "L")]
        )
        // The old id was `crop|targetRaw` — these were one row.
        #expect(early.id != late.id)
    }

    @Test("Same crop and target with different withholding periods no longer collide")
    func useIdDistinguishesPeriods() {
        let short = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Botrytis", withholdingPeriodDays: 14
        )
        let long = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Botrytis", withholdingPeriodDays: 28
        )
        #expect(short.id != long.id)

        let noRei = ChemicalRegisteredUse(crop: "Grapevines", targetRaw: "Botrytis")
        let withRei = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Botrytis", reEntryPeriodHours: 24
        )
        #expect(noRei.id != withRei.id)
    }

    @Test("Same crop and target with different restrictions no longer collide")
    func useIdDistinguishesRestrictions() {
        let dormant = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Scale",
            restrictions: "Apply while vines are fully dormant."
        )
        let postHarvest = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Scale",
            restrictions: "Apply post-harvest only."
        )
        #expect(dormant.id != postHarvest.id)
    }

    @Test("An identical use produces an identical id")
    func useIdIsStable() {
        let make = {
            ChemicalRegisteredUse(
                crop: "Grapevines",
                targetRaw: "Powdery mildew",
                rates: [ChemicalLabelRate(label: "Dilute", basis: .per100Litres, value: 2, unit: "L")],
                withholdingPeriodDays: 14,
                restrictions: "Do not graze."
            )
        }
        #expect(make().id == make().id)
    }

    // MARK: - Collection helpers

    @Test("Rate collections partition without losing anything")
    func collectionHelpers() throws {
        let uses = [
            try decodeUse("""
            { "crop": "Grapevines", "target_raw": "Scale", "rates": [
              { "label": "Dilute", "basis": "per_100_litres", "value": 2, "unit": "L" },
              { "label": "Airblast", "basis": "per_hectare", "value": 4, "unit": "L" }
            ] }
            """),
            try decodeUse("""
            { "crop": "Apples", "target_raw": "Codling moth", "rates": [
              { "label": "", "basis": "per_100_litres", "value": 9, "unit": "L" }
            ] }
            """)
        ]
        #expect(uses.allRatesPer100L.count == 2)
        #expect(uses.allRatesPerHectare.count == 1)
        #expect(uses.viticultural.count == 1)
        #expect(uses.hasUsableViticulturalRate)

        // Both bases are reported, neither is dropped.
        #expect(uses.rateBases.contains(.per100Litres))
        #expect(uses.rateBases.contains(.perHectare))
    }

    @Test("A grapevine use with only verbatim wording reports no usable rate")
    func viticulturalUsabilityIsHonest() throws {
        let uses = [
            try decodeUse("""
            { "crop": "Grapevines", "target_raw": "Scale", "rates": [
              { "label": "", "basis": "other", "unit": "", "raw_text": "As directed" }
            ] }
            """)
        ]
        // This is the case the save contract must refuse to treat as ready.
        #expect(!uses.hasUsableViticulturalRate)
    }
}

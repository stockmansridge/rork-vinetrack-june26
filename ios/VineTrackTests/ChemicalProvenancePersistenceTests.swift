import Foundation
import Testing
@testable import VineTrack

/// P2B — provenance preservation through the Saved Chemical intelligence blob.
///
/// The server records `field_provenance` (top level) and per-use `provenance`
/// maps. iOS must decode them, persist them, and re-encode them without loss —
/// while records saved before provenance existed keep decoding with none, and
/// nothing on device ever derives, upgrades or invents a tier.
struct ChemicalProvenancePersistenceTests {

    // MARK: - Helpers

    private func decodeLookup(_ json: String) throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    private func roundTrip(_ chemical: SavedChemical) throws -> SavedChemical {
        try JSONDecoder().decode(SavedChemical.self, from: JSONEncoder().encode(chemical))
    }

    // MARK: - Sprayseal 80160: label-backed rate + WHP survive save/reopen

    @Test func spraysealKeepsManufacturerLabelProvenanceThroughSave() throws {
        let lookup = try decodeLookup(
            """
            {
              "product_name": "Sprayseal",
              "product_category": "other",
              "registered_uses": [
                {
                  "crop": "All crops",
                  "target_raw": "Pruning wound dressing",
                  "rates": [
                    { "label": "General", "basis": "per_100_litres", "value": 100, "unit": "mL" }
                  ],
                  "withholding_period_days": 0,
                  "restrictions": "NOT REQUIRED WHEN USED AS DIRECTED.",
                  "provenance": {
                    "claim": "manufacturer_label",
                    "rates": "manufacturer_label",
                    "withholding_period": "manufacturer_label",
                    "restrictions": "manufacturer_label"
                  }
                }
              ],
              "field_provenance": {
                "registered_uses": "manufacturer_label",
                "label_rates": "manufacturer_label",
                "withholding_periods": "manufacturer_label",
                "restrictions": "manufacturer_label",
                "registration": "official_register"
              },
              "schema_version": 1,
              "activity_group_table_version": 1
            }
            """
        )
        let intel = lookup.intelligence()
        #expect(intel.fieldProvenance?["label_rates"] == "manufacturer_label")
        #expect(intel.fieldProvenance?["withholding_periods"] == "manufacturer_label")
        #expect(intel.registeredUses.first?.provenance?["rates"] == "manufacturer_label")

        let saved = SavedChemical(name: "Sprayseal", chemicalIntelligence: intel)
        let reopened = try roundTrip(saved)
        let use = try #require(reopened.chemicalIntelligence?.registeredUses.first)

        #expect(use.withholdingPeriodDays == 0)
        #expect(use.provenance?["rates"] == "manufacturer_label")
        #expect(use.provenance?["withholding_period"] == "manufacturer_label")
        #expect(use.provenance?["claim"] == "manufacturer_label")
        #expect(reopened.chemicalIntelligence?.fieldProvenance?["label_rates"] == "manufacturer_label")
        #expect(reopened.chemicalIntelligence?.fieldProvenance?["registration"] == "official_register")
    }

    // MARK: - Custodia Forte: per-use provenance retained, values unchanged

    @Test func custodiaKeepsPerUseProvenanceThroughSave() throws {
        let labelProvenance = [
            "claim": "manufacturer_label",
            "rates": "manufacturer_label",
            "withholding_period": "manufacturer_label",
            "re_entry": "manufacturer_label",
            "restrictions": "manufacturer_label",
        ]
        let lookup = try decodeLookup(
            """
            {
              "product_name": "Custodia Forte",
              "product_category": "fungicide",
              "registered_uses": [
                {
                  "crop": "Grapes",
                  "target_raw": "Powdery mildew",
                  "rates": [
                    { "label": "", "basis": "per_100_litres", "value": 50, "unit": "mL" }
                  ],
                  "withholding_period_days": 28,
                  "re_entry_period_hours": 24,
                  "restrictions": "Do not apply more than 2 consecutive sprays.",
                  "provenance": {
                    "claim": "manufacturer_label",
                    "rates": "manufacturer_label",
                    "withholding_period": "manufacturer_label",
                    "re_entry": "manufacturer_label",
                    "restrictions": "manufacturer_label"
                  }
                },
                {
                  "crop": "Almonds",
                  "target_raw": "Rust",
                  "withholding_period_days": 14,
                  "provenance": {
                    "claim": "manufacturer_label",
                    "withholding_period": "ai_interpretation"
                  }
                }
              ]
            }
            """
        )
        let saved = SavedChemical(name: "Custodia Forte", chemicalIntelligence: lookup.intelligence())
        let reopened = try roundTrip(saved)
        let uses = try #require(reopened.chemicalIntelligence?.registeredUses)

        #expect(uses.count == 2)
        #expect(uses[0].withholdingPeriodDays == 28)
        #expect(uses[0].provenance == labelProvenance)
        // The AI-carried WHP on the second claim stays exactly what it was:
        // present, and honestly non-authoritative.
        #expect(uses[1].withholdingPeriodDays == 14)
        #expect(uses[1].provenance?["withholding_period"] == "ai_interpretation")
    }

    // MARK: - Prosaro: basis "other" stays reference-only with its source

    @Test func otherBasisRateKeepsSourceButStaysReferenceOnly() throws {
        let lookup = try decodeLookup(
            """
            {
              "product_name": "Prosaro",
              "registered_uses": [
                {
                  "crop": "Grapes",
                  "target_raw": "Botrytis",
                  "rates": [
                    { "label": "Directed application", "basis": "other", "unit": "", "raw_text": "Refer to label: mL per 100 m of row" }
                  ],
                  "provenance": { "claim": "manufacturer_label", "rates": "manufacturer_label" }
                }
              ]
            }
            """
        )
        let saved = SavedChemical(name: "Prosaro", chemicalIntelligence: lookup.intelligence())
        let reopened = try roundTrip(saved)
        let use = try #require(reopened.chemicalIntelligence?.registeredUses.first)
        let rate = try #require(use.rates.first)

        #expect(use.provenance?["rates"] == "manufacturer_label")
        #expect(rate.basis == .other)
        #expect(rate.value == nil)
        #expect(rate.proposedValue == nil)
        #expect(rate.displayRate == "Refer to label: mL per 100 m of row")
        #expect(rate.basis.compatibleProductRateBases.isEmpty)
    }

    // MARK: - Legacy records: no provenance in, none invented out

    @Test func legacyRecordWithoutProvenanceDecodesAndReencodesClean() throws {
        let intel = try JSONDecoder().decode(
            ChemicalIntelligence.self,
            from: Data(
                """
                {
                  "active_ingredients": [],
                  "registered_uses": [
                    { "crop": "Grapes", "target_raw": "Powdery mildew", "withholding_period_days": 21 }
                  ],
                  "product_category": "fungicide"
                }
                """.utf8
            )
        )
        #expect(intel.fieldProvenance == nil)
        #expect(intel.registeredUses.first?.provenance == nil)

        let reopened = try roundTrip(SavedChemical(name: "Legacy", chemicalIntelligence: intel))
        #expect(reopened.chemicalIntelligence?.fieldProvenance == nil)
        #expect(reopened.chemicalIntelligence?.registeredUses.first?.provenance == nil)
        #expect(reopened.chemicalIntelligence?.registeredUses.first?.withholdingPeriodDays == 21)

        // The blob must not grow fabricated provenance keys on re-save.
        let encoded = String(decoding: try JSONEncoder().encode(reopened), as: UTF8.self)
        #expect(!encoded.contains("field_provenance"))
        #expect(!encoded.contains("\"provenance\""))
    }

    // MARK: - Tolerance and losslessness

    @Test func unknownTierStringsSurviveVerbatimButNeverReadAsAuthority() throws {
        let use = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Downy mildew",
            rates: [ChemicalLabelRate(basis: .perHectare, value: 1.5, unit: "L")],
            provenance: ["rates": "future_evidence_tier"]
        )
        let saved = SavedChemical(
            name: "Future",
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [use])
        )
        let reopened = try roundTrip(saved)
        #expect(
            reopened.chemicalIntelligence?.registeredUses.first?.provenance?["rates"]
                == "future_evidence_tier"
        )
        #expect(ChemicalProvenanceTier.authoritative(fromRaw: "future_evidence_tier") == nil)
        #expect([use].uniformRatesBadge == nil)
    }

    @Test func malformedProvenanceDegradesToNilWithoutLosingTheRecord() throws {
        let use = try JSONDecoder().decode(
            ChemicalRegisteredUse.self,
            from: Data(
                #"{ "crop": "Grapes", "target_raw": "Botrytis", "provenance": 42 }"#.utf8
            )
        )
        #expect(use.crop == "Grapes")
        #expect(use.provenance == nil)

        let intel = try JSONDecoder().decode(
            ChemicalIntelligence.self,
            from: Data(#"{ "registered_uses": [], "field_provenance": "nope" }"#.utf8)
        )
        #expect(intel.fieldProvenance == nil)
    }

    @Test func unresolvedProvenanceStaysUnresolved() throws {
        let intel = ChemicalIntelligence(
            registeredUses: [],
            fieldProvenance: ["withholding_periods": "unresolved", "label_rates": "ai_interpretation"]
        )
        let reopened = try roundTrip(SavedChemical(name: "Gap", chemicalIntelligence: intel))
        #expect(reopened.chemicalIntelligence?.fieldProvenance?["withholding_periods"] == "unresolved")
        #expect(reopened.chemicalIntelligence?.fieldProvenance?["label_rates"] == "ai_interpretation")
        // Neither tier can ever present as authority.
        #expect(ChemicalProvenanceTier.authoritative(fromRaw: "unresolved") == nil)
        #expect(ChemicalProvenanceTier.authoritative(fromRaw: "ai_interpretation") == nil)
    }

    // MARK: - Display plan: lightweight, honest, never inferred

    @Test func uniformLabelBackedFactsShowOneHeaderBadge() {
        let use = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Powdery mildew",
            withholdingPeriodDays: 28,
            restrictions: "Do not graze.",
            provenance: [
                "withholding_period": "manufacturer_label",
                "restrictions": "manufacturer_label",
            ]
        )
        #expect(use.provenancePlan == .uniform(.manufacturerLabel))
        #expect(use.provenancePlan.headerBadge == .authoritative(.manufacturerLabel))
        #expect(use.provenancePlan.badge(for: .withholdingPeriod) == nil)
    }

    @Test func mixedTrustShowsPerFactBadgesWithUnresolved() {
        let use = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Powdery mildew",
            withholdingPeriodDays: 14,
            restrictions: "Do not graze.",
            provenance: [
                "withholding_period": "ai_interpretation",
                "restrictions": "manufacturer_label",
            ]
        )
        let plan = use.provenancePlan
        #expect(plan.headerBadge == nil)
        #expect(plan.badge(for: .withholdingPeriod) == .unresolved)
        #expect(plan.badge(for: .restrictions) == .authoritative(.manufacturerLabel))
    }

    @Test func recordsWithoutAuthorityShowNothing() {
        // No provenance at all (legacy / manual): nothing to show.
        let legacy = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Botrytis",
            withholdingPeriodDays: 7
        )
        #expect(legacy.provenancePlan == .hidden)

        // All-AI card: the verification banner already says unverified;
        // repeating "Unresolved" on every row is clutter, not information.
        let ai = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Botrytis",
            withholdingPeriodDays: 7,
            restrictions: "Check label.",
            provenance: [
                "withholding_period": "ai_interpretation",
                "restrictions": "ai_interpretation",
            ]
        )
        #expect(ai.provenancePlan == .hidden)

        // Provenance present but no displayed facts: nothing to badge.
        let bare = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Botrytis",
            provenance: ["claim": "manufacturer_label"]
        )
        #expect(bare.provenancePlan == .hidden)
    }

    @Test func ratesBadgeRequiresEveryOwnerToProveTheSameTier() {
        let labelUse = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Powdery mildew",
            rates: [ChemicalLabelRate(basis: .per100Litres, value: 40, unit: "mL")],
            provenance: ["rates": "manufacturer_label"]
        )
        let secondLabelUse = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Downy mildew",
            rates: [ChemicalLabelRate(basis: .perHectare, value: 1.5, unit: "L")],
            provenance: ["rates": "manufacturer_label"]
        )
        let unprovenUse = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Botrytis",
            rates: [ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")]
        )
        let aiUse = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Rust",
            rates: [ChemicalLabelRate(basis: .perHectare, value: 1, unit: "L")],
            provenance: ["rates": "ai_interpretation"]
        )

        #expect([labelUse, secondLabelUse].uniformRatesBadge == .authoritative(.manufacturerLabel))
        #expect([labelUse, unprovenUse].uniformRatesBadge == nil)
        #expect([labelUse, aiUse].uniformRatesBadge == nil)
        #expect([ChemicalRegisteredUse(crop: "Grapes", targetRaw: "Rust")].uniformRatesBadge == nil)
    }
}

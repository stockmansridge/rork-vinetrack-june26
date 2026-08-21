import Foundation
import Testing
@testable import VineTrack

/// P9 — WHP / REI / restrictions parity.
///
/// Three facts on a label are LEGAL text, not data VineTrack may improve:
/// the withholding period, the re-entry interval, and the restriction
/// statements. Each is stated PER REGISTERED USE, each is either present or
/// unresolved, and none of them may be inferred from another.
///
/// Fixtures decode through `BackendSavedChemical` — the real sync path — so
/// these assert the JSON the portal actually writes.
struct WithholdingRestrictionsParityTests {

    private func chemical(_ json: String) throws -> SavedChemical {
        try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    // MARK: - Fixtures

    /// Sprayseal 80160 — an adjuvant whose label states "NOT REQUIRED WHEN
    /// USED AS DIRECTED". The resolver serves that as 0 days with a
    /// manufacturer-label source; it is the ONLY way a 0 is ever produced from
    /// a label.
    private let sprayseal80160JSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000001",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Sprayseal",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "80160",
      "registered_product_name": "SPRAYSEAL",
      "verification_status": "verified",
      "verification": {
        "status": "verified",
        "sources": [
          { "kind": "manufacturer_label", "name": "Approved label", "reference": "80160" }
        ]
      },
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "SPRAY ADJUVANT",
          "rates": [
            { "label": "Standard", "basis": "per_100_litres", "value": 200, "unit": "mL", "raw_text": "200 mL/100 L" }
          ],
          "withholding_period_days": 0,
          "restrictions": "Shake or stir container well before use."
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    /// Custodia Forte 91636 — a 28-day grape withholding period, a stated
    /// re-entry interval, and a long multi-sentence restriction statement.
    private let custodiaForte91636JSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000002",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Custodia Forte Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "91636",
      "registered_product_name": "CUSTODIA FORTE FUNGICIDE",
      "verification_status": "verified",
      "verification": {
        "status": "verified",
        "sources": [
          { "kind": "official_register", "name": "APVMA PUBCRIS", "reference": "91636" },
          { "kind": "manufacturer_label", "name": "Approved label", "reference": "91636" }
        ]
      },
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
          "withholding_period_days": 28,
          "re_entry_period_hours": 24,
          "restrictions": "DO NOT apply more than three (3) consecutive applications of this product or any other Group 3 fungicide. DO NOT apply to grapevines destined for export wine production without first consulting your winery, as maximum residue limits differ between markets. DO NOT graze treated areas or cut for stock food."
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    /// One product, TWO registered uses with different legal text. The wrong
    /// use's wording next to a rate is the whole defect this guards.
    private let twoUseProductJSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000003",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Dual Registration Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_number": "70001",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "POWDERY MILDEW",
          "rates": [
            { "label": "Vines", "basis": "per_hectare", "value": 500, "unit": "mL", "raw_text": "500 mL/ha" }
          ],
          "withholding_period_days": 28,
          "re_entry_period_hours": 24,
          "restrictions": "GRAPEVINE: DO NOT apply after bunch closure."
        },
        {
          "crop": "APPLES",
          "target_raw": "BLACK SPOT",
          "rates": [
            { "label": "Pome", "basis": "per_hectare", "value": 900, "unit": "mL", "raw_text": "900 mL/ha" }
          ],
          "withholding_period_days": 7,
          "restrictions": "APPLES: DO NOT apply more than four (4) applications per season."
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    /// A legacy record: no structured intelligence, no legal text at all.
    private let legacyProductJSON = """
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000004",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Old Bordeaux Mix",
      "unit": "Litres",
      "rate_per_ha": 2.5,
      "active_ingredient": "Copper",
      "chemical_group": "M1",
      "rates": [
        { "label": "Standard", "value": 500, "basis": "per_hectare" }
      ]
    }
    """

    // MARK: - WHP: zero wording

    @Test func labelBackedZeroReadsNotRequired() throws {
        let saved = try chemical(sprayseal80160JSON)
        let intel = try #require(saved.chemicalIntelligence)
        let use = try #require(intel.registeredUses.first)

        #expect(use.withholdingPeriodDays == 0)
        #expect(intel.hasManufacturerLabelSource)
        #expect(
            ChemicalWithholdingDisplay.text(
                days: use.withholdingPeriodDays,
                restrictions: use.restrictions,
                hasManufacturerLabelSource: intel.hasManufacturerLabelSource
            ) == "Not required when used as directed"
        )
    }

    @Test func zeroWithoutLabelEvidenceStaysZeroDays() throws {
        // Same 0, evidence stripped: an operator-typed zero has no label
        // wording behind it, so the friendly phrase would be invented.
        var saved = try chemical(sprayseal80160JSON)
        var intel = try #require(saved.chemicalIntelligence)
        intel.verification = ChemicalVerification(status: .unverified, sources: [])
        intel.registeredUses = intel.registeredUses.map { use in
            var copy = use
            copy.restrictions = nil
            return copy
        }
        saved.chemicalIntelligence = intel

        let use = try #require(intel.registeredUses.first)
        #expect(intel.hasManufacturerLabelSource == false)
        #expect(
            ChemicalWithholdingDisplay.text(
                days: use.withholdingPeriodDays,
                restrictions: use.restrictions,
                hasManufacturerLabelSource: intel.hasManufacturerLabelSource
            ) == "0 days"
        )
    }

    @Test func statedDaysNeverBecomeWording() throws {
        // Custodia Forte 91636: 28 days, label-sourced. Evidence changes the
        // wording of a ZERO only — it never restates a real day count.
        let saved = try chemical(custodiaForte91636JSON)
        let intel = try #require(saved.chemicalIntelligence)
        let use = try #require(intel.registeredUses.first)

        #expect(use.withholdingPeriodDays == 28)
        #expect(
            ChemicalWithholdingDisplay.text(
                days: use.withholdingPeriodDays,
                restrictions: use.restrictions,
                hasManufacturerLabelSource: intel.hasManufacturerLabelSource
            ) == "28 days"
        )
    }

    @Test func missingWithholdingStaysUnresolved() throws {
        // The apple use of the two-use product states no re-entry, and a
        // legacy record states nothing at all. Neither gains a value.
        let saved = try chemical(twoUseProductJSON)
        let intel = try #require(saved.chemicalIntelligence)
        let apples = try #require(intel.registeredUses.first { $0.crop == "APPLES" })

        #expect(apples.reEntryPeriodHours == nil)
        #expect(
            ChemicalWithholdingDisplay.text(
                days: nil,
                restrictions: apples.restrictions,
                hasManufacturerLabelSource: true
            ) == nil
        )

        let legacy = try chemical(legacyProductJSON)
        let legacyUses = legacy.chemicalIntelligence?.registeredUses ?? []
        #expect(legacyUses.allSatisfy { $0.withholdingPeriodDays == nil })
    }

    // MARK: - WHP stays tied to its own registered use

    @Test func withholdingStaysWithItsOwnUse() throws {
        let saved = try chemical(twoUseProductJSON)
        let uses = try #require(saved.chemicalIntelligence?.registeredUses)

        let grapes = try #require(uses.first { $0.crop == "GRAPEVINE" })
        let apples = try #require(uses.first { $0.crop == "APPLES" })

        #expect(grapes.withholdingPeriodDays == 28)
        #expect(apples.withholdingPeriodDays == 7)
        // Nothing collapses two uses into a product-level number.
        #expect(uses.count == 2)
    }

    // MARK: - REI

    @Test func reEntryIsPreservedVerbatimAndNeverInferred() throws {
        let custodia = try chemical(custodiaForte91636JSON)
        let use = try #require(custodia.chemicalIntelligence?.registeredUses.first)
        #expect(use.reEntryPeriodHours == 24)

        // Sprayseal states a withholding period (0) and NO re-entry. A 0-day
        // withhold must not become a 0-hour re-entry, and no default fills in.
        let sprayseal = try chemical(sprayseal80160JSON)
        let adjuvantUse = try #require(sprayseal.chemicalIntelligence?.registeredUses.first)
        #expect(adjuvantUse.withholdingPeriodDays == 0)
        #expect(adjuvantUse.reEntryPeriodHours == nil)
    }

    @Test func blankManualEntryLeavesLegalFactsUnresolved() {
        // The manual editor's "0" is a PLACEHOLDER. An untouched field parses
        // to nil, not to zero — the difference between "the label says none is
        // required" and "nobody has established one".
        #expect(ChemicalManualEntry.parseInt("") == nil)
        #expect(ChemicalManualEntry.parseInt("   ") == nil)
        #expect(ChemicalManualEntry.parseInt("0") == 0)
        #expect(ChemicalManualEntry.parseInt("28") == 28)
    }

    // MARK: - Restrictions

    @Test func longRestrictionTextSurvivesVerbatim() throws {
        let saved = try chemical(custodiaForte91636JSON)
        let use = try #require(saved.chemicalIntelligence?.registeredUses.first)
        let text = try #require(use.restrictions)

        // Verbatim: the exact opening and closing sentences, unabridged, with
        // no ellipsis, summary or re-casing anywhere in between.
        #expect(text.hasPrefix("DO NOT apply more than three (3) consecutive applications"))
        #expect(text.hasSuffix("DO NOT graze treated areas or cut for stock food."))
        #expect(text.contains("maximum residue limits differ between markets"))
        #expect(text.contains("…") == false)
        #expect(text.count > 300)
    }

    @Test func restrictionsSurviveAnEncodeDecodeRoundTrip() throws {
        let saved = try chemical(custodiaForte91636JSON)
        let intel = try #require(saved.chemicalIntelligence)
        let data = try JSONEncoder().encode(intel)
        let reloaded = try JSONDecoder().decode(ChemicalIntelligence.self, from: data)

        #expect(reloaded.registeredUses.first?.restrictions == intel.registeredUses.first?.restrictions)
        #expect(reloaded.registeredUses.first?.withholdingPeriodDays == 28)
        #expect(reloaded.registeredUses.first?.reEntryPeriodHours == 24)
    }

    @Test func restrictionsStayTiedToTheSelectedRegisteredUse() throws {
        // The Spray Tool defect: a line whose rate came from the GRAPEVINE use
        // must show the grapevine statement, never the apple one.
        let saved = try chemical(twoUseProductJSON)
        let rates = SprayRegisteredUseRates.rates(for: saved)

        let vineRate = try #require(rates.first { $0.crop == "GRAPEVINE" })
        let appleRate = try #require(rates.first { $0.crop == "APPLES" })

        let vineUse = try #require(SprayRegisteredUseRates.registeredUse(for: saved, rateId: vineRate.id))
        let appleUse = try #require(SprayRegisteredUseRates.registeredUse(for: saved, rateId: appleRate.id))

        #expect(vineUse.restrictions == "GRAPEVINE: DO NOT apply after bunch closure.")
        #expect(vineUse.withholdingPeriodDays == 28)
        #expect(appleUse.restrictions == "APPLES: DO NOT apply more than four (4) applications per season.")
        #expect(appleUse.withholdingPeriodDays == 7)
    }

    @Test func legacyAndUnknownRatesBorrowNoUse() throws {
        // A legacy rate belongs to no registered use, so there is no
        // use-specific wording to show. Resolving to "some use" would attach
        // another crop's legal text to this line.
        let legacy = try chemical(legacyProductJSON)
        let legacyRate = try #require(SprayRegisteredUseRates.rates(for: legacy).first)
        #expect(legacyRate.origin == .legacy)
        #expect(SprayRegisteredUseRates.registeredUse(for: legacy, rateId: legacyRate.id) == nil)

        // An id that matches nothing (a stale selection after a label change)
        // resolves to nothing rather than to the first use on the record.
        let structured = try chemical(twoUseProductJSON)
        #expect(SprayRegisteredUseRates.registeredUse(for: structured, rateId: UUID()) == nil)
    }

    @Test func selectedUseSurvivesARelaunchOfTheSameSelection() throws {
        // Structured rate ids are derived from content, so the use behind a
        // persisted `selectedRateId` still resolves after a reload.
        let saved = try chemical(custodiaForte91636JSON)
        let concentrate = try #require(
            SprayRegisteredUseRates.rates(for: saved).first { $0.label == "Concentrate" }
        )
        let reloaded = try chemical(custodiaForte91636JSON)
        let use = try #require(
            SprayRegisteredUseRates.registeredUse(for: reloaded, rateId: concentrate.id)
        )
        #expect(use.crop == "GRAPEVINE")
        #expect(use.withholdingPeriodDays == 28)
    }

    // MARK: - Re-verify diff wording

    private func intelligence(
        uses: [ChemicalRegisteredUse],
        hasLabelSource: Bool
    ) -> ChemicalIntelligence {
        ChemicalIntelligence(
            verification: ChemicalVerification(
                status: hasLabelSource ? .verified : .unverified,
                sources: hasLabelSource
                    ? [ChemicalDataSource(kind: .manufacturerLabel, name: "Approved label")]
                    : []
            ),
            registeredUses: uses
        )
    }

    @Test func diffRendersLabelBackedZeroAsNotRequired() throws {
        let before = intelligence(
            uses: [ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "SPRAY ADJUVANT")],
            hasLabelSource: true
        )
        let after = intelligence(
            uses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "SPRAY ADJUVANT",
                    withholdingPeriodDays: 0,
                    restrictions: "Shake or stir container well before use."
                )
            ],
            hasLabelSource: true
        )

        let diff = ChemicalIntelligenceDiffer.diff(current: before, candidate: after)
        let change = try #require(diff.changes.first { $0.field == .withholdingPeriod })

        #expect(change.currentValue == nil)
        #expect(change.candidateValue == "Not required when used as directed")
    }

    @Test func diffKeepsAnUnevidencedZeroAsZeroDays() throws {
        let before = intelligence(
            uses: [ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "POWDERY MILDEW")],
            hasLabelSource: false
        )
        let after = intelligence(
            uses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "POWDERY MILDEW",
                    withholdingPeriodDays: 0
                )
            ],
            hasLabelSource: false
        )

        let diff = ChemicalIntelligenceDiffer.diff(current: before, candidate: after)
        let change = try #require(diff.changes.first { $0.field == .withholdingPeriod })
        #expect(change.candidateValue == "0 days")
    }

    @Test func diffJudgesEachSideOnItsOwnEvidence() throws {
        // A stored, operator-typed 0 being replaced by a label-parsed 0 is not
        // a value change at all — so nothing is reported. The wording rule
        // must not manufacture a change out of two identical numbers.
        let before = intelligence(
            uses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "SPRAY ADJUVANT",
                    withholdingPeriodDays: 0
                )
            ],
            hasLabelSource: false
        )
        let after = intelligence(
            uses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "SPRAY ADJUVANT",
                    withholdingPeriodDays: 0,
                    restrictions: "GRAPEVINE: NOT REQUIRED WHEN USED AS DIRECTED."
                )
            ],
            hasLabelSource: true
        )

        let diff = ChemicalIntelligenceDiffer.diff(current: before, candidate: after)
        #expect(diff.changes.contains { $0.field == .withholdingPeriod } == false)
    }

    @Test func diffReportsRealDayCountsAndReEntryUnchanged() throws {
        let before = intelligence(
            uses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "POWDERY MILDEW",
                    withholdingPeriodDays: 14,
                    reEntryPeriodHours: 12
                )
            ],
            hasLabelSource: true
        )
        let after = intelligence(
            uses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "POWDERY MILDEW",
                    withholdingPeriodDays: 28,
                    reEntryPeriodHours: 24
                )
            ],
            hasLabelSource: true
        )

        let diff = ChemicalIntelligenceDiffer.diff(current: before, candidate: after)
        let whp = try #require(diff.changes.first { $0.field == .withholdingPeriod })
        #expect(whp.currentValue == "14 days")
        #expect(whp.candidateValue == "28 days")

        let rei = try #require(diff.changes.first { $0.field == .reEntryPeriod })
        #expect(rei.currentValue == "12 hours")
        #expect(rei.candidateValue == "24 hours")
    }

    @Test func diffReportsALostReEntryAsRemovedNotZero() throws {
        let before = intelligence(
            uses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "POWDERY MILDEW",
                    reEntryPeriodHours: 24
                )
            ],
            hasLabelSource: true
        )
        let after = intelligence(
            uses: [ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "POWDERY MILDEW")],
            hasLabelSource: true
        )

        let diff = ChemicalIntelligenceDiffer.diff(current: before, candidate: after)
        let rei = try #require(diff.changes.first { $0.field == .reEntryPeriod })
        #expect(rei.currentValue == "24 hours")
        #expect(rei.candidateValue == nil)
    }

    // MARK: - History

    @Test func frozenSnapshotCarriesNoLegalTextToRestate() throws {
        // The immutable spray snapshot deliberately holds chemistry and trust
        // only. A completed spray therefore CANNOT display today's withholding
        // or restrictions as though they were the ones in force at the time —
        // there is nothing on the historical path to pull them through.
        let saved = try chemical(custodiaForte91636JSON)
        let snapshot = try #require(
            ChemicalSnapshotCapture.capture(saved, at: Date(timeIntervalSince1970: 1_780_000_000))
        )

        #expect(snapshot.registrationIdentityKey == "AU:apvma:91636")
        #expect(snapshot.productName == "Custodia Forte Fungicide")

        // Re-encode the historical line and confirm no legal field rides along.
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["withholding_period_days"] == nil)
        #expect(object["re_entry_period_hours"] == nil)
        #expect(object["restrictions"] == nil)
    }
}

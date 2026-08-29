import Foundation
import Testing
@testable import VineTrack

/// P4 — Saved Chemical cross-platform parity (iOS side).
///
/// Every fixture in this file is the CANONICAL `saved_chemicals` row shape: the
/// exact JSON the portal writes and the exact JSON the Android
/// `SavedChemicalParityTest` decodes, byte for byte. The two suites assert the
/// same values, so "saved on Android opens identically on iOS" is proven by
/// construction rather than by inspection.
///
/// What must survive a round trip, per fixture:
///   master_chemical_id / master_source_revision, registration identity,
///   actives + FRAC/HRAC/IRAC groups, verification status, registered_uses and
///   their per-use provenance, every rate with its basis and range, WHP / REI /
///   restrictions, and the label reference + version.
///
/// What must NOT happen:
///   ranges collapsing to a single number, `basis:"other"` gaining a numeric
///   value, unresolved data resolving itself, unknown provenance gaining
///   authority, or an ordinary edit clearing the Master link.
struct SavedChemicalParityTests {

    // MARK: - Helpers

    /// Decodes the canonical backend row exactly as the sync path does.
    private func decodeRow(_ json: String) throws -> SavedChemical {
        try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    private func roundTrip(_ chemical: SavedChemical) throws -> SavedChemical {
        try JSONDecoder().decode(SavedChemical.self, from: JSONEncoder().encode(chemical))
    }

    // MARK: - Canonical fixtures (identical to the Android suite)

    /// Sprayseal 80160 — label-backed 30 mL/100 L, WHP 0 with the
    /// "not required" phrase, master-linked. Deliberately written the way the
    /// PORTAL writes it: the legacy `rates` entry carries NO `id` and the
    /// `purchase` object is partial.
    private let spraysealRow = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Sprayseal Pruning Wound Treatment",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [ { "label": "Standard", "value": 300, "basis": "per_100_litres" } ],
      "purchase": { "costDollars": 250.0 },
      "active_ingredient": "Tebuconazole 430 g/L",
      "chemical_group": "3",
      "active_ingredients": [
        {
          "name": "Tebuconazole",
          "concentration": 430,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["3"],
      "activity_group_scheme": "frac",
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "80160",
      "registrant": "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
      "registered_product_name": "Sprayseal Pruning Wound Treatment",
      "label_reference": "https://elabels.apvma.gov.au/labels/80160.pdf",
      "label_version": "APVMA label approval 113355 (1/07/2025)",
      "verification_status": "partially_verified",
      "verification_sources": [
        {
          "kind": "official_register",
          "name": "APVMA PubCRIS register extract — product 80160",
          "reference": "https://data.gov.au/data/api/3/action/datastore_search",
          "retrieved_at": "2026-08-20T00:00:00Z"
        }
      ],
      "verification_unresolved_fields": ["label_rates:GRAPEVINE"],
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "EUTYPA DIEBACK",
          "rates": [
            {
              "label": "",
              "basis": "per_100_litres",
              "value": 30,
              "unit": "mL",
              "raw_text": "30 mL per 100 L of water"
            }
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
      "label_rate_bases": ["per_100_litres"],
      "activity_group_table_version": 3,
      "intelligence_schema_version": 1,
      "master_chemical_id": "33333333-3333-3333-3333-333333333333",
      "master_source_revision": 7
    }
    """

    /// Custodia Forte 91636 — rate RANGES on two bases plus a 28-day WHP.
    private let custodiaForteRow = """
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Custodia Forte Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [
        {
          "name": "Azoxystrobin",
          "concentration": 120,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "11", "common_name": "QoI / Strobilurin" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        },
        {
          "name": "Tebuconazole",
          "concentration": 200,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["11", "3"],
      "activity_group_scheme": "frac",
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "91636",
      "registrant": "ADAMA AUSTRALIA PTY LIMITED",
      "registered_product_name": "CUSTODIA FORTE FUNGICIDE",
      "label_reference": "https://elabels.apvma.gov.au/labels/91636.pdf",
      "label_version": "APVMA label approval 120011 (3/03/2026)",
      "verification_status": "partially_verified",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "POWDERY MILDEW",
          "rates": [
            {
              "label": "Dilute",
              "basis": "range_per_100_litres",
              "min_value": 40,
              "max_value": 60,
              "unit": "mL",
              "raw_text": "40–60 mL/100 L"
            },
            {
              "label": "Concentrate",
              "basis": "range_per_hectare",
              "min_value": 0.6,
              "max_value": 0.9,
              "unit": "L",
              "raw_text": "0.6–0.9 L/ha"
            }
          ],
          "withholding_period_days": 28,
          "re_entry_period_hours": 24,
          "restrictions": "DO NOT apply more than two consecutive applications.",
          "provenance": {
            "claim": "manufacturer_label",
            "rates": "manufacturer_label",
            "withholding_period": "manufacturer_label",
            "re_entry": "manufacturer_label",
            "restrictions": "manufacturer_label"
          }
        }
      ],
      "label_rate_bases": ["range_per_100_litres", "range_per_hectare"],
      "activity_group_table_version": 3,
      "intelligence_schema_version": 1
    }
    """

    /// Prosaro 63243 — contract fixture: `basis:"other"`, reference-only.
    private let prosaroRow = """
    {
      "id": "55555555-5555-5555-5555-555555555555",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Prosaro 420 SC Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [
        {
          "name": "Prothioconazole",
          "concentration": 210,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["3"],
      "activity_group_scheme": "frac",
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "63243",
      "registered_product_name": "PROSARO 420 SC FOLIAR FUNGICIDE",
      "verification_status": "partially_verified",
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
          ],
          "provenance": { "claim": "manufacturer_label", "rates": "manufacturer_label" }
        }
      ],
      "label_rate_bases": ["other"],
      "intelligence_schema_version": 1
    }
    """

    /// Custodia 320SC — identity never resolved; everything stays unresolved.
    private let custodia320Row = """
    {
      "id": "66666666-6666-6666-6666-666666666666",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Custodia 320SC",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [],
      "registration_country": "AU",
      "verification_status": "needs_match",
      "verification_unresolved_fields": [
        "registration_number", "active_ingredients", "registered_uses"
      ],
      "registered_uses": [],
      "intelligence_schema_version": 1
    }
    """

    /// Ridomil Gold — ambiguous family; fails closed with nothing asserted.
    private let ridomilRow = """
    {
      "id": "77777777-7777-7777-7777-777777777777",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Ridomil Gold",
      "unit": "Kg",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [],
      "registration_country": "AU",
      "verification_status": "needs_match",
      "verification_unresolved_fields": ["registration_number", "active_ingredients"],
      "registered_uses": [],
      "intelligence_schema_version": 1
    }
    """

    // MARK: - P4-01 Sprayseal: full structured payload survives

    @Test func spraysealRoundTripsEveryStructuredFact() throws {
        let reopened = try roundTrip(try decodeRow(spraysealRow))

        // Master linkage
        #expect(reopened.masterChemicalId
            == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(reopened.masterSourceRevision == 7)

        let intel = try #require(reopened.chemicalIntelligence)

        // Registration identity + label pointers
        #expect(intel.registration?.countryCode == "AU")
        #expect(intel.registration?.registrationNumber == "80160")
        #expect(intel.registration?.scheme?.rawValue == "apvma")
        #expect(intel.registration?.registrant == "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD")
        #expect(intel.registration?.registeredProductName == "Sprayseal Pruning Wound Treatment")
        #expect(intel.registration?.labelReference
            == "https://elabels.apvma.gov.au/labels/80160.pdf")
        #expect(intel.registration?.labelVersion == "APVMA label approval 113355 (1/07/2025)")

        // Actives + groups
        #expect(intel.activeIngredients.count == 1)
        #expect(intel.activeIngredients[0].name == "Tebuconazole")
        #expect(intel.activeIngredients[0].concentration == 430)
        #expect(intel.activeIngredients[0].concentrationUnit?.rawValue == "g/L")
        #expect(intel.activityGroupCodes == ["3"])
        #expect(intel.activityGroups.first?.scheme.rawValue == "frac")

        // Verification
        #expect(intel.verification.status == .partiallyVerified)
        #expect(intel.verification.sources.count == 1)
        #expect(intel.verification.unresolvedFields == ["label_rates:GRAPEVINE"])

        // Registered use, rate and label facts
        let use = try #require(intel.registeredUses.first)
        #expect(intel.registeredUses.count == 1)
        #expect(use.crop == "GRAPEVINE")
        #expect(use.targetRaw == "EUTYPA DIEBACK")
        #expect(use.withholdingPeriodDays == 0)
        #expect(use.restrictions == "NOT REQUIRED WHEN USED AS DIRECTED.")
        let rate = try #require(use.rates.first)
        #expect(use.rates.count == 1)
        #expect(rate.basis == .per100Litres)
        #expect(rate.value == 30)
        #expect(rate.unit == "mL")
        #expect(rate.rawText == "30 mL per 100 L of water")

        // Per-use provenance, verbatim
        #expect(use.provenance?["rates"] == "manufacturer_label")
        #expect(use.provenance?["withholding_period"] == "manufacturer_label")
        #expect(ChemicalProvenanceTier.authoritative(fromRaw: use.provenance?["rates"])
            == .manufacturerLabel)

        // The P2B/P3 WHP rule still reads the same on a reopened record.
        #expect(ChemicalWithholdingDisplay.text(
            days: use.withholdingPeriodDays,
            restrictions: use.restrictions,
            hasManufacturerLabelSource: true
        ) == "Not required when used as directed")
    }

    // MARK: - P4-02 Custodia Forte: ranges must not collapse

    @Test func custodiaForteKeepsBothRangesAndThe28DayWHP() throws {
        let reopened = try roundTrip(try decodeRow(custodiaForteRow))
        let intel = try #require(reopened.chemicalIntelligence)

        // Read-back is CANONICAL order (numeric ascending), never payload order:
        // both platforms sort so identical mixes never persist as two different-
        // looking histories, whichever order the label listed the actives.
        #expect(intel.activityGroupCodes == ["3", "11"])
        #expect(intel.registration?.registrationNumber == "91636")

        let use = try #require(intel.registeredUses.first)
        #expect(use.withholdingPeriodDays == 28)
        #expect(use.reEntryPeriodHours == 24)
        #expect(use.restrictions == "DO NOT apply more than two consecutive applications.")
        #expect(use.rates.count == 2)

        let dilute = use.rates[0]
        #expect(dilute.basis == .rangePer100Litres)
        #expect(dilute.minValue == 40)
        #expect(dilute.maxValue == 60)
        // A range must never collapse into a single value.
        #expect(dilute.value == nil)
        #expect(dilute.rawText == "40–60 mL/100 L")
        // A range proposes its LOW end — never inflated on reopen.
        #expect(dilute.proposedValue == 40)

        let concentrate = use.rates[1]
        #expect(concentrate.basis == .rangePerHectare)
        #expect(concentrate.minValue == 0.6)
        #expect(concentrate.maxValue == 0.9)
        #expect(concentrate.value == nil)

        #expect(intel.labelRateBases == [.rangePer100Litres, .rangePerHectare])
        // 28 days is a stated count; the phrase rule can never zero it.
        #expect(ChemicalWithholdingDisplay.text(
            days: use.withholdingPeriodDays,
            restrictions: use.restrictions,
            hasManufacturerLabelSource: true
        ) == "28 days")
    }

    // MARK: - P4-03 Prosaro: basis "other" stays reference-only

    @Test func prosaroOtherBasisKeepsItsWordingAndInventsNoNumber() throws {
        let reopened = try roundTrip(try decodeRow(prosaroRow))
        let intel = try #require(reopened.chemicalIntelligence)
        let use = try #require(intel.registeredUses.first)
        let rate = try #require(use.rates.first)

        #expect(rate.basis == .other)
        #expect(rate.value == nil)
        #expect(rate.minValue == nil)
        #expect(rate.maxValue == nil)
        #expect(rate.unit == "")
        #expect(rate.rawText == "Refer to the approved label for grapevine rates")
        // Reference-only: nothing for a calculation to start from.
        #expect(rate.proposedValue == nil)
        #expect(rate.displayRate == rate.rawText)

        // WHP was never stated — it must stay unstated, not become "0 days".
        #expect(use.withholdingPeriodDays == nil)
        #expect(ChemicalWithholdingDisplay.text(
            days: use.withholdingPeriodDays,
            restrictions: use.restrictions,
            hasManufacturerLabelSource: true
        ) == nil)
    }

    // MARK: - P4-04 Unresolved fixtures stay unresolved

    @Test func custodia320AndRidomilStayUnresolvedOnReopen() throws {
        for row in [custodia320Row, ridomilRow] {
            let reopened = try roundTrip(try decodeRow(row))
            let intel = try #require(reopened.chemicalIntelligence)

            #expect(intel.activeIngredients.isEmpty)
            #expect(intel.registeredUses.isEmpty)
            #expect(intel.registration?.registrationNumber == nil)
            #expect(intel.resolvedVerificationStatus == .needsMatch)
            // Unresolved fields survive verbatim.
            #expect(intel.verification.unresolvedFields.contains("registration_number"))
            // Nothing about an unresolved record may read as dependable.
            #expect(intel.isResistanceDependable == false)
            #expect(intel.hasEvidencedRegistration == false)
        }
    }

    // MARK: - P4-05 Portal-written shapes decode without loss

    @Test func portalRowWithoutRateIdsAndWithAPartialPurchaseDecodes() throws {
        let decoded = try decodeRow(spraysealRow)
        // The legacy rates array carried no `id` — before P4 this threw and
        // took the whole chemical out of the store.
        #expect(decoded.rates.count == 1)
        #expect(decoded.rates[0].value == 300)
        #expect(decoded.rates[0].basis == .per100Litres)
        // A partial purchase object keeps the value it stated and defaults
        // the rest rather than failing the record.
        #expect(decoded.purchase?.costDollars == 250)
        #expect(decoded.purchase?.containerUnit == .litres)
        // And the structured payload is untouched by either tolerance.
        #expect(decoded.chemicalIntelligence?.registration?.registrationNumber == "80160")
    }

    // MARK: - P4-06 Legacy records still open safely

    @Test func legacyRecordWithoutAnyNewerFieldsOpensSafely() throws {
        let legacy = try decodeRow(
            """
            {
              "id": "88888888-8888-8888-8888-888888888888",
              "vineyard_id": "22222222-2222-2222-2222-222222222222",
              "name": "Old Bordeaux Mix",
              "unit": "Kg",
              "rate_per_ha": 2.5,
              "active_ingredient": "Copper",
              "chemical_group": "M1"
            }
            """
        )
        // No structured payload at all — and that is the honest answer.
        #expect(legacy.chemicalIntelligence == nil)
        #expect(legacy.masterChemicalId == nil)
        #expect(legacy.rates.isEmpty)
        // The legacy read is a CANDIDATE, never verified.
        #expect(legacy.resolvedIntelligence.resolvedVerificationStatus == .needsMatch)
        #expect(try roundTrip(legacy).name == "Old Bordeaux Mix")
    }

    // MARK: - P4-07 Unknown provenance round-trips without authority

    @Test func unknownProvenanceSurvivesVerbatimWithoutBecomingAuthority() throws {
        let mutated = spraysealRow.replacingOccurrences(
            of: "\"rates\": \"manufacturer_label\"",
            with: "\"rates\": \"stone_tablet\""
        )
        let reopened = try roundTrip(try decodeRow(mutated))
        let use = try #require(reopened.chemicalIntelligence?.registeredUses.first)

        // Stored verbatim…
        #expect(use.provenance?["rates"] == "stone_tablet")
        // …but it proves nothing.
        #expect(ChemicalProvenanceTier.authoritative(fromRaw: use.provenance?["rates"]) == nil)
        // Neighbouring facts are unaffected.
        #expect(ChemicalProvenanceTier
            .authoritative(fromRaw: use.provenance?["withholding_period"]) == .manufacturerLabel)
    }

    // MARK: - P4-08 Ordinary edits never clear the Master link

    @Test func anOrdinaryEditLeavesMasterLinkageIntact() throws {
        var chemical = try decodeRow(spraysealRow)
        // An inventory/pack edit touches nothing structural.
        chemical.inventoryQuantity = 12
        chemical.notes = "Two drums in the shed"

        let reopened = try roundTrip(chemical)
        #expect(reopened.masterChemicalId
            == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(reopened.masterSourceRevision == 7)
        #expect(reopened.chemicalIntelligence?.registration?.registrationNumber == "80160")

        // The upsert carries both fields through unchanged.
        let upsert = BackendSavedChemical.upsert(
            from: reopened, createdBy: nil, clientUpdatedAt: Date()
        )
        #expect(upsert.masterChemicalId
            == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(upsert.masterSourceRevision == 7)
    }

    // MARK: - P4-09 Target vocabulary agrees with Android

    @Test func targetMappingMatchesAndroidIncludingGrassControlWording() throws {
        #expect(ChemicalRegisteredUse.mapTarget("POWDERY MILDEW") == .powderyMildew)
        #expect(ChemicalRegisteredUse.mapTarget("Downy mildew") == .downyMildew)
        #expect(ChemicalRegisteredUse.mapTarget("Bunch rot") == .botrytis)
        #expect(ChemicalRegisteredUse.mapTarget("Broadleaf weeds") == .weeds)
        // Android now reads this wording the same way.
        #expect(ChemicalRegisteredUse.mapTarget("GRASS CONTROL") == .weeds)
        // Still conservative — an unmapped target stays unmapped.
        #expect(ChemicalRegisteredUse.mapTarget("EUTYPA DIEBACK") == nil)

        // A stored explicit target survives the row round trip on the wire
        // vocabulary Android also writes.
        let use = ChemicalRegisteredUse(
            crop: "GRAPEVINE", targetRaw: "POWDERY MILDEW", target: .powderyMildew
        )
        let encoded = try JSONEncoder().encode(use)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("powdery_mildew"))
        let decoded = try JSONDecoder().decode(ChemicalRegisteredUse.self, from: encoded)
        #expect(decoded.target == .powderyMildew)
    }
}

import Foundation
import Testing
@testable import VineTrack

/// The permanent cross-platform Chemical Intelligence lookup regression —
/// pinned to a REAL product with a REAL country-scoped registration.
///
/// Custodia (Adama Australia, APVMA 66541) is the canonical fixture because it
/// exercises every defect class the lookup audit hunts at once:
///
///  * a two-active mixture (Azoxystrobin 120 g/L + Tebuconazole 200 g/L) that
///    must stay two actives with two groups (FRAC 11 + FRAC 3), never a merged
///    string;
///  * a sibling product with a near-identical name ("Custodia Forte",
///    APVMA 91636, DIFFERENT concentrations 222/370 g/L) that must never be
///    auto-matched by name similarity;
///  * the same brand name registered separately overseas (UK MAPP 16393),
///    proving registration identity is country-scoped;
///  * label uses with different rates, bases and withholding periods that must
///    stay attached to their own use;
///  * a label whose re-entry statement is narrative ("until spray has dried"),
///    so no numeric re-entry hours may ever be invented.
///
/// `ChemicalCustodiaParityTest.kt` on Android decodes the byte-identical JSON
/// fixture and asserts the same outcomes. The fixture is documented for the web
/// portal in `docs/chemical-custodia-parity-fixture.md`. If this file and that
/// document ever disagree, fix the document.
struct ChemicalCustodiaParityTests {

    /// The shared `action=structured` edge-function response for
    /// "Custodia" looked up in Australia. Identical string on Android.
    static let custodiaFixtureJSON = """
    {
      "product_name": "Custodia 320 SC",
      "product_category": "fungicide",
      "form_type": "liquid",
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "66541",
        "registrant": "Adama Australia Pty Ltd",
        "registered_product_name": "Custodia 320 SC"
      },
      "active_ingredients": [
        {
          "name": "Azoxystrobin",
          "concentration": 120,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "11", "common_name": "QoI / Strobilurin" },
          "group_source": "authoritative_classification",
          "identity_source": "ai_interpretation"
        },
        {
          "name": "Tebuconazole",
          "concentration": 200,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
          "group_source": "authoritative_classification",
          "identity_source": "ai_interpretation"
        }
      ],
      "activity_groups": ["11", "3"],
      "activity_group_scheme": "frac",
      "registered_uses": [
        {
          "crop": "Grapevines",
          "target": "powdery_mildew",
          "target_raw": "Powdery mildew",
          "rates": [
            { "label": "Dilute spraying", "basis": "per_100_litres", "value": 65, "unit": "mL" },
            { "label": "Concentrate spraying", "basis": "per_hectare", "value": 1, "unit": "L" }
          ],
          "withholding_period_days": 28,
          "restrictions": "Protectant only. DO NOT apply more than 2 sprays per season. Export grapes: do not use later than 80% capfall. Do not re-enter treated areas until the spray has dried."
        },
        {
          "crop": "Wheat",
          "target_raw": "Stripe rust",
          "rates": [
            { "label": "Standard", "basis": "range_per_hectare", "min_value": 315, "max_value": 630, "unit": "mL" }
          ],
          "withholding_period_days": 42,
          "restrictions": "Harvest WHP 6 weeks. Grazing WHP 21 days."
        }
      ],
      "label_rate_bases": ["per_100_litres", "per_hectare", "range_per_hectare"],
      "verification": {
        "status": "partially_verified",
        "sources": [
          { "kind": "ai_interpretation", "name": "Model extraction (gpt-4o)", "retrieved_at": "2026-08-18T00:00:00Z" },
          { "kind": "authoritative_classification", "name": "VineTrack activity group reference v1 (FRAC/HRAC/IRAC)", "retrieved_at": "2026-08-18T00:00:00Z" }
        ],
        "conflicts": [],
        "unresolved_fields": ["label_reference", "label_version", "re_entry_period_hours"],
        "verified_at": null
      },
      "activity_group_table_version": 1,
      "schema_version": 1
    }
    """

    private func decodeLookup() throws -> ChemicalStructuredLookup {
        // A PLAIN decoder, exactly as `ChemicalInfoService.lookupStructured`
        // uses. This is the point: the wire payload must decode without any
        // bespoke decoder configuration.
        try JSONDecoder().decode(
            ChemicalStructuredLookup.self,
            from: Data(Self.custodiaFixtureJSON.utf8)
        )
    }

    private func intelligence() throws -> ChemicalIntelligence {
        try decodeLookup().intelligence()
    }

    /// Custodia Forte — a REAL sibling registration (APVMA 91636) with
    /// different concentrations. Similar name, different product.
    private func forteIntelligence() -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Azoxystrobin",
                    concentration: 222,
                    concentrationUnit: .gramsPerLitre,
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "11"),
                    groupSource: .authoritativeClassification,
                    identitySource: .aiInterpretation
                ),
                ChemicalActiveIngredient(
                    name: "Tebuconazole",
                    concentration: 370,
                    concentrationUnit: .gramsPerLitre,
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3"),
                    groupSource: .authoritativeClassification,
                    identitySource: .aiInterpretation
                )
            ],
            registration: ChemicalRegistration(
                countryCode: "AU",
                scheme: .apvma,
                registrationNumber: "91636",
                registrant: "Adama Australia Pty Ltd",
                registeredProductName: "Custodia Forte"
            ),
            verification: ChemicalVerification(status: .partiallyVerified),
            productCategory: "fungicide"
        )
    }

    // MARK: - Transport

    @Test("The shared payload decodes with the plain decoder the lookup service actually uses")
    func transportDecodes() throws {
        let lookup = try decodeLookup()
        #expect(lookup.productName == "Custodia 320 SC")
        #expect(lookup.verification.sources.count == 2)
        // `retrieved_at` arrives as an ISO-8601 STRING from the edge function.
        // This assertion is the regression pin for the decode failure that took
        // the entire iOS structured lookup down.
        #expect(lookup.verification.sources[0].retrievedAt != nil)
        #expect(lookup.verification.verifiedAt == nil)
        #expect(lookup.schemaVersion == 1)
        #expect(lookup.activityGroupTableVersion == 1)
    }

    // MARK: - Actives

    @Test("Two actives stay separate, each owning its concentration and group")
    func activesStaySeparate() throws {
        let intel = try intelligence()
        #expect(intel.activeIngredients.count == 2)

        let azoxy = intel.activeIngredients[0]
        #expect(azoxy.name == "Azoxystrobin")
        #expect(azoxy.concentration == 120)
        #expect(azoxy.concentrationUnit == .gramsPerLitre)
        #expect(azoxy.activityGroup?.code == "11")
        #expect(azoxy.hasAuthoritativeGroup)

        let tebu = intel.activeIngredients[1]
        #expect(tebu.name == "Tebuconazole")
        #expect(tebu.concentration == 200)
        #expect(tebu.concentrationUnit == .gramsPerLitre)
        #expect(tebu.activityGroup?.code == "3")
        #expect(tebu.hasAuthoritativeGroup)

        // Never a merged display string masquerading as an active.
        #expect(!intel.activeIngredients.contains { $0.name.contains("+") })
    }

    @Test("Group codes are canonical and independent of server entry order")
    func canonicalGroups() throws {
        let intel = try intelligence()
        // Server sent ["11", "3"] (active order); the model canonicalises.
        #expect(intel.activityGroupCodes == ["3", "11"])
        #expect(intel.activityGroups.allSatisfy { $0.scheme == .frac })
    }

    // MARK: - Identity

    @Test("Registration identity is exact and country-scoped")
    func registrationIdentity() throws {
        let intel = try intelligence()
        #expect(intel.registration?.identityKey == "AU:apvma:66541")
        #expect(intel.registration?.isAuthoritativeIdentity == true)

        // The SAME brand name registered in the UK is a DIFFERENT identity.
        let ukCustodia = ChemicalRegistration(
            countryCode: "GB",
            scheme: .other,
            registrationNumber: "16393"
        )
        #expect(ukCustodia.identityKey == "GB:other:16393")
        #expect(ukCustodia.identityKey != intel.registration?.identityKey)
    }

    // MARK: - Verification honesty

    @Test("An AI lookup can never come back Verified")
    func lookupNeverVerifies() throws {
        let intel = try intelligence()
        #expect(intel.resolvedVerificationStatus == .partiallyVerified)
        #expect(!intel.isResistanceDependable)

        // Even a stored 'verified' claim cannot survive unresolved fields:
        // the evidence gate lowers it back down.
        var flipped = intel.verification
        flipped.status = .verified
        let resolved = flipped.resolvedStatus(
            actives: intel.activeIngredients,
            hasRegistration: intel.hasEvidencedRegistration
        )
        #expect(resolved == .partiallyVerified)
    }

    // MARK: - Registered uses

    @Test("Uses keep their own rates, bases and WHP; re-entry is never invented")
    func usesStaySeparate() throws {
        let intel = try intelligence()
        #expect(intel.registeredUses.count == 2)

        let grapes = intel.registeredUses[0]
        #expect(grapes.crop == "Grapevines")
        #expect(grapes.targetRaw == "Powdery mildew")
        #expect(grapes.target == .powderyMildew)
        #expect(grapes.rates.count == 2)
        #expect(grapes.rates[0].basis == .per100Litres)
        #expect(grapes.rates[0].value == 65)
        #expect(grapes.rates[0].unit == "mL")
        #expect(grapes.rates[1].basis == .perHectare)
        #expect(grapes.rates[1].value == 1)
        #expect(grapes.rates[1].unit == "L")
        #expect(grapes.withholdingPeriodDays == 28)
        // The label says "until the spray has dried" — narrative, not hours.
        #expect(grapes.reEntryPeriodHours == nil)
        #expect(grapes.restrictions?.contains("80% capfall") == true)

        let wheat = intel.registeredUses[1]
        #expect(wheat.crop == "Wheat")
        #expect(wheat.rates.count == 1)
        #expect(wheat.rates[0].basis == .rangePerHectare)
        #expect(wheat.rates[0].minValue == 315)
        #expect(wheat.rates[0].maxValue == 630)
        #expect(wheat.withholdingPeriodDays == 42)
        #expect(wheat.reEntryPeriodHours == nil)

        // The grape WHP and the wheat WHP must never bleed into each other.
        #expect(grapes.withholdingPeriodDays != wheat.withholdingPeriodDays)
        #expect(intel.labelRateBases.contains(.per100Litres))
        #expect(intel.labelRateBases.contains(.perHectare))
        #expect(intel.labelRateBases.contains(.rangePerHectare))
    }

    // MARK: - Legacy projections

    @Test("Legacy projections derive from the structured actives, never the reverse")
    func legacyProjections() throws {
        let intel = try intelligence()
        #expect(intel.legacyActiveIngredient == "Azoxystrobin 120 g/L + Tebuconazole 200 g/L")
        #expect(intel.legacyChemicalGroup == "3 + 11")
    }

    // MARK: - Similar product names

    @Test("Custodia Forte is a different registration and never auto-matches Custodia")
    func forteNeverAutoMatches() throws {
        let custodiaIntel = try intelligence()
        let custodia = SavedChemical(name: "Custodia", chemicalIntelligence: custodiaIntel)
        let forte = SavedChemical(name: "Custodia Forte", chemicalIntelligence: forteIntelligence())

        // Store duplicate gate: identity key only, never name similarity.
        #expect(ChemicalStoreMatching.findByRegistrationIdentity(
            in: [custodia],
            registration: forteIntelligence().registration
        ) == nil)
        #expect(ChemicalStoreMatching.findByRegistrationIdentity(
            in: [custodia, forte],
            registration: custodiaIntel.registration
        )?.id == custodia.id)
        #expect(ChemicalStoreMatching.findByRegistrationIdentity(
            in: [custodia],
            registration: custodiaIntel.registration,
            excludingId: custodia.id
        ) == nil)
        #expect(ChemicalStoreMatching.findByRegistrationIdentity(
            in: [custodia, forte],
            registration: nil
        ) == nil)

        // Spray-line resolution: exact unique name only — no substring, no fuzz.
        let byName = ChemicalSnapshotCapture.resolve(
            savedChemicalId: nil,
            productName: "custodia",
            in: [custodia, forte]
        )
        #expect(byName.chemical?.id == custodia.id)
        #expect(byName.match == .exactName)

        let partial = ChemicalSnapshotCapture.resolve(
            savedChemicalId: nil,
            productName: "Custodia 320",
            in: [custodia, forte]
        )
        #expect(partial.chemical == nil)
        #expect(partial.match == .unresolved)

        let byKey = ChemicalSnapshotCapture.resolve(
            savedChemicalId: nil,
            productName: nil,
            registrationIdentityKey: "AU:apvma:91636",
            in: [custodia, forte]
        )
        #expect(byKey.chemical?.id == forte.id)
        #expect(byKey.match == .registrationIdentity)
    }

    // MARK: - Legacy splitter

    @Test("The legacy splitter protects locant commas, thousands separators and units")
    func splitterProtections() {
        #expect(ChemicalIntelligence.splitActiveNames("Azoxystrobin 120 g/L + Tebuconazole 200 g/L")
            == ["Azoxystrobin", "Tebuconazole"])
        #expect(ChemicalIntelligence.splitActiveNames("2,4-D") == ["2,4-D"])
        #expect(ChemicalIntelligence.splitActiveNames("2,4-D + Dicamba") == ["2,4-D", "Dicamba"])
        #expect(ChemicalIntelligence.splitActiveNames("Bacillus amyloliquefaciens 1,000,000 CFU/g")
            == ["Bacillus amyloliquefaciens"])
        #expect(ChemicalIntelligence.splitActiveNames("Copper hydroxide and Mancozeb")
            == ["Copper hydroxide", "Mancozeb"])
        #expect(ChemicalIntelligence.splitActiveNames("Azoxystrobin · Tebuconazole")
            == ["Azoxystrobin", "Tebuconazole"])
        #expect(ChemicalIntelligence.splitActiveNames("Glyphosate, Simazine")
            == ["Glyphosate", "Simazine"])
        #expect(ChemicalIntelligence.splitActiveNames("Sulfur 800 g/kg") == ["Sulfur"])
    }
}

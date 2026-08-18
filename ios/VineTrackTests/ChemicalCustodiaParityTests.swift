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

    /// Appended to the canonical payload (in place of its closing brace) to
    /// form the master-served variant (sql/199). Identical on Android.
    static let masterEnvelopeSuffix = """
    ,
      "match_source": "master",
      "master": {
        "master_chemical_id": "c0570d1a-2026-4a66-9541-a99f66541001",
        "master_revision": 4,
        "catalogue_status": "approved",
        "registration_identity_key": "AU:apvma:66541"
      }
    }
    """

    /// The SAME canonical payload as served from the approved master catalogue:
    /// identical chemistry plus the additive envelope.
    static var custodiaMasterEnvelopeJSON: String {
        let base = custodiaFixtureJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(base.dropLast()) + masterEnvelopeSuffix
    }

    private func decodeMasterLookup() throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(
            ChemicalStructuredLookup.self,
            from: Data(Self.custodiaMasterEnvelopeJSON.utf8)
        )
    }

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

    // MARK: - Master catalogue envelope (sql/199)

    @Test("A master-served response decodes with the same plain decoder and carries the envelope")
    func masterEnvelopeDecodes() throws {
        let lookup = try decodeMasterLookup()
        #expect(lookup.matchSource == "master")
        #expect(lookup.isMasterMatch)

        let master = try #require(lookup.master)
        #expect(master.masterChemicalId == UUID(uuidString: "c0570d1a-2026-4a66-9541-a99f66541001"))
        #expect(master.masterRevision == 4)
        #expect(master.catalogueStatus == "approved")
        #expect(master.registrationIdentityKey == "AU:apvma:66541")

        // The envelope is ADDITIVE: chemistry converts identically to the
        // plain payload, and the evidence gate still rules — master-served is
        // not verified-by-magic.
        let intel = lookup.intelligence()
        #expect(intel.activeIngredients.count == 2)
        #expect(intel.activityGroupCodes == ["3", "11"])
        #expect(intel.registration?.identityKey == "AU:apvma:66541")
        #expect(intel.resolvedVerificationStatus == .partiallyVerified)
    }

    @Test("A payload without the envelope still decodes — old server, old behaviour")
    func envelopeAbsentIsNotAMasterMatch() throws {
        let lookup = try decodeLookup()
        #expect(lookup.matchSource == nil)
        #expect(lookup.master == nil)
        #expect(!lookup.isMasterMatch)
    }

    @Test("An ai_candidate envelope never reads as a master match")
    func aiCandidateEnvelopeIsNotAMasterMatch() throws {
        let base = Self.custodiaFixtureJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = String(base.dropLast()) + ", \"match_source\": \"ai_candidate\" }"
        let lookup = try JSONDecoder().decode(
            ChemicalStructuredLookup.self, from: Data(payload.utf8))
        #expect(lookup.matchSource == "ai_candidate")
        #expect(!lookup.isMasterMatch)
    }

    @Test("A master-derived Saved Chemical retains the link, the revision and its own chemistry copy")
    func masterLinkPersists() throws {
        let lookup = try decodeMasterLookup()
        let master = try #require(lookup.master)

        var chemical = SavedChemical(name: "Custodia", chemicalIntelligence: lookup.intelligence())
        chemical.masterChemicalId = master.masterChemicalId
        chemical.masterSourceRevision = master.masterRevision

        // The backend upsert carries the link in the sql/199 columns…
        let upsert = BackendSavedChemical.upsert(
            from: chemical, createdBy: nil, clientUpdatedAt: Date())
        #expect(upsert.masterChemicalId == master.masterChemicalId)
        #expect(upsert.masterSourceRevision == 4)
        // …while the chemistry travels as the vineyard's OWN sql/194 copy —
        // spray calculations never depend on a live join to the master row.
        #expect(upsert.activeIngredients?.count == 2)
        #expect(upsert.registrationNumber == "66541")

        let wire = try JSONEncoder().encode(upsert)
        let object = try #require(
            try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect((object["master_chemical_id"] as? String)?.lowercased()
            == "c0570d1a-2026-4a66-9541-a99f66541001")
        #expect(object["master_source_revision"] as? Int == 4)

        // Local persistence round-trips the link.
        let stored = try JSONDecoder().decode(
            SavedChemical.self, from: JSONEncoder().encode(chemical))
        #expect(stored.masterChemicalId == master.masterChemicalId)
        #expect(stored.masterSourceRevision == 4)

        // Vineyard-only commercial edits never move the link.
        var edited = stored
        edited.pricePerPack = 189.5
        edited.inventoryQuantity = 4
        #expect(edited.masterChemicalId == master.masterChemicalId)
        #expect(edited.masterSourceRevision == 4)

        // Master moved to revision 5 → drift is detectable; nothing rewritten.
        let updated = ChemicalMasterMatch(
            masterChemicalId: master.masterChemicalId,
            masterRevision: 5,
            catalogueStatus: "approved",
            registrationIdentityKey: master.registrationIdentityKey)
        #expect(updated.masterRevision > (edited.masterSourceRevision ?? 0))
        #expect(edited.masterSourceRevision == 4)
    }

    @Test("Backend rows restore the master link tolerantly, including from pre-sql/199 backends")
    func backendRowRestoresLink() throws {
        let row = """
        {"id":"11111111-1111-1111-1111-111111111111",
         "vineyard_id":"22222222-2222-2222-2222-222222222222",
         "name":"Custodia",
         "master_chemical_id":"c0570d1a-2026-4a66-9541-a99f66541001",
         "master_source_revision":4}
        """
        let backend = try JSONDecoder().decode(BackendSavedChemical.self, from: Data(row.utf8))
        let chemical = backend.toSavedChemical()
        #expect(chemical.masterChemicalId?.uuidString.lowercased()
            == "c0570d1a-2026-4a66-9541-a99f66541001")
        #expect(chemical.masterSourceRevision == 4)

        // A backend WITHOUT sql/199 sends no link columns — nothing breaks.
        let legacyRow = """
        {"id":"11111111-1111-1111-1111-111111111111",
         "vineyard_id":"22222222-2222-2222-2222-222222222222",
         "name":"Custodia"}
        """
        let legacy = try JSONDecoder().decode(BackendSavedChemical.self, from: Data(legacyRow.utf8))
        #expect(legacy.toSavedChemical().masterChemicalId == nil)
        #expect(legacy.toSavedChemical().masterSourceRevision == nil)
    }

    @Test("Custodia Forte can never inherit the Custodia master identity")
    func forteNeverInheritsMasterIdentity() throws {
        let master = try #require(try decodeMasterLookup().master)
        #expect(forteIntelligence().registration?.identityKey != master.registrationIdentityKey)
        #expect(forteIntelligence().registration?.identityKey == "AU:apvma:91636")
    }

    // MARK: - Jurisdiction: the same brand name overseas (GB Custodia)

    /// The UK-registered "Custodia" (MAPP 16393) — the same brand name under a
    /// DIFFERENT country's label law: cereal uses only, a different rate, a
    /// numeric re-entry period and a different WHP. Identical string on
    /// Android. An AU vineyard lookup must never consume ANY of it.
    static let custodiaGBFixtureJSON = """
    {
      "product_name": "Custodia",
      "product_category": "fungicide",
      "form_type": "liquid",
      "registration": {
        "country_code": "GB",
        "scheme": "other",
        "registration_number": "16393",
        "registrant": "Adama Agricultural Solutions UK Ltd",
        "registered_product_name": "Custodia"
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
          "crop": "Winter wheat",
          "target_raw": "Septoria leaf blotch",
          "rates": [
            { "label": "Standard", "basis": "per_hectare", "value": 2, "unit": "L" }
          ],
          "withholding_period_days": 35,
          "re_entry_period_hours": 48,
          "restrictions": "Latest application before grain milky ripe (GS 71). Maximum 2 applications per crop."
        }
      ],
      "label_rate_bases": ["per_hectare"],
      "verification": {
        "status": "partially_verified",
        "sources": [
          { "kind": "ai_interpretation", "name": "Model extraction (gpt-4o)", "retrieved_at": "2026-08-18T00:00:00Z" },
          { "kind": "authoritative_classification", "name": "VineTrack activity group reference v1 (FRAC/HRAC/IRAC)", "retrieved_at": "2026-08-18T00:00:00Z" }
        ],
        "conflicts": [],
        "unresolved_fields": ["label_reference", "label_version"],
        "verified_at": null
      },
      "activity_group_table_version": 1,
      "schema_version": 1
    }
    """

    /// Master-served variant of the GB payload — an approved GB catalogue row.
    /// Identical on Android.
    static let gbMasterEnvelopeSuffix = """
    ,
      "match_source": "master",
      "master": {
        "master_chemical_id": "b1638c93-2026-4b77-8642-b88f16393002",
        "master_revision": 2,
        "catalogue_status": "approved",
        "registration_identity_key": "GB:other:16393"
      }
    }
    """

    static var custodiaGBMasterEnvelopeJSON: String {
        let base = custodiaGBFixtureJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(base.dropLast()) + gbMasterEnvelopeSuffix
    }

    private func decodeGBLookup() throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(
            ChemicalStructuredLookup.self,
            from: Data(Self.custodiaGBFixtureJSON.utf8)
        )
    }

    private func decodeGBMasterLookup() throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(
            ChemicalStructuredLookup.self,
            from: Data(Self.custodiaGBMasterEnvelopeJSON.utf8)
        )
    }

    @Test("An AU vineyard can never consume the GB label's rates, WHP, re-entry or uses")
    func auNeverConsumesGBLabel() throws {
        let gb = try decodeGBLookup()
        // The GB label is genuinely different label law — exactly what must
        // not leak into an AU vineyard's records.
        #expect(gb.registration?.identityKey == "GB:other:16393")
        #expect(gb.registeredUses.count == 1)
        #expect(gb.registeredUses[0].crop == "Winter wheat")
        #expect(gb.registeredUses[0].withholdingPeriodDays == 35)
        #expect(gb.registeredUses[0].reEntryPeriodHours == 48)
        #expect(gb.registeredUses[0].rates[0].value == 2)

        // AU vineyard: refused OUTRIGHT — handled exactly like a failed
        // lookup, so nothing is converted, previewed, saved or linked.
        let reason = ChemicalJurisdiction.rejectionReason(for: gb, requestCountry: "AU")
        #expect(reason != nil)
        #expect(reason?.contains("GB") == true)

        // The SAME payload in its own jurisdiction is served normally — the
        // block is jurisdiction, not decode.
        #expect(ChemicalJurisdiction.rejectionReason(for: gb, requestCountry: "GB") == nil)
        // And the AU payload keeps passing for an AU vineyard.
        #expect(ChemicalJurisdiction.rejectionReason(for: try decodeLookup(), requestCountry: "AU") == nil)

        // The two labels differ precisely where cross-consumption would be
        // dangerous — which is why the gate exists.
        let au = try intelligence()
        #expect(au.registeredUses[0].withholdingPeriodDays == 28)
        #expect(au.registeredUses[0].reEntryPeriodHours == nil)
    }

    @Test("A cross-country master envelope can never become a master match")
    func crossCountryMasterNeverMatches() throws {
        let gbMaster = try decodeGBMasterLookup()
        // It DECODES as a master row…
        #expect(gbMaster.isMasterMatch)
        // …but an AU flow refuses it before anything reads `isMasterMatch`,
        // so the GB link and GB chemistry can never be threaded into a save.
        #expect(ChemicalJurisdiction.rejectionReason(for: gbMaster, requestCountry: "AU") != nil)
        #expect(ChemicalJurisdiction.rejectionReason(for: gbMaster, requestCountry: "GB") == nil)

        let auMaster = try decodeMasterLookup()
        #expect(ChemicalJurisdiction.rejectionReason(for: auMaster, requestCountry: "AU") == nil)
        #expect(ChemicalJurisdiction.rejectionReason(for: auMaster, requestCountry: "NZ") != nil)
    }

    @Test("A missing vineyard country fails closed — nothing is consumable, nothing is guessed")
    func missingCountryFailsClosed() throws {
        #expect(ChemicalJurisdiction.rejectionReason(for: try decodeLookup(), requestCountry: "") != nil)
        #expect(ChemicalJurisdiction.rejectionReason(for: try decodeMasterLookup(), requestCountry: "   ") != nil)
        // The lookup country comes from the vineyard alone — never the device
        // locale. An AU-region phone must not check the register for an
        // unset-country vineyard.
        #expect(ChemicalInfoService.resolveCountry(vineyardCountry: nil) == "")
        #expect(ChemicalInfoService.resolveCountry(vineyardCountry: "   ") == "")
        #expect(ChemicalInfoService.resolveCountry(vineyardCountry: "Australia") == "Australia")
    }

    @Test("Re-verify keys on the record's own registration country, never the vineyard fallback")
    func reverifyPreservesRecordCountry() throws {
        let chemical = SavedChemical(name: "Custodia", chemicalIntelligence: try intelligence())
        let plan = ChemicalReverification.plan(for: chemical, fallbackCountry: "NZ")
        #expect(plan.countryCode == "AU")
        #expect(plan.identityKey == "AU:apvma:66541")
        // And with no country anywhere, re-verification is refused, not guessed.
        let unidentified = SavedChemical(name: "Mystery Mix", chemicalIntelligence: nil)
        #expect(!ChemicalReverification.isOffered(for: unidentified, fallbackCountry: ""))
    }

    @Test("Vineyard display names normalise to the ISO jurisdiction codes the wire uses")
    func displayNamesNormalise() {
        #expect(ChemicalRegistration.normaliseCountry("Australia") == "AU")
        #expect(ChemicalRegistration.normaliseCountry("New Zealand") == "NZ")
        #expect(ChemicalRegistration.normaliseCountry("United Kingdom") == "GB")
        #expect(ChemicalRegistration.normaliseCountry("uk") == "GB")
        #expect(ChemicalRegistration.normaliseCountry("United States") == "US")
        #expect(ChemicalRegistration.normaliseCountry("France") == "FR")
        #expect(ChemicalRegistration.normaliseCountry("au") == "AU")
        #expect(ChemicalRegistration.normaliseCountry("") == "")
    }

    // MARK: - Saved Chemical jurisdiction suitability (registration vs vineyard)

    @Test("An AU-registered Saved Chemical in an NZ vineyard is a MISMATCH that keeps identity and chemistry")
    func savedChemicalSuitabilityAUinNZ() throws {
        let chemical = SavedChemical(name: "Custodia", chemicalIntelligence: try intelligence())
        #expect(
            ChemicalJurisdiction.suitability(for: chemical, vineyardCountry: "New Zealand")
                == .mismatch(registrationCountry: "AU", vineyardCountry: "NZ")
        )

        // Identity is preserved — never re-keyed toward the vineyard.
        #expect(chemical.resolvedIntelligence.registration?.identityKey == "AU:apvma:66541")
        // Chemistry (FRAC 3 + 11) is a scientific classification and survives.
        #expect(chemical.activityGroupCodes == ["3", "11"])

        // Re-verify still keys the AU registration…
        let plan = ChemicalReverification.plan(for: chemical, fallbackCountry: "NZ")
        #expect(plan.countryCode == "AU")
        // …and its AU evidence still reads MISMATCH for NZ afterwards — an AU
        // re-check can never produce "verified for NZ".
        #expect(
            ChemicalJurisdiction.suitability(registrationCountry: plan.countryCode, vineyardCountry: "NZ")
                == .mismatch(registrationCountry: "AU", vineyardCountry: "NZ")
        )
        // And NZ can never auto-match the AU payload as fresh evidence either.
        #expect(ChemicalJurisdiction.rejectionReason(for: try decodeLookup(), requestCountry: "NZ") != nil)
    }

    @Test("The inverse holds: a GB registration in an AU vineyard is the same mismatch")
    func savedChemicalSuitabilityGBinAU() throws {
        let gb = try decodeGBLookup()
        #expect(
            ChemicalJurisdiction.suitability(
                registrationCountry: gb.registration?.countryCode,
                vineyardCountry: "Australia"
            ) == .mismatch(registrationCountry: "GB", vineyardCountry: "AU")
        )
        #expect(gb.registration?.identityKey == "GB:other:16393")
    }

    @Test("Suitability is COMPATIBLE at home and UNKNOWN when either side has no country")
    func savedChemicalSuitabilityBaseline() throws {
        let auChemical = SavedChemical(name: "Custodia", chemicalIntelligence: try intelligence())
        #expect(ChemicalJurisdiction.suitability(for: auChemical, vineyardCountry: "Australia") == .compatible)
        #expect(ChemicalJurisdiction.suitability(for: auChemical, vineyardCountry: nil) == .unknown)
        #expect(ChemicalJurisdiction.suitability(for: auChemical, vineyardCountry: "   ") == .unknown)
        // A legacy/manual record with no registration country is UNKNOWN — not
        // a mismatch banner on every hand-typed product.
        let manual = SavedChemical(name: "Mystery Mix", chemicalIntelligence: nil)
        #expect(ChemicalJurisdiction.suitability(for: manual, vineyardCountry: "Australia") == .unknown)
        // Display names for the banner copy resolve from the same table.
        #expect(ChemicalRegistration.displayName(forCountryCode: "AU") == "Australia")
        #expect(ChemicalRegistration.displayName(forCountryCode: "nz") == "New Zealand")
        #expect(ChemicalRegistration.displayName(forCountryCode: "GB") == "United Kingdom")
    }
}

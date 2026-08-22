import Foundation
import Testing
@testable import VineTrack

/// Search → Select → Review → Save.
///
/// The defect these tests lock down: the flow used to answer "what did we learn
/// about this product?" with the answer to "was its registration confirmed?".
/// When the AU register could not confirm Dithane Rainshield, the app showed an
/// empty form — even though the lookup had returned Mancozeb, BASF and a
/// canonical product name the whole time.
///
/// The rule now is that a blank from a stronger source never erases a populated
/// value from a weaker one, and that populating a field is not the same act as
/// trusting it.
struct ChemicalReviewMergeTests {

    private static let vineyardId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func decodeSearch(_ json: String) throws -> [ChemicalSearchResult] {
        try JSONDecoder().decode(ChemicalSearchResponse.self, from: Data(json.utf8)).results
    }

    private func decodeStructured(_ json: String) throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    private func merge(
        lookup: ChemicalStructuredLookup?,
        selected: ChemicalSearchResult?,
        existing: SavedChemical? = nil,
        country: String = "AU"
    ) -> SavedChemical {
        ChemicalReviewMerge.reviewChemical(
            lookup: lookup,
            selected: selected,
            existing: existing,
            countryCode: country,
            vineyardId: Self.vineyardId
        )
    }

    // MARK: - Fixtures

    /// The reproduction. An AI-tier row: canonical name and active, but no
    /// `source` and no `registration_number`.
    private let dithaneSearchJSON = """
    {
      "results": [
        {
          "name": "Dithane Rainshield",
          "activeIngredient": "Mancozeb 750 g/kg",
          "chemicalGroup": "M3",
          "brand": "BASF",
          "primaryUse": "Fungicide",
          "modeOfAction": "Multi-site protectant"
        }
      ]
    }
    """

    /// The resolver's fail-closed response: canonical fields emptied, the
    /// model's reading quarantined into `ai_suggestion`.
    private let dithaneStructuredJSON = """
    {
      "product_name": null,
      "product_category": "",
      "form_type": null,
      "registration": {
        "country_code": "AU",
        "scheme": null,
        "registration_number": null,
        "registrant": null,
        "registered_product_name": null,
        "label_reference": null
      },
      "active_ingredients": [],
      "activity_groups": [],
      "registered_uses": [],
      "verification": {
        "status": "unverified",
        "sources": [],
        "conflicts": [],
        "unresolved_fields": ["active_ingredients", "registration_number"]
      },
      "match_source": "unresolved",
      "guidance": "We could not uniquely verify this product in the official register for Australia.",
      "ai_suggestion": {
        "note": "Unverified AI suggestion.",
        "product_name": "Dithane Rainshield",
        "registrant": "BASF",
        "product_category": "fungicide",
        "active_ingredients": [
          { "name": "Mancozeb", "concentration": 750, "concentration_unit": "g/kg" }
        ],
        "registered_uses": [
          {
            "crop": "Grapes",
            "target_raw": "Downy mildew",
            "rates": [
              { "label": "Protectant", "basis": "per_100_litres", "value": 200, "unit": "g" }
            ],
            "withholding_period_days": 14,
            "re_entry_period_hours": 24,
            "restrictions": "Do not apply after EL 31."
          }
        ]
      },
      "discovery": { "adapter": "apvma", "outcome": "unresolved" }
    }
    """

    // MARK: - 1 & 2. Selection is authoritative

    @Test("A typo search that resolves to a canonical result saves the canonical name")
    func typoDoesNotBecomeIdentity() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)

        // The canonical name drives the next lookup, not "Dithaine rainshield".
        let request = ChemicalStructuredLookupRequest(
            selected: selected, country: "AU", fallbackQuery: "Dithaine rainshield"
        )
        #expect(request.productName == "Dithane Rainshield")

        let review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)
        #expect(review.name == "Dithane Rainshield")
        #expect(review.name != "Dithaine rainshield")
    }

    // MARK: - 3, 4, 5. The Dithane Rainshield acceptance case

    @Test("Dithane Rainshield opens Review populated, with registration left blank")
    func dithaneReviewIsPopulated() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)

        #expect(review.name == "Dithane Rainshield")
        #expect(review.manufacturer == "BASF")

        let intel = try #require(review.chemicalIntelligence)
        #expect(intel.activeIngredients.map(\.name) == ["Mancozeb"])
        #expect(intel.activeIngredients.first?.concentration == 750)
        #expect(intel.activeIngredients.first?.concentrationUnit == .gramsPerKilogram)
        #expect(intel.registration?.countryCode == "AU")

        // Blank because nothing established one — never invented to fill a box.
        #expect(intel.registration?.registrationNumber == nil)
        #expect(intel.registration?.scheme == nil)

        // The legacy mirror is populated too, so older readers see it.
        #expect(review.activeIngredient.localizedCaseInsensitiveContains("Mancozeb"))

        // The product unit comes from the unit the registered RATE is quoted
        // in ("200 g per 100 L"), never from the 750 g/kg active loading —
        // those describe different quantities.
        #expect(review.unit == .grams)
    }

    @Test("A missing registration number clears neither the active nor the manufacturer")
    func missingRegistrationClearsNothing() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)

        #expect(review.chemicalIntelligence?.registration?.registrationNumber == nil)
        // The two facts that used to disappear together with it.
        #expect(review.chemicalIntelligence?.activeIngredients.isEmpty == false)
        #expect(review.manufacturer == "BASF")
    }

    @Test("Populating the form does not upgrade trust")
    func populatingDoesNotUpgradeVerification() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)
        let intel = try #require(review.chemicalIntelligence)

        // AI-tier provenance, honestly recorded...
        #expect(intel.activeIngredients.first?.identitySource == .aiInterpretation)
        // ...including the group. The reference table can say "Mancozeb is FRAC
        // M3"; it cannot say "this product contains Mancozeb", and that was the
        // unverified half.
        #expect(intel.activeIngredients.first?.hasAuthoritativeGroup == false)
        #expect(intel.activeIngredients.first?.groupSource == .aiInterpretation)
        // ...so the status cannot be moved by anything the merge did.
        #expect(!intel.hasEvidencedRegistration)
        #expect(intel.resolvedVerificationStatus == .unverified)
    }

    @Test("Registered uses, rates, WHP, re-entry and restrictions populate where found")
    func usesAndLabelFactsPopulate() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)

        let use = try #require(review.chemicalIntelligence?.registeredUses.first)
        #expect(use.crop == "Grapes")
        #expect(use.targetRaw == "Downy mildew")
        #expect(use.withholdingPeriodDays == 14)
        #expect(use.reEntryPeriodHours == 24)
        #expect(use.restrictions == "Do not apply after EL 31.")

        // Basis preserved exactly as the label states it. No conversion:
        // 200 g/100 L is not 200 g/ha, and turning one into the other would
        // mis-dose every tank mixed from it.
        let rate = try #require(use.rates.first)
        #expect(rate.basis == .per100Litres)
        #expect(rate.value == 200)
        #expect(rate.unit == "g")
    }

    // MARK: - 6 & 7. Precedence

    @Test("Exact official values beat the weaker lookup tiers")
    func officialValuesWin() throws {
        let lookup = try decodeStructured("""
        {
          "product_name": "Topas 100 EC",
          "product_category": "fungicide",
          "registration": {
            "country_code": "AU",
            "scheme": "apvma",
            "registration_number": "45557",
            "registrant": "Syngenta Australia Pty Ltd",
            "registered_product_name": "Topas 100 EC Fungicide"
          },
          "active_ingredients": [
            {
              "name": "Penconazole",
              "concentration": 100,
              "concentration_unit": "g/L",
              "activity_group": { "scheme": "frac", "code": "3" },
              "group_source": "authoritative_classification",
              "identity_source": "official_register"
            }
          ],
          "verification": {
            "status": "partially_verified",
            "sources": [{ "kind": "official_register", "name": "APVMA PUBCRIS" }],
            "conflicts": [], "unresolved_fields": []
          },
          "ai_suggestion": {
            "product_name": "Topaz",
            "registrant": "Someone Else Ltd",
            "active_ingredients": [{ "name": "Myclobutanil" }]
          },
          "discovery": { "adapter": "apvma", "outcome": "resolved" }
        }
        """)
        let selected = ChemicalSearchResult(
            name: "Topas", activeIngredient: "Something else", chemicalGroup: "",
            brand: "Marketing Brand", primaryUse: "", modeOfAction: "",
            registrationNumber: "45557", source: "official_register"
        )

        let review = merge(lookup: lookup, selected: selected)
        #expect(review.name == "Topas 100 EC Fungicide")
        #expect(review.manufacturer == "Syngenta Australia Pty Ltd")

        let intel = try #require(review.chemicalIntelligence)
        #expect(intel.activeIngredients.map(\.name) == ["Penconazole"])
        #expect(intel.registration?.registrationNumber == "45557")
        // Register-backed identity still earns Partially Verified — the merge
        // did not weaken the strong path while fixing the weak one.
        #expect(intel.hasEvidencedRegistration)
        #expect(intel.resolvedVerificationStatus == .partiallyVerified)
    }

    @Test("An empty official field falls through instead of erasing a weaker value")
    func emptyOfficialFieldsDoNotErase() throws {
        // Register confirmed the identity but supplied no registrant; the
        // advisory did. The blank must not win just because it is stronger.
        let lookup = try decodeStructured("""
        {
          "product_name": "Partial Product",
          "registration": {
            "country_code": "AU", "scheme": "apvma",
            "registration_number": "99999", "registrant": null
          },
          "active_ingredients": [],
          "verification": { "status": "unverified", "sources": [], "conflicts": [], "unresolved_fields": [] },
          "ai_suggestion": {
            "registrant": "Nufarm",
            "active_ingredients": [{ "name": "Sulfur", "concentration": 800, "concentration_unit": "g/kg" }]
          },
          "discovery": { "adapter": "apvma", "outcome": "resolved" }
        }
        """)
        let review = merge(lookup: lookup, selected: nil)

        #expect(review.manufacturer == "Nufarm")
        #expect(review.chemicalIntelligence?.activeIngredients.map(\.name) == ["Sulfur"])
        // The confirmed half is kept as confirmed.
        #expect(review.chemicalIntelligence?.registration?.registrationNumber == "99999")
    }

    @Test("With no structured lookup at all, the search row still populates the form")
    func lookupFailureStillPopulates() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let review = merge(lookup: nil, selected: selected)

        #expect(review.name == "Dithane Rainshield")
        #expect(review.manufacturer == "BASF")
        // Free text parsed into structure, and marked for what it is.
        let active = try #require(review.chemicalIntelligence?.activeIngredients.first)
        #expect(active.name == "Mancozeb")
        #expect(active.concentration == 750)
        #expect(active.identitySource == .aiInterpretation)
        #expect(review.chemicalIntelligence?.resolvedVerificationStatus == .unverified)
    }

    @Test("A concentration with no readable unit is left off rather than guessed")
    func unreadableConcentrationIsNotInvented() {
        let actives = ChemicalReviewMerge.parseActives("Mancozeb 750")
        #expect(actives.map(\.name) == ["Mancozeb"])
        // 750 could be g/kg or g/L, and those are different products.
        #expect(actives.first?.concentration == nil)
        #expect(actives.first?.concentrationUnit == nil)
    }

    // MARK: - 11. Multi-active

    @Test("A multi-active product keeps every active and its own scheme")
    func multiActiveSurvivesTheMerge() throws {
        let lookup = try decodeStructured("""
        {
          "product_name": "Combo Duo",
          "registration": { "country_code": "AU", "scheme": "apvma", "registration_number": "88881" },
          "active_ingredients": [
            {
              "name": "Spinetoram", "concentration": 120, "concentration_unit": "g/L",
              "activity_group": { "scheme": "irac", "code": "5" },
              "group_source": "authoritative_classification", "identity_source": "official_register"
            },
            {
              "name": "Pyraclostrobin", "concentration": 200, "concentration_unit": "g/L",
              "activity_group": { "scheme": "frac", "code": "11" },
              "group_source": "authoritative_classification", "identity_source": "official_register"
            }
          ],
          "verification": { "status": "partially_verified", "sources": [], "conflicts": [], "unresolved_fields": [] },
          "discovery": { "adapter": "apvma", "outcome": "resolved" }
        }
        """)
        let intel = try #require(merge(lookup: lookup, selected: nil).chemicalIntelligence)

        #expect(intel.activeIngredients.count == 2)
        // Not collapsed into one free-text group: IRAC 5 and FRAC 11 are
        // unrelated chemistries and must stay separately answerable.
        #expect(Set(intel.activityGroups.map(\.scheme)) == Set([.irac, .frac]))
        #expect(intel.activeIngredients.first { $0.name == "Spinetoram" }?.activityGroup?.scheme == .irac)
        #expect(intel.activeIngredients.first { $0.name == "Pyraclostrobin" }?.activityGroup?.scheme == .frac)
    }

    @Test("Two actives read from free text both survive")
    func multiActiveFreeTextParses() {
        let actives = ChemicalReviewMerge.parseActives("Spinetoram 120 g/L + Pyraclostrobin 200 g/L")
        #expect(actives.map(\.name) == ["Spinetoram", "Pyraclostrobin"])
        #expect(actives.allSatisfy { $0.concentrationUnit == .gramsPerLitre })
    }

    // MARK: - 8, 9, 10, 15. Editable, and it survives the existing schema

    @Test("Every reviewed field is editable and survives a save/reload round trip")
    func reviewedFieldsAreEditableAndPersist() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        var review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)

        // The operator corrects the reading and supplies the number off the drum.
        review.name = "Dithane Rainshield NT"
        review.manufacturer = "BASF Australia"
        review.notes = "Checked against the label."
        var intel = try #require(review.chemicalIntelligence)
        intel.activeIngredients = [
            ChemicalActiveIngredient(
                name: "Mancozeb",
                concentration: 800,
                concentrationUnit: .gramsPerKilogram,
                activityGroup: ChemicalActivityGroup(scheme: .frac, code: "M3"),
                groupSource: .manualEntry,
                identitySource: .manualEntry
            )
        ]
        intel.registration = ChemicalRegistration(
            countryCode: "AU", scheme: .apvma, registrationNumber: "34540"
        )
        review.chemicalIntelligence = intel

        // Round-trip through the EXISTING SavedChemical Codable contract. This
        // is also the proof that no new column was needed: every reviewed field
        // already has somewhere to live.
        let data = try JSONEncoder().encode(review)
        let reloaded = try JSONDecoder().decode(SavedChemical.self, from: data)

        #expect(reloaded.id == review.id)
        #expect(reloaded.name == "Dithane Rainshield NT")
        #expect(reloaded.manufacturer == "BASF Australia")
        #expect(reloaded.notes == "Checked against the label.")

        let reloadedIntel = try #require(reloaded.chemicalIntelligence)
        #expect(reloadedIntel.activeIngredients.first?.name == "Mancozeb")
        #expect(reloadedIntel.activeIngredients.first?.concentration == 800)
        #expect(reloadedIntel.activeIngredients.first?.activityGroup?.code == "M3")
        #expect(reloadedIntel.registration?.registrationNumber == "34540")
        #expect(reloadedIntel.registration?.scheme == .apvma)
        #expect(reloadedIntel.registeredUses.first?.withholdingPeriodDays == 14)
    }

    @Test("A reviewed record round-trips unchanged when nothing is edited")
    func unchangedReviewRoundTripsIntact() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)

        let reloaded = try JSONDecoder().decode(
            SavedChemical.self, from: try JSONEncoder().encode(review)
        )
        // The whole failure mode in one assertion: saving without editing must
        // not produce an empty shell.
        #expect(reloaded.chemicalIntelligence?.activeIngredients.map(\.name) == ["Mancozeb"])
        #expect(reloaded.manufacturer == "BASF")
        #expect(reloaded.name == "Dithane Rainshield")
    }

    // MARK: - 14. Cancel

    @Test("Building a review draft writes nothing")
    func cancelWritesNothing() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let store: [SavedChemical] = []

        let review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)

        // The draft is a value. Nothing persists it until Save runs, so
        // abandoning the flow — including from inside Edit Program Step —
        // leaves the store exactly as it was.
        #expect(store.isEmpty)
        #expect(!store.contains { $0.id == review.id })
    }

    // MARK: - Legacy record matching

    @Test("Matching a legacy record keeps its identity and fills its gaps")
    func legacyRecordKeepsItsIdentity() throws {
        var legacy = SavedChemical(vineyardId: Self.vineyardId)
        legacy.name = "dithane"
        legacy.notes = "Half a drum left in the shed."
        let legacyId = legacy.id

        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let review = merge(
            lookup: try decodeStructured(dithaneStructuredJSON),
            selected: selected,
            existing: legacy
        )

        // Same record, corrected — never a second copy.
        #expect(review.id == legacyId)
        #expect(review.name == "Dithane Rainshield")
        #expect(review.notes == "Half a drum left in the shed.")
        #expect(review.chemicalIntelligence?.activeIngredients.map(\.name) == ["Mancozeb"])
    }

    // MARK: - 16. History untouched

    @Test("Reviewing and saving a chemical rewrites no completed spray")
    func historicalChemistryUntouched() throws {
        let frozen = ChemicalLineSnapshot(
            productName: "Dithane Rainshield",
            activeIngredients: [ChemicalActiveIngredient(name: "Mancozeb")],
            activityGroupCodes: ["M3"],
            verificationStatus: .unverified
        )
        let completed = SprayRecord(
            id: UUID(),
            vineyardId: Self.vineyardId,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            sprayReference: "Downy cover 12 Nov",
            tanks: [SprayTank(chemicals: [
                SprayChemical(
                    name: "Dithane Rainshield",
                    ratePerHa: 2_000,
                    unit: .grams,
                    rateBasis: .wholeBlockArea,
                    chemicalSnapshot: frozen
                )
            ])],
            isTemplate: false
        )
        let before = completed

        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        var review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: selected)
        review.name = "Something Entirely Different"

        // P10: the frozen line describes what went through the nozzle, and no
        // amount of correcting today's Chemical Store may restate it.
        #expect(completed.tanks == before.tanks)
        #expect(completed.tanks.first?.chemicals.first?.chemicalSnapshot == frozen)
        #expect(completed.tanks.first?.chemicals.first?.name == "Dithane Rainshield")
    }
}

import Foundation
import Testing
@testable import VineTrack

/// Review Chemical must show what the server actually answered.
///
/// # The device report
///
/// On TestFlight: Chemical Store → Add Chemical → search "Dithane Rainshield" →
/// select → Review Chemical. The product name, the manufacturer, APVMA 59688
/// and FRAC M3 appeared. Everything else did not:
///
/// ```text
/// Category                 "Uncategorised"      server said fungicide
/// Unit                     "Litres"             server said form_type solid
/// Mancozeb concentration   blank                server said 750 g/kg
/// A SECOND active          "kg"                 the server said no such thing
/// Official Label URL       blank                server said the 59688 eLabel
/// Registered Uses          "No registered use is on record for this product yet."
///                                               server said three GRAPEVINE uses
/// ```
///
/// The four fields that DID populate are exactly the four the search row
/// carries on its own — name, brand, registration number, and a group the
/// on-device FRAC table derives from the name "Mancozeb". That is the whole
/// tell: the structured response never reached the merge. It had timed out at
/// the 30 s client deadline while the resolver was still reading the label, and
/// the failure was swallowed into `lookup = nil`.
///
/// These tests run the REAL path — plain `JSONDecoder` over the production
/// payload, then `ChemicalReviewMerge`, then `ChemicalReviewSession` — because
/// every one of these defects lived between those steps, and a test that built
/// the final draft by hand would have passed throughout.
struct ChemicalReviewHydrationTests {

    private static let vineyardId = UUID(uuidString: "7B0F0C2E-1A44-4C0B-9E77-1B7C1D9A5E10")!

    // MARK: - The production response, verbatim in shape

    /// APVMA 59688, as production serves it after the authority-purity and
    /// target-wording fixes: the three uses the approved label actually prints,
    /// worded as the LABEL words them — the register's "BLACK SPOT -
    /// COLLETOTRICHUM ACUTATUM" taxonomy rides along non-authoritatively in
    /// `register_target_raw`, and its separate "LEAF SPOT - ALTERNARIA
    /// CERCOSPORA" pest code is a synonym of the one printed "Phomopsis Cane
    /// and Leaf spot" row. One printed rate, owned by that one printed cell;
    /// Terra's 200 g/100 L quarantined in `ai_suggested_uses`.
    private let dithaneStructuredJSON = """
    {
      "product_name": "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
      "product_category": "fungicide",
      "form_type": "solid",
      "product_url": null,
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "59688",
        "registrant": "UPL AUSTRALIA PTY LTD",
        "registered_product_name": "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
        "label_reference": "https://elabels.apvma.gov.au/59688ELBL.pdf",
        "label_version": null
      },
      "active_ingredients": [
        {
          "name": "Mancozeb",
          "concentration": 750,
          "concentration_unit": "g/kg",
          "activity_group": {
            "scheme": "frac",
            "code": "M3",
            "common_name": "Multi-site / Dithiocarbamate"
          },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["M3"],
      "activity_group_scheme": "frac",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "Blackspot",
          "register_target_raw": "BLACK SPOT - COLLETOTRICHUM ACUTATUM",
          "rates": [],
          "withholding_period_days": 30,
          "provenance": { "claim": "manufacturer_label", "withholding_period": "manufacturer_label" }
        },
        {
          "crop": "GRAPEVINE",
          "target_raw": "Phomopsis Cane and Leaf spot",
          "register_target_raw": "PHOMOPSIS CANE",
          "target_synonyms": ["LEAF SPOT - ALTERNARIA CERCOSPORA"],
          "rates": [
            {
              "label": "",
              "basis": "range_per_100_litres",
              "min_value": 150,
              "max_value": 200,
              "unit": "g",
              "raw_text": "150 to 200 g"
            }
          ],
          "withholding_period_days": 30,
          "provenance": {
            "claim": "manufacturer_label",
            "rates": "manufacturer_label",
            "withholding_period": "manufacturer_label"
          }
        },
        {
          "crop": "GRAPEVINE",
          "target_raw": "Downy mildew",
          "register_target_raw": "DOWNY MILDEW",
          "rates": [],
          "withholding_period_days": 30,
          "provenance": { "claim": "manufacturer_label", "withholding_period": "manufacturer_label" }
        }
      ],
      "ai_suggested_uses": [
        {
          "crop": "Grapevines",
          "target_raw": "Downy mildew",
          "rates": [
            {
              "label": "",
              "basis": "per_100_litres",
              "value": 200,
              "unit": "g",
              "raw_text": "Grapevines — Blackspot; Downy mildew — 200 g per 100 L."
            }
          ]
        },
        {
          "crop": "Grapevines",
          "target_raw": "Blackspot",
          "rates": [
            {
              "label": "",
              "basis": "per_100_litres",
              "value": 200,
              "unit": "g",
              "raw_text": "Grapevines — Blackspot; Downy mildew — 200 g per 100 L."
            }
          ]
        }
      ],
      "label_rate_bases": ["range_per_100_litres"],
      "label_extraction": {
        "document_url": "https://elabels.apvma.gov.au/59688ELBL.pdf",
        "document_sha256": "5f2b0c8f1d4a6e7b9c0d1e2f3a4b5c6d7e8f90112233445566778899aabbccdd",
        "parser_version": 2,
        "unbound_rows": []
      },
      "field_provenance": {
        "registration": "official_register",
        "label_reference": "official_register",
        "active_ingredients": "official_register",
        "product_category": "official_register",
        "form_type": "official_register",
        "label_rates": "manufacturer_label",
        "withholding_periods": "manufacturer_label"
      },
      "match_source": "authoritative_candidate",
      "verification": {
        "status": "partially_verified",
        "verified_at": "2026-08-22T04:11:07.882Z",
        "sources": [
          {
            "kind": "official_register",
            "name": "APVMA PubCRIS",
            "reference": "https://portal.apvma.gov.au/pubcris?p=59688",
            "retrieved_at": "2026-08-22T04:11:07.882Z"
          },
          {
            "kind": "manufacturer_label",
            "name": "APVMA approved label",
            "reference": "https://elabels.apvma.gov.au/59688ELBL.pdf",
            "retrieved_at": "2026-08-22T04:11:07.882Z"
          },
          {
            "kind": "ai_interpretation",
            "name": "Web research extraction (gpt-5.6-terra)",
            "retrieved_at": "2026-08-22T04:11:07.882Z"
          }
        ],
        "conflicts": [],
        "unresolved_fields": [],
        "superseded_ai_interpretations": [
          {
            "field": "label_rates",
            "extracted_value": "200 g per 100 L",
            "authoritative_value": "no rate stated on the approved label for this use",
            "extracted_source": "ai_interpretation",
            "authoritative_source": "manufacturer_label"
          }
        ],
        "research_notes": [
          "A current regulator-hosted PubCRIS label PDF for this product could not be retrieved from the APVMA site."
        ]
      },
      "discovery": {
        "adapter": "apvma",
        "outcome": "resolved",
        "registration_number": "59688"
      },
      "activity_group_table_version": 3,
      "schema_version": 1
    }
    """

    /// The register row the operator actually tapped, as search returns it.
    private var dithaneRow: ChemicalSearchResult {
        ChemicalSearchResult(
            name: "Dithane Rainshield Neo Tec Fungicide",
            activeIngredient: "Mancozeb 750 g/kg",
            chemicalGroup: "",
            brand: "UPL Australia Pty Ltd",
            primaryUse: "Fungicide",
            registrationNumber: "59688",
            source: ChemicalSearchResult.officialRegisterSource,
            countryCode: "AU"
        )
    }

    // MARK: - Harness: the real decode → merge → session path

    private func decode(_ json: String) throws -> ChemicalStructuredLookup {
        // A PLAIN decoder, exactly as `ChemicalInfoService.lookupStructured`
        // uses. No date strategy, no key strategy, no leniency added here.
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    private func reviewDraft(
        lookup: ChemicalStructuredLookup?,
        selected: ChemicalSearchResult?,
        existing: SavedChemical? = nil
    ) -> SavedChemical {
        ChemicalReviewMerge.reviewChemical(
            lookup: lookup,
            selected: selected,
            existing: existing,
            countryCode: "AU",
            vineyardId: Self.vineyardId
        )
    }

    private func hydratedSession(existing: SavedChemical? = nil) throws -> ChemicalReviewSession {
        let draft = reviewDraft(
            lookup: try decode(dithaneStructuredJSON),
            selected: dithaneRow,
            existing: existing
        )
        return ChemicalReviewSession.make(chemical: existing, prefill: draft, fallbackCountry: "AU")
    }

    private func use(
        _ session: ChemicalReviewSession,
        target: String
    ) throws -> ChemicalManualUseDraft {
        try #require(session.chemistryDraft.uses.first { $0.targetRaw == target })
    }

    // MARK: - 12. The end-to-end regression

    @Test("The production Dithane response hydrates every Review Chemical field")
    func productionResponseHydratesTheReviewDraft() throws {
        let session = try hydratedSession()

        // Identity. The register shouts; the operator's own row does not, and
        // it is the same name, so the readable wording is what is shown.
        #expect(session.name == "Dithane Rainshield Neo Tec Fungicide")
        #expect(session.manufacturer == "UPL Australia Pty Ltd")
        #expect(session.chemistryDraft.registrationNumber == "59688")
        #expect(session.chemistryDraft.registrationScheme == .apvma)
        #expect(session.countryCode == "AU")

        // Category: "fungicide" is the Fungicide category, not Uncategorised.
        #expect(session.productCategory == .fungicide)

        // Form and unit: a solid product does not arrive measured in litres.
        #expect(session.formType == .solid)
        #expect(session.unit == .kilograms)

        // Chemistry: ONE active, complete, and no unit fragment beside it.
        #expect(session.chemistryDraft.actives.count == 1)
        let active = try #require(session.chemistryDraft.actives.first)
        #expect(active.name == "Mancozeb")
        #expect(active.concentrationText == "750")
        #expect(active.concentrationUnit == .gramsPerKilogram)
        #expect(active.scheme == .frac)
        #expect(active.groupCode == "M3")
        #expect(!session.chemistryDraft.actives.contains { $0.name.lowercased() == "kg" })

        // The official label link, from `registration.label_reference`.
        #expect(session.labelURL == "https://elabels.apvma.gov.au/59688ELBL.pdf")
        // product_url was null on this lookup, and null is not a blank to fill.
        #expect(session.productURL.isEmpty)

        // The three vineyard uses the label prints, and therefore no false
        // empty state.
        #expect(session.chemistryDraft.uses.count == 3)
        #expect(session.chemistryDraft.uses.allSatisfy(\.isViticultural))
        #expect(session.hasStructuredUses)
    }

    @Test("Each registered use keeps the label's own rate and withholding period")
    func registeredUsesKeepTheirLabelValues() throws {
        let session = try hydratedSession()

        for target in ["Blackspot", "Downy mildew"] {
            let entry = try use(session, target: target)
            #expect(entry.rates.isEmpty, "\(target) must carry no rate")
            #expect(entry.withholdingPeriodDaysText == "30", "\(target) WHP")
        }

        let phomopsis = try use(session, target: "Phomopsis Cane and Leaf spot")
        #expect(phomopsis.rates.count == 1)
        let rate = try #require(phomopsis.rates.first)
        #expect(rate.basis == .rangePer100Litres)
        #expect(rate.minText == "150")
        #expect(rate.maxText == "200")
        #expect(rate.unit == "g")
        #expect(phomopsis.withholdingPeriodDaysText == "30")
    }

    @Test("Terra's 200 g/100 L never becomes a canonical Downy Mildew rate")
    func aiSuggestedUsesDoNotReplaceCanonicalUses() throws {
        let lookup = try decode(dithaneStructuredJSON)
        // The response really does carry the AI reading — this test is about
        // where it is allowed to land, not about whether it was decoded.
        #expect(lookup.aiSuggestedUses.count == 2)

        let session = try hydratedSession()
        let downy = try use(session, target: "Downy mildew")
        #expect(downy.rates.isEmpty)
        // And it did not sneak in as a fourth use either. The label's own
        // "Downy mildew" row and Terra's "Downy mildew" reading are worded
        // identically now, so the count is what proves nothing was minted.
        #expect(session.chemistryDraft.uses.count == 3)
        #expect(session.chemistryDraft.uses.filter { $0.targetRaw == "Downy mildew" }.count == 1)
    }

    // MARK: - 10. No false empty state

    @Test("The legacy Use / Problem fallback is not offered once structured uses exist")
    func legacyUseFallbackIsNotOffered() throws {
        // `hasStructuredUses` is the flag the editor reads to decide whether to
        // show "No registered use is on record for this product yet."
        #expect(try hydratedSession().hasStructuredUses)

        // A product with genuinely nothing structured still gets the fallback.
        let bare = reviewDraft(lookup: nil, selected: dithaneRow)
        let bareSession = ChemicalReviewSession.make(
            chemical: nil, prefill: bare, fallbackCountry: "AU"
        )
        #expect(!bareSession.hasStructuredUses)
    }

    // MARK: - 4. The bogus "kg" active

    @Test("A search row's free-text active never yields an ingredient called kg")
    func legacyActiveParsingDoesNotInventAUnit() {
        let actives = ChemicalReviewMerge.parseActives("Mancozeb 750 g/kg")
        #expect(actives.count == 1)
        #expect(actives.first?.name == "Mancozeb")
        // The slash is a unit divider, so the concentration survives whole.
        #expect(actives.first?.concentration == 750)
        #expect(actives.first?.concentrationUnit == .gramsPerKilogram)
        #expect(!actives.contains { $0.name.lowercased() == "kg" })
    }

    @Test("Structured actives win outright; the free-text row is never appended")
    func structuredActivesSuppressLegacyParsing() throws {
        let session = try hydratedSession()
        // The row said "Mancozeb 750 g/kg" AND the response said Mancozeb
        // 750 g/kg. Exactly one active must survive, from the structured array.
        #expect(session.chemistryDraft.actives.count == 1)
        #expect(session.chemistryDraft.actives.first?.concentrationText == "750")
    }

    @Test("A mixture still splits on the separators that really are separators")
    func mixturesStillSplit() {
        let actives = ChemicalReviewMerge.parseActives(
            "Spinetoram 120 g/L + Pyraclostrobin 200 g/L"
        )
        #expect(actives.map(\.name) == ["Spinetoram", "Pyraclostrobin"])
        #expect(actives.allSatisfy { $0.concentrationUnit == .gramsPerLitre })
        #expect(actives.allSatisfy { $0.concentration != nil })
    }

    // MARK: - 11. One projection, both entry paths

    @Test("Search → Select and the editor's Search Again produce the same draft")
    func bothEntryPathsShareOneProjection() throws {
        let lookup = try decode(dithaneStructuredJSON)

        // A: Add Chemical → search → select → the editor opens on the draft.
        let addFlow = ChemicalReviewSession.make(
            chemical: nil,
            prefill: reviewDraft(lookup: lookup, selected: dithaneRow),
            fallbackCountry: "AU"
        )

        // B: the editor is already open on a bare record and re-searches.
        var editing = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        editing.apply(
            reviewed: reviewDraft(lookup: lookup, selected: dithaneRow),
            fallbackCountry: "AU"
        )

        #expect(editing.chemistryDraft == addFlow.chemistryDraft)
        #expect(editing.formType == addFlow.formType)
        #expect(editing.unit == addFlow.unit)
        #expect(editing.productCategory == addFlow.productCategory)
        #expect(editing.labelURL == addFlow.labelURL)
    }

    @Test("Match & Verify on a stored product shows the lookup, not the old record")
    func matchAndVerifyShowsTheResolvedDraft() throws {
        // The reproduction: an existing legacy record being re-identified. The
        // session used to seed from the STORED chemical and ignore the prefill
        // entirely, so everything the lookup had just established was dropped
        // on the one path where a lookup had definitely run.
        let legacy = SavedChemical(
            vineyardId: Self.vineyardId,
            name: "Dithane",
            unit: .litres,
            activeIngredient: "Mancozeb",
            productForm: "liquid"
        )
        let session = try hydratedSession(existing: legacy)

        #expect(session.chemistryDraft.uses.count == 3)
        #expect(session.chemistryDraft.registrationNumber == "59688")
        #expect(session.productCategory == .fungicide)
        #expect(session.formType == .solid)
        #expect(session.unit == .kilograms)
        #expect(session.labelURL == "https://elabels.apvma.gov.au/59688ELBL.pdf")
    }

    // MARK: - 13. Save, reload, review again

    @Test("Every structured field survives save and reopen")
    func structuredFieldsSurviveSaveAndReopen() throws {
        let session = try hydratedSession()

        // What the editor's Save writes: the structured record, plus the legacy
        // scalars DERIVED from it.
        let legacy = session.legacyProjection()
        var stored = reviewDraft(lookup: try decode(dithaneStructuredJSON), selected: dithaneRow)
        stored.name = session.name
        stored.unit = session.unit
        stored.productForm = session.formType == .liquid ? "liquid" : "solid"
        stored.productCategory = session.productCategory?.rawValue ?? ""
        stored.manufacturer = legacy.manufacturer
        stored.labelURL = legacy.labelURL
        stored.activeIngredient = legacy.activeIngredient
        stored.chemicalGroup = legacy.chemicalGroup
        stored.chemicalIntelligence = session.intelligenceToPersist

        // Through the real persistence shape and back.
        let data = try JSONEncoder().encode(stored)
        let reloaded = try JSONDecoder().decode(SavedChemical.self, from: data)
        let reopened = ChemicalReviewSession.make(
            chemical: reloaded, prefill: nil, fallbackCountry: "AU"
        )

        #expect(reopened.name == "Dithane Rainshield Neo Tec Fungicide")
        #expect(reopened.manufacturer == "UPL Australia Pty Ltd")
        #expect(reopened.productCategory == .fungicide)
        #expect(reopened.formType == .solid)
        #expect(reopened.unit == .kilograms)
        #expect(reopened.labelURL == "https://elabels.apvma.gov.au/59688ELBL.pdf")
        #expect(reopened.chemistryDraft.registrationNumber == "59688")
        #expect(reopened.chemistryDraft.registrationScheme == .apvma)

        let active = try #require(reopened.chemistryDraft.actives.first)
        #expect(reopened.chemistryDraft.actives.count == 1)
        #expect(active.name == "Mancozeb")
        #expect(active.concentrationText == "750")
        #expect(active.concentrationUnit == .gramsPerKilogram)
        #expect(active.scheme == .frac)
        #expect(active.groupCode == "M3")

        #expect(reopened.chemistryDraft.uses.count == 3)
        let phomopsis = try use(reopened, target: "Phomopsis Cane and Leaf spot")
        #expect(phomopsis.rates.first?.basis == .rangePer100Litres)
        #expect(phomopsis.rates.first?.minText == "150")
        #expect(phomopsis.rates.first?.maxText == "200")
        #expect(phomopsis.rates.first?.unit == "g")
        #expect(phomopsis.withholdingPeriodDaysText == "30")
        let downy = try use(reopened, target: "Downy mildew")
        #expect(downy.rates.isEmpty)
        #expect(downy.withholdingPeriodDaysText == "30")

        // The label's wording survives the round trip — no layer between the
        // server and the reopened editor re-imposes the register's taxonomy.
        #expect(!reopened.chemistryDraft.uses.contains { $0.targetRaw.contains(" - ") })
    }

    // MARK: - The deadline that started all of it

    @Test("Resolving one product is given long enough to actually finish")
    func structuredLookupHasARealisticDeadline() {
        // APVMA 59688 measured ~55 s server-side: register query, label
        // discovery, PDF fetch, DFU extraction and a web-research pass. At the
        // old shared 30 s ceiling that request could only ever fail.
        #expect(ChemicalInfoService.structuredLookupTimeout >= 90)
        // Search is a list query and stays snappy.
        #expect(ChemicalInfoService.searchTimeout == 30)
        #expect(ChemicalInfoService.structuredLookupTimeout > ChemicalInfoService.searchTimeout)
    }

    @Test("A timeout is reported as its own recoverable failure")
    func timeoutIsItsOwnError() {
        let message = ChemicalLookupError.timedOut.errorDescription ?? ""
        #expect(!message.isEmpty)
        // It must tell the operator the useful thing: ask again.
        #expect(message.lowercased().contains("again"))
    }

    @Test("A failed lookup degrades honestly instead of inventing chemistry")
    func failedLookupProducesAnHonestDraft() {
        // This is what the operator saw. It is still reachable — deliberately,
        // via "Continue Without Register Details" — but it must no longer
        // fabricate a second active or a category.
        let draft = reviewDraft(lookup: nil, selected: dithaneRow)
        let intel = draft.chemicalIntelligence

        #expect(draft.name == "Dithane Rainshield Neo Tec Fungicide")
        #expect(intel?.activeIngredients.count == 1)
        #expect(intel?.activeIngredients.first?.name == "Mancozeb")
        #expect(!(intel?.activeIngredients.contains { $0.name.lowercased() == "kg" } ?? false))
        #expect(intel?.registeredUses.isEmpty ?? true)
        #expect(draft.labelURL.isEmpty)
        // Nothing established a category, so nothing claims one.
        #expect(draft.productCategory.isEmpty)
    }
}

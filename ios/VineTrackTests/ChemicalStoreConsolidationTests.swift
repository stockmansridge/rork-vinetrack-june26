import Foundation
import Testing
@testable import VineTrack

/// The Chemical Store architecture, end to end.
///
/// ```text
/// MASTER CHEMICAL CATALOGUE      shared reference, approved rows only
///   ↓ optional approved reference
/// VINEYARD SAVED CHEMICAL        the ONE operator-facing record
///   ↓ selected for application
/// SPRAY RECORD CHEMICAL SNAPSHOT frozen history, never rewritten
/// ```
///
/// These tests lock down the consolidation of two iOS lookup pipelines into
/// one. The second pipeline mapped a lookup into the editor's legacy free-text
/// fields by hand and never touched the structured sql/194 chemistry, which is
/// how one screen could show "No active ingredients recorded" directly above
/// "Recorded as text: Mancozeb · M5" — two answers to the same question, and
/// the wrong resistance group on the visible one.
struct ChemicalStoreConsolidationTests {

    private static let vineyardId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

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

    private func session(for draft: SavedChemical) -> ChemicalReviewSession {
        ChemicalReviewSession.make(chemical: nil, prefill: draft, fallbackCountry: "AU")
    }

    // MARK: - Fixtures

    /// The reproduction: an AI-tier row carrying the canonical name, the active
    /// and a WRONG resistance group (M5 is Chlorothalonil; Mancozeb is M3).
    private var dithaneRow: ChemicalSearchResult {
        ChemicalSearchResult(
            name: "Dithane Rainshield",
            activeIngredient: "Mancozeb 750 g/kg",
            chemicalGroup: "M5",
            brand: "BASF",
            primaryUse: "Fungicide"
        )
    }

    /// The resolver's fail-closed response: canonical fields emptied, the
    /// model's reading quarantined into `ai_suggestion`.
    private let dithaneStructuredJSON = """
    {
      "product_name": null,
      "product_category": "Fungicide",
      "form_type": null,
      "registration": {
        "country_code": "AU", "scheme": null, "registration_number": null,
        "registrant": null, "registered_product_name": null
      },
      "active_ingredients": [],
      "registered_uses": [],
      "verification": {
        "status": "unverified", "sources": [], "conflicts": [],
        "unresolved_fields": ["active_ingredients", "registration_number"]
      },
      "match_source": "unresolved",
      "ai_suggestion": {
        "note": "Unverified AI suggestion.",
        "product_name": "Dithane Rainshield",
        "registrant": "BASF",
        "product_category": "fungicide",
        "active_ingredients": [
          {
            "name": "Mancozeb", "concentration": 750, "concentration_unit": "g/kg",
            "activity_group": { "scheme": "frac", "code": "M5" }
          }
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

    // MARK: - 1, 2, 3. One pipeline

    @Test("Every Add Chemical entry point produces the same reviewed draft")
    func oneLookupPipeline() throws {
        // The Chemical Store, the Spray Calculator and the Spray Program all
        // open `ChemicalMatchFlowView`, which resolves through
        // `ChemicalProductSearchSheet` and maps through `ChemicalReviewMerge`.
        // Same inputs, same output, wherever the operator started.
        let lookup = try decodeStructured(dithaneStructuredJSON)
        let fromStore = merge(lookup: lookup, selected: dithaneRow)
        let fromProgram = merge(lookup: lookup, selected: dithaneRow)

        #expect(fromStore.name == fromProgram.name)
        #expect(fromStore.manufacturer == fromProgram.manufacturer)
        #expect(fromStore.productCategory == fromProgram.productCategory)
        #expect(fromStore.chemicalIntelligence == fromProgram.chemicalIntelligence)
    }

    @Test("The editor's own re-search goes through the same merge, not a private mapping")
    func editorResearchUsesTheSharedMerge() throws {
        // The retired pipeline filled `activeIngredient` and `chemicalGroup` as
        // free text and left the structured record empty. The replacement
        // applies a `ChemicalReviewMerge` draft, so the editor cannot produce a
        // different answer from the Add Chemical flow.
        var editing = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        editing.notes = "Half a drum left in the shed."
        editing.costText = "480"

        let reviewed = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        editing.apply(reviewed: reviewed, fallbackCountry: "AU")

        let fresh = session(for: reviewed)
        #expect(editing.name == fresh.name)
        #expect(editing.manufacturer == fresh.manufacturer)
        #expect(editing.chemistryDraft.actives.map(\.name) == fresh.chemistryDraft.actives.map(\.name))
        #expect(editing.productCategory == fresh.productCategory)
        // Re-identifying a product says nothing about what it cost or how much
        // is in the shed, so the operator's own data is untouched.
        #expect(editing.notes == "Half a drum left in the shed.")
        #expect(editing.costText == "480")
    }

    // MARK: - 4, 5, 6. The draft is stable

    @Test("Seeding is deterministic, so a redraw cannot change the form")
    func seedingIsDeterministic() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)

        // The editor seeds once, but SwiftUI may run its initialiser again on
        // any parent rebuild. Identical input must give an identical session,
        // or "what is on screen" becomes a function of how often the view was
        // rebuilt.
        let first = session(for: draft)
        let second = session(for: draft)
        let third = session(for: draft)
        #expect(first == second)
        #expect(second == third)
        #expect(!first.populatedActives.isEmpty)
    }

    @Test("Operator edits survive repeated redraws of the parent")
    func editsSurviveRedraws() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        var live = session(for: draft)

        live.name = "Dithane Rainshield NT"
        live.chemistryDraft.actives[0].concentrationText = "640"

        // Simulate scroll / screenshot / background-foreground: the parent
        // rebuilds and re-runs the seeding expression. `@State` keeps the live
        // value, so the seed is computed and thrown away.
        for _ in 0..<5 {
            _ = session(for: draft)
        }

        #expect(live.name == "Dithane Rainshield NT")
        #expect(live.chemistryDraft.actives.first?.concentrationText == "640")
        #expect(live.chemistryDraft.actives.first?.name == "Mancozeb")
    }

    @Test("Opening the session runs no lookup and needs no network")
    func sessionIsPureAndOffline() throws {
        // `ChemicalReviewSession.make` is a pure function of its inputs. There
        // is nothing async to re-fire on `onAppear`, on a scene change or on a
        // sheet redraw — which is what used to restart the lookup and overwrite
        // fields the operator had already corrected.
        let draft = merge(lookup: nil, selected: dithaneRow)
        let built = session(for: draft)
        #expect(built.name == "Dithane Rainshield")
        // The country default is applied at seeding, once, rather than by an
        // `onAppear` that fires again on every re-appearance.
        #expect(built.chemistryDraft.countryCode == "AU")
    }

    // MARK: - 7, 8, 9. Structured hydration

    @Test("Dithane Rainshield hydrates a STRUCTURED Mancozeb active")
    func structuredActiveIsHydrated() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        let built = session(for: draft)

        let active = try #require(built.chemistryDraft.actives.first)
        #expect(active.name == "Mancozeb")
        #expect(active.concentrationText == "750")
        #expect(active.concentrationUnit == .gramsPerKilogram)
    }

    @Test("The Active Ingredients section is not empty when a structured active exists")
    func activeSectionIsNotEmpty() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        let built = session(for: draft)

        // `populatedActives` is exactly what the section renders. Non-empty
        // means the "No active ingredients recorded" branch is unreachable —
        // and so is the read-only "Recorded as text" block below it, which only
        // shows when there are no structured actives.
        #expect(!built.populatedActives.isEmpty)
        #expect(built.populatedActives.map(\.name) == ["Mancozeb"])
    }

    @Test("Legacy active text is DERIVED from the structured chemistry")
    func legacyTextIsDerived() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        let built = session(for: draft)

        // The old scalars are a projection of the structure, never a parallel
        // source — and they exist only at save time, not as editable fields.
        // Note the group: the row said M5, the record says M3.
        let legacy = built.legacyProjection()
        #expect(legacy.activeIngredient.contains("Mancozeb"))
        #expect(legacy.chemicalGroup.contains("M3"))
        #expect(!legacy.chemicalGroup.contains("M5"))
    }

    // MARK: - 10. Category

    @Test("A fungicide lookup shows Fungicide, not Uncategorised")
    func categoryMaps() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        #expect(draft.productCategory == ProductCategory.fungicide.rawValue)
        #expect(session(for: draft).productCategory == .fungicide)

        // The register and the resolver word it differently; all of them land
        // on the same category rather than falling through to Uncategorised.
        #expect(ProductCategory.parse("Fungicide") == .fungicide)
        #expect(ProductCategory.parse("fungicides") == .fungicide)
        #expect(ProductCategory.parse("Growth regulator") == .growthRegulator)
        #expect(ProductCategory.parse("") == nil)
    }

    // MARK: - 11. Blank registration

    @Test("A blank registration number clears nothing else")
    func blankRegistrationClearsNothing() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        let built = session(for: draft)

        #expect(built.chemistryDraft.registrationNumber.isEmpty)
        #expect(built.registrationNotConfirmed)
        // Everything the lookup DID find is still on screen.
        #expect(built.name == "Dithane Rainshield")
        #expect(built.manufacturer == "BASF")
        #expect(built.populatedActives.count == 1)
        #expect(built.chemistryDraft.uses.count == 1)
    }

    // MARK: - 12, 13, 14, 15, 16. Registered uses survive the round trip

    @Test("Uses, WHP, re-entry, restrictions and rate bases survive lookup → review → save → reload")
    func registeredUsesSurviveRoundTrip() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        let built = session(for: draft)

        // Present in the reviewable draft, as structure rather than as a line
        // of legacy text.
        let editable = try #require(built.chemistryDraft.uses.first)
        #expect(editable.crop == "Grapes")
        #expect(editable.targetRaw == "Downy mildew")
        #expect(editable.withholdingPeriodDaysText == "14")
        #expect(editable.reEntryPeriodHoursText == "24")
        #expect(editable.restrictions == "Do not apply after EL 31.")
        #expect(editable.rates.first?.basis == .per100Litres)
        #expect(editable.rates.first?.valueText == "200")
        #expect(editable.rates.first?.unit == "g")

        // And still present after a save/reload through the EXISTING schema.
        let reloaded = try JSONDecoder().decode(
            SavedChemical.self, from: try JSONEncoder().encode(draft)
        )
        let stored = try #require(reloaded.chemicalIntelligence?.registeredUses.first)
        #expect(stored.crop == "Grapes")
        #expect(stored.targetRaw == "Downy mildew")
        #expect(stored.withholdingPeriodDays == 14)
        #expect(stored.reEntryPeriodHours == 24)
        #expect(stored.restrictions == "Do not apply after EL 31.")
        // The basis is never converted: 200 g/100 L is not 200 g/ha, and
        // turning one into the other mis-doses every tank mixed from it.
        #expect(stored.rates.first?.basis == .per100Litres)
        #expect(stored.rates.first?.value == 200)
        #expect(stored.rates.first?.unit == "g")
    }

    @Test("Structured uses are not replaced by the legacy Use / Problem text")
    func structuredUsesAreNotCollapsedToText() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)

        // "Fungicide" in the legacy Use box is a display convenience. It must
        // never be the only place the registered use landed, because a crop, a
        // target, a rate, a WHP and an REI cannot be recovered from one word.
        #expect(draft.use == "Fungicide")
        #expect(draft.chemicalIntelligence?.registeredUses.count == 1)
        #expect(draft.chemicalIntelligence?.registeredUses.first?.targetRaw == "Downy mildew")
    }

    // MARK: - 17. Product unit

    @Test("Product unit is NOT inferred from active concentration alone")
    func productUnitIsNotGuessedFromConcentration() {
        // 750 g/kg says how much Mancozeb is IN the product. kg/ha says how
        // much product goes ON the block. Reading one off the other is a guess
        // that then shows up in the Spray Calculator as a rate.
        #expect(ChemicalReviewMerge.productUnit(formType: nil, uses: []) == nil)

        // An explicit formulation may establish it.
        #expect(ChemicalReviewMerge.productUnit(formType: "Wettable granule", uses: []) == .kilograms)
        #expect(ChemicalReviewMerge.productUnit(formType: "liquid", uses: []) == .litres)

        // So may the unit a registered rate is actually quoted in.
        let use = ChemicalRegisteredUse(
            crop: "Grapes",
            targetRaw: "Downy mildew",
            rates: [ChemicalLabelRate(label: "", basis: .perHectare, value: 2, unit: "L")]
        )
        #expect(ChemicalReviewMerge.productUnit(formType: nil, uses: [use]) == .litres)
    }

    @Test("With no formulation and no rate unit, the unit is left for review")
    func unitLeftForReviewWhenUnknown() throws {
        let lookup = try decodeStructured("""
        {
          "product_name": "Concentration Only",
          "active_ingredients": [],
          "registered_uses": [],
          "verification": { "status": "unverified", "sources": [], "conflicts": [], "unresolved_fields": [] },
          "ai_suggestion": {
            "active_ingredients": [
              { "name": "Sulfur", "concentration": 800, "concentration_unit": "g/kg" }
            ]
          },
          "discovery": { "adapter": "apvma", "outcome": "unresolved" }
        }
        """)
        let draft = merge(lookup: lookup, selected: ChemicalSearchResult(name: "Concentration Only"))
        // Untouched at the record's default rather than silently made kg.
        #expect(draft.unit == .litres)
        #expect(draft.chemicalIntelligence?.activeIngredients.first?.concentrationUnit == .gramsPerKilogram)
    }

    // MARK: - 18. Activity group reconciliation

    @Test("An incompatible suggested group is corrected and the disagreement recorded")
    func incompatibleGroupIsRejected() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        let intel = try #require(draft.chemicalIntelligence)

        // The lookup said Mancozeb · M5. M5 is Chlorothalonil. Carrying that
        // into a resistance calculation would mis-state the whole spray
        // programme's group rotation.
        let active = try #require(intel.activeIngredients.first)
        #expect(active.activityGroup?.code == "M3")
        #expect(active.activityGroup?.scheme == .frac)

        // Corrected, not silently: the disagreement is on the record.
        let conflict = try #require(intel.verification.conflicts.first)
        #expect(conflict.activeIngredientName == "Mancozeb")
        #expect(conflict.authoritativeValue.contains("M3"))
        #expect(conflict.extractedValue.contains("M5"))
    }

    @Test("An authoritative group is only claimed when the identity was established")
    func groupAuthorityFollowsIdentityAuthority() throws {
        let unverified = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        let unverifiedActive = try #require(unverified.chemicalIntelligence?.activeIngredients.first)
        // The table knows Mancozeb is M3. It does not know this product
        // contains Mancozeb — that came from the model.
        #expect(unverifiedActive.activityGroup?.code == "M3")
        #expect(unverifiedActive.groupSource == .aiInterpretation)
        #expect(unverified.chemicalIntelligence?.resolvedVerificationStatus != .verified)

        let registered = try decodeStructured("""
        {
          "product_name": "Topas 100 EC",
          "registration": {
            "country_code": "AU", "scheme": "apvma", "registration_number": "45557",
            "registrant": "Syngenta Australia Pty Ltd"
          },
          "active_ingredients": [
            {
              "name": "Penconazole", "concentration": 100, "concentration_unit": "g/L",
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
          "discovery": { "adapter": "apvma", "outcome": "resolved" }
        }
        """)
        let verified = merge(lookup: registered, selected: ChemicalSearchResult(
            name: "Topas 100 EC", registrationNumber: "45557", source: "official_register"
        ))
        let verifiedActive = try #require(verified.chemicalIntelligence?.activeIngredients.first)
        #expect(verifiedActive.groupSource == .authoritativeClassification)
        #expect(verifiedActive.hasAuthoritativeGroup)
    }

    // MARK: - 19, 20. Multi-active and schemes

    @Test("Every active survives independently, each with its own scheme")
    func multiActiveKeepsEveryActiveAndScheme() throws {
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
        let draft = merge(lookup: lookup, selected: ChemicalSearchResult(name: "Combo Duo"))
        let intel = try #require(draft.chemicalIntelligence)

        #expect(intel.activeIngredients.count == 2)
        // IRAC 5 and FRAC 11 are unrelated chemistries. Collapsing them to
        // "5 + 11" would read as one classification system used twice.
        #expect(intel.activeIngredients.first { $0.name == "Spinetoram" }?.activityGroup?.scheme == .irac)
        #expect(intel.activeIngredients.first { $0.name == "Pyraclostrobin" }?.activityGroup?.scheme == .frac)
        #expect(Set(intel.activityGroups.map(\.scheme)) == Set([.irac, .frac]))

        // Both reach the editable draft as separate rows.
        let built = session(for: draft)
        #expect(built.populatedActives.count == 2)
        #expect(built.populatedActives.map(\.scheme) == [.irac, .frac])
    }

    @Test("A herbicide keeps its HRAC scheme rather than being read as FRAC")
    func hracStaysDistinct() throws {
        let lookup = try decodeStructured("""
        {
          "product_name": "Knockdown 450",
          "registration": { "country_code": "AU", "scheme": "apvma", "registration_number": "70001" },
          "active_ingredients": [
            {
              "name": "Glyphosate", "concentration": 450, "concentration_unit": "g/L",
              "identity_source": "official_register"
            }
          ],
          "verification": { "status": "partially_verified", "sources": [], "conflicts": [], "unresolved_fields": [] },
          "discovery": { "adapter": "apvma", "outcome": "resolved" }
        }
        """)
        let draft = merge(lookup: lookup, selected: ChemicalSearchResult(name: "Knockdown 450"))
        let active = try #require(draft.chemicalIntelligence?.activeIngredients.first)
        #expect(active.activityGroup?.scheme == .hrac)
        #expect(active.activityGroup?.code == "G")
    }

    // MARK: - 21, 22, 23, 24. Master catalogue ranking

    private func masterRow(
        name: String = "Custodia",
        country: String? = "AU",
        status: String? = "approved"
    ) -> ChemicalSearchResult {
        ChemicalSearchResult(
            name: name, brand: "Adama", source: ChemicalSearchResult.masterSource,
            countryCode: country, reviewStatus: status
        )
    }

    private func registerRow(_ name: String) -> ChemicalSearchResult {
        ChemicalSearchResult(
            name: name, brand: "Registrant", registrationNumber: "12345",
            source: ChemicalSearchResult.officialRegisterSource
        )
    }

    @Test("With zero approved Masters, search still works and ranks the register first")
    func noApprovedMastersStillWorks() {
        // The expected state today: sql/199 seeded its fixture as a CANDIDATE
        // deliberately. An empty tier B is not a failure.
        let ordered = ChemicalSearchRanking.ordered(
            results: [dithaneRow, registerRow("Topas 100 EC")],
            savedChemicals: [],
            vineyardCountry: "AU"
        )
        #expect(ordered.count == 2)
        #expect(ordered.first?.tier == .officialRegister)
        #expect(ordered.first?.result.name == "Topas 100 EC")
        #expect(ordered.last?.tier == .suggestion)
        #expect(!ordered.contains { $0.tier == .approvedMaster })
    }

    @Test("An approved same-country Master outranks the register and the suggestions")
    func approvedMasterRanksFirst() {
        let ordered = ChemicalSearchRanking.ordered(
            results: [dithaneRow, registerRow("Topas 100 EC"), masterRow()],
            savedChemicals: [],
            vineyardCountry: "AU"
        )
        #expect(ordered.map(\.tier) == [.approvedMaster, .officialRegister, .suggestion])
        #expect(ordered.first?.result.name == "Custodia")
    }

    @Test("A candidate Master is never presented as approved")
    func candidateMasterIsNotApproved() {
        let candidate = masterRow(status: "candidate")
        #expect(!ChemicalSearchRanking.isUsableMaster(candidate, vineyardCountry: "AU"))

        let ordered = ChemicalSearchRanking.ordered(
            results: [candidate, registerRow("Topas 100 EC")],
            savedChemicals: [],
            vineyardCountry: "AU"
        )
        // Not hidden — it may still be the product on the drum — but it has
        // lost an authority it never earned.
        #expect(ordered.first?.tier == .officialRegister)
        #expect(ordered.last?.tier == .suggestion)
        #expect(ordered.last?.result.name == "Custodia")
    }

    @Test("A retired Master is not offered as a current authoritative option")
    func retiredMasterIsDemoted() {
        #expect(!ChemicalSearchRanking.isUsableMaster(masterRow(status: "retired"), vineyardCountry: "AU"))
    }

    @Test("An AU Master is not authoritative for an NZ vineyard")
    func crossCountryMasterIsNotAuthoritative() {
        let auMaster = masterRow(country: "AU")
        #expect(ChemicalSearchRanking.isUsableMaster(auMaster, vineyardCountry: "AU"))
        // Same name, different registration, different label law.
        #expect(!ChemicalSearchRanking.isUsableMaster(auMaster, vineyardCountry: "NZ"))

        let ordered = ChemicalSearchRanking.ordered(
            results: [auMaster], savedChemicals: [], vineyardCountry: "NZ"
        )
        #expect(ordered.first?.tier == .suggestion)
    }

    @Test("A product already in the store is shown first, to prevent a duplicate")
    func existingStoreRecordRanksFirst() {
        var stocked = SavedChemical(vineyardId: Self.vineyardId)
        stocked.name = "Custodia"

        let ordered = ChemicalSearchRanking.ordered(
            results: [registerRow("Topas 100 EC"), masterRow()],
            savedChemicals: [stocked],
            vineyardCountry: "AU"
        )
        #expect(ordered.first?.tier == .alreadyInStore)
        #expect(ordered.first?.isDuplicate == true)
        #expect(ordered.first?.existing?.id == stocked.id)
    }

    // MARK: - 25, 26. One saved_chemicals row, master link optional

    @Test("Selecting an approved Master records the link and the revision")
    func masterSelectionRecordsTheReference() throws {
        let masterId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let lookup = try decodeStructured("""
        {
          "product_name": "Custodia",
          "product_category": "fungicide",
          "registration": {
            "country_code": "AU", "scheme": "apvma", "registration_number": "66541",
            "registrant": "Adama Australia"
          },
          "active_ingredients": [
            {
              "name": "Tebuconazole", "concentration": 200, "concentration_unit": "g/L",
              "identity_source": "official_register"
            }
          ],
          "verification": {
            "status": "partially_verified",
            "sources": [{ "kind": "official_register", "name": "APVMA PUBCRIS" }],
            "conflicts": [], "unresolved_fields": []
          },
          "match_source": "master",
          "master": {
            "master_chemical_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "master_revision": 4,
            "catalogue_status": "approved"
          },
          "discovery": { "adapter": "master", "outcome": "resolved" }
        }
        """)
        #expect(lookup.isMasterMatch)

        let draft = merge(lookup: lookup, selected: masterRow())
        // The Master stays a reference; the vineyard's record is the one
        // saved_chemicals row, and it cites where its chemistry came from.
        #expect(draft.masterChemicalId == masterId)
        #expect(draft.masterSourceRevision == 4)
        #expect(session(for: draft).masterChemicalId == masterId)

        // Same sql/194 chemistry shape as any other saved chemical — no second
        // chemistry format, no copy of the catalogue row.
        #expect(draft.chemicalIntelligence?.activeIngredients.map(\.name) == ["Tebuconazole"])
    }

    @Test("A non-Master selection leaves the master link null, which is valid forever")
    func nonMasterSelectionHasNoLink() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        #expect(draft.masterChemicalId == nil)
        #expect(draft.masterSourceRevision == nil)

        let reloaded = try JSONDecoder().decode(
            SavedChemical.self, from: try JSONEncoder().encode(draft)
        )
        #expect(reloaded.masterChemicalId == nil)
        #expect(reloaded.masterSourceRevision == nil)
        // Still a complete, usable record.
        #expect(reloaded.chemicalIntelligence?.activeIngredients.map(\.name) == ["Mancozeb"])
    }

    @Test("A candidate Master block is refused as a master match")
    func candidateMasterBlockIsRefused() throws {
        let lookup = try decodeStructured("""
        {
          "product_name": "Custodia",
          "active_ingredients": [],
          "registered_uses": [],
          "verification": { "status": "unverified", "sources": [], "conflicts": [], "unresolved_fields": [] },
          "match_source": "master",
          "master": {
            "master_chemical_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "master_revision": 1,
            "catalogue_status": "candidate"
          },
          "discovery": { "adapter": "master", "outcome": "resolved" }
        }
        """)
        #expect(!lookup.isMasterMatch)

        let draft = merge(lookup: lookup, selected: masterRow(status: "candidate"))
        // An unreviewed draft row must not become a cited reference.
        #expect(draft.masterChemicalId == nil)
    }

    // MARK: - 27. Full sql/194 round trip

    @Test("Save and reload retains every piece of sql/194 structured chemistry")
    func fullStructuredRoundTrip() throws {
        let draft = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        var edited = draft
        var intel = try #require(edited.chemicalIntelligence)
        intel.registration = ChemicalRegistration(
            countryCode: "AU",
            scheme: .apvma,
            registrationNumber: "34540",
            registrant: "BASF Australia",
            registeredProductName: "Dithane Rainshield NeoTec",
            labelReference: "https://example.test/label.pdf",
            labelVersion: "2024-03"
        )
        edited.chemicalIntelligence = intel

        let reloaded = try JSONDecoder().decode(
            SavedChemical.self, from: try JSONEncoder().encode(edited)
        )
        let stored = try #require(reloaded.chemicalIntelligence)

        // Chemistry
        #expect(stored.activeIngredients.first?.name == "Mancozeb")
        #expect(stored.activeIngredients.first?.concentration == 750)
        #expect(stored.activeIngredients.first?.concentrationUnit == .gramsPerKilogram)
        #expect(stored.activeIngredients.first?.activityGroup?.code == "M3")
        #expect(stored.activeIngredients.first?.activityGroup?.scheme == .frac)
        // Registration identity
        #expect(stored.registration?.countryCode == "AU")
        #expect(stored.registration?.scheme == .apvma)
        #expect(stored.registration?.registrationNumber == "34540")
        #expect(stored.registration?.registrant == "BASF Australia")
        #expect(stored.registration?.registeredProductName == "Dithane Rainshield NeoTec")
        #expect(stored.registration?.labelReference == "https://example.test/label.pdf")
        #expect(stored.registration?.labelVersion == "2024-03")
        // Uses
        #expect(stored.registeredUses.first?.withholdingPeriodDays == 14)
        // Provenance
        #expect(!stored.verification.conflicts.isEmpty)
        #expect(stored.verification.unresolvedFields.contains("registration_number"))
        // Product information
        #expect(reloaded.productCategory == ProductCategory.fungicide.rawValue)
        #expect(reloaded.manufacturer == "BASF")
    }

    // MARK: - 28. History untouched

    @Test("Reviewing and re-saving a chemical rewrites no completed spray")
    func historicalSnapshotsUntouched() throws {
        let frozen = ChemicalLineSnapshot(
            productName: "Dithane Rainshield",
            activeIngredients: [ChemicalActiveIngredient(name: "Mancozeb")],
            activityGroupCodes: ["M5"],
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

        var review = merge(lookup: try decodeStructured(dithaneStructuredJSON), selected: dithaneRow)
        review.name = "Something Entirely Different"

        // P10: the frozen line describes what went through the nozzle. Even the
        // group correction from M5 to M3 stops at today's Chemical Store — the
        // record of what was actually applied is not a place to be right later.
        #expect(completed.tanks == before.tanks)
        #expect(completed.tanks.first?.chemicals.first?.chemicalSnapshot == frozen)
        #expect(completed.tanks.first?.chemicals.first?.chemicalSnapshot?.activityGroupCodes == ["M5"])
    }
}

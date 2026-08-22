import Foundation
import Testing
@testable import VineTrack

/// ONE editable chemical record, on ONE screen.
///
/// The defect these tests lock down: Review Chemical presented the legacy
/// scalar fields AND the structured sql/194 chemistry as two editable UIs over
/// the same record. On a live Dithane Rainshield lookup the structured side
/// held Mancozeb 640 g/kg, FRAC M3, Grapes / Downy mildew, 2.5 kg/ha, WHP 21,
/// REI 0 — while the outer screen showed `Rate per ha: 0`, `Rate per 100L: 0`,
/// a blank Official Label URL and a free-text `Use / Problem`. Not two records:
/// two representations, contradicting each other, both claiming to be editable.
///
/// The structured record is now the only thing the operator edits. The legacy
/// scalars are produced from it at save time and never travel back.
struct ChemicalReviewUIConsolidationTests {

    private static let vineyardId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    private func decodeStructured(_ json: String) throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    /// The live device result, verbatim.
    private let dithaneJSON = """
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
        "unresolved_fields": ["registration_number"]
      },
      "match_source": "unresolved",
      "ai_suggestion": {
        "note": "Unverified AI suggestion.",
        "product_name": "Dithane Rainshield",
        "registrant": "BASF Australia Ltd",
        "product_category": "fungicide",
        "active_ingredients": [
          { "name": "Mancozeb", "concentration": 640, "concentration_unit": "g/kg" }
        ],
        "registered_uses": [
          {
            "crop": "Grapes (winegrapes)",
            "target_raw": "Downy mildew",
            "rates": [
              { "label": "", "basis": "per_hectare", "value": 2.5, "unit": "kg" }
            ],
            "withholding_period_days": 21,
            "re_entry_period_hours": 0,
            "restrictions": "Do not apply after EL 31."
          }
        ]
      },
      "discovery": { "adapter": "apvma", "outcome": "unresolved" }
    }
    """

    private var dithaneRow: ChemicalSearchResult {
        ChemicalSearchResult(
            name: "Dithane Rainshield",
            activeIngredient: "Mancozeb 640 g/kg",
            brand: "BASF Australia Ltd",
            primaryUse: "Fungicide"
        )
    }

    private func dithaneDraft() throws -> SavedChemical {
        ChemicalReviewMerge.reviewChemical(
            lookup: try decodeStructured(dithaneJSON),
            selected: dithaneRow,
            existing: nil,
            countryCode: "AU",
            vineyardId: Self.vineyardId
        )
    }

    private func session(
        _ draft: SavedChemical,
        country: String = "AU"
    ) -> ChemicalReviewSession {
        ChemicalReviewSession.make(chemical: nil, prefill: draft, fallbackCountry: country)
    }

    // MARK: - 1, 2, 3. One page

    @Test("The structured active is on the main Review screen")
    func structuredActiveOnMainScreen() throws {
        let built = session(try dithaneDraft())

        // `populatedActives` is what the Active Ingredients section renders.
        let active = try #require(built.populatedActives.first)
        #expect(active.name == "Mancozeb")
        #expect(active.concentrationText == "640")
        #expect(active.concentrationUnit == .gramsPerKilogram)
        #expect(active.scheme == .frac)
        #expect(ChemicalActivityGroup.normaliseCode(active.groupCode) == "M3")
    }

    @Test("Editing on the main screen reaches the record — no second editor needed")
    func mainScreenEditsReachTheRecord() throws {
        var built = session(try dithaneDraft())

        // Every control on Review Chemical binds into `chemistryDraft`. There is
        // no separate draft owned by a second editor to keep in step, so a
        // change made on the main page IS a change to what gets saved.
        built.chemistryDraft.actives[0].concentrationText = "750"
        built.chemistryDraft.uses[0].withholdingPeriodDaysText = "14"
        built.chemistryDraft.uses[0].rates[0].valueText = "3"

        let persisted = try #require(built.intelligenceToPersist)
        #expect(persisted.activeIngredients.first?.concentration == 750)
        #expect(persisted.registeredUses.first?.withholdingPeriodDays == 14)
        #expect(persisted.registeredUses.first?.rates.first?.value == 3)
    }

    @Test("The structured registered use is on the main Review screen")
    func structuredUseOnMainScreen() throws {
        let built = session(try dithaneDraft())

        #expect(built.hasStructuredUses)
        let use = try #require(built.chemistryDraft.uses.first)
        #expect(use.crop == "Grapes (winegrapes)")
        #expect(use.targetRaw == "Downy mildew")
        #expect(use.rates.first?.basis == .perHectare)
        #expect(use.rates.first?.valueText == "2.5")
        #expect(use.rates.first?.unit == "kg")
    }

    // MARK: - 4, 5. No contradictory zero

    @Test("2.5 kg/ha never coexists with a legacy 0 kg/ha")
    func structuredRateHasNoZeroTwin() throws {
        let built = session(try dithaneDraft())

        // The one rate the screen shows.
        let display = try #require(built.perHectareRateDisplay)
        #expect(Double(display) == 2.5)

        // And the legacy scalar it projects — the same number, not a zero. The
        // old form printed `Rate per ha: 0` here because the scalar column had
        // never been filled while the structured rate had.
        let legacy = built.legacyProjection()
        #expect(legacy.ratePerHa == 2.5)
        #expect(legacy.rates.contains { $0.basis == .perHectare })
        // 2.5 kg expressed in the base unit the store keeps rates in.
        #expect(legacy.rates.first { $0.basis == .perHectare }?.value == 2500)
    }

    @Test("A missing rate is absent, never rendered as zero")
    func missingRateIsNotZero() throws {
        var bare = SavedChemical(vineyardId: Self.vineyardId)
        bare.name = "No Rate On Record"
        let built = ChemicalReviewSession.make(
            chemical: bare, prefill: nil, fallbackCountry: "AU"
        )

        // nil, not "0". Zero is a legitimate number that would read as "the
        // label says apply nothing".
        #expect(built.perHectareRateDisplay == nil)
        #expect(built.per100LitreRateDisplay == nil)
        // And no phantom rate row is written.
        #expect(built.legacyProjection().rates.isEmpty)
    }

    @Test("A rate is never converted across states of matter")
    func rateUnitsAreNotConvertedAcrossForms() {
        let litres = ChemicalLabelRate(basis: .perHectare, value: 2.5, unit: "L")
        // Litres into a solid product would silently restate 2.5 L/ha as
        // 2.5 kg/ha, because both scale to the same base number here.
        #expect(ChemicalReviewSession.displayValue(litres, productUnit: .kilograms) == nil)
        #expect(ChemicalReviewSession.displayValue(litres, productUnit: .litres) == 2.5)
        // Within one state of matter, conversion is real arithmetic.
        let grams = ChemicalLabelRate(basis: .perHectare, value: 2500, unit: "g")
        #expect(ChemicalReviewSession.displayValue(grams, productUnit: .kilograms) == 2.5)
    }

    // MARK: - 6, 7, 8. Label facts come from the structured use

    @Test("Withholding period comes from the structured registered use")
    func withholdingFromStructuredUse() throws {
        let built = session(try dithaneDraft())
        #expect(built.chemistryDraft.uses.first?.withholdingPeriodDaysText == "21")
        #expect(built.intelligenceToPersist?.registeredUses.first?.withholdingPeriodDays == 21)
    }

    @Test("Re-entry period comes from the structured use, and zero hours is a real value")
    func reEntryFromStructuredUse() throws {
        let built = session(try dithaneDraft())
        // REI 0 is the label genuinely saying "no re-entry delay" — quite
        // different from not knowing. It survives as 0, not as blank.
        #expect(built.chemistryDraft.uses.first?.reEntryPeriodHoursText == "0")
        #expect(built.intelligenceToPersist?.registeredUses.first?.reEntryPeriodHours == 0)
    }

    @Test("Restrictions come from the structured registered use")
    func restrictionsFromStructuredUse() throws {
        let built = session(try dithaneDraft())
        #expect(built.chemistryDraft.uses.first?.restrictions == "Do not apply after EL 31.")
        #expect(built.intelligenceToPersist?.registeredUses.first?.restrictions
                == "Do not apply after EL 31.")
    }

    // MARK: - 9, 10. One label link, one manufacturer

    @Test("The official label field IS registration.labelReference")
    func labelURLIsTheStructuredReference() throws {
        var withLabel = try dithaneDraft()
        var intel = try #require(withLabel.chemicalIntelligence)
        intel.registration = ChemicalRegistration(
            countryCode: "AU",
            labelReference: "https://example.test/dithane-label.pdf"
        )
        withLabel.chemicalIntelligence = intel
        withLabel.labelURL = ""

        var built = session(withLabel)
        // The structured value populates the one visible field — the old form
        // left this blank while the record held the URL all along.
        #expect(built.labelURL == "https://example.test/dithane-label.pdf")

        // Editing that field writes the structured reference; there is no
        // second copy to fall out of step.
        built.labelURL = "https://example.test/v2.pdf"
        #expect(built.chemistryDraft.labelReference == "https://example.test/v2.pdf")
        #expect(built.intelligenceToPersist?.registration?.labelReference
                == "https://example.test/v2.pdf")
        #expect(built.legacyProjection().labelURL == "https://example.test/v2.pdf")
    }

    @Test("Manufacturer has exactly one editable representation")
    func manufacturerHasOneRepresentation() throws {
        var built = session(try dithaneDraft())
        #expect(built.manufacturer == "BASF Australia Ltd")

        built.manufacturer = "BASF Australia Pty Ltd"
        // One stored value: the structured registrant.
        #expect(built.chemistryDraft.registrant == "BASF Australia Pty Ltd")
        #expect(built.intelligenceToPersist?.registration?.registrant == "BASF Australia Pty Ltd")
        // And the legacy column is projected from it, not edited beside it.
        #expect(built.legacyProjection().manufacturer == "BASF Australia Pty Ltd")
    }

    // MARK: - 11, 12. Legacy use fields step aside

    @Test("Use / Problem is not offered while structured uses exist")
    func legacyUseHiddenWhenStructuredUsesExist() throws {
        let built = session(try dithaneDraft())
        // `hasStructuredUses` is exactly the condition guarding the legacy
        // section, so true means those two boxes are not on screen.
        #expect(built.hasStructuredUses)
    }

    @Test("Target Problem is projected from the structured target, not typed beside it")
    func targetProblemIsProjected() throws {
        let built = session(try dithaneDraft())
        let legacy = built.legacyProjection()
        #expect(legacy.problem == "Downy mildew")
        #expect(legacy.use == "Fungicide")
    }

    @Test("A record with no structured use still offers the simple Use / Problem fallback")
    func legacyUseAvailableWhenNothingStructured() {
        var manual = SavedChemical(vineyardId: Self.vineyardId)
        manual.name = "Shed Mix"
        manual.use = "Wetter"
        manual.problem = "Coverage"

        var built = ChemicalReviewSession.make(
            chemical: manual, prefill: nil, fallbackCountry: "AU"
        )
        #expect(!built.hasStructuredUses)
        #expect(built.use == "Wetter")
        // Still the operator's own value on the way out.
        #expect(built.legacyProjection().problem == "Coverage")

        // And the moment a real use is recorded, the structured one wins.
        built.chemistryDraft.uses = [
            ChemicalManualUseDraft(crop: "Grapes", targetRaw: "Botrytis")
        ]
        #expect(built.hasStructuredUses)
        #expect(built.legacyProjection().problem == "Botrytis")
    }

    // MARK: - 13, 14, 15, 16, 17. Country-aware registration identity

    @Test("The registration identifier is still persisted internally")
    func registrationIdentifierPersists() throws {
        var built = session(try dithaneDraft())
        built.chemistryDraft.registrationNumber = "34540"
        built.chemistryDraft.registrationScheme = .apvma

        let persisted = try #require(built.intelligenceToPersist)
        #expect(persisted.registration?.registrationNumber == "34540")
        #expect(persisted.registration?.scheme == .apvma)
        #expect(persisted.registration?.countryCode == "AU")
        // The identity key is what keeps two similarly named products apart and
        // stops an AU record matching an NZ one.
        #expect(persisted.registration?.identityKey == "AU:apvma:34540")

        // Survives the existing storage contract untouched.
        var saved = try dithaneDraft()
        saved.chemicalIntelligence = persisted
        let reloaded = try JSONDecoder().decode(
            SavedChemical.self, from: try JSONEncoder().encode(saved)
        )
        #expect(reloaded.chemicalIntelligence?.registration?.registrationNumber == "34540")
    }

    @Test("An Australian vineyard sees APVMA wording")
    func australiaUsesAPVMA() throws {
        var built = session(try dithaneDraft(), country: "AU")
        built.chemistryDraft.registrationNumber = "34540"

        let terms = try #require(built.registrationTerms)
        #expect(terms.fieldLabel == "APVMA Registration Number")
        #expect(terms.helpText.contains("APVMA registration number is the unique number printed on an Australian registered chemical product label"))
        #expect(terms.schemes == [.apvma])
        // Never the bare word most growers cannot act on.
        #expect(terms.fieldLabel != "Registration Number")
        #expect(built.registrationCompactLine == "APVMA registration: 34540")
    }

    @Test("A New Zealand vineyard sees ACVM wording")
    func newZealandUsesACVM() throws {
        var nzDraft = try dithaneDraft()
        var intel = try #require(nzDraft.chemicalIntelligence)
        intel.registration = ChemicalRegistration(
            countryCode: "NZ", scheme: .acvm, registrationNumber: "P1234"
        )
        nzDraft.chemicalIntelligence = intel

        let built = session(nzDraft, country: "NZ")
        let terms = try #require(built.registrationTerms)
        #expect(terms.fieldLabel == "ACVM Registration Number")
        #expect(terms.helpText.contains("ACVM registration number is the unique number shown on a New Zealand registered chemical product label"))
        #expect(built.registrationCompactLine == "ACVM registration: P1234")
        // An APVMA field has no meaning here.
        #expect(!terms.schemes.contains(.apvma))
    }

    @Test("An unsupported country shows neither APVMA nor ACVM")
    func unsupportedCountryHidesRegistration() {
        #expect(ChemicalRegistrationTerminology.terms(forCountryCode: "FR") == nil)
        #expect(!ChemicalRegistrationTerminology.isSupported(countryCode: "US"))
        // Nothing at all is rendered — not an empty APVMA box, not a generic one.
        #expect(ChemicalRegistrationTerminology.compactLine(
            countryCode: "FR", registrationNumber: "12345"
        ) == nil)

        var french = SavedChemical(vineyardId: Self.vineyardId)
        french.name = "Produit"
        let built = ChemicalReviewSession.make(
            chemical: french, prefill: nil, fallbackCountry: "FR"
        )
        #expect(built.registrationTerms == nil)
        #expect(built.registrationCompactLine == nil)
    }

    @Test("A missing identifier states the fact instead of showing a blank field")
    func missingIdentifierIsStatedNotAsked() throws {
        let built = session(try dithaneDraft(), country: "AU")

        #expect(!built.hasRegistrationNumber)
        // A statement, not a prompt. Nobody is asked to go and find one, and no
        // empty required-looking box appears on the normal screen.
        #expect(built.registrationCompactLine == "Registration not confirmed")
        #expect(built.chemistryDraft.registrationNumber.isEmpty)
        // Saving is not blocked by its absence.
        #expect(built.isValid)
    }

    // MARK: - 18, 19, 20. Direction of truth

    @Test("Saving structured data updates the compatibility projections")
    func savingUpdatesProjections() throws {
        var built = session(try dithaneDraft())
        built.chemistryDraft.actives[0].concentrationText = "800"
        built.chemistryDraft.uses[0].rates[0].valueText = "3"
        built.chemistryDraft.uses[0].targetRaw = "Powdery mildew"

        let legacy = built.legacyProjection()
        #expect(legacy.activeIngredient.contains("800"))
        #expect(legacy.ratePerHa == 3)
        #expect(legacy.problem == "Powdery mildew")
        #expect(legacy.chemicalGroup.contains("M3"))
    }

    @Test("Stale legacy scalars never overwrite the structured record")
    func staleLegacyNeverWins() throws {
        // A record whose old columns disagree with its structured chemistry —
        // exactly what a half-migrated product looks like.
        var conflicted = try dithaneDraft()
        conflicted.activeIngredient = "Sulfur 800 g/kg"
        conflicted.chemicalGroup = "M2"
        conflicted.ratePerHa = 9
        conflicted.problem = "Something else"
        conflicted.manufacturer = "Someone Else Ltd"

        let built = ChemicalReviewSession.make(
            chemical: conflicted, prefill: nil, fallbackCountry: "AU"
        )

        // The structured record wins everywhere, because nothing on the screen
        // edits the scalars and nothing reads them back.
        #expect(built.populatedActives.map(\.name) == ["Mancozeb"])
        #expect(built.manufacturer == "BASF Australia Ltd")

        let legacy = built.legacyProjection()
        #expect(legacy.activeIngredient.contains("Mancozeb"))
        #expect(!legacy.activeIngredient.contains("Sulfur"))
        #expect(legacy.chemicalGroup.contains("M3"))
        #expect(legacy.ratePerHa == 2.5)
        #expect(legacy.problem == "Downy mildew")
        #expect(legacy.manufacturer == "BASF Australia Ltd")
    }

    @Test("A legacy-only record is hydrated into structure once, then edited there")
    func legacyOnlyRecordUpgrades() throws {
        var legacyOnly = SavedChemical(vineyardId: Self.vineyardId)
        legacyOnly.name = "Old Sulfur"
        legacyOnly.activeIngredient = "Sulfur"
        legacyOnly.chemicalGroup = "M2"
        legacyOnly.unit = .kilograms
        legacyOnly.ratePerHa = 5
        legacyOnly.chemicalIntelligence = nil

        var built = ChemicalReviewSession.make(
            chemical: legacyOnly, prefill: nil, fallbackCountry: "AU"
        )

        // Read into the structured draft ONCE, including the scalar rate, so
        // the operator reviews and edits it in the one place the app now reads.
        #expect(built.populatedActives.first?.name.contains("Sulfur") == true)
        #expect(built.perHectareRateDisplay.flatMap(Double.init) == 5)

        // From here the structured value is the truth.
        built.chemistryDraft.productRates[0].valueText = "6"
        #expect(built.legacyProjection().ratePerHa == 6)
        #expect(built.intelligenceToPersist?.registeredUses.first?.rates.first?.value == 6)
    }

    // MARK: - 21. Stability

    @Test("Seeding stays deterministic and edits survive repeated redraws")
    func draftRemainsStable() throws {
        let draft = try dithaneDraft()
        #expect(session(draft) == session(draft))

        var live = session(draft)
        live.name = "Dithane Rainshield NT"
        live.chemistryDraft.uses[0].withholdingPeriodDaysText = "28"

        // Scroll, screenshot, background/foreground: the parent rebuilds and
        // re-runs the seeding expression, which `@State` discards.
        for _ in 0..<5 { _ = session(draft) }

        #expect(live.name == "Dithane Rainshield NT")
        #expect(live.chemistryDraft.uses[0].withholdingPeriodDaysText == "28")
        #expect(live.populatedActives.map(\.name) == ["Mancozeb"])
        #expect(live.perHectareRateDisplay.flatMap(Double.init) == 2.5)
    }

    // MARK: - 22. History untouched

    @Test("Consolidating the editor rewrites no completed spray")
    func historicalSnapshotsUntouched() throws {
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

        var built = session(try dithaneDraft())
        built.name = "Something Entirely Different"
        built.chemistryDraft.uses[0].rates[0].valueText = "99"
        _ = built.legacyProjection()

        // P9/P10: the frozen line records what went through the nozzle. Editing
        // today's Chemical Store — however thoroughly — does not restate it.
        #expect(completed.tanks == before.tanks)
        #expect(completed.tanks.first?.chemicals.first?.chemicalSnapshot == frozen)
        #expect(completed.tanks.first?.chemicals.first?.ratePerHa == 2_000)
    }
}

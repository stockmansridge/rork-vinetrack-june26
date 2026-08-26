import Foundation
import Testing
@testable import VineTrack

/// Chemical Editor parity with the Portal's default-rate workflow.
///
/// The workflow both platforms must implement:
///
/// ```text
/// choose registered product → identity locked → label data loaded
///   → grapevine uses/rates displayed → operator accepts or chooses
///     default rate(s) → save
/// ```
///
/// The acceptance product is VICOL WINTER OIL INSECTICIDE, APVMA 33182, whose
/// label conditions its grapevine rates BY STATE. That is what makes it the
/// right fixture: the same product states `2 L/100 L` and `3 L/100 L`, and
/// which one is correct depends entirely on where the vineyard is. Anything
/// that flattens, merges or guesses across those conditions produces a
/// defensible-looking number that is wrong for most of Australia.
struct ChemicalDefaultRateTests {

    private static let vineyardId = UUID(uuidString: "33182000-0000-0000-0000-000000000001")!

    // MARK: - Fixtures

    /// The VICOL 33182 response, shaped exactly as `chemical-info-lookup`
    /// serves it: split label URLs, a classified product page, and grapevine
    /// uses whose rates carry the STATE column as their condition.
    private static let vicolJSON = """
    {
      "product_name": "VICOL WINTER OIL INSECTICIDE",
      "product_category": "insecticide",
      "form_type": "liquid",
      "product_url": null,
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "33182",
        "registrant": "Victorian Chemical Company Pty Ltd",
        "registered_product_name": "VICOL WINTER OIL INSECTICIDE",
        "label_reference": "https://portal.apvma.gov.au/pubcris/33182/label.pdf",
        "manufacturer_label_url": "https://www.vicchem.com/labels/vicol-winter-oil.pdf",
        "regulator_label_url": "https://portal.apvma.gov.au/pubcris/33182/label.pdf",
        "manufacturer_product_url": "https://www.vicchem.com/product_detail?pn=19200",
        "label_version": null
      },
      "label_urls": {
        "regulator_label_url": "https://portal.apvma.gov.au/pubcris/33182/label.pdf",
        "manufacturer_label_url": "https://www.vicchem.com/labels/vicol-winter-oil.pdf",
        "product_url": "https://www.vicchem.com/product_detail?pn=19200"
      },
      "active_ingredients": [
        { "name": "Petroleum Oil", "concentration": 861, "concentration_unit": "g_per_l" }
      ],
      "activity_groups": [],
      "registered_uses": \(registeredUsesJSON),
      "grapevine_uses": \(grapevineUsesJSON),
      "other_crop_uses": \(otherCropUsesJSON),
      "registered_for_grapevine": true,
      "label_rate_bases": ["per_100_litres"],
      "verification": {
        "status": "partially_verified",
        "sources": [
          { "kind": "manufacturer_label", "name": "Vicchem approved label",
            "reference": "https://www.vicchem.com/labels/vicol-winter-oil.pdf" }
        ],
        "conflicts": [],
        "unresolved_fields": []
      },
      "activity_group_table_version": 3,
      "schema_version": 1
    }
    """

    /// The two grapevine uses, each stating BOTH a mainland and a Tasmanian
    /// rate. Withholding and re-entry are absent throughout: this label states
    /// neither, and the fixture must not quietly supply them.
    private static let grapevineUsesJSON = """
    [
      {
        "crop": "GRAPEVINES",
        "target_raw": "European red mite",
        "rates": [
          { "label": "NSW, Vic, SA", "basis": "per_100_litres", "value": 3,
            "unit": "L", "raw_text": "3 L/100 L (NSW, Vic, SA)" },
          { "label": "Tasmania", "basis": "per_100_litres", "value": 2,
            "unit": "L", "raw_text": "2 L/100 L (Tasmania)" }
        ]
      },
      {
        "crop": "GRAPEVINES",
        "target_raw": "Grapevine scale",
        "rates": [
          { "label": "NSW, Vic, Qld, SA, WA", "basis": "per_100_litres", "value": 3,
            "unit": "L", "raw_text": "3 L/100 L (NSW, Vic, Qld, SA, WA)" },
          { "label": "Tasmania", "basis": "per_100_litres", "value": 2,
            "unit": "L", "raw_text": "2 L/100 L (Tasmania)" }
        ]
      }
    ]
    """

    /// Real non-grapevine content from the same label. Retained on the record,
    /// kept out of the vineyard's normal view.
    private static let otherCropUsesJSON = """
    [
      { "crop": "POME FRUIT", "target_raw": "San Jose scale",
        "rates": [ { "label": "", "basis": "per_100_litres", "value": 1,
                     "unit": "L", "raw_text": "1 L/100 L" } ] },
      { "crop": "PEACH", "target_raw": "Two-spotted mite",
        "rates": [ { "label": "", "basis": "per_100_litres", "value": 1,
                     "unit": "L", "raw_text": "1 L/100 L" } ] },
      { "crop": "PLUM", "target_raw": "Bryobia mite", "rates": [] },
      { "crop": "NECTARINE", "target_raw": "Two-spotted mite", "rates": [] },
      { "crop": "ALMOND", "target_raw": "Two-spotted mite", "rates": [] }
    ]
    """

    /// `registered_uses` is the whole label — grapevine AND everything else.
    private static var registeredUsesJSON: String {
        let grapes = grapevineUsesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = otherCropUsesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[" + grapes.dropFirst().dropLast() + "," + others.dropFirst().dropLast() + "]"
    }

    private func decodeVicol() throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(
            ChemicalStructuredLookup.self,
            from: Data(Self.vicolJSON.utf8)
        )
    }

    /// The reviewable draft the operator lands on after selecting 33182.
    private func vicolDraft() throws -> SavedChemical {
        ChemicalReviewMerge.reviewChemical(
            lookup: try decodeVicol(),
            selected: nil,
            existing: nil,
            countryCode: "AU",
            vineyardId: Self.vineyardId
        )
    }

    private func vicolSession(
        jurisdiction: ChemicalRateJurisdiction? = nil
    ) throws -> ChemicalReviewSession {
        ChemicalReviewSession.make(
            chemical: nil,
            prefill: try vicolDraft(),
            fallbackCountry: "AU",
            jurisdiction: jurisdiction
        )
    }

    // MARK: - §2 Label / product links

    @Test("The manufacturer PRODUCT page is decoded and reaches the record")
    func manufacturerProductPageDecoded() throws {
        let lookup = try decodeVicol()

        // Both places the server states it.
        #expect(lookup.registration?.manufacturerProductURL
            == "https://www.vicchem.com/product_detail?pn=19200")
        #expect(lookup.labelURLs?.productURL
            == "https://www.vicchem.com/product_detail?pn=19200")

        // And the tier that won, so a blank field can never be mistaken for a
        // response that carried nothing.
        let choice = ChemicalProductReference.resolve(
            lookup: lookup, advisoryURL: nil, existingRecordURL: nil
        )
        #expect(choice?.origin == .registrationProductURL)

        // It survives the merge onto the record, and onto the editable session.
        let draft = try vicolDraft()
        #expect(draft.productURL.contains("vicchem.com/product_detail"))
        let session = try vicolSession()
        #expect(session.productURL.contains("vicchem.com/product_detail"))
    }

    @Test("A response that states the page ONLY in label_urls still shows it")
    func productPageFromLabelURLsAlone() throws {
        // The exact regression this guards: iOS read one key, the server writes
        // three, and a page arriving in the wrong one was silently discarded.
        let json = """
        {
          "product_name": "X",
          "registration": { "country_code": "AU", "scheme": "apvma",
                            "registration_number": "1" },
          "label_urls": { "product_url": "https://maker.example/product/x" }
        }
        """
        let lookup = try JSONDecoder().decode(
            ChemicalStructuredLookup.self, from: Data(json.utf8)
        )
        #expect(lookup.registration?.manufacturerProductURL == nil)
        let choice = ChemicalProductReference.resolve(
            lookup: lookup, advisoryURL: nil, existingRecordURL: nil
        )
        #expect(choice?.url == "https://maker.example/product/x")
        #expect(choice?.origin == .labelURLsProductURL)
    }

    @Test("Manufacturer label, regulator label and product page stay three things")
    func labelSeparationHolds() throws {
        let session = try vicolSession()

        #expect(session.manufacturerLabelURL == "https://www.vicchem.com/labels/vicol-winter-oil.pdf")
        #expect(session.labelURL == "https://portal.apvma.gov.au/pubcris/33182/label.pdf")
        #expect(session.productURL == "https://www.vicchem.com/product_detail?pn=19200")

        // The three must never collapse into one another. An APVMA address
        // under a "Manufacturer label" heading is the failure that matters:
        // it tells the operator the registrant published something they did not.
        #expect(session.manufacturerLabelURL != session.labelURL)
        #expect(session.productURL != session.labelURL)
        #expect(session.productURL != session.manufacturerLabelURL)
        #expect(session.labelURL.contains("apvma.gov.au"))
        #expect(!session.manufacturerLabelURL.contains("apvma.gov.au"))
    }

    @Test("A product page can never be promoted into the Official Label field")
    func productPageIsNeverALabel() throws {
        // No label anywhere, only a marketing page. The label field must stay
        // empty rather than borrow it.
        let json = """
        {
          "product_name": "X",
          "registration": { "country_code": "AU", "scheme": "apvma",
                            "registration_number": "1",
                            "manufacturer_product_url": "https://maker.example/products/x" }
        }
        """
        let lookup = try JSONDecoder().decode(
            ChemicalStructuredLookup.self, from: Data(json.utf8)
        )
        let label = ChemicalLabelReference.resolve(
            lookup: lookup, existingStructured: nil, existingRecordURL: nil
        )
        #expect(label == nil)
    }

    // MARK: - §3 Grapevine-only normal view

    @Test("The normal view shows grapevine uses only")
    func normalViewIsGrapevineOnly() throws {
        let session = try vicolSession()

        #expect(session.isRegisteredForGrapevine)
        #expect(session.grapevineUses.count == 2)
        #expect(session.grapevineUses.allSatisfy(\.isViticultural))

        // The crops a vineyard operator must NOT have to scroll past.
        let normalCrops = Set(session.grapevineUses.map { $0.crop.uppercased() })
        for crop in ["PEACH", "PLUM", "NECTARINE", "ALMOND", "POME FRUIT"] {
            #expect(!normalCrops.contains(crop))
        }
    }

    @Test("Non-grapevine crops are RETAINED, not discarded")
    func otherCropsRetained() throws {
        let session = try vicolSession()

        let otherCrops = Set(session.otherCropUses.map { $0.crop.uppercased() })
        #expect(otherCrops == ["POME FRUIT", "PEACH", "PLUM", "NECTARINE", "ALMOND"])

        // Still on the record that gets SAVED — retention is what makes a
        // future re-verification comparable, and what lets a grower check
        // whether a drum they own covers something else.
        let stored = session.intelligenceToPersist
        let storedCrops = Set(
            (stored?.registeredUses ?? []).statedUses.map { $0.crop.uppercased() }
        )
        #expect(storedCrops.contains("ALMOND"))
        #expect(storedCrops.contains("GRAPEVINES"))
        #expect(storedCrops.count == 6)
    }

    @Test("Grapevine uses are ordered FIRST on the stored record")
    func grapevineUsesLead() throws {
        let draft = try vicolDraft()
        let stated = (draft.chemicalIntelligence?.registeredUses ?? []).statedUses
        #expect(stated.first?.isViticultural == true)
        // The partition is stable: once a non-grapevine use appears, no
        // grapevine use may follow it.
        let firstOtherIndex = stated.firstIndex { !$0.isViticultural }
        if let firstOtherIndex {
            #expect(!stated[firstOtherIndex...].contains { $0.isViticultural })
        }
    }

    // MARK: - §4 Individual registered rate rows

    @Test("Each conditional rate stays its own row, attached to its condition")
    func conditionalRatesStaySeparate() throws {
        let session = try vicolSession()
        let rates = session.grapevineUses.flatMap(\.rates)

        // Four registered rows, exactly as the label prints them.
        #expect(rates.count == 4)

        let pairs = Set(rates.map { "\($0.displayRate)|\($0.label)" })
        #expect(pairs == [
            "3 L/100 L|NSW, Vic, SA",
            "2 L/100 L|Tasmania",
            "3 L/100 L|NSW, Vic, Qld, SA, WA",
        ])
        // Two rows share "2 L/100 L|Tasmania" — one per registered target —
        // which is why the set has three members and the array has four.

        // Every rate keeps a condition. A number with no condition is not a
        // registered rate, it is a rate detached from the thing that authorises it.
        #expect(rates.allSatisfy { !$0.label.isEmpty })
        // And its verbatim wording.
        #expect(rates.allSatisfy { !($0.rawText ?? "").isEmpty })
    }

    @Test("Rates are never concatenated into one string")
    func ratesAreNeverConcatenated() throws {
        let session = try vicolSession()
        for rate in session.grapevineUses.flatMap(\.rates) {
            // The exact defect: "2 L/100 L 3 L/100 L 3 L/100 L 2 L/100 L" as
            // a single rate. One displayed rate carries ONE number or one band.
            #expect(rate.displayRate.count < 20)
            #expect(!rate.displayRate.contains("L/100 L 2"))
            #expect(!rate.displayRate.contains("L/100 L 3"))
        }
    }

    // MARK: - §5 / §7 Ranges

    @Test("Two different values never become a synthetic range")
    func noSyntheticRange() throws {
        let options = ChemicalDefaultRate.options(
            .per100Litres, from: try vicolSession().grapevineUses
        )
        // 2 and 3 are two registered choices, not "2–3".
        #expect(options.count == 2)
        #expect(Set(options.map(\.displayRate)) == ["3 L/100 L", "2 L/100 L"])
        #expect(options.allSatisfy { !$0.isLabelRange })
        #expect(options.allSatisfy { $0.rate.minValue == nil && $0.rate.maxValue == nil })
        #expect(!options.contains { $0.displayRate.contains("2–3") })
    }

    @Test("A TRUE label range stays one selectable rate with both bounds")
    func trueLabelRangeStaysOne() {
        let use = ChemicalRegisteredUse(
            crop: "Grapevines",
            targetRaw: "Powdery mildew",
            rates: [
                ChemicalLabelRate(
                    label: "Dilute spraying",
                    basis: .rangePer100Litres,
                    minValue: 100,
                    maxValue: 200,
                    unit: "mL",
                    rawText: "100–200 mL/100 L"
                )
            ]
        )
        let options = ChemicalDefaultRate.options(.per100Litres, from: [use])

        // ONE option, not two defaults of 100 and 200.
        #expect(options.count == 1)
        let only = options[0]
        #expect(only.isLabelRange)
        #expect(only.rate.minValue == 100)
        #expect(only.rate.maxValue == 200)
        #expect(only.rate.unit == "mL")
        #expect(only.rate.basis == .rangePer100Litres)
        #expect(only.displayRate == "100–200 mL/100 L")
        #expect(only.rate.rawText == "100–200 mL/100 L")

        // A single registered rate, so it is the recommendation.
        let plan = ChemicalDefaultRate.plan(grapevineUses: [use])
        #expect(plan.per100Litres.recommendation == .onlyRegisteredRate)
        #expect(plan.per100Litres.recommendedOptionId == only.id)
        #expect(plan.per100Litres.recommendation.badge == "Recommended")
    }

    // MARK: - §5 The recommendation rule

    @Test("Step 1: the vineyard's state resolves a state-conditioned label")
    func jurisdictionRecommendation() throws {
        let plan = ChemicalDefaultRate.plan(
            grapevineUses: try vicolSession().grapevineUses,
            jurisdiction: .nsw
        )
        let group = plan.per100Litres

        #expect(group.recommendation == .jurisdiction(.nsw))
        #expect(group.recommendation.badge == "Recommended for NSW")
        #expect(group.recommendedOption?.displayRate == "3 L/100 L")
        #expect(!group.requiresChoice)

        // Both registered rates remain visible and selectable — narrowing the
        // RECOMMENDATION is not the same as hiding a registered rate.
        #expect(group.options.count == 2)
    }

    @Test("A rate outside the vineyard's jurisdiction is never recommended")
    func neverRecommendsOutsideJurisdiction() throws {
        let uses = try vicolSession().grapevineUses

        for (jurisdiction, expected) in [
            (ChemicalRateJurisdiction.nsw, "3 L/100 L"),
            (.tas, "2 L/100 L"),
            (.wa, "3 L/100 L"),
        ] {
            let group = ChemicalDefaultRate
                .plan(grapevineUses: uses, jurisdiction: jurisdiction)
                .per100Litres
            #expect(group.recommendedOption?.displayRate == expected)
            // Whatever is recommended must be registered where the vineyard is.
            #expect(group.recommendedOption?.applies(in: jurisdiction) == true)
        }

        // Queensland appears on the scale row only, so exactly one rate applies.
        let qld = ChemicalDefaultRate
            .plan(grapevineUses: uses, jurisdiction: .qld).per100Litres
        #expect(qld.recommendedOption?.displayRate == "3 L/100 L")
    }

    @Test("Step 2: one distinct rate is recommended when the state is unknown")
    func singleRateRecommendedWithoutJurisdiction() {
        let use = ChemicalRegisteredUse(
            crop: "Grapevines",
            targetRaw: "Grapevine scale",
            rates: [
                ChemicalLabelRate(
                    label: "Dormant", basis: .per100Litres,
                    value: 2, unit: "L", rawText: "2 L/100 L"
                )
            ]
        )
        let group = ChemicalDefaultRate.plan(grapevineUses: [use]).per100Litres
        #expect(group.recommendation == .onlyRegisteredRate)
        #expect(group.recommendation.badge == "Recommended")
        #expect(group.recommendedOption?.displayRate == "2 L/100 L")
    }

    @Test("Step 2 merges identical numbers across different conditions")
    func identicalRatesAcrossConditionsAreOneChoice() {
        // Two registered targets, same number. A grower pours one thing.
        let uses = [
            ChemicalRegisteredUse(
                crop: "Grapevines", targetRaw: "European red mite",
                rates: [ChemicalLabelRate(
                    label: "NSW, Vic, SA", basis: .per100Litres,
                    value: 3, unit: "L", rawText: "3 L/100 L"
                )]
            ),
            ChemicalRegisteredUse(
                crop: "Grapevines", targetRaw: "Grapevine scale",
                rates: [ChemicalLabelRate(
                    label: "NSW, Vic, Qld, SA, WA", basis: .per100Litres,
                    value: 3, unit: "L", rawText: "3 L/100 L"
                )]
            ),
        ]
        let group = ChemicalDefaultRate.plan(grapevineUses: uses).per100Litres

        #expect(group.options.count == 1)
        #expect(group.recommendation == .onlyRegisteredRate)
        // Merged on the NUMBER, never on the conditions — both survive and
        // stay inspectable, which is the only thing that makes merging honest.
        #expect(group.options[0].conditions.count == 2)
        #expect(Set(group.options[0].conditions.map(\.targetRaw))
            == ["European red mite", "Grapevine scale"])
    }

    @Test("Step 3: several applicable rates require the operator to choose")
    func multipleApplicableRatesRequireChoice() throws {
        let uses = try vicolSession().grapevineUses

        // No state on record: 2 and 3 both stand, and neither may be assumed.
        let unknown = ChemicalDefaultRate.plan(grapevineUses: uses).per100Litres
        #expect(unknown.recommendation == .operatorMustChoose)
        #expect(unknown.recommendedOptionId == nil)
        #expect(unknown.requiresChoice)
        #expect(unknown.options.count == 2)

        // Victoria appears on BOTH mainland rows but not the Tasmanian ones,
        // so it still resolves; a state that genuinely matched two distinct
        // numbers would not.
        let bothApply = [
            ChemicalRegisteredUse(
                crop: "Grapevines", targetRaw: "Scale",
                rates: [
                    ChemicalLabelRate(label: "NSW", basis: .per100Litres,
                                      value: 3, unit: "L", rawText: "3 L/100 L"),
                    ChemicalLabelRate(label: "NSW", basis: .per100Litres,
                                      value: 5, unit: "L", rawText: "5 L/100 L"),
                ]
            )
        ]
        let ambiguousInNSW = ChemicalDefaultRate
            .plan(grapevineUses: bothApply, jurisdiction: .nsw).per100Litres
        #expect(ambiguousInNSW.recommendation == .operatorMustChoose)
        #expect(ambiguousInNSW.recommendedOptionId == nil)
    }

    @Test("A jurisdiction no rate covers does not fall back to another state's")
    func noApplicableRateDoesNotFallBack() throws {
        let uses = try vicolSession().grapevineUses
        // The Northern Territory is on neither row. Step 2 must NOT resurrect
        // a mainland or Tasmanian rate for it.
        let group = ChemicalDefaultRate
            .plan(grapevineUses: uses, jurisdiction: .nt).per100Litres
        #expect(group.recommendedOptionId == nil)
        #expect(group.requiresChoice)
        // The registered rates are still shown — the operator may knowingly
        // choose one; VineTrack simply will not choose for them.
        #expect(group.options.count == 2)
    }

    @Test("An unconditioned rate applies in every jurisdiction")
    func unconditionedRateAppliesEverywhere() {
        let use = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Powdery mildew",
            rates: [ChemicalLabelRate(
                label: "", basis: .per100Litres,
                value: 1, unit: "L", rawText: "1 L/100 L"
            )]
        )
        for jurisdiction in ChemicalRateJurisdiction.allCases {
            let group = ChemicalDefaultRate
                .plan(grapevineUses: [use], jurisdiction: jurisdiction).per100Litres
            // Silence in the condition is not exclusion.
            #expect(group.recommendedOption?.displayRate == "1 L/100 L")
        }
    }

    // MARK: - §5A / §6 No invented hectare rate

    @Test("No /ha rate is invented from a /100 L label")
    func noHectareRateInvented() throws {
        let plan = ChemicalDefaultRate.plan(
            grapevineUses: try vicolSession().grapevineUses,
            jurisdiction: .nsw
        )
        let hectare = plan.perHectare

        #expect(hectare.isEmpty)
        #expect(hectare.options.isEmpty)
        #expect(hectare.recommendation == .noRegisteredRate)
        #expect(hectare.recommendedOptionId == nil)
        #expect(hectare.recommendation.badge == nil)
        #expect(hectare.emptyStatement == "No registered per-hectare rate on this label")
        // A conversion would need a carrier volume the label never stated.
        #expect(!hectare.requiresChoice)
    }

    @Test("The two bases are decided independently")
    func basesAreIndependent() {
        let use = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Botrytis",
            rates: [
                ChemicalLabelRate(label: "Dilute", basis: .per100Litres,
                                  value: 2, unit: "L", rawText: "2 L/100 L"),
                ChemicalLabelRate(label: "Airblast", basis: .perHectare,
                                  value: 4, unit: "L", rawText: "4 L/ha"),
            ]
        )
        let plan = ChemicalDefaultRate.plan(grapevineUses: [use])
        #expect(plan.per100Litres.recommendedOption?.displayRate == "2 L/100 L")
        #expect(plan.perHectare.recommendedOption?.displayRate == "4 L/ha")
        // Neither basis borrows the other's number.
        #expect(plan.per100Litres.options.count == 1)
        #expect(plan.perHectare.options.count == 1)
    }

    @Test("A verbatim `other` rate can never become a default")
    func verbatimRateIsNotADefault() {
        let use = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Weeds",
            rates: [ChemicalLabelRate(
                label: "", basis: .other, unit: "",
                rawText: "Apply as directed by an agronomist"
            )]
        )
        let plan = ChemicalDefaultRate.plan(grapevineUses: [use])
        // Worth storing, and not a number anything may be dosed from.
        #expect(plan.per100Litres.isEmpty)
        #expect(plan.perHectare.isEmpty)
    }

    // MARK: - §6 VICOL 33182 acceptance, NSW vineyard

    @Test("VICOL 33182 on an NSW vineyard produces the accepted screen")
    func vicol33182NSWAcceptance() throws {
        let session = try vicolSession(jurisdiction: .nsw)

        // Identity locked, exactly as selected.
        #expect(session.name == "Vicol Winter Oil Insecticide")
        #expect(session.chemistryDraft.registrationNumber == "33182")
        #expect(session.chemistryDraft.registrationScheme == .apvma)
        #expect(session.countryCode == "AU")

        let plan = session.defaultRatePlan

        // Per 100 L: 3 L/100 L, Recommended for NSW.
        #expect(plan.per100Litres.recommendedOption?.displayRate == "3 L/100 L")
        #expect(plan.per100Litres.recommendation.badge == "Recommended for NSW")

        // Per hectare: nothing invented.
        #expect(plan.perHectare.emptyStatement
            == "No registered per-hectare rate on this label")
        #expect(plan.perHectare.recommendedOption == nil)

        // The operator may still inspect and change the registered options.
        #expect(plan.per100Litres.options.count == 2)
        #expect(Set(plan.per100Litres.options.map(\.displayRate))
            == ["3 L/100 L", "2 L/100 L"])

        // Nothing awaits a decision, because NSW resolved it.
        #expect(session.basesAwaitingDefaultChoice.isEmpty)

        // And the default in force is the recommendation.
        #expect(session.resolvedDefaultOption(for: .per100Litres)?.displayRate
            == "3 L/100 L")
        #expect(session.resolvedDefaultOption(for: .perHectare) == nil)
    }

    // MARK: - §8 Persistence parity

    @Test("Choosing a default does not destroy the authoritative rate list")
    func defaultChoiceKeepsAuthoritativeRates() throws {
        var session = try vicolSession(jurisdiction: .nsw)

        let before = session.grapevineUses.flatMap(\.rates)
        #expect(before.count == 4)

        // Deliberately choose AGAINST the recommendation.
        let tasmanian = session.defaultRatePlan.per100Litres.options
            .first { $0.displayRate == "2 L/100 L" }
        #expect(tasmanian != nil)
        session.selectDefaultRate(tasmanian!, for: .per100Litres)

        #expect(session.resolvedDefaultOption(for: .per100Litres)?.displayRate
            == "2 L/100 L")

        // Every registered rate survives, unedited, with its condition.
        let after = session.grapevineUses.flatMap(\.rates)
        #expect(after.count == 4)
        #expect(Set(after.map(\.displayRate)) == ["3 L/100 L", "2 L/100 L"])
        #expect(Set(after.map(\.label))
            == ["NSW, Vic, SA", "Tasmania", "NSW, Vic, Qld, SA, WA"])

        // Other crops are untouched too.
        #expect(session.otherCropUses.count == 5)

        // And the record that would be SAVED still holds the whole label.
        let persisted = session.intelligenceToPersist
        #expect((persisted?.registeredUses ?? []).statedUses.count == 7)
        #expect((persisted?.registeredUses ?? []).viticultural.flatMap(\.rates).count == 4)
    }

    @Test("The chosen default is what the legacy operational columns store")
    func chosenDefaultDrivesLegacyProjection() throws {
        var session = try vicolSession(jurisdiction: .nsw)
        session.unit = .litres

        // Recommendation in force: 3 L/100 L.
        let recommended = session.legacyProjection()
        let recommendedRate = recommended.rates.first { $0.basis == .per100Litres }
        #expect(recommendedRate != nil)
        #expect(recommendedRate?.label == "NSW, Vic, SA")

        // Choose the Tasmanian rate; the stored operational value follows the
        // DECISION, not whichever row happened to be parsed first.
        let tasmanian = session.defaultRatePlan.per100Litres.options
            .first { $0.displayRate == "2 L/100 L" }!
        session.selectDefaultRate(tasmanian, for: .per100Litres)

        let chosen = session.legacyProjection()
        let chosenRate = chosen.rates.first { $0.basis == .per100Litres }
        #expect(chosenRate?.label == "Tasmania")
        #expect(chosenRate?.value != recommendedRate?.value)

        // No hectare rate is written, because the label states none.
        #expect(!chosen.rates.contains { $0.basis == .perHectare })
        #expect(chosen.ratePerHa == 0)
    }

    @Test("A stored default is recovered on re-open, not re-decided")
    func storedDefaultIsRecovered() throws {
        var session = try vicolSession(jurisdiction: .nsw)
        session.unit = .litres
        let tasmanian = session.defaultRatePlan.per100Litres.options
            .first { $0.displayRate == "2 L/100 L" }!
        session.selectDefaultRate(tasmanian, for: .per100Litres)

        // Persist it the way Save does.
        var saved = try vicolDraft()
        let projection = session.legacyProjection()
        saved.rates = projection.rates
        saved.ratePerHa = projection.ratePerHa
        saved.chemicalIntelligence = session.intelligenceToPersist

        // Re-open. The deliberate choice must survive, even though the NSW
        // recommendation would have said 3 L/100 L.
        let reopened = ChemicalReviewSession.make(
            chemical: saved, prefill: nil, fallbackCountry: "AU", jurisdiction: .nsw
        )
        #expect(reopened.resolvedDefaultOption(for: .per100Litres)?.displayRate
            == "2 L/100 L")
        #expect(reopened.defaultRatePlan.per100Litres.recommendedOption?.displayRate
            == "3 L/100 L")
    }

    // MARK: - §9 WHP / REI

    @Test("Unresolved WHP and REI stay nil and read as Not stated")
    func unresolvedWithholdingStaysNil() throws {
        let session = try vicolSession(jurisdiction: .nsw)

        // The VICOL fixture states neither. Nothing may zero-fill them.
        for use in session.grapevineUses {
            #expect(use.withholdingPeriodDays == nil)
            #expect(use.reEntryPeriodHours == nil)
            #expect(use.reEntryStatement == nil)
            #expect(use.reEntryDisplay == .notStated)

            let whp = ChemicalWithholdingDisplay.display(
                days: use.withholdingPeriodDays,
                restrictions: use.restrictions,
                hasManufacturerLabelSource: true
            )
            #expect(whp == "Not stated")
            #expect(whp != "0 days")
        }
    }

    @Test("An explicit zero WHP is kept as zero, never as missing")
    func explicitZeroIsPreserved() throws {
        // The other half of the rule: 0 is a fact, and must not be erased into
        // "Not stated" any more than nil may be filled in as 0.
        let json = """
        {
          "crop": "Grapevines", "target_raw": "Scale",
          "withholding_period_days": 0, "re_entry_period_hours": 0,
          "rates": []
        }
        """
        let use = try JSONDecoder().decode(
            ChemicalRegisteredUse.self, from: Data(json.utf8)
        )
        #expect(use.withholdingPeriodDays == 0)
        #expect(use.reEntryPeriodHours == 0)
        #expect(use.reEntryDisplay == .hours(0, statement: nil))
    }

    // MARK: - Jurisdiction parsing

    @Test("State abbreviations are matched as whole tokens only")
    func jurisdictionTokenMatching() {
        #expect(ChemicalRateJurisdiction.mentioned(in: "NSW, Vic, Qld, SA, WA")
            == [.nsw, .vic, .qld, .sa, .wa])
        #expect(ChemicalRateJurisdiction.mentioned(in: "Tasmania") == [.tas])
        #expect(ChemicalRateJurisdiction.mentioned(in: "New South Wales only") == [.nsw])

        // The failure that would silently re-scope a rate: a state code found
        // inside an ordinary word.
        #expect(ChemicalRateJurisdiction.mentioned(in: "Apply with water").isEmpty)
        #expect(ChemicalRateJurisdiction.mentioned(in: "Late season application").isEmpty)
        #expect(ChemicalRateJurisdiction.mentioned(in: "Dilute spraying").isEmpty)
        #expect(ChemicalRateJurisdiction.mentioned(in: "").isEmpty)
        #expect(ChemicalRateJurisdiction.mentioned(in: nil).isEmpty)
    }

    @Test("An unrecognised vineyard jurisdiction resolves to nil, never a guess")
    func jurisdictionParseIsStrict() {
        #expect(ChemicalRateJurisdiction.parse("NSW") == .nsw)
        #expect(ChemicalRateJurisdiction.parse("nsw") == .nsw)
        #expect(ChemicalRateJurisdiction.parse("Tasmania") == .tas)
        #expect(ChemicalRateJurisdiction.parse("Marlborough") == nil)
        #expect(ChemicalRateJurisdiction.parse("") == nil)
        #expect(ChemicalRateJurisdiction.parse(nil) == nil)
    }
}

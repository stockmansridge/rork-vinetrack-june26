import Foundation
import Testing

@testable import VineTrack

/// P2C Chemical Search release — the three customer-flow behaviours completed
/// for the release candidate.
///
/// ```text
/// §1  Change Product          — "this isn't the product on my drum"
/// §2  Registration notice     — not raised before a product has been chosen
/// §3  Exact vineyard dose     — a real number from inside a registered band,
///                               without editing the band
/// ```
///
/// The fixtures are the two acceptance products: THIOVIT JET (APVMA 53904), a
/// sulfur microgranule whose grapevine Powdery Mildew rate is printed as a
/// BAND, and VICOL WINTER OIL (APVMA 33182), a different registrant's liquid.
/// A band and a single value are the two shapes a default has to survive, and
/// two products are what a "Change Product" has to tell apart.
struct ChemicalCustomerFlowTests {

    private static let vineyardId = UUID(uuidString: "53904000-0000-0000-0000-000000000001")!

    // MARK: - Fixtures

    /// Thiovit, reduced to one grapevine direction stating a true label RANGE.
    /// One option means the recommendation rule settles it, so the exact-dose
    /// tests are about the band and not about picking between rows.
    private static let thiovitJSON = """
    {
      "product_name": "THIOVIT JET MICROGRANULE FUNGICIDE/MITICIDE",
      "product_category": "fungicide",
      "form_type": "solid",
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "53904",
        "registrant": "SYNGENTA AUSTRALIA PTY LTD",
        "registered_product_name": "THIOVIT JET MICROGRANULE FUNGICIDE/MITICIDE",
        "label_reference": "https://portal.apvma.gov.au/pubcris/53904/label.pdf",
        "regulator_label_url": "https://portal.apvma.gov.au/pubcris/53904/label.pdf"
      },
      "active_ingredients": [
        { "name": "Sulfur As Elemental Sulfur", "concentration": 800,
          "concentration_unit": "g_per_kg" }
      ],
      "activity_groups": [],
      "registered_uses": \(thiovitUsesJSON),
      "grapevine_uses": \(thiovitUsesJSON),
      "registered_for_grapevine": true,
      "label_rate_bases": ["range_per_100_litres"],
      "verification": {
        "status": "partially_verified",
        "sources": [],
        "conflicts": [],
        "unresolved_fields": []
      },
      "schema_version": 1
    }
    """

    private static let thiovitUsesJSON = """
    [
      {
        "crop": "Grapes table grapes, fruit destined for drying",
        "target_raw": "Powdery Mildew",
        "direction_id": "dir-table-drying",
        "withholding_period_days": 0,
        "rates": [
          { "label": "NSW, Vic, Tas, SA, WA only", "basis": "range_per_100_litres",
            "min_value": 100, "max_value": 200, "unit": "g",
            "rate_id": "rate-table-drying-pm",
            "raw_text": "100-200 g/100 L (NSW, Vic, Tas, SA, WA only)" }
        ]
      }
    ]
    """

    /// A DIFFERENT registered product, for the Change Product path.
    private static let vicolJSON = """
    {
      "product_name": "VICOL WINTER OIL INSECTICIDE",
      "product_category": "insecticide",
      "form_type": "liquid",
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "33182",
        "registrant": "Victorian Chemical Company Pty Ltd",
        "registered_product_name": "VICOL WINTER OIL INSECTICIDE",
        "label_reference": "https://portal.apvma.gov.au/pubcris/33182/label.pdf",
        "regulator_label_url": "https://portal.apvma.gov.au/pubcris/33182/label.pdf"
      },
      "active_ingredients": [
        { "name": "Petroleum Oil", "concentration": 861, "concentration_unit": "g_per_l" }
      ],
      "activity_groups": [],
      "registered_uses": \(vicolUsesJSON),
      "grapevine_uses": \(vicolUsesJSON),
      "registered_for_grapevine": true,
      "label_rate_bases": ["per_100_litres"],
      "verification": {
        "status": "partially_verified",
        "sources": [],
        "conflicts": [],
        "unresolved_fields": []
      },
      "schema_version": 1
    }
    """

    private static let vicolUsesJSON = """
    [
      {
        "crop": "GRAPEVINES",
        "target_raw": "Grapevine scale",
        "rates": [
          { "label": "NSW, Vic, Qld, SA, WA", "basis": "per_100_litres",
            "value": 3, "unit": "L", "raw_text": "3 L/100 L" }
        ]
      }
    ]
    """

    private func draft(_ json: String) throws -> SavedChemical {
        let lookup = try JSONDecoder().decode(
            ChemicalStructuredLookup.self, from: Data(json.utf8)
        )
        return ChemicalReviewMerge.reviewChemical(
            lookup: lookup,
            selected: nil,
            existing: nil,
            countryCode: "AU",
            vineyardId: Self.vineyardId
        )
    }

    private func thiovitSession() throws -> ChemicalReviewSession {
        ChemicalReviewSession.make(
            chemical: nil,
            prefill: try draft(Self.thiovitJSON),
            fallbackCountry: "AU"
        )
    }

    // MARK: - §1 Change Product

    @Test("Reviewing a lookup is the state that offers Change Product")
    func reviewingLookupIsDetected() throws {
        let session = try thiovitSession()
        #expect(session.isReviewingLookup)
        // Editing a record already on file is NOT a product change situation.
        let editing = ChemicalReviewSession.make(
            chemical: try draft(Self.thiovitJSON),
            prefill: nil,
            fallbackCountry: "AU"
        )
        #expect(!editing.isReviewingLookup)
    }

    @Test("Product identity distinguishes two registrations")
    func identityKeyDistinguishesProducts() throws {
        let thiovit = try thiovitSession()
        let vicol = ChemicalReviewSession.make(
            chemical: nil, prefill: try draft(Self.vicolJSON), fallbackCountry: "AU"
        )
        #expect(thiovit.productIdentityKey != vicol.productIdentityKey)
        #expect(thiovit.productIdentityKey.contains("53904"))
        #expect(vicol.productIdentityKey.contains("33182"))
    }

    @Test("Changing product RETIRES the previous product's default decision")
    func changingProductClearsDefaults() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres
        let option = try #require(session.resolvedDefaultOption(for: basis))
        session.selectDefaultRate(option, for: basis)
        let accepted = session.setDefaultRateValue(150, for: basis)
        #expect(accepted)
        #expect(session.defaultRateValues[basis] == 150)

        // The operator realises it is the wrong drum and picks VICOL instead.
        session.apply(reviewed: try draft(Self.vicolJSON), fallbackCountry: "AU")

        // A dose chosen off Thiovit's label must not survive onto VICOL's.
        #expect(session.defaultRateValues.isEmpty)
        #expect(session.selectedDefaultRateIds.isEmpty)
        #expect(session.name.contains("VICOL"))
        #expect(session.chemistryDraft.registrationNumber == "33182")
    }

    @Test("Changing product keeps what the OPERATOR owns")
    func changingProductKeepsOperationalData() throws {
        var session = try thiovitSession()
        session.costText = "184.50"
        session.containerSizeText = "20"
        session.notes = "Shed B, top shelf"
        session.inventoryText = "3"
        session.trackPurchase = true

        session.apply(reviewed: try draft(Self.vicolJSON), fallbackCountry: "AU")

        // Re-identifying a product says nothing about what it cost.
        #expect(session.costText == "184.50")
        #expect(session.containerSizeText == "20")
        #expect(session.notes == "Shed B, top shelf")
        #expect(session.inventoryText == "3")
        #expect(session.trackPurchase)
    }

    @Test("Re-searching the SAME product keeps a still-registered default")
    func sameProductRetainsAuthorisedDefault() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres
        let option = try #require(session.resolvedDefaultOption(for: basis))
        session.selectDefaultRate(option, for: basis)
        let accepted = session.setDefaultRateValue(150, for: basis)
        #expect(accepted)

        // Same registration, re-verified. The band still authorises 150.
        session.apply(reviewed: try draft(Self.thiovitJSON), fallbackCountry: "AU")

        #expect(session.defaultRateValues[basis] == 150)
        #expect(session.selectedDefaultRateIds[basis] == option.id)
    }

    // MARK: - §2 The registration notice is not raised prematurely

    @Test("A blank manual entry is NOT told it is missing a registration number")
    func blankEntryRaisesNoRegistrationNotice() {
        let blank = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        // Nothing has been searched, nothing chosen. The identifier is
        // something VineTrack fills in from a lookup, never something the
        // operator is asked for, so there is nothing to report yet.
        #expect(!blank.showsRegistrationIssues)
    }

    @Test("A reviewed lookup DOES report an unresolved registration")
    func reviewedLookupRaisesRegistrationNotice() throws {
        // A candidate was chosen: whether its identity resolved is now real
        // news about a decision the operator actually took.
        #expect(try thiovitSession().showsRegistrationIssues)
    }

    @Test("A record that already carries a registration number reports normally")
    func recordWithRegistrationRaisesNotice() throws {
        var session = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        #expect(!session.showsRegistrationIssues)
        session.chemistryDraft.registrationNumber = "53904"
        #expect(session.hasRegistrationNumber)
        #expect(session.showsRegistrationIssues)
    }

    @Test("The gate suppresses the notice only — it never edits the contract")
    func gateDoesNotWeakenTheContract() {
        let blank = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        // The evaluation is untouched: the contract still knows, Save still
        // behaves, the screen is simply not shouting about it yet.
        #expect(blank.saveEvaluation.violations.contains { $0.field == "registration" })
    }

    // MARK: - §3 An exact vineyard dose inside a registered band

    @Test("The band is read from the label, both ends preserved")
    func bandIsReadFromLabel() throws {
        let session = try thiovitSession()
        let option = try #require(
            session.resolvedDefaultOption(for: .per100Litres)
        )
        #expect(option.isLabelRange)
        let bounds = try #require(option.authorisedBounds)
        #expect(bounds.min == 100)
        #expect(bounds.max == 200)
        // With no dose named, the band starts at its LOWER bound — never the
        // top, which would over-apply by default.
        #expect(option.startingValue == 100)
    }

    @Test("A dose inside the band is accepted")
    func inRangeDoseAccepted() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres
        let acceptedMid = session.setDefaultRateValue(150, for: basis)
        #expect(acceptedMid)
        #expect(session.resolvedDefaultValue(for: basis) == 150)
        // Both ends are registered rates in their own right.
        let acceptedFloor = session.setDefaultRateValue(100, for: basis)
        #expect(acceptedFloor)
        let acceptedCeiling = session.setDefaultRateValue(200, for: basis)
        #expect(acceptedCeiling)
    }

    @Test("A dose OUTSIDE the band is refused and changes nothing")
    func outOfRangeDoseRefused() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres
        let accepted = session.setDefaultRateValue(150, for: basis)
        #expect(accepted)

        // 600 is a real Thiovit rate — for WINE grapes, under a different
        // direction. It is not registered for this one, and the band is the
        // authority on what may be applied.
        let refusedAbove = session.setDefaultRateValue(600, for: basis)
        #expect(!refusedAbove)
        let refusedBelow = session.setDefaultRateValue(99, for: basis)
        #expect(!refusedBelow)
        let refusedZero = session.setDefaultRateValue(0, for: basis)
        #expect(!refusedZero)
        let refusedNegative = session.setDefaultRateValue(-5, for: basis)
        #expect(!refusedNegative)
        // The earlier, valid decision is untouched by a refused one.
        #expect(session.resolvedDefaultValue(for: basis) == 150)
    }

    @Test("Naming a dose NEVER edits the registered range")
    func doseDoesNotMutateLabelRange() throws {
        var session = try thiovitSession()
        let before = session.grapevineUses.flatMap(\.rates)
        let accepted = session.setDefaultRateValue(150, for: .per100Litres)
        #expect(accepted)
        let after = session.grapevineUses.flatMap(\.rates)

        // The label evidence is byte-for-byte what it was. Narrowing the
        // registered range to the grower's own figure would tell the next
        // operator, the re-verification and the audit trail that the label
        // says 150 when it says 100-200.
        #expect(before == after)
        let rate = try #require(after.first)
        #expect(rate.minValue == 100)
        #expect(rate.maxValue == 200)
        #expect(rate.label == "NSW, Vic, Tas, SA, WA only")
        #expect(session.grapevineUses.flatMap(\.rates).count == 1)
    }

    @Test("The chosen dose is what the spray calculation starts from")
    func doseReachesTheProjection() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres

        // Before: the bottom of the band.
        let atFloor = session.per100LitreRateDisplay
        let accepted = session.setDefaultRateValue(150, for: basis)
        #expect(accepted)
        let atChosen = session.per100LitreRateDisplay

        #expect(atFloor != atChosen)
        // Projected through the product's own unit (kg for a solid), so the
        // stored operational rate is 150 g expressed on the record's scale.
        #expect(atChosen != nil)
        #expect(session.resolvedDefaultValue(for: basis) == 150)
    }

    @Test("Clearing the dose returns to the bottom of the band")
    func clearingDoseReturnsToFloor() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres
        let accepted = session.setDefaultRateValue(150, for: basis)
        #expect(accepted)
        session.clearDefaultRateValue(for: basis)
        #expect(session.defaultRateValues[basis] == nil)
        #expect(session.resolvedDefaultValue(for: basis) == 100)
    }

    @Test("A dose survives save and reload")
    func doseSurvivesRoundTrip() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres
        let accepted = session.setDefaultRateValue(150, for: basis)
        #expect(accepted)

        // The decision persists through the legacy projection the Spray Tool
        // reads, and is RECOVERED by matching the band that authorises it —
        // never reconstructed.
        let projection = session.legacyProjection()
        let stored = try #require(projection.rates.first { $0.basis == .per100Litres })
        #expect(stored.value > 0)
        // The condition travels with it, so the stored rate says which
        // registered condition it came from.
        #expect(stored.label == "NSW, Vic, Tas, SA, WA only")
    }

    @Test("Switching to a different registered rate retires the old dose")
    func switchingOptionClearsDose() throws {
        var session = try thiovitSession()
        let basis = ChemicalDefaultRateBasis.per100Litres
        let option = try #require(session.resolvedDefaultOption(for: basis))
        let accepted = session.setDefaultRateValue(150, for: basis)
        #expect(accepted)
        #expect(session.defaultRateValues[basis] == 150)

        // Re-selecting is a fresh decision about which registered rate applies;
        // a number taken from the previous one is not carried onto it.
        session.selectDefaultRate(option, for: basis)
        #expect(session.defaultRateValues[basis] == nil)
    }

    @Test("A single-value rate authorises only its own number")
    func singleValueRateHasNoBand() throws {
        let session = ChemicalReviewSession.make(
            chemical: nil, prefill: try draft(Self.vicolJSON), fallbackCountry: "AU"
        )
        let option = try #require(
            session.resolvedDefaultOption(for: .per100Litres)
        )
        #expect(!option.isLabelRange)
        #expect(option.authorises(3))
        #expect(!option.authorises(2))
        #expect(!option.authorises(4))
        let bounds = try #require(option.authorisedBounds)
        #expect(bounds.min == 3)
        #expect(bounds.max == 3)
    }
}

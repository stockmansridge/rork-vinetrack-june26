import Foundation
import Testing
@testable import VineTrack

/// A first add must not be saveable until the operator has said what this
/// vineyard actually pours.
///
/// # The defect these tests exist to prevent
///
/// CHATEAU registers `560–700 g/ha`. The screen showed that band with the
/// exact-dose box PREFILLED at 560 and a line reading "leave it blank to use
/// 560", so the fastest path through the form — read, tap Save — recorded the
/// bottom of the band as though the grower had chosen it. Nobody chose it. A
/// vineyard dosing 620 got 560 on every subsequent spray calculation, and the
/// record claimed an operator decision that never happened.
///
/// The correction is one rule in one place: the box starts empty, a band is
/// only confirmed by a number typed INSIDE it, and `isValid` refuses the save
/// until then. A recommendation is VineTrack reading the label; a confirmation
/// is the grower answering it.
@MainActor
struct ChemicalRateConfirmationGateTests {

    private static let vineyardId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    private static let optionKey = "default_option_v1_dd81178fa70649ce9a097ad840805834"

    /// CHATEAU (APVMA 80647): one grapevine band, 560–700 g/ha, WHP 98.
    ///
    /// `rate_ids` are deliberately NOT in sorted order: the server minted the
    /// key over these exact bytes in this exact order.
    private static let chateauLookupJSON = """
    {
      "name": "CHATEAU WDG HERBICIDE",
      "registration_number": "80647",
      "country_code": "AU",
      "product_category": "Herbicide",
      "registered_uses": [
        {
          "crop": "Grapevines",
          "target": "Annual broadleaf weeds",
          "direction_id": "dir_v1_chateau",
          "withholding_period_days": 98,
          "rates": [
            {
              "label": "All states",
              "basis": "range_per_hectare",
              "min_value": 560,
              "max_value": 700,
              "unit": "g",
              "raw_text": "560 - 700 g/ha",
              "rate_id": "rate_v1_zeta"
            }
          ]
        }
      ],
      "default_rate_options": {
        "per_hectare": [
          {
            "option_key": "default_option_v1_dd81178fa70649ce9a097ad840805834",
            "rate_ids": ["rate_v1_zeta", "rate_v1_alpha"],
            "basis": "per_hectare",
            "unit": "g",
            "min_value": 560,
            "max_value": 700,
            "direction_ids": ["dir_v1_chateau"],
            "targets": ["Annual broadleaf weeds"],
            "crops": ["Grapevines"]
          }
        ],
        "per_100_litres": []
      }
    }
    """

    private func decode(_ json: String) throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    private func row() -> ChemicalSearchRow {
        ChemicalSearchRow(
            result: ChemicalSearchResult(
                name: "CHATEAU WDG HERBICIDE",
                brand: "Sumitomo Chemical Australia",
                registrationNumber: "80647",
                source: ChemicalSearchResult.officialRegisterSource
            ),
            tier: .officialRegister,
            existing: nil
        )
    }

    /// A first add of CHATEAU, exactly as the review screen receives it.
    ///
    /// The category is asserted rather than assumed so a failure here reads as
    /// "the gate is wrong", never as "the fixture was incomplete".
    private func firstAddSession() throws -> ChemicalReviewSession {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: try decode(Self.chateauLookupJSON),
            country: "AU",
            existing: nil,
            vineyardId: Self.vineyardId
        )
        let draft = try #require(coordinator.reviewDraft)
        var session = ChemicalReviewSession.make(
            chemical: nil,
            prefill: draft,
            fallbackCountry: "AU",
            serverDefaultRateOptions: coordinator.reviewDefaultRateOptions
        )
        if session.chemistryDraft.productCategory.trimmingCharacters(in: .whitespaces).isEmpty {
            session.chemistryDraft.productCategory = ProductCategory.herbicide.rawValue
        }
        return session
    }

    // MARK: - 1. The band starts blank

    @Test("CHATEAU's registered band begins with no rate entered")
    func chateauBeginsBlank() throws {
        let session = try firstAddSession()
        let option = try #require(session.defaultRatePlan.group(.perHectare).options.first)

        #expect(option.isLabelRange)
        #expect(option.authorisedBounds?.min == 560)
        #expect(option.authorisedBounds?.max == 700)
        // Nothing chosen, nothing typed. The badge below is a reading of the
        // label, not an answer to it.
        #expect(session.defaultRateValues[.perHectare] == nil)
        #expect(session.selectedDefaultRateIds[.perHectare] == nil)
        #expect(!session.isDefaultRateConfirmed(for: .perHectare))
    }

    // MARK: - 2. Inclusive validation

    @Test(
        "Both ends of the band and everything between are accepted",
        arguments: [560.0, 600.0, 700.0]
    )
    func boundsAreInclusive(_ value: Double) throws {
        var session = try firstAddSession()
        #expect(session.setDefaultRateValue(value, for: .perHectare))
        #expect(session.defaultRateValues[.perHectare] == value)
        #expect(session.isDefaultRateConfirmed(for: .perHectare))
    }

    @Test("A rate outside the band is refused and records nothing", arguments: [559.0, 701.0])
    func outsideTheBandIsRefused(_ value: Double) throws {
        var session = try firstAddSession()
        #expect(!session.setDefaultRateValue(value, for: .perHectare))
        // Refused means unchanged: an off-label figure never lands in the
        // session in any form.
        #expect(session.defaultRateValues[.perHectare] == nil)
        #expect(!session.isDefaultRateConfirmed(for: .perHectare))
        #expect(!session.isValid)
    }

    // MARK: - 3. The Save gate

    @Test("A blank band keeps Save disabled")
    func blankBandKeepsSaveDisabled() throws {
        let session = try firstAddSession()
        #expect(session.requiresDefaultRateConfirmation)
        #expect(!session.hasConfirmedDefaultRate)
        #expect(session.isAwaitingDefaultRateConfirmation)
        #expect(!session.isValid)
        // And the block is the RATE question, not some other missing field —
        // otherwise this test would pass for the wrong reason.
        #expect(session.blockingViolations.isEmpty)
    }

    @Test("Selecting the band without entering a rate keeps Save disabled")
    func selectingWithoutValueKeepsSaveDisabled() throws {
        var session = try firstAddSession()
        let option = try #require(session.defaultRatePlan.group(.perHectare).options.first)

        session.selectDefaultRate(option, for: .perHectare)
        #expect(session.selectedDefaultRateIds[.perHectare] == Self.optionKey)
        // A band with no number names no dose. Picking the row is not an answer.
        #expect(session.defaultRateValues[.perHectare] == nil)
        #expect(!session.isDefaultRateConfirmed(for: .perHectare))
        #expect(!session.isValid)
    }

    @Test("Entering 600 confirms the rate and enables Save")
    func enteringRateEnablesSave() throws {
        var session = try firstAddSession()
        #expect(!session.isValid)

        #expect(session.setDefaultRateValue(600, for: .perHectare))

        #expect(session.isDefaultRateConfirmed(for: .perHectare))
        #expect(session.hasConfirmedDefaultRate)
        #expect(!session.isAwaitingDefaultRateConfirmation)
        #expect(session.blockingViolations.isEmpty)
        #expect(session.isValid)
    }

    // MARK: - 4. What the confirmation persists

    @Test("The confirmed default keeps the server's key and rate id order")
    func confirmedDefaultKeepsServerIdentity() throws {
        var session = try firstAddSession()
        #expect(session.setDefaultRateValue(600, for: .perHectare))

        let stored = try #require(session.storedDefaultRates?.perHectare)
        #expect(stored.optionKey == Self.optionKey)
        // Verbatim, in the SERVER's order — never re-sorted, never de-duplicated.
        #expect(stored.rateIds == ["rate_v1_zeta", "rate_v1_alpha"])
        #expect(stored.basis == "per_hectare")
        // The LABEL's unit. The vineyard buys CHATEAU by the kilogram; the rate
        // is still grams.
        #expect(stored.unit == "g")
        #expect(stored.value == 600)
        // The band itself is untouched evidence.
        #expect(stored.minValue == 560)
        #expect(stored.maxValue == 700)
        #expect(stored.source == "operator")
    }

    /// A device-assembled option carries no register identity, so confirming
    /// one would enable a Save that then wrote no default at all.
    @Test("An option without a server twin can never satisfy the gate")
    func deviceBuiltOptionNeverConfirms() throws {
        var session = try firstAddSession()
        // The plan the edit path builds: same numbers, no server identity.
        session.serverDefaultRateOptions = nil
        let option = try #require(session.defaultRatePlan.group(.perHectare).options.first)
        #expect(option.server == nil)

        session.selectDefaultRate(option, for: .perHectare)
        _ = session.setDefaultRateValue(600, for: .perHectare)

        #expect(!session.isDefaultRateConfirmed(for: .perHectare))
        #expect(!session.isValid)
        #expect(session.storedDefaultRates == nil)
    }

    // MARK: - 5. Who the gate does NOT apply to

    /// Manual entry never went near the register: there is no canonical option
    /// to confirm, so demanding one would make the manual path unsaveable.
    @Test("Manual entry stays saveable under its existing rules")
    func manualEntryStaysSaveable() {
        var session = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        session.name = "HOMEMADE HORTI OIL"
        session.chemistryDraft.productCategory = ProductCategory.fungicide.rawValue
        session.chemistryDraft.uses = [
            ChemicalManualUseDraft(
                crop: "Grapevines",
                targetRaw: "Powdery mildew",
                rates: [
                    ChemicalManualRateDraft(
                        basis: .perHectare, valueText: "2", unit: "L"
                    )
                ],
                withholdingPeriodDaysText: "14"
            )
        ]

        #expect(!session.requiresDefaultRateConfirmation)
        #expect(!session.hasConfirmedDefaultRate)
        #expect(session.blockingViolations.isEmpty)
        #expect(session.isValid)
    }

    /// An existing record is already saved. Blocking a price or note edit
    /// behind a rate question would strand it unrepairable — which is how bad
    /// data becomes permanent.
    @Test("Editing an existing record is unaffected by the gate")
    func existingRecordIsUnaffected() {
        let chemical = SavedChemical(name: "CHATEAU WDG HERBICIDE")
        var session = ChemicalReviewSession.make(
            chemical: chemical, prefill: nil, fallbackCountry: "AU"
        )
        #expect(!session.requiresDefaultRateConfirmation)
        #expect(!session.isAwaitingDefaultRateConfirmation)
        #expect(session.isValid)

        session.notes = "Stored in the back shed."
        #expect(session.isValid)
    }
}

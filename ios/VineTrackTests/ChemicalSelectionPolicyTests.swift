import Foundation
import Testing
@testable import VineTrack

/// iOS ranking policy and WHP/REI honesty (task Phase 17 F, H).
///
/// # The inference under test
///
/// "One result means one answer" is the assumption that let an ambiguous query
/// become a silent product decision. A single row is produced just as readily
/// by CERTAINTY as by STARVATION — and "Hortitrol winter oil" produced exactly
/// one confident-looking row for a product whose registered name shares not one
/// word with the query, because a contaminated alias was the only thing that
/// got through.
///
/// The row count cannot tell those two apart. The server can. These tests pin
/// the app to the server's verdict, in both directions: it must ask when told
/// to ask, and it must not turn every search into a questionnaire when the
/// identity is genuinely proven.
@Suite("Chemical selection policy and unresolved-value rendering")
struct ChemicalSelectionPolicyTests {

    // MARK: - Fixtures

    private func candidate(
        _ name: String,
        registration: String?,
        source: String? = ChemicalSearchResult.officialRegisterSource,
        scheme: String? = "apvma",
        registrant: String = "Victorian Chemical Company",
        category: String? = "Insecticide",
        grapevine: Bool? = nil
    ) -> ChemicalSearchResult {
        ChemicalSearchResult(
            name: name,
            activeIngredient: "Petroleum Oil 861 g/L",
            brand: registrant,
            registrationNumber: registration,
            registrationScheme: scheme,
            registrant: registrant,
            productCategory: category,
            hasGrapevineUse: grapevine,
            source: source,
            countryCode: "AU"
        )
    }

    private func ranking(
        state: String,
        autoSelect: Bool,
        exact: String? = nil
    ) -> ChemicalSearchRankingSummary {
        ChemicalSearchRankingSummary(
            searchState: state,
            autoSelectAllowed: autoSelect,
            exactRegistrationNumber: exact
        )
    }

    // MARK: - H. iOS ranking policy

    /// THE required case. One row, and the server says it is not settled.
    @Test("A single result with needs_choice does NOT auto-apply")
    func singleResultNeedingChoiceShowsPicker() {
        let results = [candidate("VICOL WINTER OIL INSECTICIDE", registration: "33182")]

        let outcome = ChemicalSelectionPolicy.decide(
            results: results,
            ranking: ranking(state: "needs_choice", autoSelect: false)
        )

        guard case .requiresChoice(let shown) = outcome else {
            Issue.record("one weak result must still be a human decision")
            return
        }
        #expect(shown.count == 1)
        // And nothing was bound.
        if case .autoSelect = outcome { Issue.record("must not auto-select") }
    }

    @Test("A single result the server proves exact MAY be auto-selected")
    func singleProvenResultAutoSelects() {
        let results = [candidate("CHATEAU HERBICIDE", registration: "80647")]

        let outcome = ChemicalSelectionPolicy.decide(
            results: results,
            ranking: ranking(state: "exact", autoSelect: true, exact: "80647")
        )

        guard case .autoSelect(let picked) = outcome else {
            Issue.record("a proven exact identity should not need a tap")
            return
        }
        #expect(picked.registrationNumber == "80647")
    }

    /// The wire state the backend actually emits for an ambiguous answer.
    @Test("The server's own ambiguous state forces the picker")
    func ambiguousStateShowsPicker() {
        let results = [
            candidate("VICOL WINTER OIL INSECTICIDE", registration: "33182"),
            candidate("SYNERTROL HORTI BOTANICAL OIL CONCENTRATE", registration: "50067"),
        ]
        let outcome = ChemicalSelectionPolicy.decide(
            results: results,
            ranking: ranking(state: "ambiguous", autoSelect: false)
        )
        guard case .requiresChoice(let shown) = outcome else {
            Issue.record("two plausible products is a choice")
            return
        }
        #expect(shown.count == 2)
    }

    /// The app refuses even when the server says yes, if it cannot identify
    /// what it would be binding.
    @Test("A candidate with no registration number is never auto-selected")
    func unidentifiableCandidateNeverAutoSelects() {
        let results = [candidate("SOME WINTER OIL", registration: nil, source: nil)]
        let outcome = ChemicalSelectionPolicy.decide(
            results: results,
            ranking: ranking(state: "exact", autoSelect: true)
        )
        guard case .requiresChoice = outcome else {
            Issue.record("an unidentifiable row cannot be locked, so it cannot be bound")
            return
        }
    }

    @Test("A rival authoritative candidate blocks auto-selection")
    func rivalBlocksAutoSelect() {
        let results = [
            candidate("WINTER OIL", registration: "11111"),
            candidate("WINTER OIL CONCENTRATE", registration: "22222"),
        ]
        let outcome = ChemicalSelectionPolicy.decide(
            results: results,
            ranking: ranking(state: "exact", autoSelect: true, exact: "11111")
        )
        guard case .requiresChoice = outcome else {
            Issue.record("two register-backed rows is a human decision")
            return
        }
    }

    @Test("A server that disagrees with itself is treated as ambiguous")
    func disagreeingServerShowsPicker() {
        // auto_select_allowed says yes, but the exact registration named is
        // not the row present. That is not a tiebreak to resolve on device.
        let results = [candidate("VICOL WINTER OIL INSECTICIDE", registration: "33182")]
        let outcome = ChemicalSelectionPolicy.decide(
            results: results,
            ranking: ranking(state: "exact", autoSelect: true, exact: "50067")
        )
        guard case .requiresChoice = outcome else {
            Issue.record("contradictory ranking metadata must fail closed")
            return
        }
    }

    /// Deployment skew: a shipped app can reach a server with no ranking block.
    @Test("An absent ranking block fails closed to the picker")
    func absentRankingFailsClosed() {
        let results = [candidate("VICOL WINTER OIL INSECTICIDE", registration: "33182")]
        let outcome = ChemicalSelectionPolicy.decide(results: results, ranking: nil)
        guard case .requiresChoice = outcome else {
            Issue.record("no verdict is not a positive verdict")
            return
        }
    }

    @Test("An empty answer is empty, not a choice")
    func emptyAnswer() {
        let outcome = ChemicalSelectionPolicy.decide(
            results: [],
            ranking: ranking(state: "no_official_match", autoSelect: false)
        )
        guard case .empty = outcome else {
            Issue.record("nothing to choose from")
            return
        }
    }

    @Test("A long ambiguous answer is trimmed to a decidable shortlist")
    func shortlistIsBounded() {
        let results = (1...12).map {
            candidate("WINTER OIL \($0)", registration: "\(10000 + $0)")
        }
        let outcome = ChemicalSelectionPolicy.decide(
            results: results,
            ranking: ranking(state: "ambiguous", autoSelect: false)
        )
        guard case .requiresChoice(let shown) = outcome else {
            Issue.record("expected a choice")
            return
        }
        #expect(shown.count == ChemicalSelectionPolicy.maxPresentedCandidates)
        // The SERVER's order survives the trim — the app takes the top of the
        // ranking, it does not pick favourites.
        #expect(shown.first?.registrationNumber == "10001")
    }

    // MARK: - Decoding the ranking block

    @Test("The ranking block decodes from the server's snake_case wire form")
    func rankingDecodes() throws {
        let json = """
        {
          "results": [],
          "ranking": {
            "search_state": "ambiguous",
            "auto_select_allowed": false,
            "exact_registration_number": null,
            "strong_candidate_count": 2,
            "strong_official_candidate_count": 2
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChemicalSearchResponse.self, from: json)
        #expect(decoded.ranking?.searchState == "ambiguous")
        #expect(decoded.ranking?.autoSelectAllowed == false)
        #expect(decoded.ranking?.strongCandidateCount == 2)
    }

    @Test("A malformed ranking block decodes to 'ask the operator'")
    func malformedRankingFailsClosed() throws {
        let json = """
        { "results": [], "ranking": { "auto_select_allowed": "yes please" } }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChemicalSearchResponse.self, from: json)
        #expect(decoded.ranking?.autoSelectAllowed == false)
    }

    @Test("A candidate row decodes its exact registration identity")
    func candidateIdentityDecodes() throws {
        let json = """
        {
          "results": [{
            "name": "VICOL WINTER OIL INSECTICIDE",
            "registration_number": "33182",
            "registration_scheme": "apvma",
            "registration_country": "AU",
            "registrant": "Victorian Chemical Company",
            "product_category": "Insecticide",
            "has_grapevine_use": true,
            "source": "official_register"
          }]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChemicalSearchResponse.self, from: json)
        let row = try #require(decoded.results.first)
        #expect(row.registrationNumber == "33182")
        #expect(row.registrationScheme == "apvma")
        #expect(row.countryCode == "AU")
        #expect(row.registrant == "Victorian Chemical Company")
        #expect(row.hasGrapevineUse == true)
    }

    // MARK: - The selection travels intact (Phase 9)

    @Test("A selected candidate's exact identity reaches the structured request")
    func selectionCarriesIdentity() {
        let selected = candidate("VICOL WINTER OIL INSECTICIDE", registration: "33182")
        let request = ChemicalStructuredLookupRequest(
            selected: selected,
            country: "AU",
            fallbackQuery: "Hortitrol winter oil"
        )

        #expect(request.registrationNumber == "33182")
        #expect(request.registrationScheme == "apvma")
        #expect(request.hasSelectedIdentity)
        // The typed phrase is DEAD as an identity. It survives nowhere in the
        // request that could be matched against a product name.
        #expect(request.productName == "VICOL WINTER OIL INSECTICIDE")
        #expect(request.productName != "Hortitrol winter oil")
    }

    @Test("A candidate with no registration makes no identity claim")
    func unregisteredSelectionMakesNoClaim() {
        let selected = candidate("SOME WINTER OIL", registration: nil, source: nil, scheme: nil)
        let request = ChemicalStructuredLookupRequest(selected: selected, country: "AU")
        #expect(request.registrationNumber == nil)
        #expect(request.registrationScheme == nil)
        #expect(!request.hasSelectedIdentity)
    }

    // MARK: - Candidate presentation

    @Test("A candidate row shows the facts a viticulturist decides on")
    func candidateSummaryShowsDecidableFacts() {
        let summary = ChemicalCandidateSummary(
            result: candidate(
                "VICOL WINTER OIL INSECTICIDE",
                registration: "33182",
                grapevine: true
            ),
            country: "AU"
        )
        #expect(summary.name == "VICOL WINTER OIL INSECTICIDE")
        #expect(summary.registrationLabel == "APVMA 33182")
        #expect(summary.registrant == "Victorian Chemical Company")
        #expect(summary.activeIngredient == "Petroleum Oil 861 g/L")
        #expect(summary.category == "Insecticide")
        #expect(summary.grapevineNote == "Grapevine uses found")
    }

    /// Unknown is not "no". A register discovery listing carries no use table.
    @Test("Unknown grapevine relevance is silent, never negative")
    func unknownGrapevineRelevanceIsSilent() {
        let unknown = ChemicalCandidateSummary(
            result: candidate("VICOL WINTER OIL INSECTICIDE", registration: "33182", grapevine: nil),
            country: "AU"
        )
        #expect(unknown.grapevineNote == nil)

        let checked = ChemicalCandidateSummary(
            result: candidate(
                "SYNERTROL HORTI BOTANICAL OIL CONCENTRATE",
                registration: "50067",
                category: "Adjuvant",
                grapevine: false
            ),
            country: "AU"
        )
        #expect(checked.grapevineNote == "No grapevine uses found")
    }

    // MARK: - F. WHP / REI must not default to zero

    /// Missing is not zero, and it is not blank either. A hidden row reads as
    /// "no restriction"; "Not stated" reads as "go and check the label".
    @Test("A missing withholding period renders as Not stated, never 0 days")
    func missingWhpIsNotStated() {
        let rendered = ChemicalWithholdingDisplay.display(
            days: nil,
            restrictions: nil,
            hasManufacturerLabelSource: false
        )
        #expect(rendered == "Not stated")
        #expect(rendered != "0 days")
    }

    @Test("An explicit zero withholding period is still zero")
    func explicitZeroWhpSurvives() {
        let plain = ChemicalWithholdingDisplay.display(
            days: 0,
            restrictions: nil,
            hasManufacturerLabelSource: false
        )
        #expect(plain == "0 days")

        // With label evidence behind it, the label's own wording is used.
        let labelBacked = ChemicalWithholdingDisplay.display(
            days: 0,
            restrictions: nil,
            hasManufacturerLabelSource: true
        )
        #expect(labelBacked == "Not required when used as directed")
    }

    @Test("Decoding a use with absent WHP/REI keeps them nil")
    func decodingKeepsPeriodsNil() throws {
        let json = """
        {
          "crop": "GRAPEVINE",
          "target_raw": "GRAPEVINE SCALE",
          "rates": [
            { "value": 2, "unit": "L", "basis": "per_100_litres" },
            { "value": 3, "unit": "L", "basis": "per_100_litres" }
          ]
        }
        """.data(using: .utf8)!

        let use = try JSONDecoder().decode(ChemicalRegisteredUse.self, from: json)
        #expect(use.withholdingPeriodDays == nil)
        #expect(use.reEntryPeriodHours == nil)
        #expect(use.withholdingPeriodDays != 0)
        #expect(use.reEntryPeriodHours != 0)
        // Two rates stayed two rates, in the label's own basis.
        #expect(use.rates.count == 2)
        #expect(use.rates.allSatisfy { $0.basis == .per100Litres })
    }

    @Test("Re-entry keeps its three distinct answers")
    func reEntryHasThreeStates() {
        let stated = ChemicalRegisteredUse(
            crop: "GRAPEVINE",
            targetRaw: "SCALE",
            reEntryPeriodHours: 12
        )
        #expect(stated.reEntryDisplay.summary == "12 hours")
        #expect(stated.reEntryDisplay.isStated)

        // A binding rule with no number in it. Not "not stated".
        let conditional = ChemicalRegisteredUse(
            crop: "GRAPEVINE",
            targetRaw: "SCALE",
            reEntryStatement: "DO NOT allow entry until the spray has dried"
        )
        #expect(conditional.reEntryPeriodHours == nil)
        #expect(conditional.reEntryDisplay.isStated)
        #expect(conditional.reEntryDisplay.summary == "DO NOT allow entry until the spray has dried")

        let silent = ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "SCALE")
        #expect(!silent.reEntryDisplay.isStated)
        #expect(silent.reEntryDisplay.summary == "Not stated on label")
    }
}

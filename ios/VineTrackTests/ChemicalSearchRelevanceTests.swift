import Foundation
import Testing
@testable import VineTrack

/// Search must answer the question the operator asked.
///
/// Two device failures motivate this suite, and they are opposite faults of the
/// same missing rule:
///
/// - `Chateau` — a real Sumitomo herbicide, APVMA 80647 — could not be found at
///   all.
/// - `Switch` returned SWITCH FUNGICIDE and, beside it as an equal candidate,
///   MORTEIN PEACEFUL NIGHTS MOSQUITO & FLY CONTROL WITH AUTO SWITCH OFF
///   TECHNOLOGY.
///
/// The national register is a legal list. It contains household insecticides
/// and veterinary medicines, and its full-text search matches whole words in
/// any column, so returning the Mortein row is not a register defect. Ranking
/// it level with an exact product-name hit is a VineTrack defect.
///
/// Nothing here classifies products. A rule that decided which chemicals were
/// "agricultural enough" would bury exactly the regional adjuvants,
/// biostimulants and fertilisers a vineyard buys, so this is name relevance
/// only, and it demotes rather than deletes.
struct ChemicalSearchRelevanceTests {

    private func registerRow(_ name: String, brand: String = "Registrant") -> ChemicalSearchResult {
        ChemicalSearchResult(
            name: name,
            brand: brand,
            registrationNumber: "80647",
            source: ChemicalSearchResult.officialRegisterSource
        )
    }

    // MARK: - 8. Chateau

    @Test("'Chateau' surfaces CHATEAU HERBICIDE as the leading candidate")
    func chateauIsFound() {
        let ordered = ChemicalSearchRanking.ordered(
            results: [
                registerRow("PENDIMETHALIN 440 HERBICIDE"),
                registerRow("CHATEAU HERBICIDE", brand: "Sumitomo Chemical Australia")
            ],
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Chateau"
        )
        #expect(ordered.first?.result.name == "CHATEAU HERBICIDE")
        #expect(ordered.first?.relevance == .leadingProductName)
    }

    /// The operator types the product the way it is written on the drum.
    @Test("'Chateau Herbicide' matches the registered name exactly")
    func chateauHerbicideIsExact() {
        let ordered = ChemicalSearchRanking.ordered(
            results: [registerRow("CHATEAU HERBICIDE")],
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Chateau Herbicide"
        )
        #expect(ordered.first?.relevance == .exactName)
    }

    /// Registers shout. Operators do not.
    @Test("'chateau' in lower case is the same query")
    func chateauIsCaseInsensitive() {
        let ordered = ChemicalSearchRanking.ordered(
            results: [registerRow("CHATEAU HERBICIDE")],
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "chateau"
        )
        #expect(ordered.first?.relevance == .leadingProductName)
        #expect(ordered.first?.tier == .officialRegister)
    }

    // MARK: - 9, 10. Switch vs Mortein

    private var switchResults: [ChemicalSearchResult] {
        [
            registerRow(
                "MORTEIN PEACEFUL NIGHTS MOSQUITO & FLY CONTROL WITH AUTO SWITCH OFF TECHNOLOGY",
                brand: "AU Pest Pty Limited"
            ),
            registerRow("SWITCH FUNGICIDE", brand: "Syngenta Australia Pty Ltd")
        ]
    }

    @Test("SWITCH FUNGICIDE ranks above an incidental 'switch off' product")
    func switchFungicideRanksFirst() {
        let ordered = ChemicalSearchRanking.ordered(
            results: switchResults,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Switch"
        )
        #expect(ordered.first?.result.name == "SWITCH FUNGICIDE")
        #expect(ordered.first?.relevance == .leadingProductName)
    }

    /// The register put Mortein FIRST in this fixture on purpose: relevance has
    /// to beat arrival order, not merely agree with it.
    @Test("An incidental word match is demoted out of the primary results")
    func incidentalMatchIsDemoted() {
        let ordered = ChemicalSearchRanking.ordered(
            results: switchResults,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Switch"
        )
        let mortein = ordered.first { $0.result.name.hasPrefix("MORTEIN") }
        #expect(mortein?.relevance == .incidental)
        #expect(mortein?.tier == .weakMatch)
        #expect(ordered.last?.tier == .weakMatch)
    }

    /// Demotion is presentation, never deletion. The register row is still
    /// selectable — under a heading that says what it is.
    @Test("A demoted row is still present and still shown")
    func demotedRowIsNotRemoved() {
        let ordered = ChemicalSearchRanking.ordered(
            results: switchResults,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Switch"
        )
        #expect(ordered.count == 2)
        #expect(ChemicalSearchTier.weakMatch.label == "Other register matches")
    }

    /// The safety valve. With nothing strong on screen the operator's only lead
    /// may be the weak one, and burying it would show an empty result list for
    /// a product that IS in the register.
    @Test("With no strong candidate, weak matches stay in the primary results")
    func weakMatchesSurviveWhenNothingIsStrong() {
        let ordered = ChemicalSearchRanking.ordered(
            results: [registerRow("MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY")],
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Switch"
        )
        #expect(ordered.first?.tier == .officialRegister)
        #expect(ordered.first?.relevance == .incidental)
    }

    // MARK: - Niche products must not be collateral damage

    /// This is the rule that stops relevance turning into a "mainstream
    /// chemicals only" filter. An operator searching a chemistry word wants the
    /// products that contain it.
    @Test("A chemistry word match is strong enough to stay in the primary list")
    func chemistryWordMatchStaysPrimary() {
        let ordered = ChemicalSearchRanking.ordered(
            results: [
                registerRow("TRI-BASE BLUE COPPER FUNGICIDE"),
                registerRow("COPPER OXYCHLORIDE FUNGICIDE")
            ],
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Copper"
        )
        #expect(ordered.allSatisfy { $0.tier == .officialRegister })
        #expect(ordered.first?.result.name == "COPPER OXYCHLORIDE FUNGICIDE")
        #expect(ordered.last?.relevance == .containedPhrase)
    }

    /// A vineyard's own record and the approved catalogue are provenance, not
    /// relevance. They are never demoted by a name rule.
    @Test("A stocked product is never demoted by name relevance")
    func inStoreIsNeverDemoted() {
        let scored = ChemicalNameRelevanceScorer.score(
            query: "Switch",
            name: "MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY"
        )
        #expect(scored == .incidental)
        #expect(!scored.isStrong)
        #expect(ChemicalNameRelevance.exactName.isStrong)
        #expect(ChemicalNameRelevance.containedPhrase.isStrong)
        #expect(!ChemicalNameRelevance.unrelated.isStrong)
    }

    /// A query that matched on the holder or the active ingredient, never on
    /// the name, is the weakest thing search can return.
    @Test("A row matched on something other than its name scores unrelated")
    func nonNameMatchIsUnrelated() {
        #expect(
            ChemicalNameRelevanceScorer.score(query: "Syngenta", name: "SWITCH FUNGICIDE")
                == .unrelated
        )
    }

    /// Ordering must be stable when relevance ties, so the register's own
    /// ranking survives.
    @Test("Equal relevance preserves the server's order")
    func equalRelevanceKeepsServerOrder() {
        let ordered = ChemicalSearchRanking.ordered(
            results: [registerRow("COPPER A"), registerRow("COPPER B")],
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Copper"
        )
        #expect(ordered.map(\.result.name) == ["COPPER A", "COPPER B"])
    }
}

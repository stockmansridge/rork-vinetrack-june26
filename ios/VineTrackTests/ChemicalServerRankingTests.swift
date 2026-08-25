import Foundation
import Testing

@testable import VineTrack

/// Task §1 — ranking is server-authoritative.
///
/// The Hortitrol split ("Portal resolves to APVMA 50067, iOS resolves to
/// 33182") had one structural cause: iOS re-scored and re-sorted whatever the
/// server sent, Android did not sort at all, and the Portal did something
/// third. Three clients asking one server the same question therefore got
/// three different answers.
///
/// These tests pin the fix: when the server ranked, iOS shows THAT order,
/// unchanged. The on-device scorer survives only as a deployment shim for a
/// server that has not been updated yet.
struct ChemicalServerRankingTests {

    private func ranked(
        _ name: String,
        registration: String,
        tier: String,
        relevance: String,
        score: Double,
        order: Int
    ) -> ChemicalSearchResult {
        ChemicalSearchResult(
            name: name,
            registrationNumber: registration,
            source: ChemicalSearchResult.officialRegisterSource,
            rankTier: tier,
            rankRelevance: relevance,
            rankScore: score,
            rankReason: "\(relevance)/\(tier)",
            registerOrder: order
        )
    }

    private func unranked(_ name: String, registration: String = "1") -> ChemicalSearchResult {
        ChemicalSearchResult(
            name: name,
            registrationNumber: registration,
            source: ChemicalSearchResult.officialRegisterSource
        )
    }

    /// The reproduction, as the ranked server serves it.
    private var hortitrol: [ChemicalSearchResult] {
        [
            ranked(
                "HORTITROL WINTER OIL", registration: "50067",
                tier: "official_register", relevance: "exact_name",
                score: 100, order: 2
            ),
            ranked(
                "SUMMER AND WINTER SPRAYING OIL", registration: "33182",
                tier: "weak_match", relevance: "unrelated",
                score: 0, order: 0
            ),
            ranked(
                "WHITE OIL INSECTICIDE", registration: "12345",
                tier: "weak_match", relevance: "unrelated",
                score: 0, order: 1
            )
        ]
    }

    // MARK: - Served order wins

    @Test("The served order is displayed exactly, never re-sorted")
    func servedOrderIsPreserved() {
        let rows = ChemicalSearchRanking.ordered(
            results: hortitrol,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Hortitrol winter oil"
        )
        #expect(rows.map(\.result.registrationNumber) == ["50067", "33182", "12345"])
    }

    /// The register returned the noise FIRST. If iOS re-derived the order from
    /// its own scorer this would still pass, so the decisive test is the next
    /// one: an order the client would NOT have chosen.
    @Test("An order the client disagrees with is still honoured")
    func serverOrderBeatsClientOpinion() {
        // Server says the weak row leads. The client's own scorer would put
        // the exact name first. The server wins — that is the whole point.
        let contrarian = [
            ranked(
                "SUMMER AND WINTER SPRAYING OIL", registration: "33182",
                tier: "official_register", relevance: "unrelated",
                score: 10, order: 0
            ),
            ranked(
                "HORTITROL WINTER OIL", registration: "50067",
                tier: "official_register", relevance: "exact_name",
                score: 100, order: 1
            )
        ]
        let rows = ChemicalSearchRanking.ordered(
            results: contrarian,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Hortitrol winter oil"
        )
        #expect(rows.map(\.result.registrationNumber) == ["33182", "50067"])
    }

    @Test("Server tiers map onto the display tiers")
    func serverTiersMap() {
        let rows = ChemicalSearchRanking.ordered(
            results: hortitrol,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Hortitrol winter oil"
        )
        #expect(rows[0].tier == .officialRegister)
        #expect(rows[0].relevance == .exactName)
        #expect(rows[1].tier == .weakMatch)
        #expect(ChemicalSearchRanking.tier(fromServer: "approved_master") == .approvedMaster)
        #expect(ChemicalSearchRanking.tier(fromServer: "suggestion") == .suggestion)
        // An unknown tier from a newer server degrades to the weakest claim
        // rather than being promoted.
        #expect(ChemicalSearchRanking.tier(fromServer: "something_new") == .suggestion)
        #expect(ChemicalSearchRanking.relevance(fromServer: "nonsense") == .unrelated)
    }

    @Test("Nothing is dropped from the served list")
    func nothingIsDropped() {
        let rows = ChemicalSearchRanking.ordered(
            results: hortitrol,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Hortitrol winter oil"
        )
        #expect(rows.count == 3)
    }

    // MARK: - Duplicate annotation must not reorder

    @Test("A stocked product is flagged in place, not floated to the top")
    func duplicateDoesNotReorder() {
        // The old client floated "already in your store" to position one. That
        // is a LOCAL reorder of a server-owned list: two vineyards would see
        // the same search in two different orders. It is now an annotation.
        var stocked = SavedChemical(name: "WHITE OIL INSECTICIDE")
        stocked.name = "WHITE OIL INSECTICIDE"

        let rows = ChemicalSearchRanking.ordered(
            results: hortitrol,
            savedChemicals: [stocked],
            vineyardCountry: "AU",
            query: "Hortitrol winter oil"
        )
        #expect(rows.map(\.result.registrationNumber) == ["50067", "33182", "12345"])
        // Still discoverable as a duplicate, just where the server put it.
        #expect(rows[2].isDuplicate)
        #expect(rows[0].isDuplicate == false)
    }

    // MARK: - Transition shim

    @Test("An unranked server still gets the on-device protection")
    func legacyFallbackStillProtects() {
        // Between an App Store release and the function deploy, the server
        // sends no ranking. Falling back to raw register order would put
        // MORTEIN above SWITCH FUNGICIDE.
        let rows = ChemicalSearchRanking.ordered(
            results: [
                unranked("MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY", registration: "1"),
                unranked("SWITCH FUNGICIDE", registration: "2")
            ],
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Switch"
        )
        #expect(rows.first?.result.name == "SWITCH FUNGICIDE")
        #expect(rows.last?.tier == .weakMatch)
    }

    @Test("One ranked row is enough to trust the whole served list")
    func partialRankingUsesServedOrder() {
        // A mixed list means the server ranked and simply had nothing to say
        // about one row. Re-running the client scorer over the whole list
        // would silently override the server on the rows it DID rank.
        let mixed = [
            ranked(
                "SUMMER AND WINTER SPRAYING OIL", registration: "33182",
                tier: "official_register", relevance: "unrelated",
                score: 10, order: 0
            ),
            unranked("HORTITROL WINTER OIL", registration: "50067")
        ]
        let rows = ChemicalSearchRanking.ordered(
            results: mixed,
            savedChemicals: [],
            vineyardCountry: "AU",
            query: "Hortitrol winter oil"
        )
        #expect(rows.map(\.result.registrationNumber) == ["33182", "50067"])
    }

    @Test("isServerRanked keys off the reason the server always sets")
    func serverRankedDetection() {
        #expect(hortitrol[0].isServerRanked)
        #expect(unranked("X").isServerRanked == false)
        // Whitespace is not a ranking.
        let blank = ChemicalSearchResult(name: "X", rankReason: "   ")
        #expect(blank.isServerRanked == false)
    }

    // MARK: - Scorer defect repair

    /// The scorer's headline protection never actually fired: `containsRun`
    /// returned `.containedPhrase` for any contiguous run, and
    /// `.containedPhrase` is strong, so the Mortein row was never demoted —
    /// even though two existing tests asserted it should be.
    @Test("An incidental word buried mid-name scores incidental, not contained")
    func mortenIsIncidental() {
        let scored = ChemicalNameRelevanceScorer.score(
            query: "Switch",
            name: "MORTEIN PEACEFUL NIGHTS WITH AUTO SWITCH OFF TECHNOLOGY"
        )
        #expect(scored == .incidental)
        #expect(!scored.isStrong)
    }

    /// The other half of the same rule, which must NOT regress: a chemistry
    /// word followed only by a formulation word is genuinely descriptive.
    @Test("A chemistry word before a formulation word stays a contained phrase")
    func copperStaysContained() {
        let scored = ChemicalNameRelevanceScorer.score(
            query: "Copper",
            name: "TRI-BASE BLUE COPPER FUNGICIDE"
        )
        #expect(scored == .containedPhrase)
        #expect(scored.isStrong)
    }

    @Test("The device scorer agrees with the server on the measured cases")
    func deviceMatchesServer() {
        // Both implementations must give the same verdict, or the fallback
        // would order differently from the server it stands in for.
        #expect(
            ChemicalNameRelevanceScorer.score(query: "Chateau", name: "CHATEAU HERBICIDE")
                == .leadingProductName
        )
        #expect(
            ChemicalNameRelevanceScorer.score(query: "Kocide", name: "KOCIDE BLUE XTRA")
                == .leadingToken
        )
        #expect(
            ChemicalNameRelevanceScorer.score(
                query: "Hortitrol winter oil", name: "HORTITROL WINTER OIL"
            ) == .exactName
        )
        #expect(
            ChemicalNameRelevanceScorer.score(
                query: "Hortitrol winter oil", name: "SUMMER AND WINTER SPRAYING OIL"
            ) == .unrelated
        )
    }
}

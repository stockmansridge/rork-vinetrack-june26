import Foundation
import Observation

/// DEBUG-only lifecycle trace for the product lookup.
///
/// Rotation, screenshots and scene changes are exactly the events that are
/// impossible to reason about from a crash-free black box: nothing fails, the
/// work simply stops. This records WHEN the view appeared, disappeared, or was
/// asked to cancel, so a device reproduction says which event killed a lookup
/// instead of leaving it to inference.
///
/// Never compiled into a release build, and deliberately carries no chemistry,
/// no query text and no user data — only lifecycle verbs.
nonisolated enum ChemicalLookupTrace {
    static func log(_ event: String, _ detail: String = "") {
        #if DEBUG
        let suffix = detail.isEmpty ? "" : " \(detail)"
        print("[ChemicalLookup] \(event)\(suffix)")
        #endif
    }
}

/// Why a lookup session was torn down. Only these three reasons may cancel
/// in-flight work.
nonisolated enum ChemicalLookupCancellation: String, Sendable {
    /// The operator pressed Cancel, or genuinely dismissed the presentation.
    case operatorDismissed
    /// A new search was started, superseding the previous one.
    case superseded
    /// The owning presentation was destroyed for good.
    case presentationEnded
}

/// Owns a product-lookup session for as long as the PRESENTATION lives.
///
/// # Why this is not `@State` inside the search view
///
/// The search screen used to own `searchTask` and `resolveTask` as `@State`
/// and cancel both from `.onDisappear`. On a real phone that hook does not
/// mean "the operator left". It fires when the device rotates, when the sheet
/// is re-laid-out behind a system snapshot (which is what a screenshot takes),
/// and whenever SwiftUI decides to reconstruct the subtree. A 180 s structured
/// resolve was therefore being cancelled by turning the phone sideways, and
/// the resolved draft — held as `@State` in the flow view that the same
/// reconstruction rebuilt — could be dropped, returning a fully populated
/// Review Chemical to Add Chemical.
///
/// A SwiftUI view body is a description that the framework may throw away and
/// rebuild at will. Network work and a half-finished record are not
/// descriptions, so they do not belong there. This object is created once by
/// the presenting view and held in `@State`, which SwiftUI keeps alive across
/// every reconstruction of the views below it. Cancellation becomes something
/// a person does, not something a layout pass does.
@MainActor
@Observable
final class ChemicalLookupCoordinator {

    // MARK: - Session state

    var query: String = ""
    private(set) var rows: [ChemicalSearchRow] = []
    /// The server's verdict on the last search. Nil before any search, and on
    /// servers that predate the ranking block.
    private(set) var ranking: ChemicalSearchRankingSummary?
    /// True when identity is NOT settled and the operator must choose.
    ///
    /// iOS has always shown a list rather than auto-applying a row, so this
    /// does not gate the picker's existence -- it gates what the picker SAYS.
    /// An operator being asked to choose deserves to know they are choosing,
    /// rather than assuming the top row is the answer.
    private(set) var requiresOperatorChoice: Bool = false
    private(set) var isSearching: Bool = false
    private(set) var isResolving: Bool = false
    private(set) var searchError: String?

    /// The row whose RESOLUTION failed, kept so the operator can retry it or
    /// deliberately go on with only what the search row carried.
    private(set) var unresolvedRow: ChemicalSearchRow?

    /// The reviewed, unsaved draft.
    ///
    /// Lives HERE rather than in the flow view's `@State` because it is the
    /// result of work, not a piece of layout. Once set it survives every
    /// rotation, screenshot and rebuild until someone explicitly finishes or
    /// abandons the review.
    var reviewDraft: SavedChemical?

    /// The operator asked for the blank manual form instead.
    var showManualEntry: Bool = false

    /// A record the operator already owns, opened INSTEAD of researching.
    ///
    /// Set by the pre-research same-name decision (item 5). Deliberately
    /// distinct from `reviewDraft`: that is an unsaved draft to create, this
    /// is an existing row to edit in place, so Save must take the update path
    /// rather than writing a second copy of a product already in the store.
    var existingToReview: SavedChemical?

    /// Same-name records found in the operator's OWN store, offline.
    ///
    /// Non-empty means the decision is on screen and NOTHING has been looked
    /// up: this list is produced by reading `savedChemicals`, never by asking
    /// the server.
    var sameNameMatches: [SavedChemical] = []

    /// Set once the operator has deliberately answered the same-name
    /// question, so it is asked once per typed name rather than on every tap.
    var duplicateDecision: ChemicalStoreMatching.Decision?

    private var hasSeededQuery: Bool = false
    private var searchTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?

    init() {}

    // MARK: - Derived

    var hasInFlightWork: Bool { isSearching || isResolving }

    /// True when a review session is open and owns the screen.
    var isReviewing: Bool {
        reviewDraft != nil || showManualEntry || existingToReview != nil
    }

    /// True while the pre-research same-name decision is awaiting an answer.
    var isAwaitingDuplicateDecision: Bool { !sameNameMatches.isEmpty }

    // MARK: - Lifecycle

    /// Seeds the search box ONCE per session. Re-seeding on a second
    /// `onAppear` would throw away whatever the operator had retyped.
    func seedQueryIfNeeded(_ initial: String) {
        guard !hasSeededQuery else { return }
        hasSeededQuery = true
        if query.isEmpty { query = initial }
    }

    /// The ONLY way in-flight work is cancelled.
    func cancel(_ reason: ChemicalLookupCancellation) {
        ChemicalLookupTrace.log("cancel", reason.rawValue)
        searchTask?.cancel()
        resolveTask?.cancel()
        searchTask = nil
        resolveTask = nil
        isSearching = false
        isResolving = false
    }

    /// Ends the review session. Called only from Save or an explicit Cancel.
    func finishReview() {
        ChemicalLookupTrace.log("review_finished")
        reviewDraft = nil
        showManualEntry = false
        existingToReview = nil
    }

    // MARK: - Pre-research duplicate decision (item 5)

    /// The ONLY route to a remote search.
    ///
    /// The operator's own Chemical Store is consulted FIRST, offline, and a
    /// same-name record stops the flow before a single request is issued.
    /// Returns `false` when the decision is now on screen and no lookup ran.
    ///
    /// Declining costs exactly nothing: no lookup, no write.
    @discardableResult
    func startSearchUnlessDuplicate(
        country: String,
        savedChemicals: [SavedChemical],
        existing: SavedChemical?
    ) -> Bool {
        if duplicateDecision == nil {
            let matches = ChemicalStoreMatching.findByProductName(
                in: savedChemicals,
                query: query,
                // A legacy record being re-matched is not a duplicate of itself.
                excludingId: existing?.id
            )
            if !matches.isEmpty {
                ChemicalLookupTrace.log("duplicate_decision_shown", "matches=\(matches.count)")
                sameNameMatches = matches
                return false
            }
        }
        startSearch(country: country, savedChemicals: savedChemicals)
        return true
    }

    /// "Review / re-verify the one I already have." Researches nothing.
    func reviewExisting(_ chemical: SavedChemical) {
        ChemicalLookupTrace.log("duplicate_decision", "review_existing")
        duplicateDecision = .reviewExisting(chemical.id)
        sameNameMatches = []
        existingToReview = chemical
    }

    /// "This is a different product." Only now may the register be searched.
    func createSeparate(country: String, savedChemicals: [SavedChemical]) {
        ChemicalLookupTrace.log("duplicate_decision", "create_separate")
        duplicateDecision = .createSeparate
        sameNameMatches = []
        startSearch(country: country, savedChemicals: savedChemicals)
    }

    /// Backed out. Zero research calls, zero writes; the typed query survives.
    func cancelDuplicateDecision() {
        ChemicalLookupTrace.log("duplicate_decision", "cancelled")
        duplicateDecision = nil
        sameNameMatches = []
    }

    /// A retyped name is a new question, so a previous "different product"
    /// answer must not carry over and suppress the check for the new name.
    func queryChanged() {
        duplicateDecision = nil
        sameNameMatches = []
    }

    // MARK: - Search

    func startSearch(country: String, savedChemicals: [SavedChemical]) {
        // A new search supersedes the previous one — and ONLY the previous one.
        searchTask?.cancel()
        ChemicalLookupTrace.log("search_started")
        searchTask = Task { [weak self] in
            await self?.runSearch(country: country, savedChemicals: savedChemicals)
        }
    }

    private func runSearch(country: String, savedChemicals: [SavedChemical]) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        unresolvedRow = nil
        ranking = nil
        requiresOperatorChoice = false
        defer { isSearching = false }
        do {
            let response = try await ChemicalInfoService()
                .searchResponse(query: trimmed, country: country)
            try Task.checkCancellation()
            ranking = response.ranking

            // The SERVER decides whether identity is settled. The app reads
            // that decision; it does not re-derive one from the row count,
            // which cannot tell certainty apart from starvation.
            switch ChemicalSelectionPolicy.decide(
                results: response.results,
                ranking: response.ranking
            ) {
            case .autoSelect:
                requiresOperatorChoice = false
            case .requiresChoice, .empty:
                requiresOperatorChoice = true
            }

            rows = ChemicalSearchRanking.ordered(
                results: response.results,
                savedChemicals: savedChemicals,
                vineyardCountry: country,
                query: trimmed
            )
            ChemicalLookupTrace.log(
                "search_finished",
                "rows=\(rows.count) state=\(response.ranking?.searchState ?? "-")"
            )
            if rows.isEmpty {
                searchError = "No products found. Try a different spelling, or enter the product manually."
            }
        } catch is CancellationError {
            ChemicalLookupTrace.log("search_cancelled")
            return
        } catch {
            // The typed query is deliberately left intact so a failed lookup
            // never costs the operator their input.
            rows = []
            ranking = nil
            requiresOperatorChoice = false
            searchError = (error as? LocalizedError)?.errorDescription
                ?? "Lookup is unavailable. Check your connection and try again."
            ChemicalLookupTrace.log("search_failed")
        }
    }

    // MARK: - Resolve

    func startSelect(
        _ row: ChemicalSearchRow,
        country: String,
        existing: SavedChemical?,
        vineyardId: UUID
    ) {
        resolveTask?.cancel()
        ChemicalLookupTrace.log("resolve_started")
        resolveTask = Task { [weak self] in
            await self?.resolve(row, country: country, existing: existing, vineyardId: vineyardId)
        }
    }

    /// Resolve the selected product and hand back the merged draft.
    ///
    /// A failed resolution is NOT a product with an empty label: the fallback
    /// still exists so an operator with no connection can record the drum in
    /// their hand, but it is a decision they take with the consequence stated.
    private func resolve(
        _ row: ChemicalSearchRow,
        country: String,
        existing: SavedChemical?,
        vineyardId: UUID
    ) async {
        isResolving = true
        searchError = nil
        unresolvedRow = nil
        defer { isResolving = false }

        let lookup: ChemicalStructuredLookup
        do {
            lookup = try await ChemicalInfoService().lookupStructured(
                ChemicalStructuredLookupRequest(
                    selected: row.result,
                    country: country,
                    fallbackQuery: query
                )
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            ChemicalLookupTrace.log("resolve_cancelled")
            return
        } catch {
            unresolvedRow = row
            searchError = (error as? LocalizedError)?.errorDescription
                ?? "Could not load this product's registered details. Check your connection and try again."
            ChemicalLookupTrace.log("resolve_failed")
            return
        }

        // Jurisdiction rejection stays absolute: another country's rates, WHP
        // and re-entry statements are another country's law.
        if let reason = ChemicalJurisdiction.rejectionReason(for: lookup, requestCountry: country) {
            searchError = reason
            ChemicalLookupTrace.log("resolve_rejected_jurisdiction")
            return
        }

        handOff(row, lookup: lookup, country: country, existing: existing, vineyardId: vineyardId)
    }

    /// The ONE projection from a selected row into the reviewable draft.
    func handOff(
        _ row: ChemicalSearchRow,
        lookup: ChemicalStructuredLookup?,
        country: String,
        existing: SavedChemical?,
        vineyardId: UUID
    ) {
        ChemicalLookupTrace.log("handoff_executed", lookup == nil ? "degraded" : "resolved")
        reviewDraft = ChemicalReviewMerge.reviewChemical(
            lookup: lookup,
            selected: row.result,
            existing: existing ?? row.existing,
            countryCode: country,
            vineyardId: vineyardId
        )
    }

    /// Continue with only what the search row carried.
    func continueWithoutRegisterDetails(
        country: String,
        existing: SavedChemical?,
        vineyardId: UUID
    ) {
        guard let row = unresolvedRow else { return }
        handOff(row, lookup: nil, country: country, existing: existing, vineyardId: vineyardId)
    }
}

import Foundation

/// The status of one planned position, derived entirely from engine output.
///
/// There is deliberately no numeric score. "Reaches strategy limit" and "would exceed
/// strategy" are different decisions for an operator standing at a shed door, and a
/// shared number like "risk 73" would collapse them into something nobody can act on
/// or argue with.
nonisolated enum ResistancePlanPositionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Permitted, with headroom left, from dependable evidence.
    case goodFit = "good_fit"
    /// Permitted, but lands exactly on a published maximum.
    case reachesStrategyLimit = "reaches_strategy_limit"
    /// Goes past a published maximum.
    case wouldExceedStrategy = "would_exceed_strategy"
    /// Permitted arithmetically, but something needs an operator's eye: an
    /// unconfirmable mixture, an unverified product, published guidance.
    case needsReview = "needs_review"
    /// The engine cannot reach a conclusion, because the history it would have to
    /// count is incomplete or disputed.
    case unableToFullyAssess = "unable_to_fully_assess"

    nonisolated var label: String {
        switch self {
        case .goodFit: return "Good fit"
        case .reachesStrategyLimit: return "Reaches strategy limit"
        case .wouldExceedStrategy: return "Would exceed strategy"
        case .needsReview: return "Needs review"
        case .unableToFullyAssess: return "Unable to fully assess"
        }
    }

    /// Worst-first ranking for multi-block aggregation.
    ///
    /// `unableToFullyAssess` outranks `reachesStrategyLimit` on purpose. "Reaches the
    /// limit" reads as a definite, understood position; "unable to assess" means the
    /// true answer might be worse than anything shown. Presenting the softer of the
    /// two would hide the uncertainty behind a number that looks settled.
    nonisolated var rank: Int {
        switch self {
        case .wouldExceedStrategy: return 5
        case .unableToFullyAssess: return 4
        case .reachesStrategyLimit: return 3
        case .needsReview: return 2
        case .goodFit: return 1
        }
    }

    nonisolated static func worst(_ statuses: [ResistancePlanPositionStatus]) -> ResistancePlanPositionStatus {
        statuses.max { $0.rank < $1.rank } ?? .needsReview
    }
}

/// A specific, nameable gap in a block's recorded history.
nonisolated enum ResistanceHistoryConcern: String, Codable, Sendable, Hashable, CaseIterable {
    case unverifiedChemistry = "unverified_chemistry"
    case unavailableChemistry = "unavailable_chemistry"
    case conflictingChemistry = "conflicting_chemistry"
    case unresolvedBlockAttribution = "unresolved_block_attribution"
    case unknownTargets = "unknown_targets"

    nonisolated var label: String {
        switch self {
        case .unverifiedChemistry: return "Contains unverified chemistry"
        case .unavailableChemistry: return "Contains unavailable chemistry"
        case .conflictingChemistry: return "Contains conflicting chemistry"
        case .unresolvedBlockAttribution: return "Historical block attribution incomplete"
        case .unknownTargets: return "Contains sprays with unknown disease targets"
        }
    }
}

/// Whether a block's season history can carry a confident assessment, and if not, why.
nonisolated struct ResistanceBlockHistoryCheck: Codable, Sendable, Hashable {
    nonisolated var blockId: String
    /// Completed applications for this block, this season, targeting the planned
    /// disease.
    nonisolated var relevantApplicationCount: Int
    nonisolated var concerns: [ResistanceHistoryConcern]
    nonisolated var unverifiedCount: Int
    nonisolated var unavailableCount: Int
    nonisolated var conflictingCount: Int
    nonisolated var unknownTargetCount: Int
    /// Vineyard-wide applications that could concern this disease but cannot be placed
    /// on any block.
    ///
    /// The SAME count appears on every selected block, and that is not a bug. An
    /// unattributed spray happened somewhere in this vineyard; nothing establishes
    /// which block, so it is a live possibility for all of them. Attaching it to one
    /// block would invent the very attribution the record is missing.
    nonisolated var unresolvedVineyardApplicationCount: Int

    nonisolated var isCompleteEnoughToAssess: Bool { concerns.isEmpty }

    nonisolated var hasSeasonHistory: Bool { relevantApplicationCount > 0 }

    /// Operator-facing headline for this block's history state.
    nonisolated func headline(disease: ResistanceDisease) -> String {
        if !concerns.isEmpty { return concerns[0].label }
        if relevantApplicationCount == 0 {
            return "No recorded \(disease.label) sprays this season"
        }
        return "Current-season history available"
    }
}

/// One completed application on a block's season timeline.
nonisolated struct ResistancePlanTimelineEntry: Codable, Sendable, Hashable, Identifiable {
    nonisolated var applicationId: String
    nonisolated var appliedAtEpochMs: Int64
    /// FRAC identity — the primary resistance concept. Product names are secondary.
    nonisolated var groupsLabel: String
    nonisolated var productNames: [String]
    nonisolated var availability: ChemicalIntelligenceAvailability
    nonisolated var targetsRecorded: Bool

    nonisolated var id: String { applicationId }
}

/// A block's completed season history for the planned disease.
nonisolated struct ResistancePlanBlockTimeline: Codable, Sendable, Hashable {
    nonisolated var blockId: String
    nonisolated var entries: [ResistancePlanTimelineEntry]
}

/// Resistance-oriented season totals for one block.
///
/// Counted from resistance application EVENTS — one application is one event per
/// block, so a three-product tank counts once. Counting tank lines would inflate every
/// total and make the percentage rules meaningless.
nonisolated struct ResistanceBlockSeasonTotals: Codable, Sendable, Hashable {
    nonisolated var blockId: String
    nonisolated var diseaseSprayCount: Int
    /// Group code -> number of applications containing it, this block, this season.
    nonisolated var applicationsByGroup: [String: Int]

    /// Groups in canonical display order.
    nonisolated var orderedGroups: [String] {
        applicationsByGroup.keys.sorted(by: ResistanceGroupCode.isOrderedBefore)
    }
}

/// One block's answer for one planned position.
nonisolated struct ResistancePlanBlockOutcome: Sendable, Hashable {
    nonisolated var blockId: String
    nonisolated var status: ResistancePlanPositionStatus
    /// The full explainable engine result, carried through untouched so the UI can
    /// show observed count, threshold, contributing dates and published source.
    nonisolated var evaluation: ResistanceEvaluation
}

/// The evaluation of one planned position across every selected block.
nonisolated struct ResistancePlanPositionEvaluation: Sendable, Hashable {
    nonisolated var positionId: String
    /// Zero-based index in the plan.
    nonisolated var index: Int
    /// Display ordinal continuing the season's completed sprays, e.g. `4`.
    nonisolated var displayOrdinal: Int
    /// Worst state across all selected blocks.
    nonisolated var status: ResistancePlanPositionStatus
    nonisolated var blocks: [ResistancePlanBlockOutcome]
    /// Set when the position has no chemistry chosen yet.
    nonisolated var awaitingChemistry: Bool

    /// True when the blocks do not all agree — the case that must stay expandable
    /// rather than being averaged away.
    nonisolated var blocksDisagree: Bool {
        Set(blocks.map(\.status)).count > 1
    }

    nonisolated var findings: [ResistanceRuleResult] {
        blocks.flatMap { $0.evaluation.findings }
    }
}

/// A strategy-compatible group option for a position.
nonisolated struct ResistancePlanGroupOption: Sendable, Hashable {
    nonisolated var listing: ResistanceGroupListing
    nonisolated var status: ResistancePlanPositionStatus
    /// True when this group shares nothing with the most recent application in the
    /// effective sequence — the rotation the strategy actually asks for.
    nonisolated var differsFromRecentSequence: Bool
    nonisolated var statusByBlock: [String: ResistancePlanPositionStatus]
}

/// A Chemical Store product offered for a chosen group.
///
/// Supplied by the caller from the vineyard's own Chemical Store. The Planner never
/// invents a product, and never presents one as registered for the disease unless the
/// structured Chemical Intelligence says so.
nonisolated struct ResistancePlanChemicalCandidate: Sendable, Hashable, Identifiable {
    nonisolated var savedChemicalId: String
    nonisolated var productName: String
    nonisolated var groups: ResistanceGroupSignature
    nonisolated var availability: ChemicalIntelligenceAvailability
    /// From structured registered-use evidence. Nil = not known. NEVER derived from
    /// group membership.
    nonisolated var registeredForDisease: Bool?
    /// Vineyard/product country, for jurisdiction filtering. Nil = unknown.
    nonisolated var countryCode: String?

    nonisolated var id: String { savedChemicalId }

    nonisolated init(
        savedChemicalId: String,
        productName: String,
        groups: ResistanceGroupSignature,
        availability: ChemicalIntelligenceAvailability,
        registeredForDisease: Bool? = nil,
        countryCode: String? = nil
    ) {
        self.savedChemicalId = savedChemicalId
        self.productName = productName
        self.groups = groups
        self.availability = availability
        self.registeredForDisease = registeredForDisease
        self.countryCode = countryCode
    }
}

/// A Chemical Store product matched to a planned group.
nonisolated struct ResistancePlanProductOption: Sendable, Hashable, Identifiable {
    nonisolated var candidate: ResistancePlanChemicalCandidate
    /// True when the product's groups are exactly the planned signature. False means
    /// the product also carries other groups, which the engine will evaluate as a
    /// different (co-formulated) chemistry.
    nonisolated var isExactSignatureMatch: Bool

    nonisolated var id: String { candidate.savedChemicalId }

    /// Caveat that must remain visible while this product is planned, or nil when the
    /// product's chemistry is dependable.
    nonisolated var caveat: String? {
        switch candidate.availability {
        case .availableVerified:
            return nil
        case .availablePartiallyVerified:
            return "Recorded as \(candidate.groups.displayLabel) — chemical information partially verified"
        case .availableUnverified:
            return "Recorded as \(candidate.groups.displayLabel) — chemical information unverified"
        case .conflict:
            return "Sources disagree about this product's chemistry, so its \(candidate.groups.displayLabel) identity cannot be relied on"
        case .unavailable:
            return "No usable chemistry is recorded for this product"
        }
    }

    /// Registered-use wording. Absence of evidence is stated as such — never as a
    /// registration claim, and never inferred from the FRAC group.
    nonisolated var registeredUseNote: String {
        switch candidate.registeredForDisease {
        case .some(true): return "Registered use recorded for this disease"
        case .some(false): return "No registered use recorded for this disease"
        case .none: return "Registered use for this disease not known"
        }
    }
}

/// The full Planner output for one plan.
nonisolated struct ResistancePlanEvaluation: Sendable {
    /// False when no VineTrack strategy exists for the vineyard's jurisdiction.
    nonisolated var isSupported: Bool
    nonisolated var unsupportedMessage: String?
    nonisolated var strategyName: String?
    nonisolated var sourceOrganisation: String?
    nonisolated var rulesetId: String?
    nonisolated var rulesetVersion: String?
    nonisolated var rulesetValidFrom: String?
    nonisolated var historyChecks: [ResistanceBlockHistoryCheck]
    nonisolated var timelines: [ResistancePlanBlockTimeline]
    nonisolated var positions: [ResistancePlanPositionEvaluation]
    nonisolated var seasonTotals: [ResistanceBlockSeasonTotals]
    /// Vineyard-wide applications that could concern this disease but cannot be placed
    /// on a block.
    nonisolated var unresolvedApplicationCount: Int
    /// True when any selected block's history cannot carry a confident assessment.
    nonisolated var hasHistoryConcerns: Bool

    nonisolated func historyCheck(blockId: String) -> ResistanceBlockHistoryCheck? {
        historyChecks.first { $0.blockId == blockId }
    }

    nonisolated func timeline(blockId: String) -> ResistancePlanBlockTimeline? {
        timelines.first { $0.blockId == blockId }
    }

    nonisolated func totals(blockId: String) -> ResistanceBlockSeasonTotals? {
        seasonTotals.first { $0.blockId == blockId }
    }

    nonisolated var worstPositionStatus: ResistancePlanPositionStatus? {
        positions.isEmpty ? nil : ResistancePlanPositionStatus.worst(positions.map(\.status))
    }
}

/// The Resistance Planner.
///
/// Pure domain logic with NO resistance rules of its own. Every verdict it returns
/// comes from `ResistanceEngine.evaluate`; the Planner's whole job is to decide WHAT to
/// ask (which block, which sequence prefix, which candidate) and to arrange the
/// answers. If a count appears in the UI, the engine produced it — the Planner never
/// counts sprays itself, because a second implementation of "how many Group 11 sprays
/// is that" would eventually disagree with the first.
///
/// Mirrors `ResistancePlanner.kt` on Android.
nonisolated enum ResistancePlanner {

    nonisolated static let unsupportedJurisdictionMessage =
        "Resistance planning is not yet configured for this vineyard's jurisdiction."

    /// Shown whenever the engine reports `ResistanceMixtureRequirement.unknown`.
    ///
    /// Held here rather than typed into each platform's view so iOS and Android cannot
    /// drift into wording one softer than the other. The UI must never decide for itself
    /// that two FRAC groups in a tank satisfy a mixture requirement.
    nonisolated static let mixtureUnconfirmedLabel =
        "Mixture requirement cannot be fully confirmed"

    /// One day, for spacing synthetic planned timestamps.
    private nonisolated static let dayMs: Int64 = 86_400_000

    nonisolated struct Request: Sendable {
        nonisolated var plan: ResistancePlan
        nonisolated var season: ResistanceSeason
        nonisolated var seasonCalendar: ResistanceSeasonCalendar
        /// Every completed resistance event available, for any block, disease or
        /// season. The engine does the filtering — pre-filtering here would strip the
        /// previous-season tail that cross-season rules need.
        nonisolated var events: [ResistanceApplicationEvent]
        /// Real applications whose treated blocks were never recorded.
        nonisolated var unresolvedApplications: [ResistanceEventSource.UnresolvedBlockApplication]
        nonisolated var registry: ResistanceRulesetRegistry

        nonisolated init(
            plan: ResistancePlan,
            season: ResistanceSeason,
            seasonCalendar: ResistanceSeasonCalendar,
            events: [ResistanceApplicationEvent],
            unresolvedApplications: [ResistanceEventSource.UnresolvedBlockApplication] = [],
            registry: ResistanceRulesetRegistry = ResistanceRulesets.registry
        ) {
            self.plan = plan
            self.season = season
            self.seasonCalendar = seasonCalendar
            self.events = events
            self.unresolvedApplications = unresolvedApplications
            self.registry = registry
        }
    }

    // MARK: - Entry point

    nonisolated static func evaluate(_ request: Request) -> ResistancePlanEvaluation {
        let plan = request.plan
        guard let ruleset = request.registry.current(
            jurisdiction: plan.jurisdiction,
            crop: plan.crop,
            disease: plan.disease
        ) else {
            return ResistancePlanEvaluation(
                isSupported: false,
                unsupportedMessage: unsupportedJurisdictionMessage,
                strategyName: nil,
                sourceOrganisation: nil,
                rulesetId: nil,
                rulesetVersion: nil,
                rulesetValidFrom: nil,
                historyChecks: [],
                timelines: [],
                positions: [],
                seasonTotals: [],
                unresolvedApplicationCount: 0,
                hasHistoryConcerns: false
            )
        }

        let unresolved = request.unresolvedApplications.filter {
            $0.mayConcern(plan.disease) && $0.seasonId == request.season.id
        }

        let checks = plan.blockIds.map {
            historyCheck(blockId: $0, request: request, unresolvedCount: unresolved.count)
        }
        let timelines = plan.blockIds.map { timeline(blockId: $0, request: request) }
        let totals = plan.blockIds.map { seasonTotals(blockId: $0, request: request) }
        let positions = plan.positions.indices.map { index in
            evaluatePosition(at: index, request: request, completedCounts: totals)
        }

        return ResistancePlanEvaluation(
            isSupported: true,
            unsupportedMessage: nil,
            strategyName: ruleset.strategyName,
            sourceOrganisation: ruleset.sourceOrganisation,
            rulesetId: ruleset.id,
            rulesetVersion: ruleset.rulesetVersion,
            rulesetValidFrom: ruleset.validFrom,
            historyChecks: checks,
            timelines: timelines,
            positions: positions,
            seasonTotals: totals,
            unresolvedApplicationCount: unresolved.count,
            hasHistoryConcerns: checks.contains { !$0.isCompleteEnoughToAssess }
        )
    }

    // MARK: - Position evaluation

    /// Evaluates position `index` for every selected block.
    ///
    /// The sequence handed to the engine is HISTORY + EVERY PRECEDING PLANNED POSITION,
    /// with the position itself as the candidate. Positions after it are excluded
    /// entirely — a spray planned for December cannot influence whether October's
    /// choice is allowed.
    ///
    /// Preceding positions are passed as `.planned` with `includePlanned: true` rather
    /// than being disguised as `.actual`. The engine already distinguishes the two, and
    /// laundering a plan into history would be a lie that leaks: the same events are
    /// used elsewhere to report what was actually applied.
    nonisolated static func evaluatePosition(
        at index: Int,
        request: Request,
        completedCounts: [ResistanceBlockSeasonTotals]? = nil
    ) -> ResistancePlanPositionEvaluation {
        let plan = request.plan
        let position = plan.positions[index]
        let totals = completedCounts ?? plan.blockIds.map { seasonTotals(blockId: $0, request: request) }
        // The ordinal continues the longest block history, so "Spray 4" means the
        // fourth spray for the block that has had the most — never a count that no
        // block actually experienced.
        let completed = totals.map(\.diseaseSprayCount).max() ?? 0

        guard !position.isEmpty else {
            return ResistancePlanPositionEvaluation(
                positionId: position.id,
                index: index,
                displayOrdinal: completed + index + 1,
                status: .needsReview,
                blocks: [],
                awaitingChemistry: true
            )
        }

        let timestamps = plannedTimestamps(request: request)
        let outcomes: [ResistancePlanBlockOutcome] = plan.blockIds.map { blockId in
            let precedingPlanned = (0..<index).map { earlier in
                event(
                    for: plan.positions[earlier],
                    blockId: blockId,
                    kind: .planned,
                    epochMs: timestamps[earlier],
                    request: request
                )
            }
            let candidate = event(
                for: position,
                blockId: blockId,
                kind: .candidate,
                epochMs: timestamps[index],
                request: request
            )
            let evaluation = ResistanceEngine.evaluate(
                ResistanceEvaluationRequest(
                    jurisdiction: plan.jurisdiction,
                    crop: plan.crop,
                    disease: plan.disease,
                    blockId: blockId,
                    season: request.season,
                    seasonCalendar: request.seasonCalendar,
                    events: request.events + precedingPlanned,
                    candidate: candidate,
                    // Preceding planned positions must count; the plan is the whole
                    // point of the exercise.
                    includePlanned: true,
                    registry: request.registry
                )
            )
            return ResistancePlanBlockOutcome(
                blockId: blockId,
                status: status(for: evaluation, position: position),
                evaluation: evaluation
            )
        }

        return ResistancePlanPositionEvaluation(
            positionId: position.id,
            index: index,
            displayOrdinal: completed + index + 1,
            status: ResistancePlanPositionStatus.worst(outcomes.map(\.status)),
            blocks: outcomes,
            awaitingChemistry: false
        )
    }

    /// Maps an engine verdict onto a planner status.
    ///
    /// Nothing is re-derived here — the engine has already decided. This only chooses
    /// the operator-facing name, and refuses to call a result a good fit when a
    /// requirement could not be confirmed.
    nonisolated static func status(
        for evaluation: ResistanceEvaluation,
        position: ResistancePlannedPosition?
    ) -> ResistancePlanPositionStatus {
        switch evaluation.status {
        case .unsupportedRuleset, .unableToFullyAssess:
            return .unableToFullyAssess
        case .strategyExceeded:
            return .wouldExceedStrategy
        case .limitReached:
            return .reachesStrategyLimit
        case .compliant, .approachingLimit, .notApplicable:
            // A mixture requirement that cannot be confirmed is not a pass.
            if evaluation.ruleResults.contains(where: { $0.status == .requirementUnproven }) {
                return .needsReview
            }
            // An unverified or conflicting product keeps its caveat visible in the
            // status, so a plan built on shaky chemistry never renders as clean.
            if let position, !position.productsRequiringCaveat.isEmpty {
                return .needsReview
            }
            if evaluation.evidenceQuality != .high { return .needsReview }
            // Guidance deliberately does NOT downgrade the status. The powdery ruleset
            // carries a blanket preventative-use guideline that is present in every
            // evaluation, so treating guidance as "needs review" would mark every
            // powdery position for review and make "good fit" unreachable — destroying
            // the signal the status exists to carry. Guidance still appears in
            // `findings`, which is where published advice with no threshold belongs.
            return .goodFit
        }
    }

    // MARK: - Group options

    /// Strategy-compatible group options for a position, worst options omitted.
    ///
    /// Each option is a real engine evaluation of that group placed at that position,
    /// for every selected block — not a heuristic and not a lookup table. Groups whose
    /// worst block outcome would exceed the strategy are excluded from the offer.
    nonisolated static func groupOptions(at index: Int, request: Request) -> [ResistancePlanGroupOption] {
        let plan = request.plan
        guard let ruleset = request.registry.current(
            jurisdiction: plan.jurisdiction,
            crop: plan.crop,
            disease: plan.disease
        ), index >= 0, index <= plan.positions.count else { return [] }

        let recentGroups = recentGroupsBefore(index: index, request: request)

        var options: [ResistancePlanGroupOption] = []
        for listing in ruleset.groups {
            var trial = plan
            let product = ResistancePlannedProduct(
                id: "trial",
                groups: listing.signature,
                source: .group
            )
            let trialPosition = ResistancePlannedPosition(
                id: index < plan.positions.count ? plan.positions[index].id : "trial-position",
                products: [product]
            )
            if index < trial.positions.count {
                trial.positions[index] = trialPosition
            } else {
                trial.positions.append(trialPosition)
            }
            var trialRequest = request
            trialRequest.plan = trial
            let evaluation = evaluatePosition(at: index, request: trialRequest)
            guard evaluation.status != .wouldExceedStrategy else { continue }
            var byBlock: [String: ResistancePlanPositionStatus] = [:]
            for outcome in evaluation.blocks { byBlock[outcome.blockId] = outcome.status }
            options.append(
                ResistancePlanGroupOption(
                    listing: listing,
                    status: evaluation.status,
                    differsFromRecentSequence: listing.signature.codes.allSatisfy { !recentGroups.contains($0) },
                    statusByBlock: byBlock
                )
            )
        }

        // Rotation first: a group sharing nothing with the recent sequence is what the
        // strategy actually asks for, so it leads regardless of how tidy the
        // arithmetic looks for a repeat.
        return options.sorted { lhs, rhs in
            if lhs.differsFromRecentSequence != rhs.differsFromRecentSequence {
                return lhs.differsFromRecentSequence
            }
            if lhs.status.rank != rhs.status.rank { return lhs.status.rank < rhs.status.rank }
            return ResistanceGroupCode.isOrderedBefore(
                lhs.listing.signature.codes.first ?? "",
                rhs.listing.signature.codes.first ?? ""
            )
        }
    }

    /// Groups in the most recent application before `index`, across the effective
    /// sequence (history plus preceding planned positions).
    ///
    /// Taken per block and unioned: with two blocks selected the "recent sequence"
    /// differs between them, and a group that rotates away from one may repeat on the
    /// other. Unioning keeps the recommendation conservative rather than optimistic.
    nonisolated static func recentGroupsBefore(index: Int, request: Request) -> Set<String> {
        let plan = request.plan
        if index > 0, index <= plan.positions.count {
            return plan.positions[index - 1].componentGroups
        }
        var groups: Set<String> = []
        for blockId in plan.blockIds {
            let history = request.events
                .filter {
                    $0.blockId == blockId && $0.kind == .actual && $0.targetsRecorded
                        && $0.targets(plan.disease) && request.season.contains($0.appliedAtEpochMs)
                }
                .chronological
            if let last = history.last { groups.formUnion(last.componentGroups) }
        }
        return groups
    }

    // MARK: - Product options

    /// Chemical Store products offered for a planned group.
    ///
    /// Filtering is by jurisdiction and structured group only. Registered use and
    /// verification state are REPORTED, never used to silently drop a product the
    /// operator owns — a grower with one unverified Group 7 product needs to see it
    /// and its caveat, not an empty list.
    nonisolated static func productOptions(
        for signature: ResistanceGroupSignature,
        candidates: [ResistancePlanChemicalCandidate],
        jurisdiction: ResistanceJurisdiction
    ) -> [ResistancePlanProductOption] {
        let wanted = Set(signature.codes)
        guard !wanted.isEmpty else { return [] }
        let expectedCountry = jurisdiction.expectedCountryCode

        return candidates
            .filter { candidate in
                // Unknown country is not a mismatch: most Chemical Store entries
                // predate country capture, and hiding them would leave the grower
                // unable to plan with products they actually hold.
                guard let country = candidate.countryCode?.uppercased(), !country.isEmpty,
                      let expected = expectedCountry
                else { return true }
                return country == expected
            }
            .filter { !wanted.isDisjoint(with: Set($0.groups.codes)) }
            .map {
                ResistancePlanProductOption(
                    candidate: $0,
                    isExactSignatureMatch: Set($0.groups.codes) == wanted
                )
            }
            .sorted { lhs, rhs in
                if lhs.isExactSignatureMatch != rhs.isExactSignatureMatch {
                    return lhs.isExactSignatureMatch
                }
                if lhs.candidate.availability != rhs.candidate.availability {
                    return availabilityRank(lhs.candidate.availability)
                        > availabilityRank(rhs.candidate.availability)
                }
                return lhs.candidate.productName.localizedCaseInsensitiveCompare(rhs.candidate.productName) == .orderedAscending
            }
    }

    private nonisolated static func availabilityRank(_ availability: ChemicalIntelligenceAvailability) -> Int {
        switch availability {
        case .availableVerified: return 5
        case .availablePartiallyVerified: return 4
        case .availableUnverified: return 3
        case .conflict: return 2
        case .unavailable: return 1
        }
    }

    // MARK: - History reporting

    nonisolated static func historyCheck(
        blockId: String,
        request: Request,
        unresolvedCount: Int
    ) -> ResistanceBlockHistoryCheck {
        let plan = request.plan
        let inSeason = request.events.filter {
            $0.blockId == blockId && $0.kind == .actual && request.season.contains($0.appliedAtEpochMs)
        }
        let relevant = inSeason.filter { $0.targetsRecorded && $0.targets(plan.disease) }
        let unknownTargets = inSeason.filter { !$0.targetsRecorded }

        let unverified = relevant.filter { $0.availability == .availableUnverified || $0.availability == .availablePartiallyVerified }
        let unavailable = relevant.filter { $0.availability == .unavailable }
        let conflicting = relevant.filter { $0.availability == .conflict }

        var concerns: [ResistanceHistoryConcern] = []
        // Ordered worst-first so the headline names the most serious gap.
        if unresolvedCount > 0 { concerns.append(.unresolvedBlockAttribution) }
        if !unknownTargets.isEmpty { concerns.append(.unknownTargets) }
        if !conflicting.isEmpty { concerns.append(.conflictingChemistry) }
        if !unavailable.isEmpty { concerns.append(.unavailableChemistry) }
        if !unverified.isEmpty { concerns.append(.unverifiedChemistry) }

        return ResistanceBlockHistoryCheck(
            blockId: blockId,
            relevantApplicationCount: relevant.count,
            concerns: concerns,
            unverifiedCount: unverified.count,
            unavailableCount: unavailable.count,
            conflictingCount: conflicting.count,
            unknownTargetCount: unknownTargets.count,
            unresolvedVineyardApplicationCount: unresolvedCount
        )
    }

    nonisolated static func timeline(blockId: String, request: Request) -> ResistancePlanBlockTimeline {
        let plan = request.plan
        let entries = request.events
            .filter {
                $0.blockId == blockId && $0.kind == .actual && request.season.contains($0.appliedAtEpochMs)
                    && $0.targetsRecorded && $0.targets(plan.disease)
            }
            .chronological
            .map { event in
                ResistancePlanTimelineEntry(
                    applicationId: event.applicationId,
                    appliedAtEpochMs: event.appliedAtEpochMs,
                    groupsLabel: ResistanceGroupSignature.of(Array(event.componentGroups)).displayLabel,
                    productNames: event.products.compactMap { $0.productName }.filter { !$0.isEmpty },
                    availability: event.availability,
                    targetsRecorded: event.targetsRecorded
                )
            }
        return ResistancePlanBlockTimeline(blockId: blockId, entries: entries)
    }

    /// Season totals for a block, counted from resistance events (never tank lines).
    nonisolated static func seasonTotals(blockId: String, request: Request) -> ResistanceBlockSeasonTotals {
        let plan = request.plan
        let relevant = request.events.filter {
            $0.blockId == blockId && $0.kind == .actual && request.season.contains($0.appliedAtEpochMs)
                && $0.targetsRecorded && $0.targets(plan.disease)
        }
        var byGroup: [String: Int] = [:]
        for event in relevant {
            // One application contributes at most one to each group it contains, so a
            // co-formulation of 11+3 counts once for 11 and once for 3 — not twice for
            // either, and not once for "11+3" as though that were a third group.
            for code in event.componentGroups {
                byGroup[code, default: 0] += 1
            }
        }
        return ResistanceBlockSeasonTotals(
            blockId: blockId,
            diseaseSprayCount: relevant.count,
            applicationsByGroup: byGroup
        )
    }

    // MARK: - Synthetic planned chronology

    /// Timestamps for the plan's positions, derived from plan ORDER.
    ///
    /// PLAN ORDER IS AUTHORITATIVE, and an optional target date is display metadata
    /// only. Two reasons. First, resistance rules are sequence-dependent, so reordering
    /// positions has to change the answers (that is the whole value of the tool); if a
    /// stale date could override the order, the list an operator is reading would
    /// disagree with the arithmetic behind it. Second, requiring dates just to plan a
    /// rotation would make the tool unusable in the only situation it is really needed
    /// — deciding chemistry months out, before any date is knowable.
    ///
    /// Slots are placed after the last completed application in the season and spaced
    /// so they always remain strictly increasing AND inside the season, so a long plan
    /// cannot silently spill into the next season and reset a seasonal maximum.
    nonisolated static func plannedTimestamps(request: Request) -> [Int64] {
        let plan = request.plan
        guard !plan.positions.isEmpty else { return [] }
        let lastHistory = request.events
            .filter {
                plan.blockIds.contains($0.blockId) && $0.kind == .actual
                    && request.season.contains($0.appliedAtEpochMs)
            }
            .map(\.appliedAtEpochMs)
            .max()
        let anchor = max(lastHistory ?? request.season.startEpochMs, request.season.startEpochMs)
        let remaining = max(request.season.endEpochMs - anchor, Int64(plan.positions.count + 1))
        let spacing = max(1, min(dayMs, remaining / Int64(plan.positions.count + 1)))
        return plan.positions.indices.map { anchor + spacing * Int64($0 + 1) }
    }

    /// Builds a resistance event from a planned position.
    ///
    /// `targetsRecorded` is true and `targets` is the planned disease: the operator has
    /// explicitly said what this slot is for, which is exactly the fact pre-sql/193
    /// history lacks.
    ///
    /// `mixturePartnerAtLabelRate` is deliberately left nil. A plan cannot establish
    /// that a partner will go in at an effective rate, so mixture rules correctly
    /// return "cannot be confirmed" rather than a comfortable pass.
    nonisolated static func event(
        for position: ResistancePlannedPosition,
        blockId: String,
        kind: ResistanceEventKind,
        epochMs: Int64,
        request: Request
    ) -> ResistanceApplicationEvent {
        ResistanceApplicationEvent(
            applicationId: plannedApplicationId(planId: request.plan.id, positionId: position.id),
            kind: kind,
            appliedAtEpochMs: epochMs,
            seasonId: request.season.id,
            vineyardId: request.plan.vineyardId,
            blockId: blockId,
            targets: [request.plan.disease],
            targetsRecorded: true,
            products: position.products.map { product in
                ResistanceProductLine(
                    lineId: product.id,
                    productName: product.productName,
                    savedChemicalId: product.savedChemicalId,
                    groups: product.groups,
                    availability: product.effectiveAvailability
                )
            }
        )
    }

    /// Namespaced so a planned position can never collide with a real spray record id.
    nonisolated static func plannedApplicationId(planId: String, positionId: String) -> String {
        "plan:\(planId):position:\(positionId)"
    }
}

nonisolated extension ChemicalIntelligenceAvailability {
    /// Verification mark for a product's chemistry.
    ///
    /// Lives in the domain rather than in each platform's view so the two phones cannot
    /// drift to different symbols for the same evidence state — a grower comparing an
    /// iPhone and an Android in the same shed must not see one product marked differently
    /// on each.
    nonisolated var plannerMark: String {
        switch self {
        case .availableVerified: return "✓ Verified"
        case .availablePartiallyVerified: return "◐ Partially Verified"
        case .availableUnverified: return "○ Unverified"
        case .conflict: return "⚠ Conflict"
        case .unavailable: return "— No chemistry"
        }
    }
}

nonisolated extension ResistanceJurisdiction {
    /// ISO country code this jurisdiction expects, for Chemical Store filtering.
    nonisolated var expectedCountryCode: String? {
        switch self {
        case .australia: return "AU"
        case .newZealand: return "NZ"
        case .unknown: return nil
        }
    }
}

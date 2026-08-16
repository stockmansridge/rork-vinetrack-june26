import Foundation

/// What to evaluate. Explicit and deterministic: the same request produces the same
/// result on iOS and Android, and on any device in any time zone.
nonisolated struct ResistanceEvaluationRequest: Sendable {
    /// From the VINEYARD's stored country — never the phone locale.
    nonisolated var jurisdiction: ResistanceJurisdiction
    nonisolated var crop: ResistanceCrop
    nonisolated var disease: ResistanceDisease
    nonisolated var blockId: String
    nonisolated var season: ResistanceSeason
    nonisolated var seasonCalendar: ResistanceSeasonCalendar
    /// Every candidate event, any block, any disease, any season. The engine does the
    /// filtering, so callers cannot accidentally pre-filter away the previous
    /// season's tail that a cross-season rule needs.
    nonisolated var events: [ResistanceApplicationEvent]
    /// A proposed next spray. Need not be saved and need not have a real ID — the
    /// Guided Spray plan being assessed has neither.
    nonisolated var candidate: ResistanceApplicationEvent?
    /// Whether scheduled-but-unapplied events count as history. False in v1: a plan
    /// is not an application.
    nonisolated var includePlanned: Bool
    nonisolated var registry: ResistanceRulesetRegistry

    nonisolated init(
        jurisdiction: ResistanceJurisdiction,
        crop: ResistanceCrop,
        disease: ResistanceDisease,
        blockId: String,
        season: ResistanceSeason,
        seasonCalendar: ResistanceSeasonCalendar,
        events: [ResistanceApplicationEvent],
        candidate: ResistanceApplicationEvent? = nil,
        includePlanned: Bool = false,
        registry: ResistanceRulesetRegistry = ResistanceRulesets.registry
    ) {
        self.jurisdiction = jurisdiction
        self.crop = crop
        self.disease = disease
        self.blockId = blockId
        self.season = season
        self.seasonCalendar = seasonCalendar
        self.events = events
        self.candidate = candidate
        self.includePlanned = includePlanned
        self.registry = registry
    }
}

/// The Resistance Rules Engine.
///
/// Pure domain logic: no SwiftUI, no repository, no clock. Everything it knows
/// arrives in the request, which is what lets one implementation serve saved
/// history, an unsaved plan, and a test fixture — and what will let the Resistance
/// Planner and the Spray Calculator share one engine instead of growing two that
/// disagree.
///
/// Mirrors `ResistanceEngine.kt` on Android.
nonisolated enum ResistanceEngine {

    nonisolated static func evaluate(_ request: ResistanceEvaluationRequest) -> ResistanceEvaluation {
        guard let ruleset = request.registry.current(
            jurisdiction: request.jurisdiction,
            crop: request.crop,
            disease: request.disease
        ) else {
            return unsupported(request)
        }

        // --- Scope to the block ---
        let blockEvents = request.events.filter { $0.blockId == request.blockId }

        let excludedPlanned = request.includePlanned
            ? []
            : blockEvents.filter { $0.kind == .planned }
        var includedKinds: Set<ResistanceEventKind> = [.actual, .candidate]
        if request.includePlanned { includedKinds.insert(.planned) }
        let history = blockEvents.filter { includedKinds.contains($0.kind) }

        // Applications with no recorded target cannot be attributed to a disease.
        // They are NOT dropped: an unattributable spray inside the season is a hole
        // in the history, and a hole must suppress a clean result rather than quietly
        // shrink the denominator.
        let unattributedInSeason = history
            .filter { request.season.contains($0.appliedAtEpochMs) && !$0.targetsRecorded }
            .chronological

        // A candidate is only relevant to the block AND disease being evaluated.
        // Without the block check, assessing a spray planned for block B would
        // silently consume block A's allowance.
        let candidate = request.candidate.flatMap {
            $0.targets(request.disease) && $0.blockId == request.blockId ? $0 : nil
        }

        let diseaseHistory = history
            .filter { $0.targetsRecorded && $0.targets(request.disease) }
            .chronological

        let currentSeasonHistory = diseaseHistory.filter { request.season.contains($0.appliedAtEpochMs) }
        let previousSeason = request.seasonCalendar.previous(request.season)
        let previousSeasonHistory = diseaseHistory.filter { previousSeason.contains($0.appliedAtEpochMs) }

        let currentSeasonSequence = (currentSeasonHistory + (candidate.map { [$0] } ?? [])).chronological
        let crossSeasonSequence = (previousSeasonHistory + currentSeasonSequence).chronological

        // Denominator for every percentage rule: applications targeting THIS disease,
        // for THIS block, in THIS season. Never all vineyard sprays, never tank lines,
        // never other diseases. A mixture is one application, so mixtures never
        // inflate it.
        let totalDiseaseSprays = currentSeasonSequence.count

        if totalDiseaseSprays == 0 && unattributedInSeason.isEmpty {
            return notApplicable(request, ruleset: ruleset, excludedPlanned: excludedPlanned)
        }

        let context = EvaluationContext(
            request: request,
            ruleset: ruleset,
            currentSeasonSequence: currentSeasonSequence,
            crossSeasonSequence: crossSeasonSequence,
            candidate: candidate,
            totalDiseaseSprays: totalDiseaseSprays,
            unattributedInSeason: unattributedInSeason
        )

        let ruleResults = ruleset.rules.map { evaluateRule($0, context) }

        let unassessable = currentSeasonSequence
            .filter { !$0.canAssessChemistry }
            .map(\.applicationId)
        let overall = overallStatus(ruleResults, unassessable: unassessable, unattributed: unattributedInSeason)
        let evidence = overallEvidence(currentSeasonSequence, unattributed: unattributedInSeason)

        return ResistanceEvaluation(
            status: overall,
            jurisdiction: request.jurisdiction,
            crop: request.crop,
            disease: request.disease,
            blockId: request.blockId,
            seasonId: request.season.id,
            rulesetId: ruleset.id,
            rulesetVersion: ruleset.rulesetVersion,
            rulesetValidFrom: ruleset.validFrom,
            ruleResults: ruleResults,
            totalDiseaseSpraysInSeason: totalDiseaseSprays,
            consideredApplicationIds: currentSeasonSequence.map(\.applicationId),
            unassessableApplicationIds: unassessable,
            unattributedApplicationIds: unattributedInSeason.map(\.applicationId),
            excludedPlannedApplicationIds: excludedPlanned.map(\.applicationId),
            evidenceQuality: evidence,
            summary: summarise(
                overall,
                evidence: evidence,
                results: ruleResults,
                disease: request.disease,
                unattributedCount: unattributedInSeason.count
            ),
            candidateApplicationId: candidate?.applicationId
        )
    }

    // MARK: - Context

    private struct EvaluationContext {
        let request: ResistanceEvaluationRequest
        let ruleset: ResistanceRuleset
        let currentSeasonSequence: [ResistanceApplicationEvent]
        let crossSeasonSequence: [ResistanceApplicationEvent]
        let candidate: ResistanceApplicationEvent?
        let totalDiseaseSprays: Int
        let unattributedInSeason: [ResistanceApplicationEvent]

        func sequence(for rule: ResistanceRule) -> [ResistanceApplicationEvent] {
            rule.crossSeason ? crossSeasonSequence : currentSeasonSequence
        }
    }

    /// An intermediate result, before availability gating and packaging.
    private struct Partial {
        var status: ResistanceRuleStatus
        var threshold: Double?
        var thresholdDescription: String
        var observedValue: Double?
        var observedDescription: String
        var explanation: String
        var contributing: [ResistanceApplicationEvent]
        var mixtureRequirement: ResistanceMixtureRequirement?
        /// Rules that are pure guidance are never gated by availability.
        var isGuidance: Bool

        init(
            status: ResistanceRuleStatus,
            threshold: Double?,
            thresholdDescription: String,
            observedValue: Double?,
            observedDescription: String,
            explanation: String,
            contributing: [ResistanceApplicationEvent],
            mixtureRequirement: ResistanceMixtureRequirement? = nil,
            isGuidance: Bool = false
        ) {
            self.status = status
            self.threshold = threshold
            self.thresholdDescription = thresholdDescription
            self.observedValue = observedValue
            self.observedDescription = observedDescription
            self.explanation = explanation
            self.contributing = contributing
            self.mixtureRequirement = mixtureRequirement
            self.isGuidance = isGuidance
        }
    }

    // MARK: - Per-rule dispatch

    private static func evaluateRule(
        _ rule: ResistanceRule,
        _ context: EvaluationContext
    ) -> ResistanceRuleResult {
        let partial: Partial
        switch rule.kind {
        case .maxConsecutiveApplications(let limit):
            partial = evaluateConsecutive(rule, context, limit: limit)
        case .noConsecutiveApplications:
            partial = evaluateConsecutive(rule, context, limit: 1)
        case .maxApplicationsPerSeason(let limit):
            partial = evaluateCount(rule, context, limit: limit, window: "season")
        case .maxApplicationsPerCrop(let limit):
            partial = evaluateCount(rule, context, limit: limit, window: "crop")
        case .maxFractionOfDiseaseSprays(let numerator, let denominator):
            partial = evaluateFraction(rule, context, numerator: numerator, denominator: denominator)
        case .maxOneInEveryNSprays(let window):
            partial = evaluateOneInEveryN(rule, context, window: window)
        case .minInterveningDifferentGroupApplications(let count):
            partial = evaluateMinIntervening(rule, context, required: count)
        case .mixtureRequired:
            partial = evaluateMixture(rule, context, onlyWhenConsecutive: false)
        case .mixtureRequiredWhenConsecutive:
            partial = evaluateMixture(rule, context, onlyWhenConsecutive: true)
        case .maxSoloApplicationsPerSeason(let limit):
            partial = evaluateSoloCount(rule, context, limit: limit)
        case .notLastSprayOfSeason:
            partial = evaluateNotLastSpray(rule, context)
        case .maxFromTotalSprayCountTable(let columnKey):
            partial = evaluateTable(rule, context, columnKey: columnKey)
        case .preventativeApplicationGuidance:
            partial = evaluateGuidance(rule)
        }
        return finalise(rule, context, partial)
    }

    // MARK: - Consecutive runs

    private static func evaluateConsecutive(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        limit: Int
    ) -> Partial {
        let sequence = context.sequence(for: rule)
        let groups = rule.selector.describedGroups.joined(separator: " + ")
        let candidateId = context.candidate?.applicationId
        let historyOnly = sequence.filter { $0.applicationId != candidateId }

        let historyRuns = maximalRuns(historyOnly, selector: rule.selector)
        let historyLongest = historyRuns.map(\.count).max() ?? 0
        let candidateMatches = context.candidate.map { rule.selector.matches($0) } ?? false
        let candidateRun = candidateMatches ? trailingRun(sequence, selector: rule.selector) : []

        let runForNote = candidateRun.isEmpty
            ? (historyRuns.max { $0.count < $1.count } ?? [])
            : candidateRun
        let crossSeasonNote = rule.crossSeason && spansSeasonBoundary(runForNote, context)
            ? " This run continues from the previous season, which the strategy counts as consecutive."
            : ""

        let thresholdText = limit == 1
            ? "Group \(groups) must not be applied consecutively"
            : "a maximum of \(limit) consecutive Group \(groups) applications"

        if historyLongest > limit {
            return Partial(
                status: .limitExceeded,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(historyLongest),
                observedDescription: "\(historyLongest) consecutive applications recorded",
                explanation: "Group \(groups) has already been applied \(historyLongest) times in a row for \(context.request.disease.label). The strategy allows \(limit).\(crossSeasonNote)",
                contributing: historyRuns.first { $0.count == historyLongest } ?? []
            )
        }
        if candidateMatches && candidateRun.count > limit {
            return Partial(
                status: .wouldExceedLimit,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(candidateRun.count),
                observedDescription: "\(candidateRun.count) consecutive applications including this one",
                explanation: "This would be consecutive Group \(groups) application number \(candidateRun.count). The strategy allows \(limit).\(crossSeasonNote)",
                contributing: candidateRun
            )
        }
        if candidateMatches && candidateRun.count == limit {
            return Partial(
                status: .wouldReachLimit,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(candidateRun.count),
                observedDescription: "\(candidateRun.count) consecutive applications including this one",
                explanation: "This would reach the strategy maximum of \(limit) consecutive Group \(groups) applications. A different group should follow.\(crossSeasonNote)",
                contributing: candidateRun
            )
        }
        if historyLongest == limit {
            return Partial(
                status: .limitReached,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(historyLongest),
                observedDescription: "\(historyLongest) consecutive applications recorded",
                explanation: "Group \(groups) has reached the strategy maximum of \(limit) consecutive applications. A different group should be used next.\(crossSeasonNote)",
                contributing: historyRuns.first { $0.count == historyLongest } ?? []
            )
        }
        if historyLongest == 0 && !candidateMatches {
            return notTriggered(rule, threshold: Double(limit), thresholdText: thresholdText)
        }
        let longest = max(historyLongest, candidateRun.count)
        if limit >= 2 && longest == limit - 1 {
            return Partial(
                status: .approachingLimit,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(longest),
                observedDescription: "\(longest) consecutive applications",
                explanation: "One more consecutive Group \(groups) application would reach the strategy maximum of \(limit).",
                contributing: candidateRun.isEmpty
                    ? (historyRuns.max { $0.count < $1.count } ?? [])
                    : candidateRun
            )
        }
        return Partial(
            status: .withinLimit,
            threshold: Double(limit),
            thresholdDescription: thresholdText,
            observedValue: Double(longest),
            observedDescription: "\(longest) consecutive applications",
            explanation: "Within the strategy limit for consecutive Group \(groups) applications.",
            contributing: []
        )
    }

    /// Maximal runs of adjacent matching events.
    private static func maximalRuns(
        _ sequence: [ResistanceApplicationEvent],
        selector: ResistanceGroupSelector
    ) -> [[ResistanceApplicationEvent]] {
        var runs: [[ResistanceApplicationEvent]] = []
        var current: [ResistanceApplicationEvent] = []
        for event in sequence {
            if selector.matches(event) {
                current.append(event)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The run of matching events ending at the end of the sequence.
    private static func trailingRun(
        _ sequence: [ResistanceApplicationEvent],
        selector: ResistanceGroupSelector
    ) -> [ResistanceApplicationEvent] {
        var trailing: [ResistanceApplicationEvent] = []
        for event in sequence.reversed() {
            if !selector.matches(event) { break }
            trailing.insert(event, at: 0)
        }
        return trailing
    }

    private static func spansSeasonBoundary(
        _ run: [ResistanceApplicationEvent],
        _ context: EvaluationContext
    ) -> Bool {
        guard run.count >= 2 else { return false }
        let inSeason = run.contains { context.request.season.contains($0.appliedAtEpochMs) }
        let outSeason = run.contains { !context.request.season.contains($0.appliedAtEpochMs) }
        return inSeason && outSeason
    }

    // MARK: - Simple counts

    private static func evaluateCount(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        limit: Int,
        window: String
    ) -> Partial {
        let matching = context.currentSeasonSequence.filter { rule.selector.matches($0) }
        let groups = rule.selector.describedGroups.joined(separator: " + ")
        return countOutcome(
            rule: rule,
            context: context,
            matching: matching,
            limit: limit,
            thresholdText: "a maximum of \(limit) Group \(groups) applications per \(window)",
            groups: groups,
            observedNoun: "applications"
        )
    }

    private static func evaluateSoloCount(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        limit: Int
    ) -> Partial {
        let ruleGroups = rule.selector.describedGroups
        let matching = context.currentSeasonSequence.filter {
            rule.selector.matches($0) && $0.groupsOtherThan(ruleGroups).isEmpty
        }
        let groups = ruleGroups.joined(separator: " + ")
        return countOutcome(
            rule: rule,
            context: context,
            matching: matching,
            limit: limit,
            thresholdText: "a maximum of \(limit) solo (unmixed) Group \(groups) applications per season",
            groups: groups,
            observedNoun: "solo applications"
        )
    }

    /// - Parameter provisionalCeiling: True when the ceiling itself can still rise
    ///   this season — the Powdery table's maxima are a function of the total spray
    ///   count. With a provisional ceiling, "reached" and "approaching" are not
    ///   meaningful: at one total spray the table permits one application of every
    ///   group, so a single spray would otherwise report "CropLife strategy maximum
    ///   reached" in a season that has barely started. Only a genuine EXCEEDANCE is
    ///   reported, because that cannot be undone by spraying more.
    private static func countOutcome(
        rule: ResistanceRule,
        context: EvaluationContext,
        matching: [ResistanceApplicationEvent],
        limit: Int,
        thresholdText: String,
        groups: String,
        observedNoun: String,
        provisionalCeiling: Bool = false
    ) -> Partial {
        let candidateId = context.candidate?.applicationId
        let historyMatching = matching.filter { $0.applicationId != candidateId }
        let candidateMatches = candidateId != nil && matching.contains { $0.applicationId == candidateId }
        let total = matching.count
        let disease = context.request.disease.label

        var outcome: Partial
        if historyMatching.count > limit {
            outcome = Partial(
                status: .limitExceeded,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(historyMatching.count),
                observedDescription: "\(historyMatching.count) \(observedNoun) recorded",
                explanation: "Group \(groups) has been applied \(historyMatching.count) times for \(disease). The strategy allows \(limit).",
                contributing: historyMatching
            )
        } else if candidateMatches && total > limit {
            outcome = Partial(
                status: .wouldExceedLimit,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(total),
                observedDescription: "\(total) \(observedNoun) including this one",
                explanation: "This would be Group \(groups) application number \(total) for \(disease). The strategy allows \(limit).",
                contributing: matching
            )
        } else if candidateMatches && total == limit {
            outcome = Partial(
                status: .wouldReachLimit,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(total),
                observedDescription: "\(total) \(observedNoun) including this one",
                explanation: "This would reach the strategy maximum of \(limit) Group \(groups) applications for \(disease).",
                contributing: matching
            )
        } else if !candidateMatches && historyMatching.count == limit {
            outcome = Partial(
                status: .limitReached,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(historyMatching.count),
                observedDescription: "\(historyMatching.count) \(observedNoun) recorded",
                explanation: "Group \(groups) has reached the strategy maximum of \(limit) applications for \(disease).",
                contributing: historyMatching
            )
        } else if total == 0 {
            outcome = notTriggered(rule, threshold: Double(limit), thresholdText: thresholdText)
        } else if total == limit - 1 {
            outcome = Partial(
                status: .approachingLimit,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(total),
                observedDescription: "\(total) \(observedNoun)",
                explanation: "One more Group \(groups) application would reach the strategy maximum of \(limit) for \(disease).",
                contributing: matching
            )
        } else {
            outcome = Partial(
                status: .withinLimit,
                threshold: Double(limit),
                thresholdDescription: thresholdText,
                observedValue: Double(total),
                observedDescription: "\(total) \(observedNoun)",
                explanation: "Within the strategy maximum of \(limit) Group \(groups) applications.",
                contributing: matching
            )
        }

        if provisionalCeiling {
            switch outcome.status {
            case .limitReached, .wouldReachLimit, .approachingLimit:
                outcome.status = .withinLimit
                outcome.explanation = "Group \(groups) is within the current strategy ceiling of \(limit). That ceiling rises if more sprays target \(disease) this season."
            default:
                break
            }
        }
        return outcome
    }

    // MARK: - Fractions

    /// Percentage restrictions, compared as exact rationals.
    ///
    /// ROUNDING, stated explicitly: the permitted count is the largest integer `c`
    /// with `c × denominator ≤ total × numerator`, i.e. `floor(total × num / den)`.
    /// Comparison never goes through a rounded display percentage, so 2 of 6 is
    /// evaluated as `2 × 3 ≤ 6 × 1` — satisfied exactly — rather than as
    /// "33.33% > 33%".
    private static func evaluateFraction(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        numerator: Int,
        denominator: Int
    ) -> Partial {
        let matching = context.currentSeasonSequence.filter { rule.selector.matches($0) }
        let candidateId = context.candidate?.applicationId
        let historyMatching = matching.filter { $0.applicationId != candidateId }
        let candidateMatches = candidateId != nil && matching.contains { $0.applicationId == candidateId }

        let total = context.totalDiseaseSprays
        let groups = rule.selector.describedGroups.joined(separator: " + ")
        let percent = Double(numerator) * 100.0 / Double(denominator)
        let percentText = percent.truncatingRemainder(dividingBy: 1.0) == 0
            ? "\(Int(percent))%"
            : String(format: "%.1f%%", percent)
        let permitted = total * numerator / denominator
        let thresholdText = "\(percentText) of the \(total) \(context.request.disease.label) spray\(total == 1 ? "" : "s") this season (\(permitted) application\(permitted == 1 ? "" : "s"))"

        // History-only denominator, for judging whether history alone breaches.
        let historyTotal = candidateId == nil ? total : total - 1
        let historyPermitted = historyTotal * numerator / denominator

        if historyMatching.count * denominator > historyTotal * numerator {
            return Partial(
                status: .limitExceeded,
                threshold: Double(historyPermitted),
                thresholdDescription: thresholdText,
                observedValue: Double(historyMatching.count),
                observedDescription: "\(historyMatching.count) of \(historyTotal) sprays",
                explanation: "Group \(groups) accounts for \(historyMatching.count) of \(historyTotal) \(context.request.disease.label) sprays, above the strategy maximum of \(percentText).",
                contributing: historyMatching
            )
        }
        if candidateMatches && matching.count * denominator > total * numerator {
            return Partial(
                status: .wouldExceedLimit,
                threshold: Double(permitted),
                thresholdDescription: thresholdText,
                observedValue: Double(matching.count),
                observedDescription: "\(matching.count) of \(total) sprays including this one",
                explanation: "This would make Group \(groups) \(matching.count) of \(total) \(context.request.disease.label) sprays, above the strategy maximum of \(percentText).",
                contributing: matching
            )
        }
        if candidateMatches && matching.count * denominator == total * numerator {
            return Partial(
                status: .wouldReachLimit,
                threshold: Double(permitted),
                thresholdDescription: thresholdText,
                observedValue: Double(matching.count),
                observedDescription: "\(matching.count) of \(total) sprays including this one",
                explanation: "This would put Group \(groups) exactly on the strategy maximum of \(percentText) of \(context.request.disease.label) sprays.",
                contributing: matching
            )
        }
        if !candidateMatches, !historyMatching.isEmpty,
           historyMatching.count * denominator == historyTotal * numerator {
            return Partial(
                status: .limitReached,
                threshold: Double(historyPermitted),
                thresholdDescription: thresholdText,
                observedValue: Double(historyMatching.count),
                observedDescription: "\(historyMatching.count) of \(historyTotal) sprays",
                explanation: "Group \(groups) is on the strategy maximum of \(percentText) of \(context.request.disease.label) sprays.",
                contributing: historyMatching
            )
        }
        if matching.isEmpty {
            return notTriggered(rule, threshold: Double(permitted), thresholdText: thresholdText)
        }
        return Partial(
            status: .withinLimit,
            threshold: Double(permitted),
            thresholdDescription: thresholdText,
            observedValue: Double(matching.count),
            observedDescription: "\(matching.count) of \(total) sprays",
            explanation: "Group \(groups) is within the strategy maximum of \(percentText) of \(context.request.disease.label) sprays.",
            contributing: matching
        )
    }

    // MARK: - One-in-every-N spacing

    /// "One in every three sprays" as SPACING, not as a percentage.
    ///
    /// Deliberately distinct from `evaluateFraction`: two Group 49 sprays out of six
    /// satisfies a 33% cap, but if both land inside the same window of three they
    /// violate one-in-three. Treating the two as interchangeable would let a
    /// back-to-back pair through on an arithmetic technicality.
    private static func evaluateOneInEveryN(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        window: Int
    ) -> Partial {
        let sequence = context.currentSeasonSequence
        let groups = rule.selector.describedGroups.joined(separator: " + ")
        let thresholdText = "no more than one Group \(groups) application in every \(window) \(context.request.disease.label) sprays"
        let candidateId = context.candidate?.applicationId

        var worstWindow: [ResistanceApplicationEvent] = []
        var worstCount = 0
        var worstIncludesCandidate = false
        if !sequence.isEmpty {
            let upper = max(0, sequence.count - window)
            for start in 0...upper {
                let end = min(start + window, sequence.count)
                let slice = Array(sequence[start..<end])
                let matches = slice.filter { rule.selector.matches($0) }
                if matches.count > worstCount {
                    worstCount = matches.count
                    worstWindow = matches
                    worstIncludesCandidate = candidateId != nil
                        && matches.contains { $0.applicationId == candidateId }
                }
            }
        }

        if worstCount == 0 {
            return notTriggered(rule, threshold: 1.0, thresholdText: thresholdText)
        }
        if worstCount <= 1 {
            return Partial(
                status: .withinLimit,
                threshold: 1.0,
                thresholdDescription: thresholdText,
                observedValue: Double(worstCount),
                observedDescription: "at most \(worstCount) in any \(window) consecutive sprays",
                explanation: "Group \(groups) spacing satisfies one in every \(window) sprays.",
                contributing: worstWindow
            )
        }
        if worstIncludesCandidate {
            return Partial(
                status: .wouldExceedLimit,
                threshold: 1.0,
                thresholdDescription: thresholdText,
                observedValue: Double(worstCount),
                observedDescription: "\(worstCount) within \(window) consecutive sprays including this one",
                explanation: "This would place \(worstCount) Group \(groups) applications inside \(window) consecutive \(context.request.disease.label) sprays. The strategy allows one in every \(window).",
                contributing: worstWindow
            )
        }
        return Partial(
            status: .limitExceeded,
            threshold: 1.0,
            thresholdDescription: thresholdText,
            observedValue: Double(worstCount),
            observedDescription: "\(worstCount) within \(window) consecutive sprays",
            explanation: "\(worstCount) Group \(groups) applications fall inside \(window) consecutive \(context.request.disease.label) sprays. The strategy allows one in every \(window).",
            contributing: worstWindow
        )
    }

    // MARK: - Intervening different-group applications

    private static func evaluateMinIntervening(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        required: Int
    ) -> Partial {
        let sequence = context.currentSeasonSequence
        let groups = rule.selector.describedGroups.joined(separator: " + ")
        let thresholdText = "at least \(required) applications of a different group between Group \(groups) applications"
        let candidateId = context.candidate?.applicationId

        let matchingIndices = sequence.indices.filter { rule.selector.matches(sequence[$0]) }
        if matchingIndices.isEmpty {
            return notTriggered(rule, threshold: Double(required), thresholdText: thresholdText)
        }

        var worstGap: Int?
        var worstPair: [ResistanceApplicationEvent] = []
        var worstIncludesCandidate = false
        for position in 1..<max(matchingIndices.count, 1) {
            let previous = matchingIndices[position - 1]
            let current = matchingIndices[position]
            let intervening = current - previous - 1
            if worstGap == nil || intervening < worstGap! {
                worstGap = intervening
                worstPair = [sequence[previous], sequence[current]]
                worstIncludesCandidate = candidateId != nil
                    && worstPair.contains { $0.applicationId == candidateId }
            }
        }

        guard let gap = worstGap else {
            return Partial(
                status: .withinLimit,
                threshold: Double(required),
                thresholdDescription: thresholdText,
                observedValue: nil,
                observedDescription: "one application, no reuse to assess",
                explanation: "Group \(groups) has been applied once, so no intervening-group requirement applies yet.",
                contributing: matchingIndices.map { sequence[$0] }
            )
        }

        if gap >= required {
            return Partial(
                status: .withinLimit,
                threshold: Double(required),
                thresholdDescription: thresholdText,
                observedValue: Double(gap),
                observedDescription: "\(gap) intervening applications at the closest reuse",
                explanation: "Group \(groups) reuse is separated by at least \(required) different-group applications.",
                contributing: worstPair
            )
        }
        if worstIncludesCandidate {
            return Partial(
                status: .wouldExceedLimit,
                threshold: Double(required),
                thresholdDescription: thresholdText,
                observedValue: Double(gap),
                observedDescription: "\(gap) intervening applications",
                explanation: "Group \(groups) was used \(gap) \(gap == 1 ? "spray" : "sprays") ago and the strategy requires at least \(required) applications of a different group before it is reapplied.",
                contributing: worstPair
            )
        }
        return Partial(
            status: .limitExceeded,
            threshold: Double(required),
            thresholdDescription: thresholdText,
            observedValue: Double(gap),
            observedDescription: "\(gap) intervening applications",
            explanation: "Two Group \(groups) applications are separated by only \(gap) different-group \(gap == 1 ? "application" : "applications"). The strategy requires at least \(required).",
            contributing: worstPair
        )
    }

    // MARK: - Mixture requirements

    /// Mixture requirements, answered honestly.
    ///
    /// CropLife defines a mixture as a co-formulation or a tank mix AT LABEL RATE of
    /// an alternative mode of action. The rate condition is the part that matters and
    /// the part group codes cannot establish: a second FRAC code in the tank does not
    /// prove that partner was loaded at a rate that actually controls the disease. So:
    ///
    /// - no alternative mode of action present at all -> `.notSatisfied` (definitive)
    /// - a partner present, adequacy unknown            -> `.unknown` (never a pass)
    /// - a partner explicitly confirmed at label rate   -> `.satisfied`
    ///
    /// The engine will therefore usually return `.unknown` rather than `.satisfied`.
    /// That is the correct answer, not a gap: claiming a resistance-strategy mixture
    /// requirement was met when nothing established the partner rate would be the
    /// single most dangerous false pass this engine could produce.
    private static func evaluateMixture(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        onlyWhenConsecutive: Bool
    ) -> Partial {
        let sequence = context.sequence(for: rule)
        let ruleGroups = rule.selector.describedGroups
        let groups = ruleGroups.joined(separator: " + ")

        let scope: [ResistanceApplicationEvent] = onlyWhenConsecutive
            ? maximalRuns(sequence, selector: rule.selector).filter { $0.count >= 2 }.flatMap { $0 }
            : sequence.filter { rule.selector.matches($0) }

        let thresholdText = onlyWhenConsecutive
            ? "consecutive Group \(groups) applications require a mixture or co-formulation with an alternative mode of action"
            : "Group \(groups) must be applied in a mixture with an effective alternative mode of action"

        if scope.isEmpty {
            return notTriggered(rule, threshold: nil, thresholdText: thresholdText)
        }

        let unmixed = scope.filter { $0.groupsOtherThan(ruleGroups).isEmpty }
        let unproven = scope.filter {
            !$0.groupsOtherThan(ruleGroups).isEmpty && $0.mixturePartnerAtLabelRate != true
        }
        let candidateId = context.candidate?.applicationId

        if !unmixed.isEmpty {
            let isCandidate = unmixed.contains { $0.applicationId == candidateId }
            return Partial(
                status: .requirementNotMet,
                threshold: nil,
                thresholdDescription: thresholdText,
                observedValue: Double(unmixed.count),
                observedDescription: "\(unmixed.count) application\(unmixed.count == 1 ? "" : "s") with no alternative mode of action",
                explanation: isCandidate
                    ? "This Group \(groups) application carries no alternative mode of action, and the strategy requires one."
                    : "\(unmixed.count) Group \(groups) application\(unmixed.count == 1 ? "" : "s") carried no alternative mode of action, which the strategy requires.",
                contributing: unmixed,
                mixtureRequirement: .notSatisfied
            )
        }
        if !unproven.isEmpty {
            return Partial(
                status: .requirementUnproven,
                threshold: nil,
                thresholdDescription: thresholdText,
                observedValue: Double(unproven.count),
                observedDescription: "\(unproven.count) application\(unproven.count == 1 ? "" : "s") with an unconfirmed mixture partner",
                explanation: "A different mode of action was present alongside Group \(groups), but VineTrack cannot confirm it was applied at an effective rate, so the mixture requirement cannot be confirmed from the recorded data.",
                contributing: unproven,
                mixtureRequirement: .unknown
            )
        }
        return Partial(
            status: .withinLimit,
            threshold: nil,
            thresholdDescription: thresholdText,
            observedValue: Double(scope.count),
            observedDescription: "\(scope.count) application\(scope.count == 1 ? "" : "s") mixed",
            explanation: "Group \(groups) was applied with a confirmed alternative mode of action.",
            contributing: scope,
            mixtureRequirement: .satisfied
        )
    }

    // MARK: - Last spray of season

    /// "Do not apply Group 40 as the last spray of the season."
    ///
    /// Reported as guidance rather than as a breach, because whether a spray is the
    /// LAST of a season is unknowable until the season ends. Calling it a breach would
    /// flag every mid-season Group 40 spray simply for being the most recent one,
    /// which would train operators to ignore the warning.
    private static func evaluateNotLastSpray(
        _ rule: ResistanceRule,
        _ context: EvaluationContext
    ) -> Partial {
        let groups = rule.selector.describedGroups.joined(separator: " + ")
        let thresholdText = "Group \(groups) should not be the last spray of the season"
        guard let last = context.currentSeasonSequence.last else {
            return notTriggered(rule, threshold: nil, thresholdText: thresholdText)
        }

        if !rule.selector.matches(last) {
            return Partial(
                status: .withinLimit,
                threshold: nil,
                thresholdDescription: thresholdText,
                observedValue: nil,
                observedDescription: "the most recent spray does not contain Group \(groups)",
                explanation: "The most recent \(context.request.disease.label) spray does not contain Group \(groups).",
                contributing: []
            )
        }

        let isCandidate = last.applicationId == context.candidate?.applicationId
        return Partial(
            status: .guidance,
            threshold: nil,
            thresholdDescription: thresholdText,
            observedValue: nil,
            observedDescription: "currently the final \(context.request.disease.label) spray of the season",
            explanation: isCandidate
                ? "The strategy advises against Group \(groups) as the last spray of the season. If no further \(context.request.disease.label) spray follows this one, that advice would not be met."
                : "Group \(groups) is currently the final \(context.request.disease.label) spray of the season. The strategy advises the season should not end on Group \(groups).",
            contributing: [last],
            isGuidance: true
        )
    }

    // MARK: - Total-spray-count table

    /// The Powdery table, whose ceiling MOVES with the season's total spray count.
    ///
    /// UNKNOWN FUTURE TOTALS, stated explicitly: for candidate evaluation the engine
    /// uses the total it can actually see — applied history plus the candidate — and
    /// reports the ceiling at that total. It never invents future sprays to unlock a
    /// higher ceiling. A season that later grows longer may legitimately permit more,
    /// and re-evaluating then will say so; the Planner will be able to surface that
    /// projection, but the engine will not pre-emptively assume a spray nobody has
    /// planned.
    private static func evaluateTable(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        columnKey: String
    ) -> Partial {
        let groups = rule.selector.describedGroups.joined(separator: " + ")
        guard let table = context.ruleset.maxUseTable, let column = table.column(columnKey) else {
            return Partial(
                status: .unableToAssess,
                threshold: nil,
                thresholdDescription: "maximum-use table unavailable",
                observedValue: nil,
                observedDescription: "not assessed",
                explanation: "The strategy's maximum-use table is not available for Group \(groups).",
                contributing: []
            )
        }

        let total = context.totalDiseaseSprays
        guard let limit = table.maxFor(columnKey, totalSprays: total) else {
            return notTriggered(rule, threshold: nil, thresholdText: "no published maximum at \(total) sprays")
        }

        let matching = context.currentSeasonSequence.filter { rule.selector.matches($0) }
        let thresholdText = "a maximum of \(limit) Group \(column.displayName) application\(limit == 1 ? "" : "s") when \(total) \(context.request.disease.label) spray\(total == 1 ? "" : "s") are applied"

        // The ceiling stops moving once the total reaches the table's open-ended final
        // row (CropLife's 9+), after which reached/approaching are real.
        let openEnded = table.rows.first { $0.isOrMore }
        let provisional = openEnded != nil && total < openEnded!.totalSprays

        return countOutcome(
            rule: rule,
            context: context,
            matching: matching,
            limit: limit,
            thresholdText: thresholdText,
            groups: column.displayName,
            observedNoun: "applications",
            provisionalCeiling: provisional
        )
    }

    // MARK: - Guidance

    private static func evaluateGuidance(_ rule: ResistanceRule) -> Partial {
        Partial(
            status: .guidance,
            threshold: nil,
            thresholdDescription: "published guidance, no numeric limit",
            observedValue: nil,
            observedDescription: "informational",
            explanation: rule.sourceText,
            contributing: [],
            isGuidance: true
        )
    }

    private static func notTriggered(
        _ rule: ResistanceRule,
        threshold: Double?,
        thresholdText: String
    ) -> Partial {
        Partial(
            status: .notTriggered,
            threshold: threshold,
            thresholdDescription: thresholdText,
            observedValue: 0,
            observedDescription: "no matching applications",
            explanation: "Group \(rule.selector.describedGroups.joined(separator: " + ")) does not appear in this history.",
            contributing: []
        )
    }

    // MARK: - Availability gating and packaging

    /// Applies Chemical Intelligence availability to a computed result.
    ///
    /// A breach computed from known chemistry SURVIVES gating — an unverified Group 11
    /// sequence that appears to exceed the published maximum is still worth telling the
    /// operator about, qualified by its evidence.
    ///
    /// A non-breach does NOT survive gating when any application in scope has
    /// conflicting or missing chemistry, because that application might have contained
    /// the very group being counted. This is where a nil `chemicalSnapshot` is
    /// prevented from meaning "no resistance issue".
    private static func finalise(
        _ rule: ResistanceRule,
        _ context: EvaluationContext,
        _ partial: Partial
    ) -> ResistanceRuleResult {
        let scope = context.sequence(for: rule)
        let opaque = scope.filter { !$0.canAssessChemistry }
        let unattributed = context.unattributedInSeason

        var status = partial.status
        var explanation = partial.explanation
        var contributing = partial.contributing

        let blocked = !opaque.isEmpty || !unattributed.isEmpty
        if blocked, !partial.isGuidance, !partial.status.isBreach,
           partial.status != .requirementUnproven {
            status = .unableToAssess
            var reasons: [String] = []
            if !opaque.isEmpty {
                reasons.append("\(opaque.count) application\(opaque.count == 1 ? "" : "s") with missing or disputed chemistry")
            }
            if !unattributed.isEmpty {
                reasons.append("\(unattributed.count) application\(unattributed.count == 1 ? "" : "s") with no recorded target disease")
            }
            explanation = "This rule cannot be assessed: \(reasons.joined(separator: " and ")) could change the result. The recorded groups alone show \(partial.observedDescription)."
            var seen: Set<String> = []
            contributing = (partial.contributing + opaque + unattributed).filter { event in
                if seen.contains(event.applicationId) { return false }
                seen.insert(event.applicationId)
                return true
            }
        }

        let evidence = ruleEvidence(scope: scope, opaque: opaque, unattributed: unattributed, partial: partial)

        var qualified = explanation
        if evidence == .qualified && status.isBreach {
            qualified = explanation
                + " This is based on recorded groups that have not been independently verified."
        }

        return ResistanceRuleResult(
            ruleId: rule.id,
            rulesetId: context.ruleset.id,
            rulesetVersion: context.ruleset.rulesetVersion,
            disease: context.request.disease,
            blockId: context.request.blockId,
            status: status,
            severity: severityFor(status),
            groups: rule.selector.describedGroups,
            threshold: partial.threshold,
            thresholdDescription: partial.thresholdDescription,
            observedValue: partial.observedValue,
            observedDescription: partial.observedDescription,
            explanation: qualified,
            contributingApplicationIds: contributing.map(\.applicationId),
            contributingDatesEpochMs: contributing.map(\.appliedAtEpochMs),
            evidenceQuality: evidence,
            mixtureRequirement: partial.mixtureRequirement,
            sourceReference: rule.sourceReference,
            sourceText: rule.sourceText
        )
    }

    private static func ruleEvidence(
        scope: [ResistanceApplicationEvent],
        opaque: [ResistanceApplicationEvent],
        unattributed: [ResistanceApplicationEvent],
        partial: Partial
    ) -> ResistanceEvidenceQuality {
        if partial.isGuidance { return .high }
        if !opaque.isEmpty || !unattributed.isEmpty { return .indeterminate }
        let relevant = partial.contributing.isEmpty ? scope : partial.contributing
        if relevant.isEmpty { return .high }
        return relevant.allSatisfy { $0.availability.isDependable } ? .high : .qualified
    }

    private static func severityFor(_ status: ResistanceRuleStatus) -> ResistanceSeverity {
        switch status {
        case .limitExceeded, .wouldExceedLimit, .requirementNotMet: return .critical
        case .limitReached, .wouldReachLimit: return .warning
        case .unableToAssess, .requirementUnproven: return .indeterminate
        case .approachingLimit: return .advisory
        case .guidance, .withinLimit, .notTriggered: return .informational
        }
    }

    // MARK: - Aggregation

    private static func overallStatus(
        _ results: [ResistanceRuleResult],
        unassessable: [String],
        unattributed: [ResistanceApplicationEvent]
    ) -> ResistanceEvaluationStatus {
        if results.contains(where: { $0.status.isBreach }) { return .strategyExceeded }
        if !unassessable.isEmpty || !unattributed.isEmpty { return .unableToFullyAssess }
        if results.contains(where: { $0.status == .unableToAssess }) { return .unableToFullyAssess }
        if results.contains(where: { $0.status == .requirementUnproven }) { return .unableToFullyAssess }
        if results.contains(where: { $0.status.isAtLimit }) { return .limitReached }
        // Escalate the overall status only once at least two applications have
        // accumulated. A single Group 3 spray is one step from a limit of two, but
        // calling a season "approaching a limit" after its first spray would make the
        // status meaningless and train operators to ignore it. The rule-level
        // approachingLimit detail is still reported for the Planner.
        if results.contains(where: { $0.status == .approachingLimit && ($0.observedValue ?? 0) >= 2 }) {
            return .approachingLimit
        }
        return .compliant
    }

    private static func overallEvidence(
        _ sequence: [ResistanceApplicationEvent],
        unattributed: [ResistanceApplicationEvent]
    ) -> ResistanceEvidenceQuality {
        if !unattributed.isEmpty || sequence.contains(where: { !$0.canAssessChemistry }) {
            return .indeterminate
        }
        return sequence.allSatisfy { $0.availability.isDependable } ? .high : .qualified
    }

    /// The operator-facing sentence.
    ///
    /// A clean arithmetic result over unverified chemistry is never reported as "all
    /// good" — it is reported as what it actually is: no limit detected USING THE
    /// RECORDED GROUPS, with the quality of those groups stated.
    private static func summarise(
        _ status: ResistanceEvaluationStatus,
        evidence: ResistanceEvidenceQuality,
        results: [ResistanceRuleResult],
        disease: ResistanceDisease,
        unattributedCount: Int
    ) -> String {
        let label = disease.label
        switch status {
        case .strategyExceeded:
            let breach = results.first { $0.status.isBreach }
            let prefix = "Resistance strategy warning: \(breach?.explanation ?? "")"
            if evidence == .indeterminate {
                return prefix + " Other applications could not be assessed, so the full picture may be worse."
            }
            return prefix

        case .limitReached:
            let reached = results.first { $0.status.isAtLimit }
            return "CropLife strategy maximum reached: \(reached?.explanation ?? "")"

        case .approachingLimit:
            let near = results.first { $0.status == .approachingLimit }
            return "Approaching a CropLife strategy limit: \(near?.explanation ?? "")"

        case .unableToFullyAssess:
            var reasons: [String] = []
            if unattributedCount > 0 {
                reasons.append("\(unattributedCount) application\(unattributedCount == 1 ? "" : "s") have no recorded target disease")
            }
            if results.contains(where: { $0.status == .unableToAssess }) {
                reasons.append("chemistry is missing or disputed on one or more applications")
            }
            if results.contains(where: { $0.status == .requirementUnproven }) {
                reasons.append("a required mixture cannot be confirmed from the recorded data")
            }
            return "Unable to fully assess the \(label) resistance strategy for this block: \(reasons.joined(separator: "; ")). No clean result can be given."

        case .compliant:
            switch evidence {
            case .high:
                return "No \(label) resistance strategy limit is reached for this block."
            case .qualified:
                return "No strategy limit detected using the recorded groups; one or more chemical records are unverified."
            case .indeterminate:
                return "No strategy limit detected using the recorded groups, but some applications could not be assessed."
            }

        case .notApplicable:
            return "No applications targeting \(label) are recorded for this block this season."

        case .unsupportedRuleset:
            return "A VineTrack resistance strategy is not yet configured for this jurisdiction."
        }
    }

    // MARK: - Early exits

    /// No strategy for this jurisdiction.
    ///
    /// Australian maximum-use rules are NOT applied as a fallback. A New Zealand
    /// vineyard assessed against CropLife Australia limits would be given confident,
    /// specific, wrong advice, which is worse than no advice.
    private static func unsupported(_ request: ResistanceEvaluationRequest) -> ResistanceEvaluation {
        ResistanceEvaluation(
            status: .unsupportedRuleset,
            jurisdiction: request.jurisdiction,
            crop: request.crop,
            disease: request.disease,
            blockId: request.blockId,
            seasonId: request.season.id,
            rulesetId: nil,
            rulesetVersion: nil,
            rulesetValidFrom: nil,
            ruleResults: [],
            totalDiseaseSpraysInSeason: 0,
            consideredApplicationIds: [],
            unassessableApplicationIds: [],
            unattributedApplicationIds: [],
            excludedPlannedApplicationIds: [],
            evidenceQuality: .indeterminate,
            summary: "A VineTrack resistance strategy is not yet configured for this jurisdiction.",
            candidateApplicationId: request.candidate?.applicationId
        )
    }

    private static func notApplicable(
        _ request: ResistanceEvaluationRequest,
        ruleset: ResistanceRuleset,
        excludedPlanned: [ResistanceApplicationEvent]
    ) -> ResistanceEvaluation {
        ResistanceEvaluation(
            status: .notApplicable,
            jurisdiction: request.jurisdiction,
            crop: request.crop,
            disease: request.disease,
            blockId: request.blockId,
            seasonId: request.season.id,
            rulesetId: ruleset.id,
            rulesetVersion: ruleset.rulesetVersion,
            rulesetValidFrom: ruleset.validFrom,
            ruleResults: [],
            totalDiseaseSpraysInSeason: 0,
            consideredApplicationIds: [],
            unassessableApplicationIds: [],
            unattributedApplicationIds: [],
            excludedPlannedApplicationIds: excludedPlanned.map(\.applicationId),
            evidenceQuality: .high,
            summary: "No applications targeting \(request.disease.label) are recorded for this block this season.",
            candidateApplicationId: request.candidate?.applicationId
        )
    }
}

import Foundation

/// The outcome of one rule against one block's history for one disease.
///
/// Deliberately never a Boolean. "Two Group 11 sprays already applied" and "this
/// would be the third consecutive Group 3" are different situations requiring
/// different operator decisions, and collapsing them to `false` throws away the only
/// information that makes the warning actionable.
nonisolated enum ResistanceRuleStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// The rule's groups do not appear in this history at all.
    case notTriggered = "not_triggered"
    /// Present, comfortably inside the published limit.
    case withinLimit = "within_limit"
    /// One more application would reach the limit.
    case approachingLimit = "approaching_limit"
    /// History sits exactly ON the published maximum. Not a breach.
    case limitReached = "limit_reached"
    /// The candidate spray would land exactly on the maximum.
    case wouldReachLimit = "would_reach_limit"
    /// The candidate spray would go past the maximum.
    case wouldExceedLimit = "would_exceed_limit"
    /// Existing history is already past the maximum.
    case limitExceeded = "limit_exceeded"
    /// A non-numeric requirement (e.g. mixture) was definitively not met.
    case requirementNotMet = "requirement_not_met"
    /// A requirement whose satisfaction cannot be established from the recorded
    /// data. Explicitly not a pass.
    case requirementUnproven = "requirement_unproven"
    /// Missing or disputed chemistry could change this rule's answer, so no answer
    /// is given.
    case unableToAssess = "unable_to_assess"
    /// Published advice carrying no threshold, surfaced for information.
    case guidance

    nonisolated var isBreach: Bool {
        self == .limitExceeded || self == .wouldExceedLimit || self == .requirementNotMet
    }

    nonisolated var isAtLimit: Bool { self == .limitReached || self == .wouldReachLimit }
}

/// How prominently a result should be surfaced.
///
/// Kept separate from `ResistanceRuleStatus` so the domain never carries UI colours,
/// and so a future revision can re-tune emphasis without touching rule logic.
nonisolated enum ResistanceSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case informational
    case advisory
    case warning
    case critical
    /// Cannot be judged — needs operator attention of a different kind.
    case indeterminate
}

/// How much the evidence behind a result can be relied on.
///
/// A count derived from verified chemistry and the same count derived from an
/// operator's unverified typing are not the same claim, and presenting them
/// identically would misrepresent both.
nonisolated enum ResistanceEvidenceQuality: String, Codable, Sendable, Hashable, CaseIterable {
    /// Every contributing application had verified chemistry.
    case high
    /// Sound arithmetic over chemistry that is partially verified or unverified.
    case qualified
    /// Conflicting, missing or unattributable data affects this result.
    case indeterminate
}

/// Whether a required mixture can be shown to have been present.
///
/// `.satisfied` is reachable only when something independent establishes that a
/// partner from an alternative mode of action was applied at an effective rate.
/// Group codes alone cannot establish that, so the engine returns `.unknown`
/// instead of a comfortable false pass.
nonisolated enum ResistanceMixtureRequirement: String, Codable, Sendable, Hashable, CaseIterable {
    case satisfied
    /// No alternative mode of action was present at all — definitive.
    case notSatisfied = "not_satisfied"
    /// A partner was present, but its adequacy cannot be established.
    case unknown
}

/// The overall verdict for one disease, one block, one season.
nonisolated enum ResistanceEvaluationStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// No published limit is reached. Qualify by evidence quality before display.
    case compliant
    case approachingLimit = "approaching_limit"
    /// Sitting exactly on a published maximum — no headroom left.
    case limitReached = "limit_reached"
    /// At least one published limit is exceeded, or would be by the candidate.
    case strategyExceeded = "strategy_exceeded"
    /// Something the engine needs is missing, disputed or unattributable. NOT a pass
    /// and NOT a breach.
    case unableToFullyAssess = "unable_to_fully_assess"
    /// Nothing in this block's history targets this disease.
    case notApplicable = "not_applicable"
    /// No VineTrack strategy exists for this jurisdiction/crop/disease.
    case unsupportedRuleset = "unsupported_ruleset"
}

/// A single explainable finding.
///
/// Every field exists so the eventual Planner and Spray Calculator can justify a
/// warning down to the published sentence. There is deliberately no opaque score
/// anywhere in this engine: "Resistance Score 73" cannot be argued with, acted on,
/// or corrected, whereas "this would be a third consecutive Group 3 application,
/// CropLife Guideline 4 permits two" can be all three.
nonisolated struct ResistanceRuleResult: Codable, Sendable, Hashable, Identifiable {
    nonisolated var ruleId: String
    nonisolated var rulesetId: String
    nonisolated var rulesetVersion: String
    nonisolated var disease: ResistanceDisease
    nonisolated var blockId: String
    nonisolated var status: ResistanceRuleStatus
    nonisolated var severity: ResistanceSeverity
    /// The group codes this rule is about.
    nonisolated var groups: [String]
    /// The published ceiling, when the rule has one.
    nonisolated var threshold: Double?
    nonisolated var thresholdDescription: String
    /// What the history actually shows.
    nonisolated var observedValue: Double?
    nonisolated var observedDescription: String
    nonisolated var explanation: String
    nonisolated var contributingApplicationIds: [String]
    nonisolated var contributingDatesEpochMs: [Int64]
    nonisolated var evidenceQuality: ResistanceEvidenceQuality
    nonisolated var mixtureRequirement: ResistanceMixtureRequirement?
    /// Published clause, e.g. `"Guideline 4"`.
    nonisolated var sourceReference: String
    /// The published sentence, verbatim.
    nonisolated var sourceText: String

    nonisolated var id: String { "\(rulesetId)|\(ruleId)|\(blockId)" }
}

/// The complete evaluation for one disease against one block.
///
/// Mirrors `ResistanceEvaluation.kt` on Android.
nonisolated struct ResistanceEvaluation: Codable, Sendable, Hashable {
    nonisolated var status: ResistanceEvaluationStatus
    nonisolated var jurisdiction: ResistanceJurisdiction
    nonisolated var crop: ResistanceCrop
    nonisolated var disease: ResistanceDisease
    nonisolated var blockId: String
    nonisolated var seasonId: String
    /// Nil only for `.unsupportedRuleset`.
    nonisolated var rulesetId: String?
    nonisolated var rulesetVersion: String?
    /// The date the governing strategy is valid as at, for auditability.
    nonisolated var rulesetValidFrom: String?
    nonisolated var ruleResults: [ResistanceRuleResult]
    /// Denominator for every percentage rule.
    nonisolated var totalDiseaseSpraysInSeason: Int
    nonisolated var consideredApplicationIds: [String]
    /// Applications whose chemistry is disputed or missing. These stay in the
    /// chronology and suppress a clean result.
    nonisolated var unassessableApplicationIds: [String]
    /// Applications that could not be attributed to any disease because targets were
    /// never recorded.
    ///
    /// These are the pre-sql/193 records. They cannot be counted against a disease,
    /// and they must not be silently dropped either — a season half made of
    /// unattributable sprays is a season nobody can account for.
    nonisolated var unattributedApplicationIds: [String]
    /// Applications excluded because they are planned rather than applied. Surfaced
    /// so the exclusion is visible rather than invisible.
    nonisolated var excludedPlannedApplicationIds: [String]
    nonisolated var evidenceQuality: ResistanceEvidenceQuality
    /// Operator-facing sentence, already qualified by evidence quality.
    nonisolated var summary: String
    nonisolated var candidateApplicationId: String?

    /// Findings worth showing, worst first.
    nonisolated var findings: [ResistanceRuleResult] {
        ruleResults
            .filter { $0.status != .notTriggered && $0.status != .withinLimit }
            .sorted { Self.severityRank($0.severity) > Self.severityRank($1.severity) }
    }

    nonisolated var breaches: [ResistanceRuleResult] {
        ruleResults.filter { $0.status.isBreach }
    }

    nonisolated var hasCandidate: Bool { candidateApplicationId != nil }

    /// Whether this result may be presented as a clean pass.
    ///
    /// False whenever chemistry is missing, disputed or unattributable, no matter how
    /// empty the arithmetic came out.
    nonisolated var isCleanResult: Bool {
        status == .compliant && evidenceQuality == .high
    }

    nonisolated static func severityRank(_ severity: ResistanceSeverity) -> Int {
        switch severity {
        case .critical: return 5
        case .warning: return 4
        case .indeterminate: return 3
        case .advisory: return 2
        case .informational: return 1
        }
    }
}

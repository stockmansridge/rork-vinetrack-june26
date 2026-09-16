import Foundation

/// The pre-completion summary and the completion rule.
///
/// Pure and platform-neutral so it mirrors the Android `ScoutReview.kt`
/// exactly, and so the rule that decides whether a vineyard walk is finished is
/// testable without a UI.
nonisolated struct ScoutReview: Equatable, Sendable {
    let blocksAssessed: Int
    let blocksIncomplete: Int
    let growthStageObservations: Int
    let attentionItems: Int
    let photoCount: Int
    let otherIssues: Int
    let generalRecommendations: Int
    /// Paddock ids with no observation at all — what blocks completion.
    let incompletePaddockIDs: [UUID]

    static let completionHint =
        "Every dropdown does not need a value. Each selected block needs at "
        + "least one observation, issue or recommendation."

    /// Completion rule.
    ///
    /// Two things are deliberately NOT required:
    ///
    ///  * Every dropdown answered. Forcing six selections per block to record
    ///    "nothing of note" teaches operators to click through defaults, which
    ///    produces confident data nobody actually looked at.
    ///  * A minimum photo or note count. Some blocks are genuinely unremarkable.
    ///
    /// What IS required is evidence that every selected block was actually
    /// visited: at least one observation, issue or recommendation each. A block
    /// added to the visit and then never opened is the one case where silence
    /// is indistinguishable from an omission, so it blocks completion.
    var canComplete: Bool { blocksAssessed > 0 && blocksIncomplete == 0 }

    /// Operator-facing explanation when completion is blocked.
    func blockedReason() -> String? {
        if blocksAssessed == 0 && blocksIncomplete == 0 {
            return "Add at least one block to this Scout before completing it."
        }
        if blocksIncomplete == 1 {
            return "1 block has no observations yet. Record an observation, issue or "
                + "recommendation for it, or remove it from this Scout."
        }
        if blocksIncomplete > 1 {
            return "\(blocksIncomplete) blocks have no observations yet. Record an "
                + "observation, issue or recommendation for each, or remove them "
                + "from this Scout."
        }
        return nil
    }

    static func of(_ visit: ScoutVisit) -> ScoutReview {
        let incomplete = visit.assessments.filter { !$0.isComplete }
        return ScoutReview(
            blocksAssessed: visit.assessments.filter(\.isComplete).count,
            blocksIncomplete: incomplete.count,
            growthStageObservations: visit.assessments.filter {
                $0.observation(.growthStage)?.linkedGrowthStageRecordID != nil
            }.count,
            attentionItems: visit.assessments.reduce(0) { $0 + $1.attentionItems.count },
            photoCount: visit.assessments.reduce(0) { $0 + $1.photoCount },
            otherIssues: visit.assessments.filter {
                $0.observation(.otherIssue)?.hasContent == true
            }.count,
            generalRecommendations: visit.assessments.filter {
                $0.observation(.generalRecommendation)?.hasContent == true
            }.count,
            incompletePaddockIDs: incomplete.map(\.paddockID)
        )
    }
}

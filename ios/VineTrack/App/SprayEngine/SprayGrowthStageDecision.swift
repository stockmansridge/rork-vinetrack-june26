import Foundation

/// Whether growth stage is stated once for the whole application or per block.
///
/// Lives here rather than in the view so the completion rules can be tested
/// without a SwiftUI host.
nonisolated enum GrowthStageMode: String, CaseIterable, Sendable {
    case same
    case perPaddock
}

/// The operator's growth-stage answer for one scope (the whole spray, or one
/// block).
///
/// The defect this type exists to fix: `UUID?` was carrying two different
/// facts. `nil` meant both "nobody has answered yet" and "the operator looked
/// at the list and deliberately chose Not Set". The guided flow could only read
/// the first meaning, so a visible, selectable option could never satisfy its
/// own step.
///
/// A growth stage is genuinely optional on a spray record — an operator may
/// legitimately apply without stating one. What is NOT optional is the
/// decision. So the decision and the value are modelled separately, and
/// `.notSet` carries no stage: nothing fake is invented to unlock the flow.
nonisolated enum SprayGrowthStageDecision: Equatable, Sendable {
    /// Nobody has answered. Step 4 is incomplete.
    case unresolved
    /// The operator deliberately chose Not Set. Step 4 is complete, stage nil.
    case notSet
    /// The operator chose an actual E-L stage.
    case stage(UUID)

    /// True once the operator has made a decision either way.
    var isResolved: Bool { self != .unresolved }

    /// The actual stage, which is `nil` for BOTH unresolved and explicit
    /// Not Set. Completion and value are independent facts.
    var stageId: UUID? {
        if case let .stage(id) = self { return id }
        return nil
    }
}

/// The whole growth-stage answer for the spray being composed: the mode, the
/// shared decision and the per-block decisions.
///
/// Pure value type. The view holds one of these instead of the three loose
/// pieces of state (`sharedGrowthStageId`, `growthStageMode`,
/// `paddockPhenologyStages`) that previously had to be kept consistent by hand.
nonisolated struct SprayGrowthStageSelection: Equatable, Sendable {
    var mode: GrowthStageMode = .same
    /// The answer used when `mode == .same`.
    var shared: SprayGrowthStageDecision = .unresolved
    /// Per-block answers used when `mode == .perPaddock`. A block with no entry
    /// is unresolved — absence is never read as an explicit Not Set.
    var perBlock: [UUID: SprayGrowthStageDecision] = [:]

    init(
        mode: GrowthStageMode = .same,
        shared: SprayGrowthStageDecision = .unresolved,
        perBlock: [UUID: SprayGrowthStageDecision] = [:]
    ) {
        self.mode = mode
        self.shared = shared
        self.perBlock = perBlock
    }

    // MARK: - Reading

    /// The decision for one block, honouring the current mode.
    func decision(for blockId: UUID) -> SprayGrowthStageDecision {
        switch mode {
        case .same: return shared
        case .perPaddock: return perBlock[blockId] ?? .unresolved
        }
    }

    /// The stage that applies to one block, or `nil` when the answer is
    /// explicitly (or not yet) no stage.
    func stageId(for blockId: UUID) -> UUID? { decision(for: blockId).stageId }

    /// The shared stage, when one was actually chosen.
    var sharedStageId: UUID? { shared.stageId }

    /// Whether the growth-stage DECISION has been made for the current block
    /// selection.
    ///
    /// This is the guided step's rule, and it is deliberately not "every block
    /// has an E-L stage": `EL12 / EL9 / Not Set` across three blocks is a
    /// complete answer.
    ///
    /// Blocks that are no longer selected are ignored entirely, so deselecting
    /// a block the operator never answered for cannot keep blocking the flow.
    func isResolved(selectedBlockIds: Set<UUID>) -> Bool {
        guard !selectedBlockIds.isEmpty else { return false }
        switch mode {
        case .same:
            return shared.isResolved
        case .perPaddock:
            return selectedBlockIds.allSatisfy { (perBlock[$0] ?? .unresolved).isResolved }
        }
    }

    /// How many of the currently selected blocks have been answered.
    func resolvedCount(selectedBlockIds: Set<UUID>) -> Int {
        selectedBlockIds.filter { (perBlock[$0] ?? .unresolved).isResolved }.count
    }

    // MARK: - Mutating

    /// Record an explicit E-L stage for the whole spray.
    ///
    /// Propagating a REAL stage to each block preserves the existing copy
    /// behaviour, so switching to Per Paddock afterwards starts from what the
    /// operator already said.
    mutating func selectShared(stageId: UUID, selectedBlockIds: Set<UUID>) {
        shared = .stage(stageId)
        for id in selectedBlockIds { perBlock[id] = .stage(stageId) }
    }

    /// Record an explicit "Not Set" for the whole spray.
    ///
    /// This resolves the shared decision and clears any per-block stage, but it
    /// does NOT stamp `.notSet` onto blocks: if the operator then switches to
    /// Per Paddock, each block should be an open question again rather than
    /// inheriting a decision that was never made about it individually.
    mutating func selectSharedNotSet(selectedBlockIds: Set<UUID>) {
        shared = .notSet
        for id in selectedBlockIds { perBlock.removeValue(forKey: id) }
    }

    /// Clear the shared answer back to unanswered (used when prefill supplies
    /// nothing, and by tests).
    mutating func clearShared() {
        shared = .unresolved
    }

    /// Record one block's answer.
    mutating func select(blockId: UUID, decision: SprayGrowthStageDecision) {
        switch decision {
        case .unresolved: perBlock.removeValue(forKey: blockId)
        case .notSet, .stage: perBlock[blockId] = decision
        }
    }

    /// Switch mode.
    ///
    /// Going back to Same for All copies a genuine shared stage down to the
    /// selected blocks, exactly as before. An unresolved or explicitly-Not-Set
    /// shared answer copies nothing: an untouched block must not be recorded as
    /// though someone decided about it.
    mutating func setMode(_ newMode: GrowthStageMode, selectedBlockIds: Set<UUID>) {
        mode = newMode
        guard newMode == .same, let stageId = shared.stageId else { return }
        for id in selectedBlockIds { perBlock[id] = .stage(stageId) }
    }

    // MARK: - Program Step prefill

    /// The phenology stage a Program Step's `growth_stage_code` refers to.
    ///
    /// Matched on STAGE NUMBERS through the existing parser, so "EL12",
    /// "E-L 12" and "el 12" all land on the same stage. Takes id/code pairs
    /// rather than the model type so the rule stays pure.
    static func programStageId(code: String?, stages: [(id: UUID, code: String)]) -> UUID? {
        guard let code, let number = ELStageParser.stageNumber(fromCode: code) else { return nil }
        return stages.first { ELStageParser.stageNumber(fromCode: $0.code) == number }?.id
    }

    /// Apply a Program Step's declared growth stage.
    ///
    /// A stated stage resolves the decision AND supplies the value. A Program
    /// Step that states nothing changes nothing: "the Program did not specify a
    /// stage" is not the same fact as "the operator deliberately chose no stage
    /// for this application", so the step stays unresolved and the operator
    /// still answers it.
    ///
    /// - Returns: true when a stage was actually applied.
    @discardableResult
    mutating func applyProgramPrefill(
        code: String?,
        stages: [(id: UUID, code: String)],
        selectedBlockIds: Set<UUID>
    ) -> Bool {
        guard let stageId = Self.programStageId(code: code, stages: stages) else { return false }
        mode = .same
        selectShared(stageId: stageId, selectedBlockIds: selectedBlockIds)
        return true
    }

    /// Drop answers for blocks that are no longer selected.
    ///
    /// Completion already ignores them; pruning keeps the state from carrying a
    /// stale decision about a block the operator has since removed.
    mutating func prune(to selectedBlockIds: Set<UUID>) {
        perBlock = perBlock.filter { selectedBlockIds.contains($0.key) }
    }

    // MARK: - Presentation

    /// The collapsed Step 4 summary.
    ///
    /// - Parameters:
    ///   - selectedBlockIds: the blocks currently in scope.
    ///   - stageLabel: resolves a stage id to its display text, so this type
    ///     never has to know about `PhenologyStage`.
    func summary(
        selectedBlockIds: Set<UUID>,
        stageLabel: (UUID) -> String?
    ) -> String {
        guard !selectedBlockIds.isEmpty else { return SprayGrowthStageCopy.selectBlocksFirst }
        switch mode {
        case .same:
            switch shared {
            case .unresolved: return SprayGrowthStageCopy.undecided
            case .notSet: return SprayGrowthStageCopy.notSet
            case let .stage(id): return stageLabel(id) ?? SprayGrowthStageCopy.notSet
            }
        case .perPaddock:
            let total = selectedBlockIds.count
            let resolved = resolvedCount(selectedBlockIds: selectedBlockIds)
            return "Per block — \(resolved)/\(total) decided"
        }
    }

    /// The compact label for one block's control in Per Paddock mode.
    ///
    /// An explicit Not Set must never render as "Select": that is what made the
    /// original defect invisible.
    func blockLabel(for blockId: UUID, stageCode: (UUID) -> String?) -> String {
        switch perBlock[blockId] ?? .unresolved {
        case .unresolved: return SprayGrowthStageCopy.selectPlaceholder
        case .notSet: return SprayGrowthStageCopy.notSet
        case let .stage(id): return stageCode(id) ?? SprayGrowthStageCopy.notSet
        }
    }
}

/// Operator-facing growth-stage wording, in one place so the tests can pin it.
nonisolated enum SprayGrowthStageCopy {
    /// Shown before any blocks are chosen.
    static let selectBlocksFirst = "Select blocks first"
    /// Shown when the decision has not been made. Deliberately not "Not set":
    /// the whole point is that an unanswered step must not look answered.
    static let undecided = "Choose a stage or Not Set"
    /// The deliberate no-stage answer.
    static let notSet = "Not Set"
    /// Per-block control before that block has been answered.
    static let selectPlaceholder = "Select"
}

import Foundation
import Testing
@testable import VineTrack

/// Growth Stage — "Not Set" must be a valid answer.
///
/// The defect these tests lock out: the Growth Stage screen offered a visible,
/// selectable **Not Set** option, but the guided flow read the growth stage as
/// `UUID?` and treated `nil` as "unanswered". Selecting the option the UI
/// itself presented therefore left Step 4 permanently incomplete and Review
/// stuck reporting "Set growth stage".
///
/// The fix separates two facts that were sharing one variable:
///
/// - has the operator DECIDED? → guided step completion
/// - is there an E-L stage?   → the recorded value, still legitimately nil
///
/// Nothing here invents a stage to unlock the flow.
struct SprayGrowthStageDecisionTests {

    // MARK: - Fixtures

    private func stage(_ number: Int) throws -> PhenologyStage {
        try #require(
            PhenologyStage.allStages.first {
                ELStageParser.stageNumber(fromCode: $0.code) == number
            },
            "No phenology stage for E-L \(number)"
        )
    }

    private var stagePairs: [(id: UUID, code: String)] {
        PhenologyStage.allStages.map { (id: $0.id, code: $0.code) }
    }

    private func label(_ id: UUID) -> String? {
        PhenologyStage.allStages.first { $0.id == id }.map { "\($0.code) — \($0.name)" }
    }

    private func code(_ id: UUID) -> String? {
        PhenologyStage.allStages.first { $0.id == id }?.code
    }

    /// A guided flow satisfying every gated step EXCEPT growth stage, so a test
    /// can flip one fact and read the consequence.
    private func inputs(growthStageResolved: Bool) -> SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = [
            SprayBlockInput(
                blockId: "block-a",
                grossAreaHectares: 10,
                mappedRowLengthMetres: 31_250,
                rowSpacingMetres: 3.2
            )
        ]
        inputs.targets = [.powderyMildew]
        inputs.sprayHeadTarget = .fullCanopy
        inputs.isGrowthStageResolved = growthStageResolved
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2_000
        inputs.carrierBasis = .litresPerHectare
        inputs.litresPerHectare = 625
        inputs.products = [
            SprayProductLineInput(
                productId: "sulphur",
                name: "Sulphur",
                unit: "L",
                basis: .wholeBlockArea,
                rate: 2
            )
        ]
        return inputs
    }

    // MARK: - 1. Unanswered

    @Test("New spray with an untouched Growth Stage leaves Step 4 incomplete")
    func untouchedIsIncomplete() {
        let blockA = UUID()
        let selection = SprayGrowthStageSelection()

        #expect(selection.shared == .unresolved)
        #expect(!selection.isResolved(selectedBlockIds: [blockA]))
        #expect(!SprayGuidedFlow(inputs: inputs(growthStageResolved: false)).isComplete(.growthStage))
    }

    /// The radio must not look pre-answered. Before any tap, the shared
    /// decision is `.unresolved`, which is NOT `.notSet` — that inequality is
    /// exactly what the Not Set radio's fill now keys off.
    @Test("Unanswered does not read as Not Set, so the radio is not pre-filled")
    func unansweredIsNotTheSameAsNotSet() {
        let selection = SprayGrowthStageSelection()

        #expect(selection.shared != .notSet)
        #expect(
            selection.summary(selectedBlockIds: [UUID()], stageLabel: label)
                == SprayGrowthStageCopy.undecided
        )
    }

    // MARK: - 2/3. Same for All

    @Test("Same for All + explicit Not Set completes Step 4")
    func sharedNotSetCompletes() {
        let blockA = UUID()
        var selection = SprayGrowthStageSelection()
        selection.selectSharedNotSet(selectedBlockIds: [blockA])

        #expect(selection.shared == .notSet)
        #expect(selection.isResolved(selectedBlockIds: [blockA]))
    }

    @Test("Same for All + EL12 completes Step 4 and stores the stage")
    func sharedStageCompletes() throws {
        let blockA = UUID()
        let el12 = try stage(12)
        var selection = SprayGrowthStageSelection()
        selection.selectShared(stageId: el12.id, selectedBlockIds: [blockA])

        #expect(selection.isResolved(selectedBlockIds: [blockA]))
        #expect(selection.sharedStageId == el12.id)
        #expect(selection.stageId(for: blockA) == el12.id)
    }

    // MARK: - 4. Value stays nil

    /// Completion and value are independent. Explicit Not Set must never
    /// fabricate a stage id or a placeholder code to satisfy the flow.
    @Test("Explicit Not Set completes the step while the stage value stays nil")
    func notSetKeepsValueNil() {
        let blockA = UUID()
        var selection = SprayGrowthStageSelection()
        selection.selectSharedNotSet(selectedBlockIds: [blockA])

        #expect(selection.isResolved(selectedBlockIds: [blockA]))
        #expect(selection.sharedStageId == nil)
        #expect(selection.stageId(for: blockA) == nil)
        #expect(selection.shared.stageId == nil)
    }

    // MARK: - 5/6. Program Step prefill

    @Test("Program Step stating EL12 arrives resolved and complete")
    func programPrefillResolves() throws {
        let blockA = UUID()
        let el12 = try stage(12)
        var selection = SprayGrowthStageSelection()

        let applied = selection.applyProgramPrefill(
            code: "EL12",
            stages: stagePairs,
            selectedBlockIds: [blockA]
        )

        #expect(applied)
        #expect(selection.mode == .same)
        #expect(selection.sharedStageId == el12.id)
        #expect(selection.isResolved(selectedBlockIds: [blockA]))
    }

    /// "The Program did not specify a stage" is not "the operator deliberately
    /// chose no stage for this application". Absence must not be promoted into
    /// a decision the operator never made.
    @Test("Program Step with no growth stage leaves Step 4 unresolved")
    func programWithoutStageStaysUnresolved() {
        let blockA = UUID()
        var selection = SprayGrowthStageSelection()

        let applied = selection.applyProgramPrefill(
            code: nil,
            stages: stagePairs,
            selectedBlockIds: [blockA]
        )

        #expect(!applied)
        #expect(selection.shared == .unresolved)
        #expect(!selection.isResolved(selectedBlockIds: [blockA]))
    }

    @Test("Unparseable Program growth stage codes are not silently accepted")
    func programWithJunkCodeStaysUnresolved() {
        var selection = SprayGrowthStageSelection()
        let applied = selection.applyProgramPrefill(
            code: "not a stage",
            stages: stagePairs,
            selectedBlockIds: [UUID()]
        )

        #expect(!applied)
        #expect(selection.shared == .unresolved)
    }

    // MARK: - 7/8/9. Per Paddock

    @Test("Per Paddock with an actual stage on every block completes Step 4")
    func perBlockAllStagesCompletes() throws {
        let a1 = UUID(), a2 = UUID()
        var selection = SprayGrowthStageSelection(mode: .perPaddock)
        selection.select(blockId: a1, decision: .stage(try stage(12).id))
        selection.select(blockId: a2, decision: .stage(try stage(9).id))

        #expect(selection.isResolved(selectedBlockIds: [a1, a2]))
    }

    /// The rule is "every selected block has been DECIDED", not "every selected
    /// block has an E-L stage".
    @Test("Per Paddock EL12 / EL9 / Not Set completes Step 4")
    func perBlockMixedWithNotSetCompletes() throws {
        let a1 = UUID(), a2 = UUID(), b1 = UUID()
        var selection = SprayGrowthStageSelection(mode: .perPaddock)
        selection.select(blockId: a1, decision: .stage(try stage(12).id))
        selection.select(blockId: a2, decision: .stage(try stage(9).id))
        selection.select(blockId: b1, decision: .notSet)

        #expect(selection.isResolved(selectedBlockIds: [a1, a2, b1]))
        #expect(selection.stageId(for: b1) == nil)
        #expect(selection.resolvedCount(selectedBlockIds: [a1, a2, b1]) == 3)
    }

    @Test("Per Paddock with one untouched block leaves Step 4 incomplete")
    func perBlockOneUntouchedIsIncomplete() throws {
        let a1 = UUID(), b1 = UUID()
        var selection = SprayGrowthStageSelection(mode: .perPaddock)
        selection.select(blockId: a1, decision: .stage(try stage(12).id))

        #expect(!selection.isResolved(selectedBlockIds: [a1, b1]))
        #expect(selection.resolvedCount(selectedBlockIds: [a1, b1]) == 1)
    }

    // MARK: - 10/11. Block-selection changes

    @Test("A newly added block starts unresolved and reopens Step 4")
    func newBlockIsUnresolved() throws {
        let a1 = UUID()
        var selection = SprayGrowthStageSelection(mode: .perPaddock)
        selection.select(blockId: a1, decision: .stage(try stage(12).id))
        #expect(selection.isResolved(selectedBlockIds: [a1]))

        let c3 = UUID()
        #expect(selection.decision(for: c3) == .unresolved)
        #expect(!selection.isResolved(selectedBlockIds: [a1, c3]))
    }

    @Test("Deselecting an unanswered block removes its blocker")
    func removedBlockStopsBlocking() throws {
        let a1 = UUID(), b1 = UUID()
        var selection = SprayGrowthStageSelection(mode: .perPaddock)
        selection.select(blockId: a1, decision: .stage(try stage(12).id))
        #expect(!selection.isResolved(selectedBlockIds: [a1, b1]))

        // B1 is deselected.
        #expect(selection.isResolved(selectedBlockIds: [a1]))
        selection.prune(to: [a1])
        #expect(selection.perBlock[b1] == nil)
        // The decision for a block that is STILL selected survives pruning.
        #expect(selection.perBlock[a1]?.stageId == (try stage(12).id))
    }

    /// Switching modes must not turn silence into a decision.
    @Test("Switching modes copies a real stage down but never an unresolved one")
    func modeSwitchDoesNotInventDecisions() throws {
        let a1 = UUID(), a2 = UUID()

        var undecided = SprayGrowthStageSelection()
        undecided.setMode(.perPaddock, selectedBlockIds: [a1, a2])
        undecided.setMode(.same, selectedBlockIds: [a1, a2])
        #expect(undecided.perBlock.isEmpty)

        var notSet = SprayGrowthStageSelection()
        notSet.selectSharedNotSet(selectedBlockIds: [a1, a2])
        notSet.setMode(.perPaddock, selectedBlockIds: [a1, a2])
        #expect(!notSet.isResolved(selectedBlockIds: [a1, a2]))

        var staged = SprayGrowthStageSelection()
        staged.selectShared(stageId: try stage(12).id, selectedBlockIds: [a1, a2])
        staged.setMode(.perPaddock, selectedBlockIds: [a1, a2])
        #expect(staged.isResolved(selectedBlockIds: [a1, a2]))
        #expect(staged.stageId(for: a2) == (try stage(12).id))
    }

    // MARK: - 12. Presentation

    @Test("Explicit Not Set collapses to \"Not Set\", never \"Select\"")
    func notSetPresentation() throws {
        let a1 = UUID(), b1 = UUID()

        var shared = SprayGrowthStageSelection()
        shared.selectSharedNotSet(selectedBlockIds: [a1])
        #expect(
            shared.summary(selectedBlockIds: [a1], stageLabel: label)
                == SprayGrowthStageCopy.notSet
        )

        var perBlock = SprayGrowthStageSelection(mode: .perPaddock)
        perBlock.select(blockId: b1, decision: .notSet)
        #expect(perBlock.blockLabel(for: b1, stageCode: code) == SprayGrowthStageCopy.notSet)
        #expect(perBlock.blockLabel(for: b1, stageCode: code) != SprayGrowthStageCopy.selectPlaceholder)
        // An untouched block still reads "Select".
        #expect(perBlock.blockLabel(for: a1, stageCode: code) == SprayGrowthStageCopy.selectPlaceholder)
    }

    @Test("A chosen stage collapses to its code and name")
    func stagePresentation() throws {
        let a1 = UUID()
        let el12 = try stage(12)
        var selection = SprayGrowthStageSelection()
        selection.selectShared(stageId: el12.id, selectedBlockIds: [a1])

        #expect(
            selection.summary(selectedBlockIds: [a1], stageLabel: label)
                == "\(el12.code) — \(el12.name)"
        )
        #expect(selection.blockLabel(for: a1, stageCode: code) == el12.code)
    }

    @Test("Per Paddock summary counts decisions, not stages")
    func perBlockSummaryCountsDecisions() throws {
        let a1 = UUID(), a2 = UUID(), b1 = UUID()
        var selection = SprayGrowthStageSelection(mode: .perPaddock)
        selection.select(blockId: a1, decision: .stage(try stage(12).id))
        selection.select(blockId: b1, decision: .notSet)

        #expect(
            selection.summary(selectedBlockIds: [a1, a2, b1], stageLabel: label)
                == "Per block — 2/3 decided"
        )
    }

    // MARK: - 13/14. Guided flow consequences

    @Test("Equipment unlocks once the growth-stage decision is made")
    func equipmentUnlocksAfterDecision() {
        let locked = SprayGuidedFlow(inputs: inputs(growthStageResolved: false))
        #expect(!locked.isUnlocked(.equipment))
        #expect(locked.activeStep == .growthStage)

        let unlocked = SprayGuidedFlow(inputs: inputs(growthStageResolved: true))
        #expect(unlocked.isUnlocked(.equipment))
        #expect(unlocked.isComplete(.growthStage))
    }

    @Test("Review stops reporting a growth-stage blocker after an explicit decision")
    func reviewBlockerClears() {
        let blocked = SprayGuidedFlow(inputs: inputs(growthStageResolved: false))
        #expect(blocked.firstBlocker == .growthStageRequired)
        #expect(!blocked.isComplete)
        #expect(!blocked.isUnlocked(.review))

        let resolved = SprayGuidedFlow(inputs: inputs(growthStageResolved: true))
        #expect(resolved.firstBlocker == nil)
        #expect(resolved.isComplete)
        #expect(resolved.isUnlocked(.review))
    }

    /// The old wording told the operator to set a stage, which is not what the
    /// step actually requires — and directly contradicted the Not Set option
    /// sitting on the screen.
    @Test("The growth-stage blocker asks for a decision, not for a stage")
    func blockerWording() {
        let blocker = SprayGuidedBlocker.growthStageRequired
        #expect(blocker.title == "Choose growth stage or Not Set")
        #expect(blocker.message.contains("Not Set"))
        #expect(!blocker.needsBlockEditor)
    }

    // MARK: - Scope guard

    /// Growth Stage became decision-based; nothing else did.
    @Test("Other required steps are unaffected by the growth-stage change")
    func otherStepsStillRequired() {
        var noBlocks = inputs(growthStageResolved: true)
        noBlocks.blocks = []
        #expect(SprayGuidedFlow(inputs: noBlocks).blocker(for: .blocks) == .noBlocksSelected)

        var noTarget = inputs(growthStageResolved: true)
        noTarget.targets = []
        #expect(SprayGuidedFlow(inputs: noTarget).blocker(for: .target) == .noTargetSelected)

        var noEquipment = inputs(growthStageResolved: true)
        noEquipment.isEquipmentSelected = false
        #expect(SprayGuidedFlow(inputs: noEquipment).blocker(for: .equipment) == .equipmentRequired)

        var noCarrier = inputs(growthStageResolved: true)
        noCarrier.litresPerHectare = nil
        #expect(SprayGuidedFlow(inputs: noCarrier).blocker(for: .carrier) == .carrierRateRequired)

        var noProducts = inputs(growthStageResolved: true)
        noProducts.products = []
        #expect(SprayGuidedFlow(inputs: noProducts).blocker(for: .products) == .noProductsAdded)
    }

    /// With no blocks chosen there is nothing to have a growth stage FOR, so
    /// the step cannot be satisfied — unchanged from before the fix.
    @Test("With no blocks selected the growth-stage step cannot be satisfied")
    func noBlocksMeansUnresolved() {
        var selection = SprayGrowthStageSelection()
        selection.selectSharedNotSet(selectedBlockIds: [])

        #expect(!selection.isResolved(selectedBlockIds: []))
        #expect(
            selection.summary(selectedBlockIds: [], stageLabel: label)
                == SprayGrowthStageCopy.selectBlocksFirst
        )
    }
}

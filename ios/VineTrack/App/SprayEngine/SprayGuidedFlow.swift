import Foundation

/// The ordered decisions in the guided Spray Calculator.
///
/// ```text
/// Application → Blocks → Target → Growth Stage → Equipment → Canopy & Spray Volume → Products → Review
/// ```
///
/// The canopy belongs in step 6, before Products, because it is what the
/// products are measured against. Discovering it only after choosing a
/// chemical — by meeting an "Unavailable" quantity and going looking for the
/// reason — is the wrong way round.
///
/// Shared verbatim by iOS and Android so an operator moving between platforms
/// meets the same decisions in the same order.
nonisolated enum SprayGuidedStep: String, Sendable, CaseIterable, Identifiable, Comparable {
    case application
    case blocks
    case target
    case growthStage
    case equipment
    case carrier
    case products
    case review

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "Application"
        case .blocks: return "Blocks"
        case .target: return "Target"
        case .growthStage: return "Growth Stage"
        case .equipment: return "Equipment"
        case .carrier: return "Canopy & Spray Volume"
        case .products: return "Products"
        case .review: return "Review"
        }
    }

    var iconName: String {
        switch self {
        case .application: return "square.grid.2x2"
        case .blocks: return "map"
        case .target: return "scope"
        case .growthStage: return "leaf.fill"
        case .equipment: return "wrench.and.screwdriver"
        case .carrier: return "drop.fill"
        case .products: return "flask.fill"
        case .review: return "checkmark.seal"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    nonisolated static func < (lhs: SprayGuidedStep, rhs: SprayGuidedStep) -> Bool {
        lhs.order < rhs.order
    }
}

/// Why a step cannot be completed yet. Each case names the ONE thing to fix, so
/// the UI never has to invent guidance.
nonisolated enum SprayGuidedBlocker: Sendable, Hashable {
    case noBlocksSelected
    /// Canonical geometry is incomplete for a calculation that needs row metres.
    case blockSetupRequired(message: String, blockIds: [String])
    case noTargetSelected
    case sprayHeadTargetRequired
    case bandWidthRequired
    /// Band width was entered but the geometry still cannot yield treated area.
    case treatedAreaUnavailable
    /// The growth-stage DECISION has not been made. An actual E-L stage is
    /// optional — explicitly choosing Not Set satisfies this step.
    case growthStageRequired
    case equipmentRequired
    /// The canopy is still showing the controls' opening position rather than a
    /// choice anybody made.
    case canopyConfirmationRequired
    /// The operator has not said whether the sprayer applies the recommended
    /// dilute volume or its own calibrated output.
    case sprayVolumeChoiceRequired
    case carrierRateRequired
    case carrierNotCalculable
    case noProductsAdded
    /// Product lines whose basis input is unavailable (names for the message).
    case unresolvedProducts(names: [String])
    /// A product is rated per TREATED hectare but the band geometry cannot yield
    /// a treated area. Named separately from `unresolvedProducts` because the fix
    /// is specific: complete the band width or the block's row geometry.
    case treatedAreaBasisUnavailable(names: [String])
    /// A banded pass has area-rated products whose area scope nobody has
    /// confirmed. The operator must say whether the label rate applies to the
    /// whole block or only the treated band.
    case productAreaBasisRequired(names: [String])

    var title: String {
        switch self {
        case .noBlocksSelected: return "Select blocks"
        case .blockSetupRequired: return "Block setup required"
        case .noTargetSelected: return "Choose a target"
        case .sprayHeadTargetRequired: return "Choose a spray head target"
        case .bandWidthRequired: return "Enter treated band width"
        case .treatedAreaUnavailable: return "Treated area unavailable"
        case .growthStageRequired: return "Choose growth stage or Not Set"
        case .equipmentRequired: return "Select spray unit"
        case .canopyConfirmationRequired: return "Select canopy type, size and density"
        case .sprayVolumeChoiceRequired: return "Choose your spray volume"
        case .carrierRateRequired: return "Enter carrier volume"
        case .carrierNotCalculable: return "Carrier volume unavailable"
        case .noProductsAdded: return "Add products"
        case .unresolvedProducts: return "Product rate unavailable"
        case .treatedAreaBasisUnavailable: return "Treated area required"
        case .productAreaBasisRequired: return "Choose an area basis"
        }
    }

    var message: String {
        switch self {
        case .noBlocksSelected:
            return "Select at least one block to calculate this spray."
        case let .blockSetupRequired(message, _):
            return message
        case .noTargetSelected:
            return "Select what this spray is targeting."
        case .sprayHeadTargetRequired:
            return "Choose where the spray head is aimed."
        case .bandWidthRequired:
            return "Enter the total treated band width per row, in metres."
        case .treatedAreaUnavailable:
            return "Row spacing or vineyard row geometry is incomplete for this calculation."
        case .growthStageRequired:
            return "Choose an E-L growth stage for the selected blocks, or choose Not Set."
        case .equipmentRequired:
            return "Select the spray unit used for this application."
        case .canopyConfirmationRequired:
            return "Choose the canopy type, size and density for this spray. They set "
                + "the dilute / runoff rate every per-100 L product is measured against, "
                + "so VineTrack will not assume them for you."
        case .sprayVolumeChoiceRequired:
            return "Say whether your sprayer will apply the recommended dilute volume "
                + "or its own calibrated rate."
        case .carrierRateRequired:
            return "Enter the carrier volume for this application."
        case .carrierNotCalculable:
            return "Row spacing or vineyard row geometry is incomplete for this calculation."
        case .noProductsAdded:
            return "Add at least one product to the tank mix."
        case let .unresolvedProducts(names):
            return "Cannot calculate \(names.joined(separator: ", ")). Check the rate basis and block geometry."
        case let .treatedAreaBasisUnavailable(names):
            return "Complete the band width and block geometry before using a Treated Area "
                + "product rate for \(names.joined(separator: ", "))."
        case let .productAreaBasisRequired(names):
            return "This is a banded application. Choose whether \(names.joined(separator: ", ")) "
                + "applies to the whole block area or only the treated band area."
        }
    }

    /// True when the operator has to leave the calculator and fix block setup.
    var needsBlockEditor: Bool {
        switch self {
        case .blockSetupRequired, .treatedAreaUnavailable, .carrierNotCalculable,
             .treatedAreaBasisUnavailable:
            return true
        default: return false
        }
    }
}

/// Everything the operator has entered. Plain data, no derived values — every
/// calculated figure comes back out through `SprayGuidedFlow.plan`.
nonisolated struct SprayGuidedInputs: Sendable {
    var sprayName: String = ""
    var operationType: OperationType = .foliarSpray

    /// Canonical geometry inputs for the selected blocks.
    var blocks: [SprayBlockInput] = []

    var targets: Set<SprayTarget> = []
    /// Targets carried from a Program Step that VineTrack has no typed case for,
    /// as stable identifiers.
    ///
    /// Pure passenger data: the planner never reads it and no calculation
    /// changes because of it. It exists so a spray planned from a step that is
    /// for Phomopsis still SAYS it is for Phomopsis, rather than arriving with
    /// no stated target — or, worse, coerced onto a built-in target it is not.
    var customTargets: [String] = []
    var sprayHeadTarget: SprayHeadTarget?
    /// Total treated band width per row, metres. Banded applications only.
    var bandWidthTotalMetres: Double?

    /// Whether the growth-stage DECISION has been made — not whether a stage
    /// value exists.
    ///
    /// An operator who deliberately chooses "Not Set" has answered the
    /// question, so this is `true` while the recorded stage stays `nil`. The
    /// two facts are independent, and nothing downstream may invent a stage to
    /// satisfy the step.
    var isGrowthStageResolved: Bool = false
    var isEquipmentSelected: Bool = false
    var tankCapacityLitres: Double = 0

    /// Whether the canopy on screen is a DECISION rather than the controls'
    /// opening position.
    ///
    /// Carried as its own flag rather than inferred from the values, because
    /// nothing about Medium / Low distinguishes "the operator looked at their
    /// vines and chose this" from "nobody has been asked yet". Same shape as
    /// `isGrowthStageResolved`, and for the same reason.
    var isCanopyConfirmed: Bool = false

    /// The canopy, including its training system and whether it was chosen.
    ///
    /// `nil` for a caller that predates the Canopy & Spray Volume step. The
    /// legacy `dilute*` inputs below then apply exactly as before, which is
    /// what keeps historical records and existing tests reproducing their
    /// original numbers.
    var canopy: SprayCanopySelection?
    /// The vineyard's own canopy water-rate table.
    var canopyWaterRates: CanopyWaterRateEntry = .defaults
    /// Whether the sprayer applies the recommended dilute volume, or its own.
    var sprayVolumeChoice: SprayVolumeChoice = .undecided
    /// The machine's calibrated output, as typed. Retained across canopy
    /// changes so re-choosing a canopy never wipes the operator's figure.
    var customSprayerRate: Double?
    /// The unit `customSprayerRate` was entered in — normally the vineyard's
    /// spray volume basis. One value, one unit, converted centrally.
    var customSprayerBasis: SprayCarrierBasis = .litresPerHectare

    var carrierBasis: SprayCarrierBasis = .litresPerHectare
    /// L/ha mode: the rate the operator entered.
    var litresPerHectare: Double?
    /// L/ha mode: the dilute/runoff reference used for concentration, when the
    /// existing canopy water-rate table supplies one.
    var diluteLitresPerHectare: Double?
    /// L/100 m mode: dilute/runoff reference rate.
    var diluteLitresPer100Metres: Double?
    /// L/100 m mode: the actual applied rate.
    var appliedLitresPer100Metres: Double?

    var products: [SprayProductLineInput] = []
    var notes: String = ""

    init() {}
}

/// The guided Spray Calculator's derived state.
///
/// # Single calculation authority
///
/// This type is the ONLY bridge between operator input and
/// `SprayApplicationPlanner.plan`. The View reads `plan` and formats it. The
/// View never computes row length, treated area, concentration factor, total
/// carrier, derived L/ha or product totals — if a number is displayed, it came
/// out of the plan.
///
/// A plan is built on EVERY evaluation, even before the carrier step is valid,
/// using a zero-litre placeholder carrier. That is what lets step 3 preview
/// gross and treated hectares the instant a band width is typed without opening
/// a second arithmetic path: treated area does not depend on carrier volume, so
/// the placeholder cannot change it. Per-100 L product lines correctly report
/// `isUnresolved` until a real carrier exists.
///
/// # Progressive disclosure
///
/// `unlockedSteps` / `activeStep` are derived, not stored, so the UI cannot
/// drift from the validation rules. A step unlocks only when every step before
/// it is complete.
nonisolated struct SprayGuidedFlow: Sendable {
    let inputs: SprayGuidedInputs
    let profile: SprayVineyardProfile

    init(inputs: SprayGuidedInputs, profile: SprayVineyardProfile = SprayVineyardProfile()) {
        self.inputs = inputs
        self.profile = profile
    }

    // MARK: - Application mode

    /// Maps the operator-facing operation type onto the engine's mode.
    ///
    /// Spreader is a whole-block application: it has no band geometry and no
    /// canopy target, so it resolves treated area exactly like a foliar pass.
    var mode: SprayApplicationMode {
        switch inputs.operationType {
        case .bandedSpray: return .banded
        case .foliarSpray, .spreader: return .wholeBlock
        }
    }

    /// True when this application needs a spray head target (foliar only).
    var requiresSprayHeadTarget: Bool { inputs.operationType == .foliarSpray }

    /// True when this application needs a treated band width (banded only).
    var requiresBandWidth: Bool { inputs.operationType == .bandedSpray }

    /// True when canopy-specific settings apply. Spreader has no canopy.
    var supportsCanopySettings: Bool { inputs.operationType != .spreader }

    /// True when this application may not proceed on an unconfirmed canopy.
    ///
    /// A foliar spray is the case where the canopy decides the answer: dilute /
    /// runoff comes from the canopy table, the concentration factor comes from
    /// dilute, and every per-100 L product dose comes from the factor. A
    /// spreader has no canopy at all, and a banded pass is governed by its band
    /// width — neither is gated here, because a prompt raised where it cannot
    /// change the arithmetic is a prompt operators learn to dismiss.
    var requiresCanopyConfirmation: Bool { inputs.operationType == .foliarSpray }

    /// Whether the canopy has actually been answered — training system
    /// included. Falls back to the legacy flag when no canopy is supplied.
    var isCanopyAnswered: Bool {
        inputs.canopy?.isConfirmed ?? inputs.isCanopyConfirmed
    }

    /// True when a foliar spray still needs its canopy answered.
    var isCanopyOutstanding: Bool {
        requiresCanopyConfirmation && !isCanopyAnswered
    }

    /// True when a training system has yet to be chosen. Distinct from the
    /// size/density question so the screen can name the one that is missing.
    var isCanopyTypeOutstanding: Bool {
        guard requiresCanopyConfirmation, let canopy = inputs.canopy else { return false }
        return canopy.type == nil
    }

    // MARK: - Recommended volume vs actual sprayer output

    /// THE recommended-versus-actual decision.
    ///
    /// Single authority for the CF 1.00 reference volume, the machine's actual
    /// output, and the concentration factor between them. Both carrier bases
    /// read this one value, so the two screens cannot disagree.
    var volumeDecision: SprayVolumeDecision? {
        guard let canopy = inputs.canopy else { return nil }
        return SprayVolumeDecisionResolver.decide(
            canopy: canopy,
            settings: inputs.canopyWaterRates,
            rowSpacingMetres: geometry.uniformRowSpacingMetres,
            choice: inputs.sprayVolumeChoice,
            customRate: inputs.customSprayerRate,
            customBasis: inputs.customSprayerBasis
        )
    }

    /// True when the operator has not yet said whether the sprayer will apply
    /// the recommended volume.
    var isSprayVolumeChoiceOutstanding: Bool {
        guard requiresCanopyConfirmation, inputs.canopy != nil, isCanopyAnswered else { return false }
        return inputs.sprayVolumeChoice == .undecided
    }

    // MARK: - Application intent

    /// The spray head target that actually applies, which is `nil` for anything
    /// that is not a foliar pass.
    ///
    /// This is where "changing Foliar → Banded clears the spray head target" is
    /// enforced. Doing it here rather than only in the screens means a stale
    /// value can never reach the snapshot even if a UI forgets to reset its own
    /// state — the persisted record cannot claim a banded pass was aimed at the
    /// bunch line. The same rule already governs `bandWidth` in the other
    /// direction.
    var effectiveSprayHeadTarget: SprayHeadTarget? {
        requiresSprayHeadTarget ? inputs.sprayHeadTarget : nil
    }

    /// The operator's targets in stable presentation order, de-duplicated.
    var orderedTargets: [SprayTarget] {
        SprayTarget.presentationOrder.filter(inputs.targets.contains)
    }

    // MARK: - Carrier policy

    /// Which carrier bases this vineyard may enter.
    var carrierPolicy: SprayCarrierVolumePolicy { profile.resolvedPolicy }

    /// True when the vineyard profile leaves no choice, so the UI must not offer
    /// one. An NZ/SWNZ vineyard is locked to L/100 m.
    var isCarrierBasisLocked: Bool { profile.isCarrierBasisLocked }

    /// The basis actually in force: the operator's choice when the profile
    /// allows either, otherwise whatever the profile mandates.
    var effectiveCarrierBasis: SprayCarrierBasis {
        carrierPolicy.allows(inputs.carrierBasis) ? inputs.carrierBasis : carrierPolicy.defaultBasis
    }

    // MARK: - Geometry

    /// Canonical geometry for the current selection. The single source of truth
    /// for row length and row spacing in this screen.
    var geometry: SprayApplicationGeometry {
        SprayGeometryResolver.resolve(inputs.blocks)
    }

    /// True when the chosen workflow genuinely needs canonical row metres.
    ///
    /// A banded application needs them for treated area; an L/100 m carrier
    /// needs them for total litres. A whole-block L/ha spray does not, so a
    /// block with area but no row spacing must NOT be blocked out of that path.
    var requiresCanonicalRowLength: Bool {
        mode == .banded || effectiveCarrierBasis == .litresPer100Metres
    }

    private var hasBlocks: Bool { !inputs.blocks.isEmpty }

    private var hasGrossArea: Bool { geometry.grossAreaHectares > 0 }

    // MARK: - Carrier volume

    /// The resolved carrier volume, or `nil` when it is not calculable yet.
    ///
    /// Built only by `SprayCarrierVolumeCalculator`; the flow never does the
    /// arithmetic itself.
    var carrier: SprayCarrierVolume? {
        switch effectiveCarrierBasis {
        case .litresPerHectare:
            guard let rate = Self.positive(inputs.litresPerHectare) else { return nil }
            // ONE definition of concentration, shared with the row-length
            // branch. Computing it here — even identically — is how the two
            // bases drifted apart in the first place.
            let dilute = Self.positive(inputs.diluteLitresPerHectare)
            let factor = SprayCarrierConversion.concentrationFactor(dilute: dilute, actual: rate)
            return SprayCarrierVolumeCalculator.perHectare(
                litresPerHectare: rate,
                areaHectares: geometry.grossAreaHectares,
                concentrationFactor: factor,
                diluteLitresPerHectare: dilute,
                rowLengthMetres: geometry.totalRowLengthMetres,
                rowSpacingMetres: geometry.uniformRowSpacingMetres
            )
        case .litresPer100Metres:
            guard let applied = Self.positive(inputs.appliedLitresPer100Metres) else { return nil }
            return SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: applied,
                diluteLitresPer100Metres: Self.positive(inputs.diluteLitresPer100Metres),
                geometry: geometry
            )
        }
    }

    /// A zero-litre stand-in so a plan can always be produced for preview.
    ///
    /// Deliberately zero rather than a guess: a per-100 L product measured
    /// against it resolves to `nil` (unresolved) instead of a fabricated dose.
    private var placeholderCarrier: SprayCarrierVolume {
        SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 0,
            areaHectares: geometry.grossAreaHectares,
            rowLengthMetres: geometry.totalRowLengthMetres,
            rowSpacingMetres: geometry.uniformRowSpacingMetres
        )
    }

    /// True when the carrier volume is fully resolved and usable.
    var isCarrierResolved: Bool { (carrier?.totalLitres ?? 0) > 0 }

    // MARK: - Band width

    /// The band width to feed the engine, only when it is genuinely valid.
    var bandWidth: SprayBandWidth? {
        guard requiresBandWidth, let total = Self.positive(inputs.bandWidthTotalMetres) else { return nil }
        return .total(total)
    }

    // MARK: - THE plan

    /// THE canonical calculation for the current inputs.
    ///
    /// Always non-nil so the UI has one thing to read at every stage. Before the
    /// carrier step is valid it is built on the zero-litre placeholder, which
    /// affects only carrier-dependent figures.
    var plan: SprayApplicationPlan {
        SprayApplicationPlanner.plan(
            blocks: inputs.blocks,
            mode: mode,
            bandWidth: bandWidth,
            carrier: carrier ?? placeholderCarrier,
            tankCapacityLitres: inputs.tankCapacityLitres,
            productLines: inputs.products
        )
    }

    /// The plan to PERSIST — only once the flow is genuinely complete, so a
    /// half-entered spray can never be frozen into a compliance record.
    var persistablePlan: SprayApplicationPlan? {
        isComplete ? plan : nil
    }

    /// The snapshot to hand to the persistence layer.
    ///
    /// Built exclusively by projecting the plan, so the 17 sql/191 + sql/192
    /// columns are never populated from individual UI state variables.
    var snapshot: SprayApplicationSnapshot? {
        guard let plan = persistablePlan else { return nil }
        let snapshot = SprayApplicationSnapshot(
            plan: plan,
            targets: orderedTargets,
            customTargets: inputs.customTargets,
            sprayHeadTarget: effectiveSprayHeadTarget
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    // MARK: - Per-step validation

    /// The blocker for a given step, or `nil` when that step is satisfied.
    func blocker(for step: SprayGuidedStep) -> SprayGuidedBlocker? {
        switch step {
        case .application:
            return nil // An operation type is always selected.

        case .blocks:
            guard hasBlocks else { return .noBlocksSelected }
            if requiresCanonicalRowLength, !geometry.isUsable {
                return .blockSetupRequired(
                    message: geometry.unavailableMessage
                        ?? SprayGeometryUnavailable.missingGeometry.message,
                    blockIds: geometry.unresolvedBlocks.map(\.blockId)
                )
            }
            return nil

        case .target:
            if inputs.targets.isEmpty { return .noTargetSelected }
            if requiresSprayHeadTarget, inputs.sprayHeadTarget == nil {
                return .sprayHeadTargetRequired
            }
            if requiresBandWidth {
                guard bandWidth != nil else { return .bandWidthRequired }
                // Band width is valid but geometry still cannot produce a
                // treated area — say so instead of showing gross as treated.
                if plan.treatedAreaHectares == nil { return .treatedAreaUnavailable }
            }
            return nil

        case .growthStage:
            return inputs.isGrowthStageResolved ? nil : .growthStageRequired

        case .equipment:
            return inputs.isEquipmentSelected ? nil : .equipmentRequired

        case .carrier:
            // The canopy is asked FIRST because everything else in this step is
            // derived from it. Reporting "enter carrier volume" while the canopy
            // is still unanswered names the second question and hides the first.
            if isCanopyOutstanding { return .canopyConfirmationRequired }
            // Asked only once the canopy can actually recommend something —
            // there is nothing to accept or override before that.
            if isSprayVolumeChoiceOutstanding { return .sprayVolumeChoiceRequired }
            // A resolved volume decision IS the carrier volume, so the step is
            // done. Falling through to the legacy `litresPerHectare` /
            // `appliedLitresPer100Metres` fields asked for the same decision a
            // second time in a field the new path never fills: the operator
            // entered 600 L/ha, saw the actual output and CF 1.19× render
            // correctly, and was still told "Enter carrier volume" with Products
            // locked. The fix is to stop asking twice — NOT to copy the value
            // into the old fields, which would put the same decision in two
            // places and invite them to disagree.
            if let decision = volumeDecision, decision.isResolved {
                return isCarrierResolved ? nil : .carrierNotCalculable
            }
            switch effectiveCarrierBasis {
            case .litresPerHectare:
                guard Self.positive(inputs.litresPerHectare) != nil else { return .carrierRateRequired }
            case .litresPer100Metres:
                guard Self.positive(inputs.appliedLitresPer100Metres) != nil else { return .carrierRateRequired }
            }
            return isCarrierResolved ? nil : .carrierNotCalculable

        case .products:
            guard !inputs.products.isEmpty else { return .noProductsAdded }
            // A product rated per TREATED hectare against geometry that cannot
            // produce one is called out specifically, so the operator is never
            // left guessing which of several possible inputs is missing — and is
            // never quietly dosed against gross area instead.
            // A banded pass multiplies an area rate by either gross or treated
            // hectares — several times apart. Refusing to proceed until the
            // operator says which is deliberate: silently defaulting would freeze
            // an unconfirmed guess into a compliance record. Whole-block passes
            // are never ambiguous, so they are never asked.
            if mode == .banded {
                let undecided = inputs.products.filter(\.needsAreaBasisDecision)
                if !undecided.isEmpty {
                    return .productAreaBasisRequired(names: undecided.map(\.name))
                }
            }
            let treatedAreaLines = inputs.products.filter { $0.basis == .treatedArea }
            if !treatedAreaLines.isEmpty, plan.treatedAreaHectares == nil {
                return .treatedAreaBasisUnavailable(names: treatedAreaLines.map(\.name))
            }
            let unresolved = plan.unresolvedProductLines
            guard unresolved.isEmpty else {
                return .unresolvedProducts(names: unresolved.map(\.name))
            }
            return nil

        case .review:
            return nil
        }
    }

    func isComplete(_ step: SprayGuidedStep) -> Bool { blocker(for: step) == nil }

    // MARK: - Progressive disclosure

    /// True when every step before `step` is complete, so `step` may be shown.
    ///
    /// `.application` is always unlocked; nothing else is reachable until the
    /// decisions it depends on have actually been made.
    func isUnlocked(_ step: SprayGuidedStep) -> Bool {
        SprayGuidedStep.allCases
            .filter { $0 < step }
            .allSatisfy(isComplete)
    }

    var unlockedSteps: [SprayGuidedStep] {
        SprayGuidedStep.allCases.filter(isUnlocked)
    }

    /// The first step still needing attention — the one to expand by default.
    /// Every earlier step collapses to a compact summary with an Edit action.
    var activeStep: SprayGuidedStep {
        SprayGuidedStep.allCases.first { !isComplete($0) } ?? .review
    }

    /// Steps that are complete AND behind the active step, so they may collapse.
    func isCollapsible(_ step: SprayGuidedStep) -> Bool {
        step < activeStep && isComplete(step)
    }

    /// Everything up to (but not including) Review is satisfied.
    var isComplete: Bool {
        SprayGuidedStep.allCases
            .filter { $0 < .review }
            .allSatisfy(isComplete)
    }

    /// The first blocker across the whole flow, for the primary action's hint.
    var firstBlocker: SprayGuidedBlocker? {
        SprayGuidedStep.allCases.lazy.compactMap { blocker(for: $0) }.first
    }

    var progressFraction: Double {
        let gated = SprayGuidedStep.allCases.filter { $0 < .review }
        guard !gated.isEmpty else { return 1 }
        return Double(gated.filter(isComplete).count) / Double(gated.count)
    }

    // MARK: - Resistance Check reservation

    /// Whether the future Resistance Check panel has a reason to appear.
    ///
    /// Reserved location only — this task ships NO rules engine and NO warnings.
    /// The flag exists so the panel's insertion point beneath the relevant
    /// chemistry is already decided and both platforms agree on when it applies.
    var isResistanceCheckApplicable: Bool {
        inputs.targets.contains { $0.isFungicideResistanceRelevant }
    }

    // MARK: - Helpers

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

import Foundation

/// Whether an event actually happened, is planned, or is being hypothesised.
///
/// The engine must be able to answer "what if I spray this next?" for a plan that
/// has never been saved, so completion can never be a precondition for evaluation.
/// Equally, a merely planned spray must not silently inflate a seasonal count as
/// though it had been applied.
nonisolated enum ResistanceEventKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// A genuine, completed application. Counts as history.
    case actual
    /// A future spray the operator has scheduled. Recognised now so the Planner
    /// needs no engine change, but excluded from v1 counting unless requested.
    case planned
    /// The spray being assessed right now. Never persisted.
    case candidate

    nonisolated var isHistory: Bool { self == .actual }
}

/// One product line within an application, reduced to what resistance analysis
/// needs.
///
/// Groups arrive here from the FROZEN `ChemicalLineSnapshot` on the spray record —
/// never from today's Chemical Store record. Re-reading the live product would let
/// a classification corrected in 2029 rewrite what the 2026 rotation is said to
/// have been, and every rotation decision derived from it.
nonisolated struct ResistanceProductLine: Codable, Sendable, Hashable, Identifiable {
    nonisolated var lineId: String
    nonisolated var productName: String?
    nonisolated var savedChemicalId: String?
    /// Groups carried by THIS product. Two codes here means a co-formulation.
    nonisolated var groups: ResistanceGroupSignature
    nonisolated var availability: ChemicalIntelligenceAvailability

    nonisolated var id: String { lineId }
    nonisolated var hasGroups: Bool { !groups.codes.isEmpty }

    nonisolated init(
        lineId: String,
        productName: String?,
        savedChemicalId: String?,
        groups: ResistanceGroupSignature,
        availability: ChemicalIntelligenceAvailability
    ) {
        self.lineId = lineId
        self.productName = productName
        self.savedChemicalId = savedChemicalId
        self.groups = groups
        self.availability = availability
    }
}

/// The canonical unit of resistance history: ONE spray application, for ONE block.
///
/// Deliberately not a database model. The engine consumes these and nothing else,
/// which is what lets the identical rule logic serve saved history, an unsaved
/// Guided Spray plan, and a test fixture.
///
/// Mirrors `ResistanceApplicationEvent.kt` on Android.
nonisolated struct ResistanceApplicationEvent: Codable, Sendable, Hashable, Identifiable {
    /// Spray record ID, or a temporary ID for an unsaved candidate.
    nonisolated var applicationId: String
    nonisolated var kind: ResistanceEventKind
    nonisolated var appliedAtEpochMs: Int64
    nonisolated var seasonId: String
    nonisolated var vineyardId: String
    /// The block this event applies to.
    ///
    /// One spray covering three blocks becomes three events — resistance history
    /// belongs to the vines that received the chemistry, and block 1 having had two
    /// Group 11 sprays says nothing about block 3.
    nonisolated var blockId: String
    /// The diseases the operator declared this spray was FOR, from the persisted
    /// `spray_records.targets`.
    ///
    /// Never inferred from the chemistry: a Group 11 product applied purely for
    /// downy mildew must not silently consume the block's powdery mildew Group 11
    /// allowance.
    nonisolated var targets: [ResistanceDisease]
    /// Whether targets were recorded at all.
    ///
    /// False for pre-sql/193 history. Critically different from an empty target
    /// list: "recorded as targeting nothing" is a fact, whereas "never asked" is an
    /// unknown that must suppress a clean result rather than quietly removing the
    /// application from every disease history.
    nonisolated var targetsRecorded: Bool
    nonisolated var products: [ResistanceProductLine]
    /// Whether a partner from an alternative mode of action was present AT A
    /// REGISTERED/EFFECTIVE RATE, when that is genuinely known.
    ///
    /// Nil — the default — means unknown, which is the honest answer from group data
    /// alone. Group codes cannot establish that a tank partner was loaded at a rate
    /// that actually controls the disease, and a mixture requirement is about
    /// efficacy, not the presence of a second code.
    nonisolated var mixturePartnerAtLabelRate: Bool?

    nonisolated var id: String { "\(applicationId)|\(blockId)" }

    nonisolated init(
        applicationId: String,
        kind: ResistanceEventKind,
        appliedAtEpochMs: Int64,
        seasonId: String,
        vineyardId: String,
        blockId: String,
        targets: [ResistanceDisease],
        targetsRecorded: Bool,
        products: [ResistanceProductLine],
        mixturePartnerAtLabelRate: Bool? = nil
    ) {
        self.applicationId = applicationId
        self.kind = kind
        self.appliedAtEpochMs = appliedAtEpochMs
        self.seasonId = seasonId
        self.vineyardId = vineyardId
        self.blockId = blockId
        self.targets = targets
        self.targetsRecorded = targetsRecorded
        self.products = products
        self.mixturePartnerAtLabelRate = mixturePartnerAtLabelRate
    }

    /// Every group present, however it arrived (solo, co-formulated, tank-mixed).
    nonisolated var componentGroups: Set<String> {
        Set(products.flatMap { $0.groups.codes })
    }

    /// Signatures of products carrying more than one group — true co-formulations.
    nonisolated var coformulationSignatures: [ResistanceGroupSignature] {
        products.map(\.groups).filter { $0.isCoformulation }
    }

    /// How far this event's chemistry can be trusted: the WEAKEST of its product
    /// lines, plus `.unavailable` when no product carried usable groups at all.
    ///
    /// Weakest-wins because one unverifiable product in the tank is enough to make
    /// the application's group set uncertain.
    nonisolated var availability: ChemicalIntelligenceAvailability {
        if products.isEmpty || !products.contains(where: { $0.hasGroups }) {
            return .unavailable
        }
        let order: [ChemicalIntelligenceAvailability] = [
            .unavailable, .conflict, .availableUnverified, .availablePartiallyVerified,
            .availableVerified,
        ]
        return products
            .min { (order.firstIndex(of: $0.availability) ?? 0) < (order.firstIndex(of: $1.availability) ?? 0) }?
            .availability ?? .unavailable
    }

    /// Whether this event's chemistry can be reasoned about at all.
    nonisolated var canAssessChemistry: Bool { availability.canAssess }

    nonisolated func targets(_ disease: ResistanceDisease) -> Bool { targets.contains(disease) }

    /// Groups present that are NOT among `groups` — candidate mixture partners from
    /// a different cross-resistance group.
    nonisolated func groupsOtherThan(_ groups: [String]) -> Set<String> {
        componentGroups.filter { !groups.contains($0) }
    }

    /// This event as one classification scheme sees it.
    ///
    /// Applied by the engine before anything is counted, so every rule compares
    /// like with like. A product line whose chemistry belongs to another scheme
    /// keeps its LINE — it was really in the tank, and its verification state still
    /// governs how far the application can be trusted — but contributes no groups,
    /// exactly as an adjuvant does.
    nonisolated func projected(into scheme: ChemicalActivityGroupScheme) -> ResistanceApplicationEvent {
        var projected = self
        projected.products = products.map { product in
            var line = product
            line.groups = product.groups.projected(into: scheme)
            return line
        }
        return projected
    }

    /// Chronological ordering: by instant, then by application ID.
    ///
    /// The ID tie-breaker is what makes results reproducible. Two sprays on the same
    /// date are still two distinct applications (a morning and an afternoon job are
    /// not one spray), and database row order is not a chronology — it changes with
    /// sync.
    nonisolated static func isOrderedBefore(
        _ lhs: ResistanceApplicationEvent,
        _ rhs: ResistanceApplicationEvent
    ) -> Bool {
        if lhs.appliedAtEpochMs != rhs.appliedAtEpochMs {
            return lhs.appliedAtEpochMs < rhs.appliedAtEpochMs
        }
        return lhs.applicationId < rhs.applicationId
    }
}

nonisolated extension Array where Element == ResistanceApplicationEvent {
    nonisolated var chronological: [ResistanceApplicationEvent] {
        sorted(by: ResistanceApplicationEvent.isOrderedBefore)
    }
}

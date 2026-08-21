import Foundation

/// The Live Resistance Check shown while a spray is being planned in the Spray
/// Calculator.
///
/// # This file contains NO resistance rules
///
/// It is an ADAPTER, and deliberately nothing more. It expresses the spray being
/// composed as a one-position `ResistancePlan` and hands it to
/// `ResistancePlanner.evaluatePosition` — the very function the standalone
/// Resistance Planner calls for a position the operator is editing. Groups
/// detected, previous uses, repeat warnings, severity, status and rule results
/// therefore come out of one implementation, not two.
///
/// That indirection is the whole point. A second "is this rotation OK?" written
/// against the Spray Calculator's own state would start life agreeing with the
/// Planner and drift the first time a rule changed — and a vineyard shown "good
/// fit" on one screen and "would exceed strategy" on the other has no reason to
/// believe either.
///
/// # What it decides
///
/// Only WHAT TO ASK: which diseases (the spray's declared targets), which blocks
/// (the ones selected), and which chemistry (the product lines chosen). The
/// answers are the engine's.
nonisolated enum SprayResistanceCheck {

    /// Synthetic plan id for the spray under composition.
    ///
    /// Namespaced so the events it generates can never be mistaken for a saved plan
    /// or a real spray record: `ResistancePlanner.plannedApplicationId` builds
    /// `"plan:spray-calculator-candidate:position:…"`, which no persisted row uses.
    nonisolated static let candidatePlanId = "spray-calculator-candidate"
    nonisolated static let candidatePositionId = "candidate"

    // MARK: - Request

    nonisolated struct Request: Sendable {
        nonisolated var vineyardId: String
        /// Blocks this spray will treat. Each is evaluated against its OWN history.
        nonisolated var blockIds: [String]
        /// The diseases the operator declared this spray is FOR.
        ///
        /// Resistance history is per disease, so a tank addressing powdery and downy
        /// is two separate questions and gets two separate answers. Never inferred
        /// from the chemistry in the tank.
        nonisolated var diseases: [ResistanceDisease]
        /// The products chosen, as planner products so the Planner's own evaluator
        /// can consume them unchanged.
        nonisolated var products: [ResistancePlannedProduct]
        nonisolated var jurisdiction: ResistanceJurisdiction
        nonisolated var crop: ResistanceCrop
        nonisolated var season: ResistanceSeason
        nonisolated var seasonCalendar: ResistanceSeasonCalendar
        /// Every candidate event, any block, any disease, any season. The engine
        /// filters — pre-filtering here would strip the previous-season tail that
        /// cross-season rules need.
        nonisolated var events: [ResistanceApplicationEvent]
        nonisolated var unresolvedApplications: [ResistanceEventSource.UnresolvedBlockApplication]
        nonisolated var registry: ResistanceRulesetRegistry
        nonisolated var nowMs: Int64

        nonisolated init(
            vineyardId: String,
            blockIds: [String],
            diseases: [ResistanceDisease],
            products: [ResistancePlannedProduct],
            jurisdiction: ResistanceJurisdiction,
            crop: ResistanceCrop = .grape,
            season: ResistanceSeason,
            seasonCalendar: ResistanceSeasonCalendar,
            events: [ResistanceApplicationEvent],
            unresolvedApplications: [ResistanceEventSource.UnresolvedBlockApplication] = [],
            registry: ResistanceRulesetRegistry = ResistanceRulesets.registry,
            nowMs: Int64
        ) {
            self.vineyardId = vineyardId
            self.blockIds = blockIds
            self.diseases = diseases
            self.products = products
            self.jurisdiction = jurisdiction
            self.crop = crop
            self.season = season
            self.seasonCalendar = seasonCalendar
            self.events = events
            self.unresolvedApplications = unresolvedApplications
            self.registry = registry
            self.nowMs = nowMs
        }
    }

    // MARK: - Result

    /// The verdict for ONE disease, across every selected block.
    nonisolated struct DiseaseOutcome: Sendable, Identifiable {
        nonisolated var disease: ResistanceDisease
        /// False when no published strategy covers this jurisdiction/crop/disease.
        /// An absent strategy is stated, never rendered as a pass.
        nonisolated var isSupported: Bool
        nonisolated var unsupportedMessage: String?
        nonisolated var strategyName: String?
        /// The classification scheme the governing strategy numbers its groups in.
        /// Carried so a finding can be matched to the product that caused it without
        /// re-resolving the ruleset, and without comparing bare numbers across schemes.
        nonisolated var scheme: ChemicalActivityGroupScheme
        nonisolated var position: ResistancePlanPositionEvaluation?
        /// Real applications in this season whose treated blocks were never recorded
        /// and which could concern this disease.
        nonisolated var unresolvedApplicationCount: Int

        nonisolated var id: String { disease.rawValue }

        nonisolated var status: ResistancePlanPositionStatus {
            guard isSupported else { return .unableToFullyAssess }
            return position?.status ?? .unableToFullyAssess
        }

        nonisolated var blocks: [ResistancePlanBlockOutcome] { position?.blocks ?? [] }

        /// Engine findings across every block, worst first.
        nonisolated var findings: [ResistanceRuleResult] {
            blocks
                .flatMap { $0.evaluation.findings }
                .sorted {
                    ResistanceEvaluation.severityRank($0.severity)
                        > ResistanceEvaluation.severityRank($1.severity)
                }
        }
    }

    nonisolated struct Result: Sendable {
        nonisolated var outcomes: [DiseaseOutcome]
        /// True when the spray declared no resistance-relevant target, or selected no
        /// block, or chose no chemistry. Nothing to say is NOT the same as nothing
        /// wrong, so the caller shows nothing rather than a reassuring panel.
        nonisolated var isApplicable: Bool

        nonisolated var status: ResistancePlanPositionStatus? {
            guard isApplicable, !outcomes.isEmpty else { return nil }
            return ResistancePlanPositionStatus.worst(outcomes.map(\.status))
        }

        nonisolated static let notApplicable = Result(outcomes: [], isApplicable: false)

        /// Signature of each product line, by product id, so a finding can be shown
        /// under the line that carries the group.
        nonisolated var productGroups: [String: ResistanceGroupSignature] = [:]

        /// Findings that concern the groups ONE product line contributes.
        ///
        /// Filtered, never recomputed: the finding is the engine's and this only
        /// decides which line it belongs under, so the operator can see which tin in
        /// the shed a warning is about.
        ///
        /// Codes are compared in the governing strategy's own scheme, so a rule about
        /// FRAC 3 never attaches itself to an IRAC 3 insecticide sharing the number.
        nonisolated func findings(forProductId productId: String) -> [ResistanceRuleResult] {
            guard let signature = productGroups[productId] else { return [] }
            return outcomes.flatMap { outcome -> [ResistanceRuleResult] in
                let groups = Set(signature.projected(into: outcome.scheme).codes)
                guard !groups.isEmpty else { return [] }
                return outcome.findings.filter { !groups.isDisjoint(with: Set($0.groups)) }
            }
        }
    }

    // MARK: - Evaluation

    nonisolated static func evaluate(_ request: Request) -> Result {
        let diseases = request.diseases.uniqued()
        guard !diseases.isEmpty,
              !request.blockIds.isEmpty,
              !request.products.isEmpty
        else { return .notApplicable }

        let position = ResistancePlannedPosition(
            id: candidatePositionId,
            products: request.products
        )

        let outcomes = diseases.map { disease -> DiseaseOutcome in
            let plan = ResistancePlan(
                id: candidatePlanId,
                vineyardId: request.vineyardId,
                seasonId: request.season.id,
                seasonStartYear: request.season.startYear,
                disease: disease,
                jurisdiction: request.jurisdiction,
                crop: request.crop,
                blockIds: request.blockIds,
                positions: [position],
                createdAtEpochMs: request.nowMs,
                updatedAtEpochMs: request.nowMs
            )
            let plannerRequest = ResistancePlanner.Request(
                plan: plan,
                season: request.season,
                seasonCalendar: request.seasonCalendar,
                events: request.events,
                unresolvedApplications: request.unresolvedApplications,
                registry: request.registry
            )
            guard let ruleset = request.registry.current(
                jurisdiction: request.jurisdiction,
                crop: request.crop,
                disease: disease
            ) else {
                return DiseaseOutcome(
                    disease: disease,
                    isSupported: false,
                    unsupportedMessage: ResistancePlanner.unsupportedJurisdictionMessage,
                    strategyName: nil,
                    scheme: .frac,
                    position: nil,
                    unresolvedApplicationCount: 0
                )
            }
            // The Planner's own position evaluator. Everything below this line —
            // counts, repeat warnings, severity, recommendation — is engine output.
            let evaluation = ResistancePlanner.evaluate(plannerRequest)
            return DiseaseOutcome(
                disease: disease,
                isSupported: evaluation.isSupported,
                unsupportedMessage: evaluation.unsupportedMessage,
                strategyName: evaluation.strategyName,
                scheme: ruleset.scheme,
                position: evaluation.positions.first,
                unresolvedApplicationCount: evaluation.unresolvedApplicationCount
            )
        }

        var result = Result(outcomes: outcomes, isApplicable: true)
        result.productGroups = Dictionary(
            request.products.map { ($0.id, $0.groups) },
            uniquingKeysWith: { first, _ in first }
        )
        return result
    }

    // MARK: - Input resolution

    /// A planner product for a chemical the operator has chosen to spray.
    ///
    /// Deliberately reads TODAY's Chemical Store record. The ban on live re-reads
    /// applies to reconstructing what a PAST application contained; this spray has
    /// not happened yet, so the current record is the correct and only source.
    ///
    /// Groups are taken scheme-qualified from structured Chemical Intelligence, so an
    /// HRAC or IRAC classification stays distinguishable from the FRAC group sharing
    /// its number. The bare `activityGroupCodes` array is the fallback only when the
    /// actives carry no classification at all.
    ///
    /// A product with NO usable group resolves to `.unavailable`, never to "no groups
    /// therefore no problem": an unresolved or hand-entered product is precisely the
    /// one that could be breaking the rotation.
    nonisolated static func product(
        from chemical: SavedChemical,
        lineId: String,
        disease: ResistanceDisease?
    ) -> ResistancePlannedProduct {
        let structured = ResistanceGroupSignature.of(
            structured: chemical.resolvedIntelligence.activityGroups
        )
        let groups = structured.codes.isEmpty
            ? ResistanceGroupSignature.of(chemical.activityGroupCodes)
            : structured
        let availability: ChemicalIntelligenceAvailability = groups.codes.isEmpty
            ? .unavailable
            : ChemicalIntelligenceAvailability.from(status: chemical.verificationStatus)
        return ResistancePlannedProduct(
            id: lineId,
            groups: groups,
            source: .savedChemical,
            savedChemicalId: chemical.id.uuidString,
            productName: chemical.name,
            chemicalAvailability: availability,
            registeredForPlannedDisease: disease.flatMap {
                ResistancePlanChemicalSource.registeredUse(chemical: chemical, disease: $0)
            }
        )
    }

    /// The resistance diseases a spray's declared targets map onto.
    ///
    /// Targets with no published strategy (weeds, nutrition, botrytis today) simply
    /// produce no disease, so the check stays silent rather than inventing a verdict
    /// from a strategy that does not exist.
    nonisolated static func diseases(from targets: Set<SprayTarget>) -> [ResistanceDisease] {
        ResistanceDisease.allCases.filter { disease in
            targets.contains { ResistanceDisease.fromSprayTargetRaw($0.rawValue) == disease }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

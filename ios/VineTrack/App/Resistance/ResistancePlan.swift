import Foundation

/// Where a planned position's chemistry identity came from.
///
/// The distinction matters for honesty, not for arithmetic. A stipulated group is
/// something the operator asserted for planning purposes; a saved chemical is a real
/// product whose group identity carries Chemical Intelligence evidence (or does not).
nonisolated enum ResistancePlannedChemistrySource: String, Codable, Sendable, Hashable {
    /// The operator chose FRAC group(s) directly — group-first planning.
    case group
    /// The operator chose a product from the vineyard's Chemical Store.
    case savedChemical = "saved_chemical"
}

/// One product line within a planned position.
///
/// A position holds a LIST of these rather than a single group signature, because
/// `FRAC 11 + 3` is genuinely two different things: one co-formulated product
/// carrying both codes, or two products tank-mixed. The engine treats those
/// differently (`coformulationSignatures` vs `componentGroups`), and flattening them
/// here would make the Planner unable to express a co-formulation rule at all.
nonisolated struct ResistancePlannedProduct: Codable, Sendable, Hashable, Identifiable {

    /// Wire contract. Snake_case and a flat `group_codes` array, byte-identical to
    /// Android's `@SerialName` keys, because this JSON is the shared
    /// `resistance_plans.positions` document — a plan authored on an iPhone is
    /// decoded by an Android device and (later) the portal from the same bytes.
    /// Swift's default `CodingKeys` would have emitted `savedChemicalId` and a
    /// nested `{"groups":{"codes":[...]}}` object, neither of which Android can
    /// read.
    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case groupCodes = "group_codes"
        case source
        case savedChemicalId = "saved_chemical_id"
        case productName = "product_name"
        case chemicalAvailability = "chemical_availability"
        case registeredForPlannedDisease = "registered_for_planned_disease"
    }

    nonisolated var id: String
    /// The groups this single product carries, stored as raw codes so the wire
    /// shape is a plain array on both platforms. More than one code means a
    /// co-formulation, not a tank mix.
    nonisolated var groupCodes: [String]
    nonisolated var source: ResistancePlannedChemistrySource
    nonisolated var savedChemicalId: String?
    nonisolated var productName: String?
    /// Chemical Intelligence availability of the chosen product. Meaningful only for
    /// `.savedChemical`.
    nonisolated var chemicalAvailability: ChemicalIntelligenceAvailability?
    /// Whether structured Chemical Intelligence records a registered use against the
    /// disease being planned.
    ///
    /// Nil means UNKNOWN and is the default. Never inferred from group membership: a
    /// Group 7 product is not thereby registered for powdery mildew on grapes, and
    /// presenting FRAC membership as evidence of efficacy is the exact overstatement
    /// this field exists to prevent.
    nonisolated var registeredForPlannedDisease: Bool?

    /// Normalised signature. Derived rather than stored so a stored code order can
    /// never change an evaluation — exactly the guarantee Android gets from its
    /// own `groups` getter.
    nonisolated var groups: ResistanceGroupSignature {
        get { ResistanceGroupSignature.of(groupCodes) }
        set { groupCodes = newValue.codes }
    }

    nonisolated init(
        id: String = UUID().uuidString,
        groups: ResistanceGroupSignature,
        source: ResistancePlannedChemistrySource,
        savedChemicalId: String? = nil,
        productName: String? = nil,
        chemicalAvailability: ChemicalIntelligenceAvailability? = nil,
        registeredForPlannedDisease: Bool? = nil
    ) {
        self.id = id
        self.groupCodes = groups.codes
        self.source = source
        self.savedChemicalId = savedChemicalId
        self.productName = productName
        self.chemicalAvailability = chemicalAvailability
        self.registeredForPlannedDisease = registeredForPlannedDisease
    }

    /// The availability the engine should reason from.
    ///
    /// A STIPULATED GROUP IS TREATED AS DEPENDABLE, and that deserves justification:
    /// there is no product identity to verify. The operator has declared "position 4
    /// will be a Group 7 spray", and for the purpose of arithmetic on the planned
    /// sequence that group is a premise, not an observation that could be wrong.
    /// Downgrading it would make every group-first plan report "unable to fully
    /// assess", which would defeat the entire point of planning by group — and would
    /// wrongly imply the doubt lies in the plan when it actually lies in the history.
    ///
    /// A chosen PRODUCT is different: its group identity is a claim about a real
    /// label, so its recorded availability is carried through unchanged, and an
    /// unverified or conflicting product keeps its caveat all the way into the
    /// evaluation.
    nonisolated var effectiveAvailability: ChemicalIntelligenceAvailability {
        switch source {
        case .group:
            return .availableVerified
        case .savedChemical:
            return chemicalAvailability ?? .unavailable
        }
    }

    /// Display label: the product name when one was chosen, otherwise the group.
    nonisolated var displayLabel: String {
        if let name = productName, !name.isEmpty { return name }
        return groups.displayLabel
    }
}

/// One future spray slot in a plan.
///
/// A planning position, NOT a spray record. It is never written to `spray_records`,
/// carries no tank or volume, and cannot be mistaken for history because the engine
/// only ever sees it as `.planned` or `.candidate`.
nonisolated struct ResistancePlannedPosition: Codable, Sendable, Hashable, Identifiable {

    /// Wire contract — snake_case, identical to Android. See
    /// `ResistancePlannedProduct.CodingKeys`.
    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case products
        case targetDateEpochMs = "target_date_epoch_ms"
        case growthStage = "growth_stage"
        case note
    }

    /// Stable identity, generated once and preserved across reorders, edits and
    /// persistence.
    ///
    /// This is the seam for plan-vs-actual comparison. When a real spray is eventually
    /// associated with a planned position, it will point at this id — which is why the
    /// id must survive a reorder that changes the position's number. "Spray 4" is a
    /// display ordinal, not an identity.
    nonisolated var id: String
    nonisolated var products: [ResistancePlannedProduct]
    /// Optional target timing. Display metadata only — see `ResistancePlanner`, which
    /// derives chronology from plan ORDER so a stale date can never contradict the
    /// sequence the operator is looking at.
    nonisolated var targetDateEpochMs: Int64?
    /// Optional growth-stage label, where the vineyard's existing models make one
    /// easy to name.
    nonisolated var growthStage: String?
    nonisolated var note: String?

    nonisolated init(
        id: String = UUID().uuidString,
        products: [ResistancePlannedProduct] = [],
        targetDateEpochMs: Int64? = nil,
        growthStage: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.products = products
        self.targetDateEpochMs = targetDateEpochMs
        self.growthStage = growthStage
        self.note = note
    }

    /// True when no chemistry has been chosen yet — a slot the operator has created
    /// but not filled.
    nonisolated var isEmpty: Bool { products.isEmpty || !products.contains { !$0.groups.codes.isEmpty } }

    /// Every group in this position, however it arrives.
    nonisolated var componentGroups: Set<String> {
        Set(products.flatMap { $0.groups.codes })
    }

    /// Operator-facing chemistry label, e.g. `"FRAC 11 + 3"`.
    ///
    /// Built from the position's own product signatures so a co-formulation and a
    /// tank mix of the same two codes read the same way to a human while remaining
    /// distinct to the engine.
    nonisolated var groupsLabel: String {
        let codes = ResistanceGroupSignature.of(Array(componentGroups)).codes
        guard !codes.isEmpty else { return "No chemistry selected" }
        return "FRAC " + codes.joined(separator: " + ")
    }

    /// The weakest availability among the chosen products, mirroring the engine's
    /// weakest-wins rule: one untrustworthy product makes the position's group set
    /// uncertain.
    nonisolated var effectiveAvailability: ChemicalIntelligenceAvailability {
        guard !products.isEmpty else { return .unavailable }
        let order: [ChemicalIntelligenceAvailability] = [
            .unavailable, .conflict, .availableUnverified, .availablePartiallyVerified,
            .availableVerified,
        ]
        return products
            .min { (order.firstIndex(of: $0.effectiveAvailability) ?? 0) < (order.firstIndex(of: $1.effectiveAvailability) ?? 0) }?
            .effectiveAvailability ?? .unavailable
    }

    /// Products whose FRAC identity may not be relied on without saying so.
    nonisolated var productsRequiringCaveat: [ResistancePlannedProduct] {
        products.filter { $0.source == .savedChemical && $0.effectiveAvailability.requiresQualification }
    }
}

/// A season-long resistance plan for one disease across one or more blocks.
///
/// PERSISTENCE: v1 is local to the device (see `ResistancePlanStore`). The model is
/// `Codable` and carries a vineyard id, stable position ids and the governing ruleset
/// version specifically so it can move to server storage without a shape change.
nonisolated struct ResistancePlan: Codable, Sendable, Hashable, Identifiable {

    /// Wire contract — snake_case, identical to Android, and identical to the
    /// `resistance_plans` column names so the row and the document agree.
    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case seasonId = "season_id"
        case seasonStartYear = "season_start_year"
        case disease
        case jurisdiction
        case crop
        case blockIds = "block_ids"
        case positions
        case notes
        case rulesetId = "ruleset_id"
        case rulesetVersion = "ruleset_version"
        case createdBy = "created_by"
        case createdAtEpochMs = "created_at_epoch_ms"
        case updatedAtEpochMs = "updated_at_epoch_ms"
        case deletedAtEpochMs = "deleted_at_epoch_ms"
        case serverRevision = "server_revision"
    }

    nonisolated var id: String
    nonisolated var vineyardId: String
    /// Season identity, e.g. `"2026/27"` — never a bare calendar year, because an
    /// Australian season spans two of them.
    nonisolated var seasonId: String
    nonisolated var seasonStartYear: Int
    nonisolated var disease: ResistanceDisease
    nonisolated var jurisdiction: ResistanceJurisdiction
    nonisolated var crop: ResistanceCrop
    /// Blocks this plan covers. Each is evaluated against its OWN history; they are
    /// never merged.
    nonisolated var blockIds: [String]
    /// Planned positions in sequence. Array order IS the planned chronology.
    nonisolated var positions: [ResistancePlannedPosition]
    nonisolated var notes: String?

    /// The ruleset that governed the evaluation when this plan was last saved.
    ///
    /// Stored as id + version rather than as rendered warning text. When the 2027
    /// CropLife strategy arrives, a plan built under the 2026 one must not silently
    /// re-interpret itself: comparing this against the registry's current version is
    /// what allows "a newer resistance strategy is available — review this plan"
    /// instead of a plan whose meaning changed while nobody was looking.
    nonisolated var rulesetId: String?
    nonisolated var rulesetVersion: String?
    /// Author, for attribution. NOT a visibility scope: plans are vineyard data and
    /// every authorised member sees them (see `resistance_plans` RLS). Scoping
    /// visibility to the creator would mean the manager who wrote the season plan is
    /// the only person who can open it, which defeats the purpose of a shared plan.
    nonisolated var createdBy: String?
    nonisolated var createdAtEpochMs: Int64
    nonisolated var updatedAtEpochMs: Int64
    /// Soft-delete tombstone. A deleted plan is retained so the delete propagates to
    /// other devices instead of the row silently reappearing on their next push.
    nonisolated var deletedAtEpochMs: Int64?
    /// The `server_revision` (sql/198) this local copy was based on. SERVER STATE, not
    /// editable plan content — no editor, screen or mutator may set it.
    ///
    /// Nil means "the server has never issued a revision for this plan": either it was
    /// created offline and has not landed yet, or it is a cached copy from before revisions
    /// existed. Nil is a legitimate state and is never treated as corruption — and a fake
    /// revision is NEVER manufactured to fill it, because a made-up number would be sent as
    /// `base_revision` and would either be refused forever or, worse, match by luck and
    /// overwrite an edit this device never saw.
    ///
    /// Optional also keeps every plan cached by an older build decodable.
    nonisolated var serverRevision: Int64?

    nonisolated init(
        id: String = UUID().uuidString,
        vineyardId: String,
        seasonId: String,
        seasonStartYear: Int,
        disease: ResistanceDisease,
        jurisdiction: ResistanceJurisdiction,
        crop: ResistanceCrop = .grape,
        blockIds: [String] = [],
        positions: [ResistancePlannedPosition] = [],
        notes: String? = nil,
        rulesetId: String? = nil,
        rulesetVersion: String? = nil,
        createdBy: String? = nil,
        createdAtEpochMs: Int64,
        updatedAtEpochMs: Int64,
        deletedAtEpochMs: Int64? = nil,
        serverRevision: Int64? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.seasonId = seasonId
        self.seasonStartYear = seasonStartYear
        self.disease = disease
        self.jurisdiction = jurisdiction
        self.crop = crop
        self.blockIds = blockIds
        self.positions = positions
        self.notes = notes
        self.rulesetId = rulesetId
        self.rulesetVersion = rulesetVersion
        self.createdBy = createdBy
        self.deletedAtEpochMs = deletedAtEpochMs
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
        self.serverRevision = serverRevision
    }

    // MARK: - Editing
    //
    // Every mutator returns a new plan rather than mutating in place, so a caller
    // cannot accidentally hold a stale copy, and so re-evaluation is always driven by
    // a value the UI actually rendered.

    nonisolated func addingPosition(
        _ position: ResistancePlannedPosition = ResistancePlannedPosition(),
        atEpochMs now: Int64
    ) -> ResistancePlan {
        var copy = self
        copy.positions.append(position)
        copy.updatedAtEpochMs = now
        return copy
    }

    nonisolated func removingPosition(id positionId: String, atEpochMs now: Int64) -> ResistancePlan {
        var copy = self
        copy.positions.removeAll { $0.id == positionId }
        copy.updatedAtEpochMs = now
        return copy
    }

    nonisolated func replacingPosition(
        _ position: ResistancePlannedPosition,
        atEpochMs now: Int64
    ) -> ResistancePlan {
        var copy = self
        guard let index = copy.positions.firstIndex(where: { $0.id == position.id }) else { return self }
        copy.positions[index] = position
        copy.updatedAtEpochMs = now
        return copy
    }

    /// Moves a position one slot earlier. No-op at the start.
    nonisolated func movingPositionUp(id positionId: String, atEpochMs now: Int64) -> ResistancePlan {
        guard let index = positions.firstIndex(where: { $0.id == positionId }), index > 0 else { return self }
        var copy = self
        copy.positions.swapAt(index, index - 1)
        copy.updatedAtEpochMs = now
        return copy
    }

    /// Moves a position one slot later. No-op at the end.
    nonisolated func movingPositionDown(id positionId: String, atEpochMs now: Int64) -> ResistancePlan {
        guard let index = positions.firstIndex(where: { $0.id == positionId }),
              index < positions.count - 1 else { return self }
        var copy = self
        copy.positions.swapAt(index, index + 1)
        copy.updatedAtEpochMs = now
        return copy
    }

    nonisolated func settingBlockIds(_ ids: [String], atEpochMs now: Int64) -> ResistancePlan {
        var copy = self
        var seen: Set<String> = []
        copy.blockIds = ids.filter { seen.insert($0).inserted }
        copy.updatedAtEpochMs = now
        return copy
    }

    nonisolated func settingNotes(_ notes: String?, atEpochMs now: Int64) -> ResistancePlan {
        var copy = self
        copy.notes = notes
        copy.updatedAtEpochMs = now
        return copy
    }

    /// Records the ruleset actually used, so the plan can later detect that the
    /// strategy has moved on.
    nonisolated func stampingRuleset(id rulesetId: String?, version: String?) -> ResistancePlan {
        var copy = self
        copy.rulesetId = rulesetId
        copy.rulesetVersion = rulesetVersion(from: version)
        return copy
    }

    private nonisolated func rulesetVersion(from version: String?) -> String? { version }

    /// True when a newer strategy version is in force than the one this plan recorded.
    ///
    /// Deliberately a query rather than an automatic migration: an old plan keeps its
    /// stamped version until a human reviews it.
    nonisolated func isStrategyOutdated(against registry: ResistanceRulesetRegistry) -> Bool {
        guard let stamped = rulesetVersion,
              let current = registry.current(jurisdiction: jurisdiction, crop: crop, disease: disease)
        else { return false }
        return current.rulesetVersion != stamped
    }

    /// True when this plan has been archived/soft-deleted.
    nonisolated var isDeleted: Bool { deletedAtEpochMs != nil }

    /// True when this plan has never been accepted by the server, so a versioned write must
    /// be a CREATE rather than an update of a known revision.
    nonisolated var isUnsynced: Bool { serverRevision == nil }

    /// Records the revision the server issued for this document.
    ///
    /// Separate from every content mutator on purpose: the revision is not an edit, so
    /// stamping it must never touch `updatedAtEpochMs` and must never enqueue the plan.
    nonisolated func stampingServerRevision(_ revision: Int64?) -> ResistancePlan {
        var copy = self
        copy.serverRevision = revision
        return copy
    }

    nonisolated func position(id positionId: String) -> ResistancePlannedPosition? {
        positions.first { $0.id == positionId }
    }

    /// 1-based display ordinal, e.g. position index 0 in a season with 3 completed
    /// sprays is "Spray 4".
    nonisolated func displayOrdinal(forPositionAt index: Int, completedCount: Int) -> Int {
        completedCount + index + 1
    }
}

nonisolated extension ResistanceGroupSignature {
    /// Operator-facing label for a signature, e.g. `"FRAC 11 + 3"`.
    nonisolated var displayLabel: String {
        codes.isEmpty ? "No group recorded" : "FRAC " + codes.joined(separator: " + ")
    }
}

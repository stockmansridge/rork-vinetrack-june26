import Foundation

/// Why a Program Step could not be saved.
nonisolated enum SprayProgramStepWriteError: LocalizedError, Equatable {
    /// The statement reached the database but changed no row. Under RLS that is
    /// indistinguishable from "row not found", and both mean the same thing:
    /// this save did not land.
    case notPermitted
    /// A portal Program Step edited with no connectivity. There is no offline
    /// mutation queue for `spray_jobs`, so the only honest options are to block
    /// the save or to fake it.
    case offline
    case noVineyardSelected
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notPermitted:
            return "You don't have permission to change this Program Step, or it's no longer in the program."
        case .offline:
            return "Connect to update this Program Step."
        case .noVineyardSelected:
            return "Select a vineyard before editing the spray program."
        case .invalid(let reason):
            return reason
        }
    }
}

/// Who may edit a Program Step.
///
/// The rule is the DATABASE's, restated on the client so the UI does not offer
/// a button the write will reject:
///
///   * portal-backed step -> `spray_jobs_update_managers` (sql/032), which is
///     `has_vineyard_role(vineyard_id, ['owner','manager'])`.
///   * local step -> whatever could already edit it, unchanged.
///
/// Nothing here widens access. A client check can only ever be the more
/// restrictive half of the pair — RLS remains the enforcement point, and a
/// supervisor who somehow reached the editor would still be refused by Postgres.
nonisolated enum SprayProgramStepPermissions {
    /// - Parameters:
    ///   - canManageSprayProgram: owner/manager, mirroring the UPDATE policy.
    ///   - canEditRecords: the existing local-step rule, preserved verbatim.
    static func canEdit(
        step: SprayProgramStep,
        canManageSprayProgram: Bool,
        canEditRecords: Bool
    ) -> Bool {
        step.isPortalManaged ? canManageSprayProgram : canEditRecords
    }

    /// Delete stays exactly where it was: local steps only, on the existing
    /// delete permission. Enabling mobile deletion of a shared portal row needs
    /// its own decisions about downstream references and soft-delete, and this
    /// change does not make them.
    static func canDelete(step: SprayProgramStep, canDeleteRecords: Bool) -> Bool {
        !step.isPortalManaged && canDeleteRecords
    }
}

/// One editable product line on a Program Step.
///
/// A Program Step's product line is a POINTER — "apply this Saved Chemical at
/// this rate" — not a record of what was applied. That is why the identity
/// fields here are editable and the frozen chemistry is not: replacing the
/// product changes what future sprays will apply, and rewrites nothing that
/// already happened.
nonisolated struct SprayProgramProductDraft: Identifiable, Sendable, Hashable {
    let id: UUID
    /// The Chemical Store record this line points at. `nil` means the line
    /// names a product that was never resolved to an identity — the legacy
    /// case this editor exists to fix.
    var savedChemicalId: UUID?
    var name: String
    var activeIngredient: String?
    /// The rate in `unit`, as the operator reads and types it.
    var rate: Double
    var unit: ChemicalUnit
    var basis: SprayProductRateBasis
    /// The portal's per-line carrier rate. Mobile does not edit it; it is
    /// carried so a round-trip cannot drop it.
    var waterRate: Double?
    var notes: String?
    /// Cost snapshot on the existing local line. Preserved, never edited here.
    var costPerUnit: Double
    /// The tank this line came from on a local record, so a multi-tank local
    /// recipe writes back into the tank it belongs to instead of collapsing.
    /// `nil` for a line the operator just added.
    var tankIndex: Int?
    /// The original `SprayChemical.id`, so an edit updates the same line.
    var existingLineId: UUID?
    /// Frozen chemistry carried on the existing line.
    ///
    /// Round-tripped verbatim while the line still points at the same product,
    /// and DROPPED the moment the product is replaced: a snapshot describes a
    /// specific product, so keeping it against a different one would be a
    /// fabrication. No new snapshot is captured either — a Program Step reads
    /// today's Chemical Store by design, and freezing is what the job and the
    /// completed record do.
    var chemicalSnapshot: ChemicalLineSnapshot?

    init(
        id: UUID = UUID(),
        savedChemicalId: UUID? = nil,
        name: String = "",
        activeIngredient: String? = nil,
        rate: Double = 0,
        unit: ChemicalUnit = .litres,
        basis: SprayProductRateBasis = .wholeBlockArea,
        waterRate: Double? = nil,
        notes: String? = nil,
        costPerUnit: Double = 0,
        tankIndex: Int? = nil,
        existingLineId: UUID? = nil,
        chemicalSnapshot: ChemicalLineSnapshot? = nil
    ) {
        self.id = id
        self.savedChemicalId = savedChemicalId
        self.name = name
        self.activeIngredient = activeIngredient
        self.rate = rate
        self.unit = unit
        self.basis = basis
        self.waterRate = waterRate
        self.notes = notes
        self.costPerUnit = costPerUnit
        self.tankIndex = tankIndex
        self.existingLineId = existingLineId
        self.chemicalSnapshot = chemicalSnapshot
    }

    /// The rate in BASE units (mL or g), the form both storage contracts use.
    var baseRate: Double { unit.toBase(rate) }

    /// Point this line at a different Saved Chemical.
    ///
    /// Explicit replacement only — this is never called from a name match. The
    /// operator taps a product in the Chemical Store, and THAT identity is what
    /// gets written. An unresolved legacy line ("Spray Seal") stays unresolved
    /// until they do.
    ///
    /// The rate is re-seeded from the new product's registered uses only when
    /// the label offers a single applicable value. A band, a reference-only
    /// entry or a product with no structured rates leaves the existing number
    /// alone for the operator to set — VineTrack does not pick a point inside a
    /// registered range.
    mutating func replaceProduct(with chemical: SavedChemical, seedRate: SpraySelectableRate?) {
        savedChemicalId = chemical.id
        name = chemical.name
        activeIngredient = chemical.activeIngredient.isEmpty ? nil : chemical.activeIngredient
        chemicalSnapshot = nil
        costPerUnit = 0

        if let seedRate, let seed = seedRate.seed.seedableValue, let seedBasis = seedRate.basis {
            unit = chemical.unit
            rate = chemical.unit.fromBase(seed)
            basis = seedBasis == .per100Litres ? .per100Litres : .wholeBlockArea
        } else {
            // Keep the operator's number but restate it in the new product's
            // unit, so "2" does not silently change meaning from 2 L to 2 kg.
            let previousBase = baseRate
            unit = chemical.unit
            rate = chemical.unit.fromBase(previousBase)
        }
    }

    /// Detach this line from its Saved Chemical, keeping the typed name.
    ///
    /// The honest escape hatch the Chemical Store picker already offers, and the
    /// state a legacy line is in: named, applied, but not resolvable to a
    /// product whose chemistry VineTrack can assess.
    mutating func clearProduct(name typedName: String) {
        savedChemicalId = nil
        name = typedName
        activeIngredient = nil
        chemicalSnapshot = nil
    }

    /// Whether this line resolves to a product in TODAY's Chemical Store.
    ///
    /// Identifier-only. A legacy line named "Spray Seal" must not become
    /// "verified" because a similarly named product exists — that is exactly
    /// the silent name-matching this editor makes the operator resolve by hand.
    func isResolved(in library: [SavedChemical]) -> Bool {
        guard let savedChemicalId else { return false }
        return library.contains { $0.id == savedChemicalId }
    }
}

/// The editable configuration of one Program Step.
///
/// Reusable configuration ONLY. There is deliberately no date, weather, tanks
/// applied, rows sprayed, operator, cost, application geometry or completed
/// chemistry snapshot on this type: those describe an application that
/// happened, and a Program Step never happened.
nonisolated struct SprayProgramStepDraft: Sendable, Hashable {
    let stepId: UUID
    let source: SprayProgramStepSource
    var name: String
    /// Canonical `growth_stage_code`, e.g. `"EL12"`. `nil` is a legitimate
    /// answer — a step that does not state a stage says so.
    var growthStageCode: String?
    /// The selected targets, as tags.
    ///
    /// Tags rather than a punctuation-delimited sentence the operator maintains
    /// by hand, and tags rather than a `Set<SprayTarget>`: the typed set has six
    /// cases and a vineyard routinely sprays for Eutypa, Phomopsis or Black
    /// Spot. A tag keeps the stable identifier for storage and matching AND the
    /// vineyard's own wording, so neither is traded for the other.
    var targets: [SprayTargetTag]
    var operationType: OperationType
    var equipmentId: UUID?
    var tractorId: UUID?
    var notes: String
    var products: [SprayProgramProductDraft]

    // MARK: - Load

    /// - Parameter targetLabels: the vineyard's target library, so a stored
    ///   identifier this step has no wording for still loads as real words.
    init(step: SprayProgramStep, targetLabels: [String: String] = [:]) {
        stepId = step.id
        source = step.source
        name = step.name
        growthStageCode = step.growthStageCode ?? step.elStageLabel
        targets = step.targetTags(labels: targetLabels)
        operationType = step.operationType
        equipmentId = step.record.sprayEquipmentId
        tractorId = step.record.tractorId
        notes = step.notes

        var lines: [SprayProgramProductDraft] = []
        for (tankIndex, tank) in step.record.tanks.enumerated() {
            for chemical in tank.chemicals {
                guard !chemical.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lines.append(
                    SprayProgramProductDraft(
                        savedChemicalId: chemical.savedChemicalId,
                        name: chemical.name,
                        activeIngredient: chemical.chemicalSnapshot?.activeIngredients
                            .map(\.name)
                            .joined(separator: ", "),
                        // Read through P10's basis-aware reporting so a
                        // per-100 L line loads as its per-100 L rate instead of
                        // as a fabricated zero per hectare.
                        rate: chemical.displayReportedRate,
                        unit: chemical.unit,
                        basis: chemical.reportedRateBasis,
                        notes: nil,
                        costPerUnit: chemical.costPerUnit,
                        tankIndex: tankIndex,
                        existingLineId: chemical.id,
                        chemicalSnapshot: chemical.chemicalSnapshot
                    )
                )
            }
        }
        products = lines
    }

    // MARK: - Validation

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The tags in stored order, de-duplicated.
    var normalisedTargets: [SprayTargetTag] { SprayTargetVocabulary.normalised(targets) }

    /// The typed targets among the selection — what prefills the calculator.
    var recognisedTargets: [SprayTarget] { SprayTargetVocabulary.builtIns(targets) }

    /// The display line, also written to the legacy `target` column.
    var targetDisplay: String? { SprayTargetVocabulary.displayString(targets) }

    /// Add a tag, ignoring one this step already has.
    ///
    /// De-duplication is by identifier, which is a case-insensitive slug, so
    /// "eutypa dieback" cannot join a step that already has "Eutypa Dieback".
    mutating func addTarget(_ tag: SprayTargetTag) {
        guard !targets.contains(where: { $0.identifier == tag.identifier }) else { return }
        targets = SprayTargetVocabulary.normalised(targets + [tag])
    }

    /// Remove a tag from THIS Program Step. Never touches the vineyard's
    /// library — a target the vineyard sprays for does not stop existing
    /// because one step no longer names it.
    mutating func removeTarget(_ tag: SprayTargetTag) {
        targets.removeAll { $0.identifier == tag.identifier }
    }

    /// The first reason this draft cannot be saved, or `nil`.
    var validationError: String? {
        if trimmedName.isEmpty {
            return "Give the Program Step a name."
        }
        if products.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every product needs a name."
        }
        if products.contains(where: { $0.rate < 0 }) {
            return "A product rate cannot be negative."
        }
        // A shared Program Step is stored as `spray_jobs.chemical_lines`, whose
        // unit string can only express /ha and /100 L. Rather than write "/ha"
        // over a treated-area rate and silently restate it, refuse.
        if source == .portal,
           let odd = products.first(where: { $0.basis != .wholeBlockArea && $0.basis != .per100Litres }) {
            return "\(odd.name) uses \(odd.basis.label), which the shared program can't store. Choose per hectare or per 100 L."
        }
        return nil
    }

    var isValid: Bool { validationError == nil }

    // MARK: - Portal write

    /// The `chemical_lines` JSONB array, in the shape the portal and the Excel
    /// import already write.
    ///
    /// Every field the existing contract defines is written: `chemical_id`,
    /// `name`, `active_ingredient`, `rate`, `unit`, `water_rate`, `notes` and
    /// `chemical_snapshot`. The rate BASIS is not a field — it lives inside the
    /// `unit` string (`"mL/100L"` vs `"mL/ha"`), which is the representation the
    /// portal reads, so it is composed rather than invented.
    func chemicalLines() -> [SprayJobChemicalLine] {
        products.map { product in
            SprayJobChemicalLine(
                chemicalId: product.savedChemicalId,
                name: product.name.trimmingCharacters(in: .whitespacesAndNewlines),
                activeIngredient: product.activeIngredient,
                rate: product.rate,
                unit: BackendSprayJobTemplate.composeLineUnit(product.unit, basis: product.basis),
                waterRate: product.waterRate,
                notes: product.notes,
                chemicalSnapshot: product.chemicalSnapshot
            )
        }
    }

    /// The partial update for the existing `spray_jobs` row.
    func portalPayload(updatedBy: UUID?) -> BackendSprayJobTemplateUpdate {
        BackendSprayJobTemplateUpdate(
            name: trimmedName,
            chemicalLines: chemicalLines(),
            operationType: operationType.rawValue,
            // Structured identifiers are the source of truth; the wording line
            // is written alongside as a compatibility projection for readers
            // that still consume it. Both go, so neither side has to guess.
            targets: SprayTargetVocabulary.identifiers(targets),
            target: targetDisplay,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            growthStageCode: growthStageCode,
            equipmentId: equipmentId,
            tractorId: tractorId,
            updatedBy: updatedBy
        )
    }

    // MARK: - Local write

    /// Project this draft back onto the local `spray_records` template row.
    ///
    /// Every line returns to the tank it came from, so a multi-tank local recipe
    /// is not silently collapsed into one. New lines join the first tank.
    /// Nothing operational on the record is touched: the date, trip, weather,
    /// geometry blocks and `isTemplate` all survive verbatim.
    func applied(to record: SprayRecord) -> SprayRecord {
        var updated = record
        updated.sprayReference = trimmedName
        updated.notes = notes
        updated.operationType = operationType
        updated.sprayEquipmentId = equipmentId
        updated.tractorId = tractorId

        var tanks = updated.tanks
        if tanks.isEmpty { tanks = [SprayTank(tankNumber: 1)] }
        for index in tanks.indices { tanks[index].chemicals = [] }

        for product in products {
            let index = product.tankIndex.map { min($0, tanks.count - 1) } ?? 0
            tanks[index].chemicals.append(product.toSprayChemical())
        }
        updated.tanks = tanks

        // The full selection — typed cases AND this vineyard's own. A local
        // Program Step has no free-text target column, so before this the
        // custom half had nowhere to go and was dropped on save; it now rides
        // the snapshot's `customTargets`, which persists into the same
        // `spray_records.targets` array. Targets and nothing else: a reusable
        // step carries no geometry because it does not know where it is going.
        let typed = recognisedTargets
        let custom = SprayTargetVocabulary.customs(targets).map(\.identifier)
        updated.applicationGeometry = (typed.isEmpty && custom.isEmpty)
            ? nil
            : SprayApplicationSnapshot(targets: typed, customTargets: custom)
        return updated
    }

    /// The step as it will read once saved, so the detail screen can show the
    /// new configuration without a round trip through sync.
    func projectedStep(base: SprayProgramStep) -> SprayProgramStep {
        SprayProgramStep(
            record: applied(to: base.record),
            source: base.source,
            growthStageCode: source == .portal ? growthStageCode : base.growthStageCode,
            // The wording line carries the vineyard's exact phrasing back to the
            // detail screen, so a custom target reads as it was typed even
            // before the library has synced.
            targetRaw: targetDisplay
        )
    }
}

extension SprayProgramProductDraft {
    /// The local `tanks` JSONB representation.
    ///
    /// Mirrors `BackendSprayJobTemplate.toSprayRecord`: the rate goes into the
    /// field its basis owns, and `rateBasis` is left `nil` when there is no rate
    /// at all — an honest "not stated" rather than a default that would later
    /// report as 0/ha.
    func toSprayChemical() -> SprayChemical {
        let base = baseRate
        return SprayChemical(
            id: existingLineId ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            volumePerTank: 0,
            ratePerHa: basis == .per100Litres ? 0 : base,
            ratePer100L: basis == .per100Litres ? base : 0,
            costPerUnit: costPerUnit,
            unit: unit,
            rateBasis: base > 0 ? basis : nil,
            savedChemicalId: savedChemicalId,
            chemicalSnapshot: chemicalSnapshot
        )
    }
}

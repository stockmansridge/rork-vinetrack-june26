import Foundation

/// The mobile write payload for an EXISTING portal Program Step row in
/// `public.spray_jobs` (`is_template = true`).
///
/// Deliberately a partial update. Every key below is a column the Program
/// Step's own configuration owns; everything else on the row — `id`,
/// `vineyard_id`, `is_template`, `status`, `planned_date`, `water_volume`,
/// `spray_rate_per_ha`, `created_by`, `resistance_plan_id` — is simply ABSENT
/// from the payload, so a PATCH leaves it exactly as the portal wrote it. That
/// is the whole reason this is a hand-written encoder rather than a re-encode
/// of `BackendSprayJobTemplate`: round-tripping the full row through mobile
/// would let a field mobile does not model overwrite the portal's value with a
/// decoded default.
///
/// `updated_at` is not written either — `spray_jobs_set_updated_at` (sql/032)
/// owns it.
nonisolated struct BackendSprayJobTemplateUpdate: Encodable, Sendable, Equatable {
    let name: String
    let chemicalLines: [SprayJobChemicalLine]
    let operationType: String
    /// The structured target selection (sql/193 `spray_jobs.targets`).
    ///
    /// THE source of truth for which targets a Program Step is for. Written as
    /// stable identifiers, which is what the Resistance Planner's containment
    /// query matches on and what makes a target reusable across steps.
    let targets: [String]
    /// The legacy free-text target line, written as a COMPATIBILITY PROJECTION
    /// of `targets` — existing portal and report readers still read this column,
    /// and it is the only place a custom target's exact punctuation survives the
    /// identifier slug. Nullable: clearing every target must persist as SQL
    /// NULL, not as the absence of the key.
    let target: String?
    let notes: String?
    let growthStageCode: String?
    let equipmentId: UUID?
    let tractorId: UUID?
    /// The signed-in user, for the row's audit column. Never `created_by`:
    /// a portal-created step keeps its original author.
    let updatedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case name
        case chemicalLines = "chemical_lines"
        case operationType = "operation_type"
        case targets
        case target
        case notes
        case growthStageCode = "growth_stage_code"
        case equipmentId = "equipment_id"
        case tractorId = "tractor_id"
        case updatedBy = "updated_by"
    }

    /// Explicit, because the nullable columns must encode as JSON `null` rather
    /// than being omitted.
    ///
    /// The synthesised encoder uses `encodeIfPresent` for optionals, which would
    /// silently turn "the operator removed the tractor" into "leave the tractor
    /// alone" — a save that appears to work and changes nothing.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(chemicalLines, forKey: .chemicalLines)
        try container.encode(operationType, forKey: .operationType)
        try container.encode(targets, forKey: .targets)
        try container.encode(target, forKey: .target)
        try container.encode(notes, forKey: .notes)
        try container.encode(growthStageCode, forKey: .growthStageCode)
        try container.encode(equipmentId, forKey: .equipmentId)
        try container.encode(tractorId, forKey: .tractorId)
        try container.encode(updatedBy, forKey: .updatedBy)
    }
}

extension BackendSprayJobTemplate {
    /// Compose the unit string the portal and the Excel import already write.
    ///
    /// The exact inverse of `parseLineUnit`, which is the ONLY thing that reads
    /// it back — on mobile and, through the same JSONB, in the portal. The
    /// per-100 L basis lives in this string and nowhere else, so a Program Step
    /// whose rate is quoted per 100 L must round-trip through it verbatim:
    /// writing `mL/ha` for a `mL/100L` line would silently restate the rate.
    nonisolated static func composeLineUnit(_ unit: ChemicalUnit, basis: SprayProductRateBasis) -> String {
        let measure: String
        switch unit {
        case .litres: measure = "L"
        case .millilitres: measure = "mL"
        case .kilograms: measure = "kg"
        case .grams: measure = "g"
        }
        return "\(measure)/\(basis == .per100Litres ? "100L" : "ha")"
    }

    /// Apply an already-persisted update to the in-memory row.
    ///
    /// Used to patch the offline cache after a successful write when the server
    /// response cannot be decoded. The returned value carries the SAME `id`,
    /// `vineyardId` and every column the payload does not model.
    nonisolated func applying(_ update: BackendSprayJobTemplateUpdate) -> BackendSprayJobTemplate {
        BackendSprayJobTemplate(
            id: id,
            vineyardId: vineyardId,
            name: update.name,
            status: status,
            plannedDate: plannedDate,
            chemicalLines: update.chemicalLines,
            waterVolume: waterVolume,
            sprayRatePerHa: sprayRatePerHa,
            concentrationFactor: concentrationFactor,
            operationType: update.operationType,
            target: update.target,
            targets: update.targets,
            notes: update.notes,
            growthStageCode: update.growthStageCode,
            equipmentId: update.equipmentId,
            tractorId: update.tractorId,
            createdBy: createdBy
        )
    }
}

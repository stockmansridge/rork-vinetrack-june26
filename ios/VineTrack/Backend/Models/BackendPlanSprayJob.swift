import Foundation

/// A `spray_jobs` row carrying resistance-plan provenance (sql/201).
///
/// The snapshot is decoded with the SAME `ResistancePlannedPosition` model the
/// planner writes, because the frozen document IS a sql/196 position — the
/// original planned intent, never a verdict. Decode is deliberately tolerant:
/// a job must never disappear from the planner because an optional field is
/// missing or a portal edit mangled a line.
nonisolated struct BackendPlanSprayJob: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let status: String?
    let target: String?
    let notes: String?
    let chemicalLines: [SprayJobChemicalLine]
    let resistancePlanId: String?
    let resistancePositionId: String?
    /// The ORIGINAL planned intent, frozen at creation. Read this for "what was
    /// planned"; never the current plan position (which may have been edited).
    let resistancePositionSnapshot: ResistancePlannedPosition?
    let resistancePlanSourceRevision: Int64?
    let createdAt: Date?
    let deletedAt: Date?

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case status
        case target
        case notes
        case chemicalLines = "chemical_lines"
        case resistancePlanId = "resistance_plan_id"
        case resistancePositionId = "resistance_position_id"
        case resistancePositionSnapshot = "resistance_position_snapshot"
        case resistancePlanSourceRevision = "resistance_plan_source_revision"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
    }

    nonisolated init(
        id: UUID,
        vineyardId: UUID,
        name: String,
        status: String?,
        target: String?,
        notes: String?,
        chemicalLines: [SprayJobChemicalLine],
        resistancePlanId: String?,
        resistancePositionId: String?,
        resistancePositionSnapshot: ResistancePlannedPosition?,
        resistancePlanSourceRevision: Int64?,
        createdAt: Date?,
        deletedAt: Date?
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.status = status
        self.target = target
        self.notes = notes
        self.chemicalLines = chemicalLines
        self.resistancePlanId = resistancePlanId
        self.resistancePositionId = resistancePositionId
        self.resistancePositionSnapshot = resistancePositionSnapshot
        self.resistancePlanSourceRevision = resistancePlanSourceRevision
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        target = try? container.decodeIfPresent(String.self, forKey: .target)
        notes = try? container.decodeIfPresent(String.self, forKey: .notes)
        let lossyLines = (try? container.decodeIfPresent([LossyPlanChemicalLine].self, forKey: .chemicalLines)) ?? nil
        chemicalLines = lossyLines?.compactMap(\.value) ?? []
        resistancePlanId = try? container.decodeIfPresent(String.self, forKey: .resistancePlanId)
        resistancePositionId = try? container.decodeIfPresent(String.self, forKey: .resistancePositionId)
        resistancePositionSnapshot = try? container.decodeIfPresent(
            ResistancePlannedPosition.self, forKey: .resistancePositionSnapshot
        )
        resistancePlanSourceRevision = try? container.decodeIfPresent(Int64.self, forKey: .resistancePlanSourceRevision)
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
        deletedAt = try? container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    // MARK: - Plan context

    /// Original planned intent, e.g. `"FRAC 3 — Talendo"`. Nil when the job
    /// carries no snapshot (a legacy unlinked job).
    nonisolated var originalIntentLabel: String? {
        guard let snapshot = resistancePositionSnapshot else { return nil }
        let groups = snapshot.groupsLabel
        let names = snapshot.products.compactMap(\.productName).filter { !$0.isEmpty }
        return names.isEmpty ? groups : "\(groups) — \(names.joined(separator: ", "))"
    }

    /// The job's CURRENT proposed chemistry, from its editable chemical lines.
    nonisolated var currentProposalLabel: String {
        let names = chemicalLines.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "No products proposed yet" : names.joined(separator: ", ")
    }

    /// PLAN DEVIATION, not compliance: true when the job's current proposal no
    /// longer matches the originally planned product identities. A deviating
    /// job can still be perfectly resistance-compliant — compliance is always
    /// the Resistance Engine's call against current history.
    nonisolated var deviatesFromPlan: Bool {
        guard resistancePositionSnapshot != nil else { return false }
        return plannedIdentity != proposedIdentity
    }

    private nonisolated var plannedIdentity: Set<String> {
        guard let snapshot = resistancePositionSnapshot else { return [] }
        return Set(snapshot.products.map { product in
            let key = product.savedChemicalId
                ?? product.productName
                ?? product.groups.displayLabel
            return key.lowercased()
        })
    }

    private nonisolated var proposedIdentity: Set<String> {
        Set(chemicalLines.map { line in
            (line.chemicalId?.uuidString ?? line.name).lowercased()
        })
    }

    /// Maps this job into an in-memory record used ONLY to prefill the Spray
    /// Calculator (mirrors `BackendSprayJobTemplate.toSprayRecord()`). Never
    /// stored: the calculator deep-copies into a brand-new record which then
    /// carries `sprayJobId = job.id` — the Job -> Record completion link.
    nonisolated func toPrefillRecord() -> SprayRecord {
        let chemicals: [SprayChemical] = chemicalLines.map { line in
            let parsed = BackendSprayJobTemplate.parseLineUnit(line.unit)
            let baseRate = parsed.unit.toBase(line.rate ?? 0)
            return SprayChemical(
                name: line.name,
                volumePerTank: 0,
                ratePerHa: parsed.per100L ? 0 : baseRate,
                ratePer100L: parsed.per100L ? baseRate : 0,
                costPerUnit: 0,
                unit: parsed.unit,
                savedChemicalId: line.chemicalId,
                // The chemistry frozen when the job was created. Carried so the
                // calculator can re-establish the product from STORED provenance —
                // the saved-chemical id, and failing that the registered identity
                // key inside this snapshot — rather than by matching a product
                // name, which for a group-planned line is a group label.
                //
                // It is provenance for re-resolution, NOT the chemistry the
                // eventual record will carry: completion re-captures the Chemical
                // Store as it stands at application time, which is the contract
                // every other new-application path follows.
                chemicalSnapshot: line.chemicalSnapshot
            )
        }
        let tank = SprayTank(
            tankNumber: 1,
            waterVolume: 0,
            sprayRatePerHa: 0,
            concentrationFactor: 0,
            rowApplications: [],
            chemicals: chemicals
        )
        return SprayRecord(
            id: id,
            vineyardId: vineyardId,
            sprayReference: name,
            tanks: [tank],
            notes: notes ?? "",
            // Prefill semantics only (keeps the name verbatim, no "(Copy)");
            // the record the calculator actually saves is a new non-template.
            isTemplate: true,
            operationType: .foliarSpray
        )
    }
}

/// Lossy per-line wrapper: a malformed chemical line is skipped instead of
/// failing the whole job row.
nonisolated private struct LossyPlanChemicalLine: Decodable, Sendable {
    let value: SprayJobChemicalLine?
    init(from decoder: Decoder) throws {
        value = try? SprayJobChemicalLine(from: decoder)
    }
}

/// Insert payload for a spray job created FROM a resistance plan position.
/// Codable (not just Encodable) so the offline outbox can persist it verbatim.
nonisolated struct BackendPlanSprayJobInsert: Codable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let isTemplate: Bool
    let status: String
    let target: String?
    let notes: String?
    let chemicalLines: [SprayJobChemicalLine]
    let resistancePlanId: String
    let resistancePositionId: String
    /// Frozen VERBATIM from the plan position at creation time (sql/196 shape).
    let resistancePositionSnapshot: ResistancePlannedPosition
    let resistancePlanSourceRevision: Int64?
    let createdBy: UUID?

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case isTemplate = "is_template"
        case status
        case target
        case notes
        case chemicalLines = "chemical_lines"
        case resistancePlanId = "resistance_plan_id"
        case resistancePositionId = "resistance_position_id"
        case resistancePositionSnapshot = "resistance_position_snapshot"
        case resistancePlanSourceRevision = "resistance_plan_source_revision"
        case createdBy = "created_by"
    }

    /// The optimistic local row shown while the create is queued/in flight.
    nonisolated func asJob(createdAt: Date = Date()) -> BackendPlanSprayJob {
        BackendPlanSprayJob(
            id: id,
            vineyardId: vineyardId,
            name: name,
            status: status,
            target: target,
            notes: notes,
            chemicalLines: chemicalLines,
            resistancePlanId: resistancePlanId,
            resistancePositionId: resistancePositionId,
            resistancePositionSnapshot: resistancePositionSnapshot,
            resistancePlanSourceRevision: resistancePlanSourceRevision,
            createdAt: createdAt,
            deletedAt: nil
        )
    }
}

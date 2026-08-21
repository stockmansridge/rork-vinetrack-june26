import Foundation
import Observation

/// Planner-scoped store for spray jobs created from resistance plan positions
/// (sql/201 provenance).
///
/// Local-first, mirroring `ResistancePlanRepository`: a create commits to the
/// in-memory list and a persisted outbox immediately (fully offline-capable),
/// then replays against the server. The client mints the job UUID, so a
/// retried replay is idempotent — the server treats a duplicate insert as
/// already-synced. The link (plan id + position id + frozen snapshot) rides
/// INSIDE the queued create itself, never a follow-up patch, so it survives
/// any sync ordering — including the job landing before its offline-created
/// plan.
@Observable
@MainActor
final class ResistancePlanJobService {

    /// One queued create: the full insert payload plus its proposed coverage.
    struct PendingJobCreate: Codable, Sendable {
        let payload: BackendPlanSprayJobInsert
        let paddockIds: [UUID]
    }

    private(set) var jobsByPlan: [String: [BackendPlanSprayJob]] = [:]
    private(set) var pendingCreates: [PendingJobCreate] = []
    private(set) var isSyncing: Bool = false

    private let repository: SupabaseSprayJobPlanRepository
    private let defaults: UserDefaults
    private var isPushing = false

    private static let outboxKey = "resistance_plan_spray_jobs_outbox_v1"
    private static func cacheKey(_ planId: String) -> String {
        "resistance_plan_spray_jobs_cache_v1_\(planId)"
    }

    init(
        repository: SupabaseSprayJobPlanRepository = SupabaseSprayJobPlanRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.defaults = defaults
        self.pendingCreates = Self.decode([PendingJobCreate].self, from: defaults.data(forKey: Self.outboxKey)) ?? []
    }

    // MARK: - Reads

    /// Paints from cache immediately; `refresh` reconciles with the server.
    func load(planId: String) {
        guard jobsByPlan[planId] == nil else { return }
        let cached = Self.decode([BackendPlanSprayJob].self, from: defaults.data(forKey: Self.cacheKey(planId))) ?? []
        jobsByPlan[planId] = overlayPending(on: cached, planId: planId)
    }

    func jobs(planId: String, positionId: String) -> [BackendPlanSprayJob] {
        (jobsByPlan[planId] ?? []).filter { $0.resistancePositionId == positionId }
    }

    func isPendingSync(_ jobId: UUID) -> Bool {
        pendingCreates.contains { $0.payload.id == jobId }
    }

    // MARK: - Create (local-first, queued)

    /// Creates a spray job FROM a plan position, freezing the position
    /// VERBATIM as the original-intent snapshot. Prefills only what the plan
    /// genuinely knows — product identity and planned FRAC groups — never
    /// carrier volumes or rates.
    ///
    /// `library` is the Chemical Store as it stands NOW, used to freeze each
    /// line's chemistry onto the job. See `chemicalLines(for:library:)`.
    @discardableResult
    func createJob(
        name: String,
        vineyardId: UUID,
        plan: ResistancePlan,
        position: ResistancePlannedPosition,
        target: String?,
        paddockIds: [UUID],
        library: [SavedChemical],
        createdBy: UUID?
    ) -> BackendPlanSprayJob {
        let lines = Self.chemicalLines(for: position, library: library)
        let payload = BackendPlanSprayJobInsert(
            id: UUID(),
            vineyardId: vineyardId,
            name: name,
            isTemplate: false,
            status: "planned",
            target: target,
            notes: position.note,
            chemicalLines: lines,
            resistancePlanId: plan.id,
            resistancePositionId: position.id,
            resistancePositionSnapshot: position,
            resistancePlanSourceRevision: plan.serverRevision,
            createdBy: createdBy
        )
        let optimistic = payload.asJob()
        jobsByPlan[plan.id, default: []].append(optimistic)
        persistCache(planId: plan.id)
        pendingCreates.append(PendingJobCreate(payload: payload, paddockIds: paddockIds))
        persistOutbox()
        Task { await pushOutbox() }
        return optimistic
    }

    /// Builds the job's chemical lines, FREEZING each resolved product's
    /// chemistry at creation time.
    ///
    /// `chemical_id` alone is a pointer, and a pointer is re-read. Without a
    /// frozen snapshot, re-verifying or correcting that Saved Chemical later
    /// would silently restate what this job was created to apply — including the
    /// resistance groups the position was planned around. Freezing here means the
    /// job can always answer "what chemistry was this planned with?" from its own
    /// stored row.
    ///
    /// Resolution is BY IDENTIFIER ONLY. There is deliberately no name match: a
    /// position planned as a bare group carries a group label as its display name
    /// (`"FRAC 3"`), and letting that bind to a similarly-named library record
    /// would promote a stipulation the operator never made into authoritative
    /// chemistry. Such a line is written with no snapshot, which is the honest
    /// answer — the planned group itself is preserved in
    /// `resistance_position_snapshot`.
    nonisolated static func chemicalLines(
        for position: ResistancePlannedPosition,
        library: [SavedChemical],
        at date: Date = Date()
    ) -> [SprayJobChemicalLine] {
        position.products
            .filter { !$0.groups.codes.isEmpty || !($0.productName ?? "").isEmpty }
            .map { product in
                let chemicalId = product.savedChemicalId.flatMap(UUID.init(uuidString:))
                let saved = chemicalId.flatMap { id in library.first { $0.id == id } }
                let snapshot = saved.flatMap { ChemicalSnapshotCapture.capture($0, at: date) }
                // Every active, in the product's own order, so a co-formulation
                // reads as the two-active product it is rather than one name.
                let actives = snapshot?.activeIngredients.map(\.name).filter { !$0.isEmpty } ?? []
                return SprayJobChemicalLine(
                    chemicalId: chemicalId,
                    name: product.displayLabel,
                    activeIngredient: actives.isEmpty ? nil : actives.joined(separator: " + "),
                    notes: product.groups.codes.isEmpty
                        ? nil
                        : "Planned \(product.groups.displayLabel)",
                    chemicalSnapshot: snapshot
                )
            }
    }

    // MARK: - Sync

    /// Push the outbox, then pull the plan's live jobs. Queued-but-unsynced
    /// creates stay visible by overlay so an offline create never vanishes.
    func refresh(planId: String, vineyardId: UUID) async {
        load(planId: planId)
        guard repository.isConfigured else { return }
        isSyncing = true
        defer { isSyncing = false }
        await pushOutbox()
        do {
            let fetched = try await repository.fetchJobs(vineyardId: vineyardId, planId: planId)
            jobsByPlan[planId] = overlayPending(on: fetched, planId: planId)
            persistCache(planId: planId)
        } catch {
            print("[ResistancePlanJobService] fetch failed: \(error.localizedDescription)")
        }
    }

    private func pushOutbox() async {
        guard repository.isConfigured, !isPushing else { return }
        isPushing = true
        defer { isPushing = false }
        var remaining: [PendingJobCreate] = []
        for pending in pendingCreates {
            do {
                try await repository.createJob(pending.payload, paddockIds: pending.paddockIds)
            } catch {
                // Keep the marker for the next pass — the client-minted id
                // keeps the eventual replay idempotent.
                print("[ResistancePlanJobService] queued create failed: \(error.localizedDescription)")
                remaining.append(pending)
            }
        }
        pendingCreates = remaining
        persistOutbox()
    }

    // MARK: - Persistence

    private func overlayPending(on fetched: [BackendPlanSprayJob], planId: String) -> [BackendPlanSprayJob] {
        let fetchedIds = Set(fetched.map(\.id))
        let pendingForPlan = pendingCreates
            .filter { $0.payload.resistancePlanId == planId && !fetchedIds.contains($0.payload.id) }
            .map { $0.payload.asJob() }
        return fetched + pendingForPlan
    }

    private func persistCache(planId: String) {
        defaults.set(Self.encode(jobsByPlan[planId] ?? []), forKey: Self.cacheKey(planId))
    }

    private func persistOutbox() {
        defaults.set(Self.encode(pendingCreates), forKey: Self.outboxKey)
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

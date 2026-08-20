import Foundation
import Testing
@testable import VineTrack

/// STAGE 5B — Resistance Plan -> Spray Job -> Spray Record (sql/201).
/// The iOS twin of `PlanSprayJobProvenanceTest.kt`; both suites pin the SAME
/// contract:
///  * a job created from a plan position freezes the position VERBATIM as its
///    original-intent snapshot — later plan edits never rewrite it;
///  * one position may generate many jobs; each carries its own link;
///  * plan DEVIATION (proposal differs from original intent) is separate from
///    resistance COMPLIANCE (always the engine's live call);
///  * a job-originated completion writes `spray_records.spray_job_id`;
///  * the queued create payload carries the whole link, so offline creates
///    survive any sync ordering.
struct SprayJobPlanProvenanceTests {

    private static let vineyard = UUID(uuidString: "11111111-2222-4333-8444-555555555501")!
    private static let jobId = UUID(uuidString: "ccccccc1-0000-4000-8000-000000000202")!
    private static let chemicalId = UUID(uuidString: "aaaaaaa1-0000-4000-8000-000000000301")!
    private static let planId = "bbbbbbb1-0000-4000-8000-000000000201"

    private static func frac3Position() -> ResistancePlannedPosition {
        ResistancePlannedPosition(
            id: "pos-1",
            products: [
                ResistancePlannedProduct(
                    id: "prod-1",
                    groups: ResistanceGroupSignature.of(["3"]),
                    source: .group
                ),
            ],
            note: "first cover spray"
        )
    }

    private static func insert(position: ResistancePlannedPosition) -> BackendPlanSprayJobInsert {
        BackendPlanSprayJobInsert(
            id: UUID(),
            vineyardId: vineyard,
            name: "Powdery Mildew 2026/27 — Spray 1",
            isTemplate: false,
            status: "planned",
            target: "Powdery Mildew",
            notes: position.note,
            chemicalLines: position.products.map { product in
                SprayJobChemicalLine(
                    chemicalId: product.savedChemicalId.flatMap(UUID.init(uuidString:)),
                    name: product.displayLabel
                )
            },
            resistancePlanId: planId,
            resistancePositionId: position.id,
            resistancePositionSnapshot: position,
            resistancePlanSourceRevision: 4,
            createdBy: nil
        )
    }

    private static func job(
        snapshot: ResistancePlannedPosition?,
        lines: [SprayJobChemicalLine]
    ) -> BackendPlanSprayJob {
        BackendPlanSprayJob(
            id: jobId,
            vineyardId: vineyard,
            name: "Job",
            status: "planned",
            target: nil,
            notes: nil,
            chemicalLines: lines,
            resistancePlanId: snapshot == nil ? nil : planId,
            resistancePositionId: snapshot?.id,
            resistancePositionSnapshot: snapshot,
            resistancePlanSourceRevision: nil,
            createdAt: nil,
            deletedAt: nil
        )
    }

    // MARK: - Job -> Record completion link (sql/033)

    /// Every job-originated completion writes `spray_records.spray_job_id`;
    /// ad-hoc records never touch the column (key omitted, so an upsert can
    /// never clear another writer's link).
    @Test func recordUpsertCarriesSprayJobId() throws {
        let record = SprayRecord(
            vineyardId: Self.vineyard,
            sprayReference: "Powdery spray from job",
            sprayJobId: Self.jobId
        )
        let payload = BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["spray_job_id"] as? String)?.lowercased() == Self.jobId.uuidString.lowercased())

        let adHoc = SprayRecord(vineyardId: Self.vineyard)
        let adHocPayload = BackendSprayRecord.upsert(from: adHoc, createdBy: nil, clientUpdatedAt: Date())
        let adHocData = try JSONEncoder().encode(adHocPayload)
        let adHocObject = try #require(JSONSerialization.jsonObject(with: adHocData) as? [String: Any])
        #expect(adHocObject["spray_job_id"] == nil)
    }

    // MARK: - One position -> many jobs, each with the full link

    @Test func onePositionManyJobsEachCarryTheLink() throws {
        let position = Self.frac3Position()
        let first = Self.insert(position: position)
        let second = Self.insert(position: position)
        #expect(first.id != second.id)

        for payload in [first, second] {
            let data = try JSONEncoder().encode(payload)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["resistance_plan_id"] as? String == Self.planId)
            #expect(object["resistance_position_id"] as? String == "pos-1")
            #expect(object["is_template"] as? Bool == false)
            #expect(object["status"] as? String == "planned")
            let snapshot = try #require(object["resistance_position_snapshot"] as? [String: Any])
            // The snapshot's own id must equal the position id (sql/201 shape).
            #expect(snapshot["id"] as? String == "pos-1")
        }
    }

    // MARK: - Frozen original intent

    /// Manager plans FRAC 3, a job is created, the manager later edits the
    /// position to FRAC 11 — the existing job must still show FRAC 3. Job
    /// intent is NEVER derived from the current plan position.
    @Test func planEditNeverRewritesFrozenSnapshot() {
        var position = Self.frac3Position()
        let job = Self.insert(position: position).asJob()

        position.products = [
            ResistancePlannedProduct(
                id: "prod-1",
                groups: ResistanceGroupSignature.of(["11"]),
                source: .group
            ),
        ]
        #expect(position.componentGroups == ["11"])
        #expect(job.resistancePositionSnapshot?.componentGroups == ["3"])
        #expect(job.originalIntentLabel == "FRAC 3")
    }

    // MARK: - Deviation ≠ compliance

    @Test func deviationIsSeparateFromCompliance() {
        let snapshot = ResistancePlannedPosition(
            id: "pos-1",
            products: [
                ResistancePlannedProduct(
                    id: "prod-1",
                    groups: ResistanceGroupSignature.of(["3"]),
                    source: .savedChemical,
                    savedChemicalId: Self.chemicalId.uuidString,
                    productName: "Talendo"
                ),
            ]
        )

        let matching = Self.job(
            snapshot: snapshot,
            lines: [SprayJobChemicalLine(chemicalId: Self.chemicalId, name: "Talendo")]
        )
        #expect(matching.deviatesFromPlan == false)

        let deviating = Self.job(
            snapshot: snapshot,
            lines: [SprayJobChemicalLine(name: "Different Product")]
        )
        #expect(deviating.deviatesFromPlan == true)

        // A legacy unlinked job has no plan to deviate from.
        let unlinked = Self.job(snapshot: nil, lines: [SprayJobChemicalLine(name: "Anything")])
        #expect(unlinked.deviatesFromPlan == false)
    }

    // MARK: - Offline safety: the queued create carries the whole link

    @Test func outboxRoundTripPreservesProvenance() throws {
        let pending = ResistancePlanJobService.PendingJobCreate(
            payload: Self.insert(position: Self.frac3Position()),
            paddockIds: [Self.vineyard]
        )
        let data = try JSONEncoder().encode(pending)
        let decoded = try JSONDecoder().decode(ResistancePlanJobService.PendingJobCreate.self, from: data)
        #expect(decoded.payload.resistancePlanId == Self.planId)
        #expect(decoded.payload.resistancePositionId == "pos-1")
        #expect(decoded.payload.resistancePositionSnapshot.componentGroups == ["3"])
        #expect(decoded.paddockIds == [Self.vineyard])
    }

    // MARK: - Server row decode

    @Test func serverRowDecodeKeepsProvenance() throws {
        let json = """
        {"id":"\(Self.jobId.uuidString)","vineyard_id":"\(Self.vineyard.uuidString)",\
        "name":"Powdery 2026/27 — Spray 1","status":"planned",\
        "chemical_lines":[{"chemical_id":"\(Self.chemicalId.uuidString)","name":"Talendo"}],\
        "resistance_plan_id":"\(Self.planId)","resistance_position_id":"pos-1",\
        "resistance_position_snapshot":{"id":"pos-1","products":[{"id":"prod-1","group_codes":["3"],"source":"group"}]},\
        "resistance_plan_source_revision":4}
        """
        let job = try JSONDecoder().decode(BackendPlanSprayJob.self, from: Data(json.utf8))
        #expect(job.resistancePlanId == Self.planId)
        #expect(job.resistancePositionId == "pos-1")
        #expect(job.resistancePositionSnapshot?.componentGroups == ["3"])
        #expect(job.resistancePlanSourceRevision == 4)
        #expect(job.chemicalLines.first?.chemicalId == Self.chemicalId)
        #expect(job.deviatesFromPlan == false)
    }
}

import Foundation
import Testing
@testable import VineTrack

/// PRUNING COST MODEL REPAIR (sql/200) — the iOS twin of
/// `PruningWorkTaskRepairTest.kt`. Both suites assert the SAME fixtures.
///
/// Canonical model under test:
/// * a Pruning Activity is OPERATIONAL only and links 0..N Work Tasks;
/// * Work Tasks own labour cost (labour lines, piece rate);
/// * activity labour hours / total cost are DERIVED — the SUM of the linked
///   tasks' canonical totals — never a second stored dataset;
/// * legacy activity-owned labour (sql/190 lines, sql/166 scalars) stays
///   readable but is outranked the moment a linked task carries its own cost.
struct PruningWorkTaskRepairTests {

    private static let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let block = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let activityId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let taskA = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let taskB = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private static let taskC = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    private static func close(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 0.0001
        default: return false
        }
    }

    private static func draft(mirror: UUID? = nil) -> PruningActivityDraft {
        var d = PruningActivityDraft(id: activityId, vineyardId: vineyard)
        d = PruningAllocationEditor.setSegments(
            d, paddockId: block,
            segments: (59...67).flatMap { row in (1...4).map { PruningSegment(row: row, quarter: $0) } },
            blockName: "Sauv Blanc"
        )
        d.workTaskId = mirror
        return d
    }

    private static func task(
        _ id: UUID,
        pruningActivityId: UUID? = nil,
        pieceRate: Bool = false,
        day: Int = 4
    ) -> WorkTask {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return WorkTask(
            id: id,
            vineyardId: vineyard,
            date: calendar.date(from: DateComponents(year: 2026, month: 8, day: day))!,
            taskType: "Pruning",
            costingMethodRaw: pieceRate ? "piece_rate" : "hourly",
            pieceRatePerVine: pieceRate ? 0.5 : nil,
            pieceVineCount: pieceRate ? 200 : nil,
            pruningActivityId: pruningActivityId
        )
    }

    private static func line(
        _ task: UUID,
        workers: Int,
        hours: Double,
        rate: Double?
    ) -> WorkTaskLabourLine {
        WorkTaskLabourLine(
            workTaskId: task,
            vineyardId: vineyard,
            workerType: "Crew",
            workerCount: workers,
            hoursPerWorker: hours,
            hourlyRate: rate
        )
    }

    // MARK: - §22 No cost

    @Test("An activity with zero Work Tasks is valid and records no cost")
    func zeroTasksIsValidWithNoCost() {
        let d = Self.draft()
        let linked = PruningWorkTaskLink.linkedTasks(d, tasks: [])
        #expect(linked.isEmpty)

        let resolved = PruningActivityLabourCosting.resolve(
            task: nil, activityLines: [], taskLines: [],
            legacyHours: nil, legacyRate: nil,
            linkedTasks: linked, linesByTask: [:]
        )
        #expect(resolved.source == .none)
        #expect(resolved.cost == nil)
        #expect(resolved.hours == nil)
        #expect(d.canSave)
    }

    // MARK: - §22 One Work Task

    @Test("One task, 2 × 7 h × $35 → the activity derives 14 h / $490")
    func oneTaskDerives() {
        let t = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        let lines = [Self.line(Self.taskA, workers: 2, hours: 7, rate: 35)]
        let d = Self.draft(mirror: Self.taskA)

        let linked = PruningWorkTaskLink.linkedTasks(d, tasks: [t])
        #expect(linked.count == 1)

        let resolved = PruningActivityLabourCosting.resolve(
            task: t, activityLines: [], taskLines: lines,
            legacyHours: nil, legacyRate: nil,
            linkedTasks: linked, linesByTask: [Self.taskA: lines]
        )
        #expect(Self.close(resolved.hours, 14))
        #expect(Self.close(resolved.cost, 490))
    }

    // MARK: - §22 Two Work Tasks

    @Test("Two tasks (14 h/$490 + 8 h/$320) → 2 Work Tasks · 22 h · $810")
    func twoTasksSum() {
        let a = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        let b = Self.task(Self.taskB, pruningActivityId: Self.activityId, day: 5)
        let linesByTask: [UUID: [WorkTaskLabourLine]] = [
            Self.taskA: [Self.line(Self.taskA, workers: 2, hours: 7, rate: 35)],
            Self.taskB: [Self.line(Self.taskB, workers: 1, hours: 8, rate: 40)],
        ]
        let d = Self.draft(mirror: Self.taskA)

        let linked = PruningWorkTaskLink.linkedTasks(d, tasks: [a, b])
        #expect(linked.count == 2)

        let aggregate = PruningWorkTaskLink.aggregate(linked, linesByTask: linesByTask)
        #expect(aggregate.taskCount == 2)
        #expect(Self.close(aggregate.hours, 22))
        #expect(Self.close(aggregate.cost, 810))

        let resolved = PruningActivityLabourCosting.resolve(
            task: a, activityLines: [], taskLines: linesByTask[Self.taskA] ?? [],
            legacyHours: nil, legacyRate: nil,
            linkedTasks: linked, linesByTask: linesByTask
        )
        #expect(resolved.source == .workTasks)
        #expect(resolved.taskCount == 2)
        #expect(Self.close(resolved.hours, 22))
        #expect(Self.close(resolved.cost, 810))
    }

    // MARK: - §22 Multiple labour lines stay INSIDE the task

    @Test("A task with two lines (2×7×$35 + 1×7×$45) is consumed as 21 h / $805 — unchanged")
    func multiLineTaskConsumedCanonically() {
        let t = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        let lines = [
            Self.line(Self.taskA, workers: 2, hours: 7, rate: 35),
            Self.line(Self.taskA, workers: 1, hours: 7, rate: 45),
        ]
        // The canonical Work Task calculation…
        #expect(Self.close(WorkTaskLabourCosting.totalCost(lines), 805))
        #expect(Self.close(WorkTaskLabourCosting.totalPersonHours(lines), 21))
        // …is exactly what the activity consumes. The activity never
        // reproduces the lines.
        let aggregate = PruningWorkTaskLink.aggregate([t], linesByTask: [Self.taskA: lines])
        #expect(Self.close(aggregate.hours, 21))
        #expect(Self.close(aggregate.cost, 805))
    }

    // MARK: - §22 Piece-rate + hourly mix (both linked)

    @Test("Hourly $490 + piece-rate $100 on the same activity → $590, never blended")
    func pieceAndHourlyMix() {
        let hourly = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        let piece = Self.task(Self.taskC, pruningActivityId: Self.activityId, pieceRate: true, day: 6)
        let linesByTask: [UUID: [WorkTaskLabourLine]] = [
            Self.taskA: [Self.line(Self.taskA, workers: 2, hours: 7, rate: 35)],
        ]
        let aggregate = PruningWorkTaskLink.aggregate([hourly, piece], linesByTask: linesByTask)
        #expect(Self.close(aggregate.cost, 590))
        #expect(Self.close(aggregate.hours, 14))
    }

    // MARK: - §22 Unlink

    @Test("Unlinking one task decreases the aggregate and keeps the task standalone")
    func unlinkDecreasesAggregate() {
        let a = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        var b = Self.task(Self.taskB, pruningActivityId: Self.activityId, day: 5)
        let linesByTask: [UUID: [WorkTaskLabourLine]] = [
            Self.taskA: [Self.line(Self.taskA, workers: 2, hours: 7, rate: 35)],
            Self.taskB: [Self.line(Self.taskB, workers: 1, hours: 8, rate: 40)],
        ]
        var d = Self.draft(mirror: Self.taskB)

        // Unlink B: clear its origin link; the mirror promotes to A.
        b.pruningActivityId = nil
        if d.workTaskId == Self.taskB {
            let remaining = PruningWorkTaskLink.linkedTasks(d, tasks: [a]).filter { $0.id != Self.taskB }
            d.workTaskId = remaining.first?.id
        }
        let linked = PruningWorkTaskLink.linkedTasks(d, tasks: [a, b])
        #expect(linked.map(\.id) == [Self.taskA])

        let aggregate = PruningWorkTaskLink.aggregate(linked, linesByTask: linesByTask)
        #expect(Self.close(aggregate.cost, 490))
        #expect(Self.close(aggregate.hours, 14))

        // The unlinked task remains a valid standalone cost record.
        #expect(Self.close(PruningWorkTaskLink.canonicalCost(b, lines: linesByTask[Self.taskB] ?? []), 320))
    }

    // MARK: - §22 Legacy A: activity labour + linked task → Work Task wins

    @Test("Legacy activity lines + a task with its own labour: the task is authoritative, never summed")
    func legacyLinesLoseToTask() {
        let t = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        let taskLines = [Self.line(Self.taskA, workers: 1, hours: 8, rate: 40)]
        let legacyLine = PruningActivityLabourLine(
            pruningActivityId: Self.activityId,
            vineyardId: Self.vineyard,
            workDate: Date(),
            workerType: "Old crew",
            workerCount: 2,
            hoursPerWorker: 8,
            hourlyRate: 30
        )
        let resolved = PruningActivityLabourCosting.resolve(
            task: t, activityLines: [legacyLine], taskLines: taskLines,
            legacyHours: nil, legacyRate: nil,
            linkedTasks: [t], linesByTask: [Self.taskA: taskLines]
        )
        #expect(resolved.source == .workTaskLines)
        #expect(Self.close(resolved.cost, 320))
        // Never $320 + $480 = $800.
        #expect(resolved.cost != 800)
    }

    // MARK: - §22 Legacy B: activity labour, NO task — preserved, flagged legacy

    @Test("Legacy activity labour without any task keeps resolving and is flagged for migration")
    func legacyLinesWithoutTaskPreserved() {
        let legacyLine = PruningActivityLabourLine(
            pruningActivityId: Self.activityId,
            vineyardId: Self.vineyard,
            workDate: Date(),
            workerType: "Old crew",
            workerCount: 2,
            hoursPerWorker: 8,
            hourlyRate: 30
        )
        let resolved = PruningActivityLabourCosting.resolve(
            task: nil, activityLines: [legacyLine], taskLines: [],
            legacyHours: nil, legacyRate: nil,
            linkedTasks: [], linesByTask: [:]
        )
        // The data is NOT discarded…
        #expect(Self.close(resolved.cost, 480))
        #expect(Self.close(resolved.hours, 16))
        // …and it is clearly marked as the deprecated legacy source, which is
        // what the migration classifier keys on.
        #expect(resolved.source == .pruningLabourLines)
        #expect(resolved.isLegacy)
    }

    // MARK: - §22 Cross-platform round trip

    @Test("pruningActivityId survives a Codable round trip and mirror+origin links dedupe")
    func linkRoundTripAndDedupe() throws {
        let t = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(WorkTask.self, from: data)
        #expect(decoded.pruningActivityId == Self.activityId)

        // A task linked BOTH ways (origin + legacy mirror) appears once.
        let d = Self.draft(mirror: Self.taskA)
        let linked = PruningWorkTaskLink.linkedTasks(d, tasks: [t, Self.task(Self.taskB)])
        #expect(linked.map(\.id) == [Self.taskA])

        // A pre-repair cache row without the field decodes as unlinked.
        let legacy = Self.task(Self.taskB)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyDecoded = try JSONDecoder().decode(WorkTask.self, from: legacyData)
        #expect(legacyDecoded.pruningActivityId == nil)
    }

    // MARK: - Offline linkage closeout: queued create → sync → aggregate

    @Test("Offline: Task A and B created from one activity carry the link in the queued push payload and aggregate after sync")
    func offlineCreatedTasksSurviveQueuedSync() throws {
        // Device offline: both tasks are created from the same activity,
        // exactly as the tracker creates them — BORN linked (sql/200).
        let a = Self.task(Self.taskA, pruningActivityId: Self.activityId)
        let b = Self.task(Self.taskB, pruningActivityId: Self.activityId, day: 5)

        // 1. The queued sync path replays local tasks through
        //    BackendWorkTask.upsert(from:) — the wire payload must carry
        //    pruning_activity_id for BOTH tasks, not just the first.
        for t in [a, b] {
            let payload = BackendWorkTask.upsert(from: t, createdBy: nil, clientUpdatedAt: Date())
            let object = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(payload)
            ) as? [String: Any]
            let wired = (object?["pruning_activity_id"] as? String)?.lowercased()
            #expect(wired == Self.activityId.uuidString.lowercased())
        }

        // 2. Come online/sync: the server returns both rows with the same link…
        let wire = """
        [
          {"id": "\(Self.taskA.uuidString)", "vineyard_id": "\(Self.vineyard.uuidString)",
           "task_type": "Pruning", "costing_method": "hourly",
           "pruning_activity_id": "\(Self.activityId.uuidString)"},
          {"id": "\(Self.taskB.uuidString)", "vineyard_id": "\(Self.vineyard.uuidString)",
           "task_type": "Pruning", "costing_method": "hourly",
           "pruning_activity_id": "\(Self.activityId.uuidString)"}
        ]
        """
        let synced = try JSONDecoder()
            .decode([BackendWorkTask].self, from: Data(wire.utf8))
            .map { $0.toWorkTask() }
        #expect(synced.allSatisfy { $0.pruningActivityId == Self.activityId })

        // 3. …and the activity aggregates them as TWO linked Work Tasks.
        let linesByTask: [UUID: [WorkTaskLabourLine]] = [
            Self.taskA: [Self.line(Self.taskA, workers: 2, hours: 7, rate: 35)],
            Self.taskB: [Self.line(Self.taskB, workers: 1, hours: 8, rate: 40)],
        ]
        let linked = PruningWorkTaskLink.linkedTasks(Self.draft(), tasks: synced)
        #expect(linked.count == 2)
        let aggregate = PruningWorkTaskLink.aggregate(linked, linesByTask: linesByTask)
        #expect(aggregate.taskCount == 2)
        #expect(Self.close(aggregate.hours, 22))
        #expect(Self.close(aggregate.cost, 810))
    }
}

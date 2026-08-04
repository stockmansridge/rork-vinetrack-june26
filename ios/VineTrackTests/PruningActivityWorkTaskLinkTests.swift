import Foundation
import Testing
@testable import VineTrack

/// ACTIVITY-LEVEL Work Task linkage for the multi-block pruning editor — the
/// iOS twin of `PruningActivityWorkTaskLinkTest.kt`.
///
/// The regression these tests lock down: the multi-block rebuild kept
/// `workTaskId` in the draft model but dropped the visible create / link / open /
/// unlink workflow, and the offline push had no ordering guarantee between a
/// locally-created task and the activity that references it.
struct PruningActivityWorkTaskLinkTests {

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let cabFranc = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let sauvBlanc = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let activityId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let taskId = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let otherTaskId = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 9))!
    }

    private func rows(_ numbers: [Int]) -> [PruningSegment] {
        numbers.flatMap { row in (1...4).map { PruningSegment(row: row, quarter: $0) } }
    }

    /// A two-block activity: Cab Franc rows 42–44, Sauv Blanc rows 66–67.
    private func twoBlockDraft() -> PruningActivityDraft {
        var draft = PruningActivityDraft(
            id: activityId,
            vineyardId: vineyard,
            date: day(2026, 8, 4),
            worker: "Jon",
            method: .spur,
            labourHours: 7.5,
            hourlyRate: 35,
            notes: "Finished Cab Franc and moved into Sauv Blanc"
        )
        draft = PruningAllocationEditor.setSegments(
            draft, paddockId: cabFranc, segments: rows([42, 43, 44]), blockName: "Cab Franc"
        )
        draft = PruningAllocationEditor.setSegments(
            draft, paddockId: sauvBlanc, segments: rows([66, 67]), blockName: "Sauv Blanc"
        )
        return draft
    }

    private func task(
        id: UUID? = nil,
        type: String = "Pruning",
        on date: Date? = nil,
        isArchived: Bool = false
    ) -> WorkTask {
        WorkTask(
            id: id ?? taskId,
            vineyardId: vineyard,
            date: date ?? day(2026, 8, 4),
            taskType: type,
            paddockId: cabFranc,
            paddockName: "Cab Franc",
            durationHours: 7.5,
            isArchived: isArchived,
            isFinalized: true
        )
    }

    // MARK: Create + link

    @Test("Creating a task for the activity seeds date, hours and every block")
    func createDraftSeedsFromActivity() {
        let draft = twoBlockDraft()
        let create = PruningWorkTaskLink.createDraft(draft)

        #expect(create.trimmedType == "Pruning")
        #expect(create.isValid)
        #expect(create.markCompleted)
        // Shared labour, counted ONCE for the whole job — never per block.
        #expect(PruningWorkTaskLink.durationHours(draft) == 7.5)
        #expect(Set(PruningWorkTaskLink.paddockIds(draft)) == Set([cabFranc, sauvBlanc]))
        // The notes record WHICH blocks the shared labour covered.
        #expect(create.notes.contains("Cab Franc"))
        #expect(create.notes.contains("Sauv Blanc"))
        #expect(create.notes.contains("20 quarters"))
    }

    @Test("A blank work type cannot create a task")
    func blankTypeIsInvalid() {
        #expect(PruningWorkTaskLinkDraft(taskType: "   ").isValid == false)
        let typed = PruningWorkTaskLinkDraft(taskType: " Winter pruning ")
        #expect(typed.isValid)
        #expect(typed.trimmedType == "Winter pruning")
    }

    @Test("Linking stores the task on the PARENT activity only")
    func linkIsActivityLevel() throws {
        let linked = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)

        #expect(linked.workTaskId == taskId)
        let payload = PruningActivityPayload(from: linked)
        #expect(payload.workTaskId == taskId)
        #expect(payload.clearWorkTask == false)
        // One link, one activity, two allocations — the link is not repeated.
        let encoded = try JSONEncoder().encode(payload)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(json.components(separatedBy: "work_task_id").count == 2)
        #expect(linked.activeAllocations.count == 2)
    }

    @Test("Multi-block selections survive task creation, linking and change")
    func selectionsSurviveLinking() {
        let before = twoBlockDraft()
        var after = PruningWorkTaskLink.link(before, taskId: taskId)
        after = PruningWorkTaskLink.link(after, taskId: otherTaskId)

        #expect(after.workTaskId == otherTaskId)
        #expect(after.allocations == before.allocations)
        #expect(after.totalQuarters == before.totalQuarters)
        #expect(after.labourHours == before.labourHours)
        #expect(after.focusedPaddockId == before.focusedPaddockId)
        #expect(after.allocations[cabFranc]?.quarters == 12)
        #expect(after.allocations[sauvBlanc]?.quarters == 8)
    }

    // MARK: Edit + unlink

    @Test("Unlinking clears only the parent link and asks the server to clear it")
    func unlinkIsParentOnly() {
        let linked = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)
        let unlinked = PruningWorkTaskLink.unlink(linked)

        #expect(unlinked.workTaskId == nil)
        #expect(unlinked.allocations == linked.allocations)
        #expect(unlinked.labourHours == 7.5)
        let payload = PruningActivityPayload(from: unlinked)
        #expect(payload.workTaskId == nil)
        #expect(payload.clearWorkTask)
    }

    @Test("Editing labour or blocks never disturbs the task link")
    func editingKeepsLink() {
        var draft = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)
        draft.labourHours = 9.25
        draft = PruningAllocationEditor.removeBlock(draft, paddockId: cabFranc)
        draft = PruningAllocationEditor.setSegments(
            draft, paddockId: sauvBlanc, segments: rows([66, 67, 68]), blockName: "Sauv Blanc"
        )

        #expect(draft.workTaskId == taskId)
        #expect(draft.labourHours == 9.25)
        #expect(Set(draft.allocations.keys) == Set([sauvBlanc]))
    }

    // MARK: Offline dependency

    @Test("An activity waits for a Work Task created offline")
    func activityWaitsForTask() {
        let unresolved: Set<UUID> = [taskId]

        #expect(PruningWorkTaskLink.isWaitingForTask(taskId, unresolvedTaskIds: unresolved))
        // No link, or a link to an already-synced task, never waits.
        #expect(PruningWorkTaskLink.isWaitingForTask(nil, unresolvedTaskIds: unresolved) == false)
        #expect(PruningWorkTaskLink.isWaitingForTask(otherTaskId, unresolvedTaskIds: unresolved) == false)
        #expect(PruningWorkTaskLink.isWaitingForTask(taskId, unresolvedTaskIds: []) == false)
    }

    @Test("The link is never dropped to make the pruning upload succeed")
    func linkSurvivesTheWait() throws {
        let linked = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)
        // The exact bytes an offline replay would send still carry the link.
        let queued = try JSONEncoder().encode(linked)
        let replayed = try JSONDecoder().decode(PruningActivityDraft.self, from: queued)

        #expect(replayed.workTaskId == taskId)
        #expect(PruningActivityPayload(from: replayed).workTaskId == taskId)
        #expect(PruningWorkTaskLink.isWaitingForTask(replayed.workTaskId, unresolvedTaskIds: [taskId]))
    }

    // MARK: Canonical adoption

    @Test("The canonical response restores work_task_id")
    func canonicalRestoresLink() throws {
        let local = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)
        let canonical = try JSONDecoder().decode(
            BackendPruningActivityCanonical.self,
            from: Data("""
            {
              "activity": {
                "id": "\(activityId.uuidString)",
                "vineyard_id": "\(vineyard.uuidString)",
                "entry_date": "2026-08-04",
                "worker_or_crew": "Jon",
                "method": "spur",
                "labour_hours": 7.5,
                "hourly_rate": 35,
                "notes": "Finished Cab Franc and moved into Sauv Blanc",
                "work_task_id": "\(otherTaskId.uuidString)",
                "season_year": 2026,
                "vintage_year": 2027,
                "is_reversed": false
              },
              "allocations": [
                {
                  "id": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                  "paddock_id": "\(cabFranc.uuidString)",
                  "block_name": "Cab Franc",
                  "quarters": 12,
                  "estimated_vines": 240,
                  "season_year": 2026,
                  "segments": [{ "row": 42, "segment": 1 }]
                }
              ]
            }
            """.utf8)
        )

        let adopted = PruningAllocationEditor.adoptCanonical(local, canonical: canonical)

        // The SERVER's link wins wholesale — including a task it resolved
        // differently from this device's optimistic value.
        #expect(adopted.workTaskId == otherTaskId)
        #expect(adopted.serverAcknowledged)
        #expect(adopted.serverSeasonYear == 2026)
        #expect(adopted.vintageYear == 2027)
        #expect(Set(adopted.allocations.keys) == Set([cabFranc]))
    }

    @Test("A canonical response with no task clears the local link")
    func canonicalWithoutTaskClearsLink() throws {
        let local = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)
        let canonical = try JSONDecoder().decode(
            BackendPruningActivityCanonical.self,
            from: Data("""
            {
              "activity": {
                "id": "\(activityId.uuidString)",
                "vineyard_id": "\(vineyard.uuidString)",
                "entry_date": "2026-08-04",
                "season_year": 2026,
                "is_reversed": false
              },
              "allocations": []
            }
            """.utf8)
        )

        #expect(PruningAllocationEditor.adoptCanonical(local, canonical: canonical).workTaskId == nil)
    }

    // MARK: Surfacing + deep link

    @Test("A link this device cannot resolve is surfaced, not cleared")
    func unresolvableLinkIsSurfaced() {
        let draft = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)

        #expect(PruningWorkTaskLink.hasUnresolvableLink(draft, tasks: []))
        #expect(PruningWorkTaskLink.linkedTask(draft, tasks: []) == nil)
        // Still linked — the editor warns instead of silently dropping it.
        #expect(draft.workTaskId == taskId)
        #expect(PruningWorkTaskLink.hasUnresolvableLink(draft, tasks: [task()]) == false)
        #expect(
            PruningWorkTaskLink.hasUnresolvableLink(
                PruningWorkTaskLink.unlink(draft), tasks: []
            ) == false
        )
    }

    @Test("The Activity Report resolves the exact linked task")
    func reportResolvesExactTask() {
        let draft = PruningWorkTaskLink.link(twoBlockDraft(), taskId: otherTaskId)
        let tasks = [
            task(),
            task(id: otherTaskId, type: "Winter pruning", on: day(2026, 8, 2))
        ]

        let resolved = PruningWorkTaskLink.linkedTask(draft, tasks: tasks)
        #expect(resolved?.id == otherTaskId)
        #expect(resolved?.taskType == "Winter pruning")
        #expect(PruningWorkTaskLink.label(resolved!).hasPrefix("Winter pruning · Cab Franc"))
    }

    @Test("The task picker searches type, block and date and hides archived tasks")
    func pickerSearch() {
        let tasks = [
            task(id: taskId, type: "Winter pruning", on: day(2026, 8, 4)),
            task(id: otherTaskId, type: "Spur pruning", on: day(2026, 7, 29)),
            task(id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!, isArchived: true)
        ]

        // Newest first, archived rows never offered.
        #expect(PruningWorkTaskLink.search(tasks, query: "").map(\.id) == [taskId, otherTaskId])
        #expect(PruningWorkTaskLink.search(tasks, query: "spur").map(\.id) == [otherTaskId])
        #expect(PruningWorkTaskLink.search(tasks, query: "cab franc").count == 2)
        #expect(PruningWorkTaskLink.search(tasks, query: "harvest").isEmpty)
    }
}

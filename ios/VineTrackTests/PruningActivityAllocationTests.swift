import Foundation
import Testing
@testable import VineTrack

/// SHARED MULTI-BLOCK ACTIVITY FIXTURE — the same cases exist as
/// `PruningActivityAllocationTest.kt` in the Android unit-test source set, and
/// as T3–T15 of `sql/tests/166_pruning_activities_tests.sql`.
///
/// The two rules the whole feature rests on:
///  1. selections in one block are NEVER lost by working on another block,
///  2. labour, timing and rate live once on the parent activity and are never
///     apportioned or duplicated across allocations.
struct PruningActivityAllocationTests {

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let cabFranc = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let sauvBlanc = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let pinot = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let activityId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private func draft(on day: Date? = nil) -> PruningActivityDraft {
        let workDate = day ?? date(2026, 8, 4)
        return PruningActivityDraft(
            id: activityId,
            vineyardId: vineyard,
            date: workDate,
            worker: "Jon",
            method: .spur,
            startTime: Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 8))!,
            finishTime: Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 15, minute: 30))!,
            labourHours: 7.5,
            hourlyRate: 35,
            notes: "Finished Cab Franc and moved into Sauvignon Blanc"
        )
    }

    private func rows(_ numbers: [Int]) -> [PruningSegment] {
        numbers.flatMap { row in (1...4).map { PruningSegment(row: row, quarter: $0) } }
    }

    // MARK: Selection state

    @Test("Selecting rows in two blocks keeps both selections")
    func twoBlocks() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43, 44]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66, 67]), blockName: "Sauvignon Blanc")

        #expect(d.blockCount == 2)
        #expect(d.allocations[cabFranc]?.rows == [42, 43, 44])
        #expect(d.allocations[sauvBlanc]?.rows == [66, 67])
        #expect(d.totalQuarters == 20)
        #expect(abs(d.totalRowEquivalents - 5.0) < 0.0001)
    }

    @Test("Switching blocks never clears earlier selections")
    func switchingPreservesSelections() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.focus(d, paddockId: sauvBlanc, blockName: "Sauvignon Blanc")
        #expect(d.focusedPaddockId == sauvBlanc)
        #expect(d.allocations[cabFranc]?.quarters == 4)

        d = PruningAllocationEditor.toggleSegment(d, paddockId: sauvBlanc, segment: PruningSegment(row: 66, quarter: 1))
        d = PruningAllocationEditor.focus(d, paddockId: cabFranc)
        d = PruningAllocationEditor.focus(d, paddockId: pinot, blockName: "Pinot Noir")
        d = PruningAllocationEditor.focus(d, paddockId: sauvBlanc)

        #expect(d.allocations[cabFranc]?.quarters == 4)
        #expect(d.allocations[sauvBlanc]?.quarters == 1)
        #expect(d.allocations[pinot]?.isEmpty == true)
        #expect(d.blockCount == 2)
    }

    @Test("Toggling a quarter only affects its own block")
    func toggleIsScoped() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")

        d = PruningAllocationEditor.toggleSegment(d, paddockId: cabFranc, segment: PruningSegment(row: 42, quarter: 1))
        #expect(d.allocations[cabFranc]?.quarters == 3)
        #expect(d.allocations[sauvBlanc]?.quarters == 4)

        d = PruningAllocationEditor.toggleSegment(d, paddockId: cabFranc, segment: PruningSegment(row: 42, quarter: 1))
        #expect(d.allocations[cabFranc]?.quarters == 4)
    }

    @Test("Removing one block leaves the activity and other blocks intact")
    func removingOneBlock() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")
        d = PruningAllocationEditor.removeBlock(d, paddockId: cabFranc)

        #expect(d.blockCount == 1)
        #expect(d.allocations[cabFranc] == nil)
        #expect(d.allocations[sauvBlanc]?.quarters == 4)
        #expect(d.labourHours == 7.5)
        #expect(d.hourlyRate == 35)
        #expect(d.startTime != nil)
        #expect(d.focusedPaddockId == sauvBlanc)
    }

    @Test("Empty blocks are pruned before save")
    func pruneEmpty() {
        var d = draft()
        d = PruningAllocationEditor.focus(d, paddockId: cabFranc, blockName: "Cab Franc")
        d = PruningAllocationEditor.focus(d, paddockId: sauvBlanc, blockName: "Sauvignon Blanc")
        #expect(d.canSave == false)

        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")
        #expect(d.canSave)

        let cleaned = PruningAllocationEditor.pruneEmptyBlocks(d)
        #expect(cleaned.allocations.count == 1)
        #expect(cleaned.focusedPaddockId == sauvBlanc)
    }

    @Test("The block summary reads as one activity across blocks")
    func blockSummary() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")
        #expect(d.blockSummary.contains("Cab Franc"))
        #expect(d.blockSummary.contains("Sauvignon Blanc"))
        #expect(d.blockSummary.contains(" + "))
    }

    // MARK: Labour lives once

    @Test("Labour and timing are recorded once for the whole activity")
    func labourOnce() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43, 44]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66, 67]), blockName: "Sauvignon Blanc")
        d = PruningAllocationEditor.setSegments(
            d,
            paddockId: pinot,
            segments: [PruningSegment(row: 5, quarter: 1)],
            blockName: "Pinot Noir"
        )

        #expect(abs((d.durationHours ?? 0) - 7.5) < 0.0001)
        #expect(abs((d.labourCost ?? 0) - 262.5) < 0.0001)

        let legacy = PruningAllocationEditor.toLegacyEntries(d)
        #expect(legacy.count == 3)
        #expect(legacy.filter { $0.labourHours != nil }.count == 1)
        #expect(abs(legacy.compactMap(\.labourHours).reduce(0, +) - 7.5) < 0.0001)
        #expect(legacy.filter { $0.startTime != nil }.count == 1)
        #expect(legacy.filter { $0.finishTime != nil }.count == 1)
        // At most one allocation may hold the Work Task link (sql/114).
        #expect(legacy.filter { $0.workTaskId != nil }.count <= 1)
    }

    @Test("Changing labour never moves a quarter")
    func labourChangeIsIsolated() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")
        let before = d.allocations

        d.labourHours = 9.25
        d.hourlyRate = 38
        #expect(d.allocations == before)
        #expect(d.totalQuarters == 8)
        #expect(abs((d.labourCost ?? 0) - 351.5) < 0.0001)
    }

    @Test("Vine estimates stay per block")
    func vinesPerBlock() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")
        d = PruningAllocationEditor.setEstimatedVines(d, paddockId: cabFranc, vines: 400)
        d = PruningAllocationEditor.setEstimatedVines(d, paddockId: sauvBlanc, vines: 250)

        #expect(d.allocations[cabFranc]?.estimatedVines == 400)
        #expect(d.allocations[sauvBlanc]?.estimatedVines == 250)
        #expect(d.totalEstimatedVines == 650)
    }

    // MARK: Season / vintage

    @Test("The season year is the year of the work for every allocation")
    func seasonYearFollowsTheWork() {
        #expect(PruningSeasonId.seasonYear(for: date(2026, 7, 15), calendar: Self.calendar) == 2026)
        #expect(PruningSeasonId.seasonYear(for: date(2026, 8, 4), calendar: Self.calendar) == 2026)
        #expect(PruningSeasonId.seasonYear(for: date(2026, 12, 31), calendar: Self.calendar) == 2026)
        #expect(PruningSeasonId.seasonYear(for: date(2027, 1, 1), calendar: Self.calendar) == 2027)
    }

    @Test("Changing the activity date re-points every allocation season")
    func dateChangeRepointsAllAllocations() {
        var d = draft(on: date(2026, 12, 31))
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([70]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: pinot, segments: rows([21]), blockName: "Pinot Noir")

        let before = PruningAllocationEditor.toLegacyEntries(d)
        d.date = date(2027, 1, 4)
        let after = PruningAllocationEditor.toLegacyEntries(d)

        #expect(after.count == 2)
        #expect(Set(after.map(\.seasonId)).count == 2)
        // Every allocation moved: none keeps its 2026 season row.
        #expect(Set(after.map(\.seasonId)).intersection(Set(before.map(\.seasonId))).isEmpty)
    }

    // MARK: Backwards compatibility

    @Test("An existing single-block entry opens as one allocation")
    func legacyEntryOpensAsOneAllocation() {
        let entry = PruningEntry(
            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
            vineyardId: vineyard,
            paddockId: cabFranc,
            date: date(2026, 7, 29),
            segments: rows([38, 39]),
            worker: "Historic crew",
            labourHours: 6,
            method: .cane,
            notes: "legacy",
            estimatedVines: 320,
            workTaskId: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
            updatedAt: date(2026, 7, 30)
        )

        let d = PruningActivityDraft.fromLegacyEntry(entry, blockName: "Cab Franc")
        #expect(d.id == entry.id)
        #expect(d.blockCount == 1)
        #expect(d.totalQuarters == 8)
        #expect(d.method == .cane)
        #expect(d.labourHours == 6)
        #expect(d.workTaskId == entry.workTaskId)
        #expect(d.allocations[cabFranc]?.estimatedVines == 320)
        #expect(d.serverAcknowledged)

        // ...and it round-trips back to the SAME entry id and values.
        let legacy = PruningAllocationEditor.toLegacyEntries(d)
        #expect(legacy.count == 1)
        #expect(legacy.first?.id == entry.id)
        #expect(legacy.first?.seasonId == entry.seasonId)
        #expect(legacy.first?.labourHours == entry.labourHours)
        #expect(legacy.first?.segments.count == entry.segments.count)
        #expect(legacy.first?.workTaskId == entry.workTaskId)
    }

    @Test("Editing an existing single-block entry can add another block")
    func legacyEntryGainsABlock() {
        let entry = PruningEntry(
            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
            vineyardId: vineyard,
            paddockId: cabFranc,
            date: date(2026, 7, 29),
            segments: rows([38]),
            worker: "Jon",
            labourHours: 5
        )
        var d = PruningActivityDraft.fromLegacyEntry(entry, blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([58]), blockName: "Sauvignon Blanc")

        #expect(d.blockCount == 2)
        // The original allocation keeps its ORIGINAL id (never re-keyed).
        #expect(d.allocations[cabFranc]?.allocationId(for: d.id) == entry.id)
        // The new one uses the deterministic (activity, block) id.
        #expect(
            d.allocations[sauvBlanc]?.allocationId(for: d.id)
                == PruningAllocationId.make(activityId: d.id, paddockId: sauvBlanc)
        )
        let legacy = PruningAllocationEditor.toLegacyEntries(d)
        #expect(legacy.filter { $0.labourHours != nil }.count == 1)
        #expect(abs(legacy.compactMap(\.labourHours).reduce(0, +) - 5) < 0.0001)
    }

    @Test("Allocation ids are deterministic so an offline retry cannot duplicate a block")
    func deterministicAllocationIds() {
        let a = PruningAllocationId.make(activityId: activityId, paddockId: cabFranc)
        let b = PruningAllocationId.make(activityId: activityId, paddockId: cabFranc)
        #expect(a == b)
        #expect(a != PruningAllocationId.make(activityId: activityId, paddockId: sauvBlanc))
        // MD5 v3 shape, matching derive_pruning_allocation_id in SQL.
        let text = a.uuidString.lowercased()
        #expect(Array(text)[14] == "3")
        #expect("89ab".contains(Array(text)[19]))
    }

    // MARK: Offline persistence

    @Test("An offline draft round-trips every block allocation")
    func offlineDraftRoundTrip() throws {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")
        d = PruningAllocationEditor.setEstimatedVines(d, paddockId: cabFranc, vines: 600)

        let data = try JSONEncoder().encode(d)
        let restored = try JSONDecoder().decode(PruningActivityDraft.self, from: data)
        #expect(restored.blockCount == 2)
        #expect(restored.allocations[cabFranc]?.estimatedVines == 600)
        #expect(restored.allocations[sauvBlanc]?.quarters == 4)
        #expect(restored.labourHours == 7.5)
        #expect(restored.hourlyRate == 35)
    }

    // MARK: Adopting the canonical server state

    @Test("The canonical server response replaces the local activity and allocations")
    func adoptCanonical() throws {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")

        let json = """
        {
          "activity": {
            "id": "\(activityId.uuidString)",
            "vineyard_id": "\(vineyard.uuidString)",
            "entry_date": "2026-08-04",
            "worker_or_crew": "Jon",
            "method": "spur",
            "labour_hours": 7.5,
            "hourly_rate": 35,
            "labour_cost": 262.5,
            "notes": "server note",
            "season_year": 2026,
            "vintage_year": 2027,
            "is_reversed": false
          },
          "allocations": [
            {
              "id": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
              "allocation_index": 0,
              "paddock_id": "\(cabFranc.uuidString)",
              "block_name": "Cab Franc",
              "pruning_season_id": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
              "season_year": 2026,
              "rows": [42],
              "quarters": 2,
              "row_equivalents": 0.5,
              "estimated_vines": 210,
              "is_reversed": false,
              "segments": [
                { "row": 42, "segment": 1, "row_id": null, "label": "42" },
                { "row": 42, "segment": 2, "row_id": null, "label": "42" }
              ]
            }
          ],
          "totals": {
            "allocation_count": 1,
            "block_summary": "Cab Franc",
            "quarters": 2,
            "row_equivalents": 0.5,
            "estimated_vines": 210,
            "labour_hours": 7.5,
            "hourly_rate": 35,
            "labour_cost": 262.5
          }
        }
        """
        let canonical = try JSONDecoder().decode(
            BackendPruningActivityCanonical.self,
            from: Data(json.utf8)
        )
        let adopted = PruningAllocationEditor.adoptCanonical(d, canonical: canonical)

        // The server dropped the Sauvignon Blanc allocation — the client follows.
        #expect(adopted.blockCount == 1)
        #expect(adopted.allocations[sauvBlanc] == nil)
        #expect(adopted.totalQuarters == 2)
        #expect(adopted.serverSeasonYear == 2026)
        #expect(adopted.vintageYear == 2027)
        #expect(adopted.allocations[cabFranc]?.estimatedVines == 210)
        #expect(adopted.allocations[cabFranc]?.serverSeasonYear == 2026)
        #expect(adopted.serverAcknowledged)
        #expect(adopted.notes == "server note")
        // Labour still exists exactly once.
        #expect(adopted.labourHours == 7.5)
        #expect(PruningAllocationEditor.toLegacyEntries(adopted).filter { $0.labourHours != nil }.count == 1)
        #expect(canonical.totals?.allocationCount == 1)
        #expect(canonical.totals?.labourHours == 7.5)
    }

    // MARK: Payload shape

    @Test("The upload payload carries labour once and every allocation")
    func payloadShape() throws {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")
        d = PruningAllocationEditor.focus(d, paddockId: pinot, blockName: "Pinot Noir") // opened, never selected

        let params = RecordPruningActivityParams(from: d, clientUpdatedAt: date(2026, 8, 4))
        #expect(params.activityId == d.id)
        #expect(params.activity.entryDate == "2026-08-04")
        #expect(params.activity.labourHours == 7.5)
        #expect(params.activity.hourlyRate == 35)
        #expect(params.allocations.count == 2)
        #expect(Set(params.allocations.map(\.paddockId)) == Set([cabFranc, sauvBlanc]))
        #expect(params.allocations.first { $0.paddockId == cabFranc }?.quarters == 8)
        #expect(params.allocations.first { $0.paddockId == sauvBlanc }?.quarters == 4)
        // Every segment belongs to an allocation that carries its own block.
        #expect(params.allocations.allSatisfy { !$0.segments.isEmpty })

        // Every RPC key is present with explicit nulls so PostgREST always
        // resolves the same overload.
        let encoder = JSONEncoder()
        let object = try JSONSerialization.jsonObject(
            with: try encoder.encode(UpdatePruningActivityParams(from: d, clientUpdatedAt: date(2026, 8, 4)))
        ) as? [String: Any]
        #expect(object?["p_activity_id"] != nil)
        #expect(object?["p_activity"] != nil)
        #expect(object?["p_allocations"] != nil)
        #expect(object?["p_client_updated_at"] != nil)
        let activity = object?["p_activity"] as? [String: Any]
        #expect(activity?.keys.contains("labour_hours") == true)
        #expect(activity?.keys.contains("hourly_rate") == true)
        #expect(activity?.keys.contains("work_task_id") == true)
        #expect(activity?.keys.contains("clear_work_task") == true)
    }

    @Test("A block with no selection never reaches the payload")
    func emptyBlockNeverUploads() {
        var d = draft()
        d = PruningAllocationEditor.focus(d, paddockId: cabFranc, blockName: "Cab Franc")
        let params = RecordPruningActivityParams(from: d, clientUpdatedAt: date(2026, 8, 4))
        #expect(params.allocations.isEmpty)
        #expect(d.canSave == false)
    }

    @Test("Duplicate quarters are collapsed before upload")
    func duplicatesCollapse() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(
            d,
            paddockId: cabFranc,
            segments: [
                PruningSegment(row: 42, quarter: 1),
                PruningSegment(row: 42, quarter: 1),
                PruningSegment(row: 42, quarter: 2)
            ],
            blockName: "Cab Franc"
        )
        #expect(d.allocations[cabFranc]?.quarters == 2)
        let params = RecordPruningActivityParams(from: d, clientUpdatedAt: date(2026, 8, 4))
        #expect(params.allocations.first?.segments.count == 2)
    }

    @Test("Copying one block's rows into another keeps them independent")
    func copiedSelectionsAreIndependent() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        let copied = d.allocations[cabFranc]?.segments ?? []
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: copied, blockName: "Sauvignon Blanc")
        d = PruningAllocationEditor.toggleSegment(d, paddockId: sauvBlanc, segment: PruningSegment(row: 42, quarter: 1))

        #expect(d.allocations[cabFranc]?.quarters == 4)
        #expect(d.allocations[sauvBlanc]?.quarters == 3)
    }

    @Test("An allocation exposes rows, quarters, row equivalents and vines")
    func allocationShape() {
        let selection = BlockPruningSelection(
            paddockId: cabFranc,
            blockName: "Cab Franc",
            segments: rows([42, 43]) + [PruningSegment(row: 44, quarter: 1)],
            estimatedVines: 700
        )
        #expect(selection.rows == [42, 43, 44])
        #expect(selection.quarters == 9)
        #expect(abs(selection.rowEquivalents - 2.25) < 0.0001)
        #expect(selection.estimatedVines == 700)
    }
}

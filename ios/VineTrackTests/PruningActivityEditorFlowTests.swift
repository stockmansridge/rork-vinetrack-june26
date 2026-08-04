import Foundation
import Testing
@testable import VineTrack

/// The multi-block EDITOR + LIST wiring (sql/166) — the same journeys as the
/// Android `PruningActivityEditorFlowTest.kt`:
///
/// * create a one-block and a two-block activity,
/// * switch blocks without losing selections,
/// * save, reopen, add a third block, remove the primary block,
/// * change the date across a year boundary,
/// * replay one queued activity atomically,
/// * adopt the COMPLETE canonical response,
/// * report quarter conflicts instead of a clean success,
/// * reverse the whole activity,
/// * open a legacy single-block entry.
struct PruningActivityEditorFlowTests {

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

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 9))!
    }

    private func draft(on date: Date? = nil) -> PruningActivityDraft {
        PruningActivityDraft(
            id: activityId,
            vineyardId: vineyard,
            date: date ?? day(2026, 8, 4),
            worker: "Jon",
            method: .spur,
            startTime: Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 8))!,
            finishTime: Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 15, minute: 30))!,
            labourHours: 7.5,
            hourlyRate: 35,
            notes: "Cab Franc then Sauvignon Blanc"
        )
    }

    private func rows(_ numbers: [Int]) -> [PruningSegment] {
        numbers.flatMap { row in (1...4).map { PruningSegment(row: row, quarter: $0) } }
    }

    private func decodeResult(_ json: String) throws -> PruningActivityResult {
        try JSONDecoder().decode(PruningActivityResult.self, from: Data(json.utf8))
    }

    // MARK: Create

    @Test("Create a one-block activity")
    func createOneBlock() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43]), blockName: "Cab Franc")

        #expect(d.canSave)
        #expect(d.blockCount == 1)
        #expect(d.totalQuarters == 8)
        #expect(PruningActivityListing.blockLabel(d.activeAllocations.map(\.blockName)) == "Cab Franc")
        #expect(PruningActivityListing.rowRangeLabel(d.activeAllocations[0].rows) == "42–43")
    }

    @Test("Create a two-block activity with labour recorded once")
    func createTwoBlocks() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43, 44]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66, 67]), blockName: "Sauvignon Blanc")

        #expect(d.blockCount == 2)
        #expect(d.totalQuarters == 20)
        #expect(abs(d.totalRowEquivalents - 5.0) < 0.0001)
        #expect(PruningActivityListing.blockLabel(d.activeAllocations.map(\.blockName)) == "Cab Franc + Sauvignon Blanc")

        // ONE payload, both allocations, labour on the parent only.
        let params = RecordPruningActivityParams(from: d, clientUpdatedAt: day(2026, 8, 4))
        #expect(params.allocations.count == 2)
        #expect(Set(params.allocations.map(\.paddockId)) == [cabFranc, sauvBlanc])
        #expect(params.activity.labourHours == 7.5)
        #expect(params.activity.hourlyRate == 35)
        #expect(params.activity.entryDate == "2026-08-04")
    }

    @Test("Switching blocks in the editor keeps every earlier selection")
    func switchingBlocks() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.focus(d, paddockId: sauvBlanc, blockName: "Sauvignon Blanc")
        d = PruningAllocationEditor.toggleSegment(d, paddockId: sauvBlanc, segment: PruningSegment(row: 66, quarter: 2))
        d = PruningAllocationEditor.focus(d, paddockId: cabFranc)

        #expect(d.focusedPaddockId == cabFranc)
        #expect(d.allocations[cabFranc]?.quarters == 4)
        #expect(d.allocations[sauvBlanc]?.quarters == 1)
        // Activity-level fields survive every focus change.
        #expect(d.worker == "Jon")
        #expect(d.labourHours == 7.5)
        #expect(d.startTime != nil)
    }

    // MARK: Save / reopen / edit

    @Test("Save and reopen restores every block allocation")
    func saveAndReopen() throws {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauvignon Blanc")

        // The offline draft persists the COMPLETE activity, not just the block
        // that happened to be on screen.
        let encoded = try JSONEncoder().encode(PruningAllocationEditor.pruneEmptyBlocks(d))
        let reopened = try JSONDecoder().decode(PruningActivityDraft.self, from: encoded)

        #expect(reopened.blockCount == 2)
        #expect(reopened.allocations[cabFranc]?.rows == [42, 43])
        #expect(reopened.allocations[sauvBlanc]?.rows == [66])
        #expect(reopened.labourHours == 7.5)
        #expect(reopened.blockSummary == d.blockSummary)
    }

    @Test("Add a third block while editing")
    func addThirdBlock() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauv Blanc")
        d.serverAcknowledged = true

        d = PruningAllocationEditor.setSegments(d, paddockId: pinot, segments: rows([21]), blockName: "Pinot Noir")

        #expect(d.blockCount == 3)
        #expect(d.totalQuarters == 12)
        #expect(PruningActivityListing.blockLabel(d.activeAllocations.map(\.blockName)).hasSuffix("+1 more"))

        // Full desired state: an edit sends every allocation, labour still once.
        let params = UpdatePruningActivityParams(from: d, clientUpdatedAt: day(2026, 8, 4))
        #expect(params.allocations.count == 3)
        #expect(PruningAllocationEditor.toLegacyEntries(d).filter { $0.labourHours != nil }.count == 1)
    }

    @Test("Removing the primary block retains the activity labour")
    func removePrimaryBlock() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauv Blanc")
        let primary = d.activeAllocations[0].paddockId

        d = PruningAllocationEditor.removeBlock(d, paddockId: primary)

        #expect(d.blockCount == 1)
        #expect(d.allocations[primary] == nil)
        #expect(d.labourHours == 7.5)
        #expect(d.hourlyRate == 35)
        #expect(d.startTime != nil)
        #expect(d.finishTime != nil)
        // The surviving allocation is promoted to carry the labour mirror.
        let legacy = PruningAllocationEditor.toLegacyEntries(d)
        #expect(legacy.count == 1)
        #expect(legacy[0].labourHours == 7.5)
    }

    @Test("Changing the activity date across a year boundary re-files every allocation")
    func dateAcrossYearBoundary() {
        var d = draft(on: day(2026, 12, 31))
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauv Blanc")
        #expect(PruningSeasonId.seasonYear(for: d.date, calendar: Self.calendar) == 2026)

        d.date = day(2027, 1, 1)

        #expect(PruningSeasonId.seasonYear(for: d.date, calendar: Self.calendar) == 2027)
        #expect(d.blockCount == 2)
        let legacy = PruningAllocationEditor.toLegacyEntries(d)
        #expect(legacy.count == 2)
        #expect(legacy.allSatisfy { Self.calendar.component(.year, from: $0.date) == 2027 })
        // Each allocation resolves its OWN block season for the new year.
        #expect(Set(legacy.map(\.seasonId)).count == 2)
    }

    // MARK: Offline replay + canonical adoption

    @Test("A queued activity replays as one atomic payload")
    func atomicReplay() throws {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42, 43, 44]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66, 67]), blockName: "Sauv Blanc")

        let encoded = try JSONEncoder().encode(d)
        let replayed = try JSONDecoder().decode(PruningActivityDraft.self, from: encoded)
        #expect(replayed.id == d.id)

        let first = RecordPruningActivityParams(from: d, clientUpdatedAt: day(2026, 8, 4))
        let second = RecordPruningActivityParams(from: replayed, clientUpdatedAt: day(2026, 8, 5))
        // Deterministic allocation ids — a replay recreates the same rows.
        #expect(first.allocations.map(\.id).sorted { $0.uuidString < $1.uuidString }
                == second.allocations.map(\.id).sorted { $0.uuidString < $1.uuidString })
        #expect(second.allocations.count == 2)
    }

    @Test("The complete canonical response is adopted wholesale")
    func adoptCanonical() throws {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, paddockId: cabFranc, segments: rows([42]), blockName: "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([66]), blockName: "Sauv Blanc")

        let result = try decodeResult("""
        {
          "activity_id": "\(activityId.uuidString)",
          "created": true,
          "allocation_results": [
            {"paddock_id":"\(cabFranc.uuidString)","requested":4,"attributed":4,"conflicts":[]},
            {"paddock_id":"\(sauvBlanc.uuidString)","requested":4,"attributed":4,"conflicts":[]}
          ],
          "conflicts": [],
          "canonical": {
            "activity": {
              "id":"\(activityId.uuidString)","vineyard_id":"\(vineyard.uuidString)",
              "entry_date":"2026-08-04","worker_or_crew":"Server Crew","method":"cane",
              "labour_hours":8.0,"hourly_rate":40.0,"notes":"server note",
              "season_year":2026,"vintage_year":2027,"is_reversed":false
            },
            "allocations": [
              {"id":"66666666-6666-4666-8666-666666666666","allocation_index":0,
               "paddock_id":"\(cabFranc.uuidString)","block_name":"Cab Franc",
               "season_year":2026,"vintage_year":2027,"quarters":4,"row_equivalents":1.0,
               "estimated_vines":210,
               "segments":[{"row":42,"segment":1},{"row":42,"segment":2},
                           {"row":42,"segment":3},{"row":42,"segment":4}]},
              {"id":"77777777-7777-4777-8777-777777777777","allocation_index":1,
               "paddock_id":"\(sauvBlanc.uuidString)","block_name":"Sauv Blanc",
               "season_year":2026,"vintage_year":2027,"quarters":4,"row_equivalents":1.0,
               "estimated_vines":180,
               "segments":[{"row":66,"segment":1},{"row":66,"segment":2},
                           {"row":66,"segment":3},{"row":66,"segment":4}]}
            ],
            "totals": {
              "allocation_count":2,"block_summary":"Cab Franc + Sauv Blanc","quarters":8,
              "row_equivalents":2.0,"estimated_vines":390,"labour_hours":8.0,
              "hourly_rate":40.0,"labour_cost":320.0
            }
          }
        }
        """)

        let canonical = try #require(result.canonical)
        let adopted = PruningAllocationEditor.adoptCanonical(d, canonical: canonical)
        #expect(adopted.worker == "Server Crew")
        #expect(adopted.method == .cane)
        #expect(adopted.labourHours == 8.0)
        #expect(adopted.hourlyRate == 40.0)
        #expect(adopted.serverSeasonYear == 2026)
        #expect(adopted.vintageYear == 2027)
        #expect(adopted.serverAcknowledged)
        #expect(adopted.blockCount == 2)
        #expect(adopted.allocations[cabFranc]?.estimatedVines == 210)
        #expect(adopted.allocations[sauvBlanc]?.estimatedVines == 180)

        // Fully synced: nothing refused.
        let reconciliation = PruningActivityReconciliation.from(
            result,
            blockNames: [cabFranc: "Cab Franc", sauvBlanc: "Sauv Blanc"],
            blockSummary: adopted.blockSummary,
            activityId: activityId
        )
        #expect(reconciliation.isFullySynced)
        #expect(!reconciliation.hasConflicts)
        #expect(reconciliation.quartersRecorded == 8)
        #expect(reconciliation.headline == "Activity saved")
    }

    // MARK: Conflicts

    @Test("Quarter conflicts are reported instead of a clean success")
    func conflictsReported() throws {
        let result = try decodeResult("""
        {
          "activity_id": "\(activityId.uuidString)",
          "created": true,
          "allocation_results": [
            {"paddock_id":"\(cabFranc.uuidString)","requested":8,"attributed":6,
             "conflicts":[{"paddock_id":"\(cabFranc.uuidString)","row":42,"segment":3,"reason":"already_completed"},
                          {"paddock_id":"\(cabFranc.uuidString)","row":42,"segment":4,"reason":"already_completed"}]}
          ],
          "conflicts": [
            {"paddock_id":"\(cabFranc.uuidString)","row":42,"segment":3,"reason":"already_completed"},
            {"paddock_id":"\(cabFranc.uuidString)","row":42,"segment":4,"reason":"already_completed"}
          ],
          "canonical": {
            "activity": {"id":"\(activityId.uuidString)","entry_date":"2026-08-04","season_year":2026,"vintage_year":2027},
            "allocations": [],
            "totals": {"allocation_count":1,"block_summary":"Cab Franc","quarters":6}
          }
        }
        """)

        let reconciliation = PruningActivityReconciliation.from(
            result,
            blockNames: [cabFranc: "Cab Franc"],
            blockSummary: "Cab Franc",
            activityId: activityId
        )

        #expect(reconciliation.hasConflicts)
        #expect(!reconciliation.isFullySynced)
        #expect(reconciliation.quartersRecorded == 6)
        #expect(reconciliation.quartersConflicted == 2)
        #expect(reconciliation.conflictBlockIds == [cabFranc])
        #expect(reconciliation.conflicts(in: cabFranc).count == 2)
        #expect(reconciliation.headline == "Activity saved with conflicts")
        #expect(reconciliation.detail.contains("6 quarters recorded"))
        #expect(reconciliation.detail.contains("already recorded elsewhere"))
        #expect(reconciliation.conflicts(in: cabFranc)[0].label == "Row 42 · q3")
    }

    @Test("An unacknowledged write is never reported as saved")
    func unacknowledgedWrite() throws {
        let result = try decodeResult("""
        {"activity_id":"\(activityId.uuidString)","error":"activity_not_found"}
        """)
        let reconciliation = PruningActivityReconciliation.from(
            result,
            blockSummary: "Cab Franc",
            activityId: activityId
        )
        #expect(!reconciliation.isFullySynced)
        #expect(reconciliation.headline == "Activity not saved yet")
    }

    // MARK: Reversal

    @Test("Reversing the activity reverses every allocation once")
    func reverseWholeActivity() throws {
        let result = try decodeResult("""
        {"activity_id":"\(activityId.uuidString)","reversed":true,"allocations_reversed":2,
         "quarters_released":20,
         "canonical":{"activity":{"id":"\(activityId.uuidString)","entry_date":"2026-08-04","is_reversed":true},
                      "allocations":[],
                      "totals":{"allocation_count":2,"block_summary":"Cab Franc + Sauv Blanc","quarters":0}}}
        """)
        let reconciliation = PruningActivityReconciliation.from(
            result,
            blockSummary: "Cab Franc + Sauv Blanc",
            activityId: activityId,
            isReversal: true
        )
        #expect(reconciliation.headline == "Activity reversed")
        #expect(reconciliation.detail.contains("20 quarters reopened"))
        #expect(reconciliation.detail.contains("Cab Franc + Sauv Blanc"))
    }

    // MARK: Legacy

    @Test("A legacy single-block entry opens in the multi-block editor")
    func legacyEntryOpens() {
        let entry = PruningEntry(
            id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
            vineyardId: vineyard,
            paddockId: cabFranc,
            seasonId: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            date: day(2026, 7, 29),
            segments: rows([38, 39]),
            worker: "Historic crew",
            labourHours: 6,
            method: .cane,
            estimatedVines: 320,
            updatedAt: day(2026, 7, 30)
        )

        var d = PruningActivityDraft.fromLegacyEntry(entry, blockName: "Cab Franc")
        #expect(d.blockCount == 1)
        #expect(d.id == entry.id)
        #expect(PruningActivityListing.blockLabel(d.activeAllocations.map(\.blockName)) == "Cab Franc")

        // ...and another block can be added without touching the labour.
        d = PruningAllocationEditor.setSegments(d, paddockId: sauvBlanc, segments: rows([58]), blockName: "Sauv Blanc")
        #expect(d.blockCount == 2)
        #expect(d.labourHours == 6)
        #expect(PruningAllocationEditor.toLegacyEntries(d).filter { $0.labourHours != nil }.count == 1)
    }

    // MARK: List display

    @Test("The activity list labels one, two and many blocks")
    func listLabels() {
        #expect(PruningActivityListing.blockLabel(["Cab Franc"]) == "Cab Franc")
        #expect(PruningActivityListing.blockLabel(["Cab Franc", "Sauv Blanc"]) == "Cab Franc + Sauv Blanc")
        #expect(PruningActivityListing.blockLabel(["Cab Franc", "Sauv Blanc", "Pinot", "Shiraz"])
                == "Cab Franc + Sauv Blanc +2 more")
        #expect(PruningActivityListing.blockLabel([]) == "No blocks")
        #expect(PruningActivityListing.blockLabel([" "]) == "Block")
    }

    @Test("Search matches the activity when any allocation matches")
    func searchMatching() {
        let blocks = ["Cab Franc", "Sauv Blanc"]
        #expect(PruningActivityListing.matches(query: "sauv", blockNames: blocks, worker: "Jon", notes: "", rowLabels: ["66", "67"]))
        #expect(PruningActivityListing.matches(query: "jon", blockNames: blocks, worker: "Jon", notes: "", rowLabels: []))
        #expect(PruningActivityListing.matches(query: "67", blockNames: blocks, worker: "Jon", notes: "", rowLabels: ["66", "67"]))
        #expect(!PruningActivityListing.matches(query: "shiraz", blockNames: blocks, worker: "Jon", notes: "", rowLabels: []))
        #expect(PruningActivityListing.matches(query: "  ", blockNames: blocks, worker: "Jon", notes: "", rowLabels: []))
    }

    @Test("Row ranges collapse contiguous runs")
    func rowRanges() {
        #expect(PruningActivityListing.rowRangeLabel([42, 43, 44]) == "42–44")
        #expect(PruningActivityListing.rowRangeLabel([44, 38, 43, 42, 39]) == "38–39, 42–44")
        #expect(PruningActivityListing.rowRangeLabel([66]) == "66")
        #expect(PruningActivityListing.rowRangeLabel([]) == "—")
    }
}

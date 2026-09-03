import Foundation
import Testing
@testable import VineTrack

/// PRUNING ACTIVITY CACHE ADOPTION — the regression suite for the defect where
/// iOS block and vineyard progress read LOW and the activity feed rendered
/// synced activities as "No blocks, 0 rows, 0 quarters" while the portal and
/// Android were correct.
///
/// ROOT CAUSE. `list_pruning_activities` calls `pruning_activity_json(id, false)`
/// (sql/166 §12), so every allocation comes back with `"segments": null` — the
/// per-quarter detail is deliberately withheld from the lightweight feed. The
/// iOS decoder collapsed that null into `[]`, `adoptCanonical` then replaced the
/// allocation set with empty allocations, and `PruningStore` treated every
/// allocation that had "disappeared" as STALE and stamped `reversedAt` on its
/// legacy projected entry. Since progress is calculated from those entries, one
/// pull silently reversed the whole vineyard's pruning work. The editor still
/// looked right because it reads `get_pruning_activity`, which DOES include the
/// quarters.
///
/// The rule these tests pin down: a summary response may refresh parent metadata
/// and the allocation set, but ONLY a detailed record may rewrite quarters.
@MainActor
struct PruningActivityCacheTests {

    // MARK: Fixture — the production-shaped Sauvignon Blanc case

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private static let asOf = date(2026, 8, 5)

    private static let vineyardId = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    private static let sauvBlancId = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!
    private static let cabFrancId = UUID(uuidString: "00000000-0000-4000-8000-0000000000a3")!
    private static let activityId = UUID(uuidString: "00000000-0000-4000-8000-0000000000a4")!
    private static let priorActivityId = UUID(uuidString: "00000000-0000-4000-8000-0000000000a5")!

    private static let metresPerDegreeLat = 111_320.0

    private static func rowId(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    private static func row(_ number: Int) -> PaddockRow {
        let lon = 150.0 + Double(number) * 0.001
        return PaddockRow(
            id: rowId(number),
            number: number,
            startPoint: CoordinatePoint(latitude: 0, longitude: lon),
            endPoint: CoordinatePoint(latitude: 200.0 / metresPerDegreeLat, longitude: lon)
        )
    }

    /// Sauvignon Blanc — rows 58 to 68 inclusive, eleven 200 m rows, 2200 vines.
    private static let sauvBlanc = Paddock(
        id: sauvBlancId,
        vineyardId: vineyardId,
        name: "Sauvignon Blanc",
        rows: (58...68).map { row($0) },
        vineSpacing: 1.0,
        vineCountOverride: 2_200
    )

    /// A second block, so the vineyard roll-up is a real sum and not a copy of
    /// one block's number.
    private static let cabFranc = Paddock(
        id: cabFrancId,
        vineyardId: vineyardId,
        name: "Cab Franc",
        rows: (42...45).map { row($0) },
        vineSpacing: 1.0,
        vineCountOverride: 800
    )

    private static let sauvBlancSetup = PruningBlockSetup(
        vineyardId: vineyardId,
        paddockId: sauvBlancId,
        seasonYear: 2026,
        startDate: date(2026, 8, 1),
        dueDate: date(2026, 8, 31),
        workingDays: [1, 2, 3, 4, 5]
    )

    private static let cabFrancSetup = PruningBlockSetup(
        vineyardId: vineyardId,
        paddockId: cabFrancId,
        seasonYear: 2026,
        startDate: date(2026, 8, 1),
        dueDate: date(2026, 8, 31),
        workingDays: [1, 2, 3, 4, 5]
    )

    private static func quarters(_ row: Int, _ list: [Int]) -> [PruningSegment] {
        list.map { PruningSegment(rowId: rowId(row), row: row, quarter: $0) }
    }

    private static func fullRow(_ row: Int) -> [PruningSegment] {
        quarters(row, [1, 2, 3, 4])
    }

    /// Quarters completed BEFORE this activity, by an earlier record:
    /// row 58 Q1, and rows 66–67 Q1–Q3. Seven quarters = 1.75 row equivalents.
    private static let priorSegments: [PruningSegment] =
        quarters(58, [1]) + quarters(66, [1, 2, 3]) + quarters(67, [1, 2, 3])

    /// The Sauvignon Blanc allocation of THIS activity: rows 59–60 Q4, rows
    /// 61–65 every quarter, rows 66–67 Q4. 2 + 20 + 2 = 24 quarters = 6.00 rows.
    private static let sauvBlancSegments: [PruningSegment] =
        quarters(59, [4]) + quarters(60, [4])
        + (61...65).flatMap { fullRow($0) }
        + quarters(66, [4]) + quarters(67, [4])

    /// The Cab Franc allocation of the same activity: rows 42–43 complete.
    private static let cabFrancSegments: [PruningSegment] = fullRow(42) + fullRow(43)

    // Expected totals, DERIVED from the rows above rather than copied from a
    // screenshot — so the fixture states the contract instead of pinning one
    // observed percentage. These are the same numbers the portal's
    // `row_equivalents_completed` roll-up stores and the same ones Android
    // produces from these rows; the Kotlin twin of this suite is still to be
    // written, so cross-platform agreement is asserted here by construction
    // (quarters / 4) rather than by a shared golden file.
    private static let priorQuarters = 7
    private static let activitySauvBlancQuarters = 24
    private static let sauvBlancTotalQuarters = 31          // 7 prior + 24 this
    private static let sauvBlancRowEquivalents = 7.75       // 31 / 4
    private static let sauvBlancRowCount = 11.0             // rows 58…68
    private static let cabFrancRowEquivalents = 2.0         // 8 / 4
    private static let cabFrancRowCount = 4.0

    private static let priorAllocationId = PruningAllocationId.make(
        activityId: priorActivityId,
        paddockId: sauvBlancId
    )
    private static let sauvBlancAllocationId = PruningAllocationId.make(
        activityId: activityId,
        paddockId: sauvBlancId
    )
    private static let cabFrancAllocationId = PruningAllocationId.make(
        activityId: activityId,
        paddockId: cabFrancId
    )

    // MARK: Store helpers

    /// A store backed by its own throwaway directory, so each test starts clean
    /// and "restart the app" can be simulated by building a second store over
    /// the SAME directory.
    private static func makeStore(
        directory: URL
    ) -> PruningStore {
        PruningStore(persistence: PersistenceStore(directory: directory))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pruning-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The earlier activity's projected entry — already in the cache, exactly as
    /// a previous sync would have left it.
    private static func seedPriorWork(_ store: PruningStore) {
        store.applyRemoteSeasonUpsert(sauvBlancSetup)
        store.applyRemoteSeasonUpsert(cabFrancSetup)
        store.applyRemoteEntryUpsert(
            PruningEntry(
                id: priorAllocationId,
                vineyardId: vineyardId,
                paddockId: sauvBlancId,
                seasonId: sauvBlancSetup.id,
                date: date(2026, 8, 3),
                segments: priorSegments,
                worker: "Earlier Crew",
                pruningActivityId: priorActivityId,
                allocationIndex: 0
            )
        )
        // applyRemoteEntryUpsert preserves the LOCAL segment list for an entry it
        // already knows; for a brand-new one it takes the payload as given.
    }

    // MARK: Canonical payload builders

    private static func segmentJSON(_ segments: [PruningSegment]) -> String {
        segments.map { segment in
            """
            {"row": \(segment.row), "segment": \(segment.quarter), \
            "row_id": "\(segment.rowId?.uuidString.lowercased() ?? "")", \
            "label": "\(segment.row)"}
            """
        }.joined(separator: ", ")
    }

    private static func allocationJSON(
        id: UUID,
        index: Int,
        paddockId: UUID,
        blockName: String,
        seasonId: UUID,
        segments: [PruningSegment],
        estimatedVines: Int,
        includeSegments: Bool
    ) -> String {
        let rows = Array(Set(segments.map(\.row))).sorted()
        // The exact shape of `pruning_activity_json`: rows, quarters, row
        // equivalents and vines are present in BOTH fidelities. Only `segments`
        // is withheld, and it is withheld as an explicit null.
        let segmentField = includeSegments
            ? "[\(segmentJSON(segments))]"
            : "null"
        return """
        {
          "id": "\(id.uuidString.lowercased())",
          "allocation_index": \(index),
          "paddock_id": "\(paddockId.uuidString.lowercased())",
          "block_name": "\(blockName)",
          "pruning_season_id": "\(seasonId.uuidString.lowercased())",
          "season_year": 2026,
          "vintage_year": 2027,
          "rows": [\(rows.map(String.init).joined(separator: ", "))],
          "quarters": \(segments.count),
          "row_equivalents": \(Double(segments.count) / 4.0),
          "estimated_vines": \(estimatedVines),
          "is_reversed": false,
          "segments": \(segmentField)
        }
        """
    }

    /// The two-block activity as the server returns it.
    ///
    /// `includeSegments: true` is `get_pruning_activity` and every create /
    /// update response. `false` is `list_pruning_activities`.
    private static func canonicalJSON(
        includeSegments: Bool,
        worker: String = "Pruning Crew",
        isReversed: Bool = false,
        allocations: [String]? = nil
    ) -> String {
        let defaultAllocations = [
            allocationJSON(
                id: sauvBlancAllocationId,
                index: 0,
                paddockId: sauvBlancId,
                blockName: "Sauvignon Blanc",
                seasonId: sauvBlancSetup.id,
                segments: sauvBlancSegments,
                estimatedVines: 1_200,
                includeSegments: includeSegments
            ),
            allocationJSON(
                id: cabFrancAllocationId,
                index: 1,
                paddockId: cabFrancId,
                blockName: "Cab Franc",
                seasonId: cabFrancSetup.id,
                segments: cabFrancSegments,
                estimatedVines: 400,
                includeSegments: includeSegments
            )
        ]
        let list = allocations ?? defaultAllocations
        let quarters = activitySauvBlancQuarters + cabFrancSegments.count
        return """
        {
          "activity": {
            "id": "\(activityId.uuidString.lowercased())",
            "vineyard_id": "\(vineyardId.uuidString.lowercased())",
            "entry_date": "2026-08-05",
            "worker_or_crew": "\(worker)",
            "method": "spur",
            "duration_hours": 7.5,
            "labour_hours": 26,
            "hourly_rate": 35,
            "labour_cost": 910,
            "notes": "Finished Sauvignon Blanc and started Cab Franc",
            "season_year": 2026,
            "vintage_year": 2027,
            "is_reversed": \(isReversed)
          },
          "allocations": [\(list.joined(separator: ", "))],
          "totals": {
            "allocation_count": \(list.count),
            "block_summary": "Sauvignon Blanc + Cab Franc",
            "quarters": \(quarters),
            "row_equivalents": \(Double(quarters) / 4.0),
            "estimated_vines": 1600,
            "labour_hours": 26,
            "hourly_rate": 35,
            "labour_cost": 910
          }
        }
        """
    }

    private static func canonical(
        includeSegments: Bool,
        worker: String = "Pruning Crew",
        isReversed: Bool = false,
        allocations: [String]? = nil
    ) throws -> BackendPruningActivityCanonical {
        try JSONDecoder().decode(
            BackendPruningActivityCanonical.self,
            from: Data(
                canonicalJSON(
                    includeSegments: includeSegments,
                    worker: worker,
                    isReversed: isReversed,
                    allocations: allocations
                ).utf8
            )
        )
    }

    // MARK: Progress helpers — the SHARED calculation, never a local sum

    private static func blockMetrics(_ store: PruningStore, _ paddock: Paddock) -> PruningBlockMetrics {
        PruningCalculator.metrics(
            paddock: paddock,
            setup: store.setup(for: paddock.id, seasonYear: 2026),
            entries: store.entries(for: paddock.id),
            calendar: calendar,
            asOf: asOf
        )
    }

    private static func vineyardSummary(_ store: PruningStore) -> PruningVineyardSummary {
        PruningCalculator.vineyardSummary(
            blocks: [sauvBlanc, cabFranc].map { paddock in
                (metrics: blockMetrics(store, paddock), entries: store.entries(for: paddock.id))
            },
            calendar: calendar,
            asOf: asOf
        )
    }

    private static func close(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < tolerance
    }

    // MARK: 1. The decoder tells "withheld" apart from "empty"

    @Test("A summary response decodes withheld quarters as not-supplied, never as empty")
    func summaryDecodesAsNotSupplied() throws {
        let summary = try Self.canonical(includeSegments: false)

        #expect(summary.allocations.count == 2)
        #expect(summary.isSummaryOnly)
        #expect(!summary.hasSegmentDetail)
        for allocation in summary.allocations {
            #expect(allocation.segments == nil)
            #expect(!allocation.hasSegmentDetail)
            // The quarter COUNT is still supplied — the feed knows how much work
            // exists, it just won't say which quarters.
            #expect(allocation.quarters > 0)
        }

        let detail = try Self.canonical(includeSegments: true)
        #expect(detail.hasSegmentDetail)
        #expect(!detail.isSummaryOnly)
        #expect(detail.allocations.allSatisfy { ($0.segments ?? []).isEmpty == false })
        #expect(PruningCanonicalScope(detail) == .detailed)
        #expect(PruningCanonicalScope(summary) == .summary)
        #expect(PruningCanonicalScope(detail).replacesSegments)
        #expect(!PruningCanonicalScope(summary).replacesSegments)
    }

    // MARK: 2. A detailed response is adopted whole and projected

    @Test("Adopting the canonical create response projects EVERY allocation")
    func detailedAdoptionProjectsEveryAllocation() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)

        let adopted = try #require(store.applyRemoteActivity(Self.canonical(includeSegments: true)))

        // Parent
        #expect(adopted.id == Self.activityId)
        #expect(adopted.worker == "Pruning Crew")
        #expect(Self.close(adopted.labourHours, 26))
        #expect(Self.close(adopted.hourlyRate, 35))
        #expect(adopted.serverAcknowledged)
        #expect(adopted.serverSeasonYear == 2026)
        #expect(adopted.vintageYear == 2027)
        #expect(adopted.serverQuarters == 32)
        #expect(adopted.serverAllocationCount == 2)
        #expect(!adopted.needsCanonicalDetail)

        // Every allocation, with its own quarters
        #expect(adopted.blockCount == 2)
        #expect(adopted.totalQuarters == 32)
        let sauv = try #require(adopted.allocations[Self.sauvBlancId])
        #expect(sauv.blockName == "Sauvignon Blanc")
        #expect(sauv.quarters == Self.activitySauvBlancQuarters)
        #expect(Self.close(sauv.rowEquivalents, 6.0))
        #expect(sauv.rows == [59, 60, 61, 62, 63, 64, 65, 66, 67])
        #expect(sauv.estimatedVines == 1_200)
        #expect(sauv.serverSeasonId == Self.sauvBlancSetup.id)
        #expect(sauv.serverSeasonYear == 2026)

        // Both allocations reached the legacy projection, each stamped with its
        // parent, its index, its block and the canonical season.
        let projected = store.entries.filter { $0.pruningActivityId == Self.activityId }
        #expect(projected.count == 2)
        let sauvEntry = try #require(projected.first { $0.paddockId == Self.sauvBlancId })
        #expect(sauvEntry.id == Self.sauvBlancAllocationId)
        #expect(sauvEntry.allocationIndex == 0)
        #expect(sauvEntry.segments.count == Self.activitySauvBlancQuarters)
        #expect(Self.close(sauvEntry.rowEquivalents, 6.0))
        #expect(sauvEntry.seasonId == Self.sauvBlancSetup.id)
        #expect(sauvEntry.estimatedVines == 1_200)
        #expect(sauvEntry.activityKey == Self.activityId)

        let cabEntry = try #require(projected.first { $0.paddockId == Self.cabFrancId })
        #expect(cabEntry.allocationIndex == 1)
        #expect(cabEntry.segments.count == 8)
        #expect(cabEntry.seasonId == Self.cabFrancSetup.id)
        // Labour rides on the primary allocation only — never duplicated.
        #expect(cabEntry.labourHours == nil)
        #expect(Self.close(sauvEntry.labourHours, 26))
    }

    // MARK: 3. THE REGRESSION — a summary refresh must not zero anything

    @Test("A summary refresh leaves every completed quarter intact")
    func summaryRefreshPreservesQuarters() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        let before = Self.blockMetrics(store, Self.sauvBlanc)
        #expect(Self.close(before.completedRowEquivalents, Self.sauvBlancRowEquivalents))

        // The pull that used to destroy the data.
        let refreshed = try #require(store.applyRemoteActivity(Self.canonical(includeSegments: false)))

        #expect(refreshed.blockCount == 2)
        #expect(refreshed.totalQuarters == 32)
        #expect(refreshed.allocations[Self.sauvBlancId]?.quarters == Self.activitySauvBlancQuarters)
        #expect(refreshed.allocations[Self.sauvBlancId]?.blockName == "Sauvignon Blanc")
        #expect(refreshed.allocations[Self.cabFrancId]?.quarters == 8)
        #expect(Self.close(refreshed.totalRowEquivalents, 8.0))
        #expect(refreshed.totalEstimatedVines == 1_600)
        #expect(!refreshed.needsCanonicalDetail)

        // No projected entry was reversed, and none lost its quarters.
        let projected = store.entries.filter { $0.pruningActivityId == Self.activityId }
        #expect(projected.count == 2)
        #expect(projected.allSatisfy { !$0.isReversed })
        #expect(projected.first { $0.paddockId == Self.sauvBlancId }?.segments.count == Self.activitySauvBlancQuarters)
        #expect(projected.first { $0.paddockId == Self.cabFrancId }?.segments.count == 8)
        // The earlier activity's work is untouched too.
        #expect(store.entries.first { $0.id == Self.priorAllocationId }?.segments.count == Self.priorQuarters)
        #expect(store.entries.first { $0.id == Self.priorAllocationId }?.isReversed == false)

        // And progress did not move.
        let after = Self.blockMetrics(store, Self.sauvBlanc)
        #expect(Self.close(after.completedRowEquivalents, before.completedRowEquivalents))
        #expect(Self.close(after.fractionComplete, before.fractionComplete))
    }

    @Test("Repeated summary refreshes never erode progress")
    func repeatedSummaryRefreshesAreStable() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))
        let baseline = Self.vineyardSummary(store).fraction

        // Every pull-to-refresh, app foreground and eager push ran this path.
        for _ in 0..<5 {
            store.applyRemoteActivity(try Self.canonical(includeSegments: false))
        }

        #expect(Self.close(Self.vineyardSummary(store).fraction, baseline))
        #expect(store.entries.filter { $0.pruningActivityId == Self.activityId }.allSatisfy { !$0.isReversed })
        #expect(store.auditActivityCache(vineyardId: Self.vineyardId).isHealthy)
    }

    @Test("A summary refresh still updates parent metadata")
    func summaryRefreshUpdatesParentMetadata() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        let refreshed = try #require(
            store.applyRemoteActivity(Self.canonical(includeSegments: false, worker: "Night Crew"))
        )

        // Parent metadata is not withheld, so it IS adopted.
        #expect(refreshed.worker == "Night Crew")
        // …while the quarters it did not carry are preserved.
        #expect(refreshed.totalQuarters == 32)
    }

    // MARK: 4. A block genuinely removed server-side is still reversed

    @Test("An allocation the server no longer lists is reversed even in a summary")
    func removedAllocationIsStillReversed() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        // Cab Franc was dropped from the activity on another device. Absence
        // from the allocation SET is authoritative in both fidelities.
        let sauvOnly = Self.allocationJSON(
            id: Self.sauvBlancAllocationId,
            index: 0,
            paddockId: Self.sauvBlancId,
            blockName: "Sauvignon Blanc",
            seasonId: Self.sauvBlancSetup.id,
            segments: Self.sauvBlancSegments,
            estimatedVines: 1_200,
            includeSegments: false
        )
        let refreshed = try #require(
            store.applyRemoteActivity(Self.canonical(includeSegments: false, allocations: [sauvOnly]))
        )

        #expect(refreshed.blockCount == 1)
        #expect(refreshed.allocations[Self.cabFrancId] == nil)
        // The dropped allocation's entry is reversed for the audit trail…
        #expect(store.entries.first { $0.id == Self.cabFrancAllocationId }?.isReversed == true)
        // …and only it. Sauvignon Blanc is untouched.
        #expect(store.entries.first { $0.id == Self.sauvBlancAllocationId }?.isReversed == false)
        #expect(Self.close(Self.blockMetrics(store, Self.cabFranc).completedRowEquivalents, 0))
        #expect(
            Self.close(
                Self.blockMetrics(store, Self.sauvBlanc).completedRowEquivalents,
                Self.sauvBlancRowEquivalents
            )
        )
    }

    // MARK: 5. Restart from local persistence

    @Test("Allocations and quarters survive an app restart")
    func restartRetainsAllocations() throws {
        let directory = try Self.temporaryDirectory()
        let first = Self.makeStore(directory: directory)
        Self.seedPriorWork(first)
        first.applyRemoteActivity(try Self.canonical(includeSegments: true))
        let expected = Self.blockMetrics(first, Self.sauvBlanc).completedRowEquivalents

        // Cold launch over the same on-disk cache.
        let relaunched = Self.makeStore(directory: directory)

        let restored = try #require(relaunched.activity(id: Self.activityId))
        #expect(restored.blockCount == 2)
        #expect(restored.totalQuarters == 32)
        #expect(restored.allocations[Self.sauvBlancId]?.quarters == Self.activitySauvBlancQuarters)
        #expect(restored.serverQuarters == 32)
        #expect(!restored.needsCanonicalDetail)
        #expect(Self.close(Self.blockMetrics(relaunched, Self.sauvBlanc).completedRowEquivalents, expected))

        // The first refresh after launch is a summary — it must stay stable.
        relaunched.applyRemoteActivity(try Self.canonical(includeSegments: false))
        #expect(Self.close(Self.blockMetrics(relaunched, Self.sauvBlanc).completedRowEquivalents, expected))
    }

    // MARK: 6. Repairing an already-hollow cache

    @Test("A summary-first device is flagged hollow, then repaired by the detailed record")
    func repairsHollowProjectionFromDetail() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        store.applyRemoteSeasonUpsert(Self.sauvBlancSetup)
        store.applyRemoteSeasonUpsert(Self.cabFrancSetup)

        // This device meets the activity for the first time through the summary
        // feed: it has the parent and the allocation set, but no quarters and no
        // legacy rows to rehydrate from.
        let hollow = try #require(store.applyRemoteActivity(Self.canonical(includeSegments: false)))
        #expect(hollow.blockCount == 0)
        #expect(hollow.totalQuarters == 0)
        #expect(hollow.serverQuarters == 32)
        #expect(hollow.serverAllocationCount == 2)
        // It knows it is incomplete rather than reporting zero as the truth.
        #expect(hollow.needsCanonicalDetail)
        #expect(store.activitiesNeedingCanonicalDetail(vineyardId: Self.vineyardId).map(\.id) == [Self.activityId])

        let audit = store.auditActivityCache(vineyardId: Self.vineyardId)
        #expect(!audit.isHealthy)
        #expect(audit.parentsWithoutAllocations == 1)
        #expect(audit.allocationsMissingSegmentDetail == 2)
        #expect(audit.activityIdsNeedingDetail == [Self.activityId])

        // The repair pass fetches the authoritative record.
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        let repaired = try #require(store.activity(id: Self.activityId))
        #expect(repaired.blockCount == 2)
        #expect(repaired.totalQuarters == 32)
        #expect(!repaired.needsCanonicalDetail)
        #expect(store.activitiesNeedingCanonicalDetail(vineyardId: Self.vineyardId).isEmpty)
        #expect(store.auditActivityCache(vineyardId: Self.vineyardId).isHealthy)
        #expect(
            Self.close(
                Self.blockMetrics(store, Self.sauvBlanc).completedRowEquivalents,
                6.0 // no prior work seeded in this test
            )
        )
    }

    @Test("A summary rehydrates quarters from the legacy projection when it can")
    func summaryRehydratesFromProjectedEntries() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        store.applyRemoteSeasonUpsert(Self.sauvBlancSetup)
        // The entry pull (`pruning_entries` + `pruning_row_segments`) runs
        // independently of the activity feed, so a reinstalled device often has
        // the server's real quarters before it has ever seen the activity.
        store.applyRemoteEntryUpsert(
            PruningEntry(
                id: Self.sauvBlancAllocationId,
                vineyardId: Self.vineyardId,
                paddockId: Self.sauvBlancId,
                seasonId: Self.sauvBlancSetup.id,
                date: Self.date(2026, 8, 5),
                segments: Self.sauvBlancSegments,
                pruningActivityId: Self.activityId,
                allocationIndex: 0
            )
        )

        let adopted = try #require(store.applyRemoteActivity(Self.canonical(includeSegments: false)))

        // Sauvignon Blanc came back from the entry cache; Cab Franc had nothing
        // to rehydrate from and stays hollow until the repair fetch.
        #expect(adopted.allocations[Self.sauvBlancId]?.quarters == Self.activitySauvBlancQuarters)
        #expect(adopted.blockCount == 1)
        #expect(adopted.needsCanonicalDetail)
        #expect(
            Self.close(Self.blockMetrics(store, Self.sauvBlanc).completedRowEquivalents, 6.0)
        )
    }

    // MARK: 7. Block progress comes from completed quarters

    @Test("Block progress equals completed quarters over four, across all allocations")
    func blockProgressMatchesCompletedQuarters() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        let metrics = Self.blockMetrics(store, Self.sauvBlanc)

        // 7 previously completed quarters + 24 completed in this activity.
        #expect(metrics.completed.count == Self.sauvBlancTotalQuarters)
        #expect(Self.close(metrics.completedRowEquivalents, Self.sauvBlancRowEquivalents))
        #expect(Self.close(metrics.completedRowEquivalents, Double(metrics.completed.count) / 4.0))
        #expect(Self.close(metrics.totalRowEquivalents, Self.sauvBlancRowCount))
        #expect(
            Self.close(
                metrics.fractionComplete,
                Self.sauvBlancRowEquivalents / Self.sauvBlancRowCount
            )
        )
        // 7.75 / 11 = 70.45…% — derived, not a hard-coded screenshot value.
        #expect(PruningCalculator.displayPercent(metrics.fractionComplete) == 70)

        // Row 68 was never touched, and no quarter is double-counted even though
        // rows 66–67 were worked by two different activities.
        let touchedRows: Set<Int> = Set(metrics.completed.map(\.row))
        #expect(!touchedRows.contains(68))
        #expect(touchedRows == Set(58...67))
        #expect(metrics.completed.filter { $0.row == 66 }.count == 4)
        #expect(metrics.completed.filter { $0.row == 58 }.count == 1)
    }

    // MARK: 8. Vineyard progress sums the blocks

    @Test("Vineyard progress is the sum across active blocks, not a block roll-up")
    func vineyardProgressSumsBlocks() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        let summary = Self.vineyardSummary(store)
        let expectedCompleted = Self.sauvBlancRowEquivalents + Self.cabFrancRowEquivalents
        let expectedTotal = Self.sauvBlancRowCount + Self.cabFrancRowCount

        #expect(Self.close(summary.completedRowEquivalents, expectedCompleted))  // 9.75
        #expect(Self.close(summary.totalRowEquivalents, expectedTotal))          // 15
        #expect(Self.close(summary.fraction, expectedCompleted / expectedTotal)) // 0.65
        #expect(summary.displayPercent == 65)
        #expect(summary.blockCount == 2)

        // A summary refresh must not move the vineyard number either.
        store.applyRemoteActivity(try Self.canonical(includeSegments: false))
        #expect(Self.close(Self.vineyardSummary(store).fraction, expectedCompleted / expectedTotal))
    }

    // MARK: 9. Reversed work is excluded

    @Test("Reversing the activity excludes every allocation from progress")
    func reversedAllocationsExcluded() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        store.reverseActivity(id: Self.activityId)

        // Only the earlier activity's 7 quarters remain.
        let metrics = Self.blockMetrics(store, Self.sauvBlanc)
        #expect(metrics.completed.count == Self.priorQuarters)
        #expect(Self.close(metrics.completedRowEquivalents, 1.75))
        #expect(Self.close(Self.blockMetrics(store, Self.cabFranc).completedRowEquivalents, 0))
        #expect(Self.close(Self.vineyardSummary(store).completedRowEquivalents, 1.75))

        // The rows survive as audit history, and a later summary refresh must not
        // resurrect them into progress.
        #expect(store.entries.filter { $0.pruningActivityId == Self.activityId }.count == 2)
        #expect(store.auditEntries(forVineyard: Self.vineyardId).count == 3)
        store.applyRemoteActivity(try Self.canonical(includeSegments: false, isReversed: true))
        #expect(Self.close(Self.blockMetrics(store, Self.sauvBlanc).completedRowEquivalents, 1.75))
    }

    // MARK: 10. Removing the Tracker section removed no data

    @Test("The activity feed and Activity Report data outlive the Tracker's Recent activities card")
    func activityFeedSurvivesTrackerCleanup() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        // The feed the Activity Report, the editor, exports and diagnostics read.
        let feed = store.activities(forVineyard: Self.vineyardId)
        #expect(feed.count == 1)
        #expect(feed.first?.blockCount == 2)
        #expect(store.activity(id: Self.activityId)?.totalQuarters == 32)

        // The Activity Report's own rows — one per allocation, still complete.
        let blocks: [UUID: PruningActivityBlockContext] = [
            Self.sauvBlancId: PruningActivityBlockContext(
                name: "Sauvignon Blanc",
                variety: "Sauvignon Blanc",
                rows: PruningCalculator.rowRefs(paddock: Self.sauvBlanc, setup: Self.sauvBlancSetup)
            ),
            Self.cabFrancId: PruningActivityBlockContext(
                name: "Cab Franc",
                variety: "Cab Franc",
                rows: PruningCalculator.rowRefs(paddock: Self.cabFranc, setup: Self.cabFrancSetup)
            )
        ]
        // `rows(...)` is a `PruningActivityReport` factory; `PruningActivityRow`
        // is the value type it returns.
        let reportRows = PruningActivityReport.rows(
            entries: store.auditEntries(forVineyard: Self.vineyardId),
            blocks: blocks,
            workTaskTitles: [:],
            labourCosts: [:],
            accountNames: [:],
            calendar: Self.calendar
        )
        // Two allocations of this activity plus the earlier activity's row.
        #expect(reportRows.count == 3)
        let thisActivity = reportRows.filter { $0.activityKey == Self.activityId }
        #expect(thisActivity.count == 2)
        #expect(thisActivity.map(\.allocationIndex).sorted() == [0, 1])
        #expect(Self.close(thisActivity.reduce(0) { $0 + $1.rowEquivalents }, 8.0))
        #expect(thisActivity.contains { $0.blockName == "Sauvignon Blanc" })
        #expect(thisActivity.contains { $0.blockName == "Cab Franc" })
    }

    // MARK: 11. Cross-platform parity of the Sauvignon Blanc total

    @Test("The Sauvignon Blanc fixture yields the same row-equivalent total on every platform")
    func sauvignonBlancRowEquivalentParity() throws {
        let directory = try Self.temporaryDirectory()
        let store = Self.makeStore(directory: directory)
        Self.seedPriorWork(store)
        store.applyRemoteActivity(try Self.canonical(includeSegments: true))

        let metrics = Self.blockMetrics(store, Self.sauvBlanc)
        let activityQuarters = store.entries
            .first { $0.id == Self.sauvBlancAllocationId }?
            .segments.count ?? 0

        // The parity line the portal and Android must both reproduce from these
        // same rows. Kept as one rendered string so the Kotlin twin can assert
        // the identical literal when it is added.
        let rendered = [
            "quarters_this_activity=\(activityQuarters)",
            "row_equivalents_this_activity=\(String(format: "%.2f", Double(activityQuarters) / 4.0))",
            "quarters_block_total=\(metrics.completed.count)",
            "row_equivalents_block_total=\(String(format: "%.2f", metrics.completedRowEquivalents))",
            "block_rows=\(Int(metrics.totalRowEquivalents))",
            "block_percent=\(PruningCalculator.displayPercent(metrics.fractionComplete))"
        ].joined(separator: "|")

        #expect(rendered == """
        quarters_this_activity=24|row_equivalents_this_activity=6.00|\
        quarters_block_total=31|row_equivalents_block_total=7.75|\
        block_rows=11|block_percent=70
        """)

        // The editor, the block card and the parent draft must all agree.
        let draft = try #require(store.activity(id: Self.activityId))
        #expect(draft.allocations[Self.sauvBlancId]?.quarters == activityQuarters)
        #expect(Self.close(draft.allocations[Self.sauvBlancId]?.rowEquivalents, 6.0))
    }
}

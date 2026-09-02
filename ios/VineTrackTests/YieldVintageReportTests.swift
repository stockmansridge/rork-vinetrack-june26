import XCTest
@testable import VineTrack

/// Contract tests for the Vintage-driven Yield Report and Bunch Count Trip
/// rules. Mirrors `YieldVintageReportTest.kt` on Android so both platforms
/// pin the same behaviour:
///  - latest COMPLETED trip per Block + Vintage drives the current estimate
///    (never summed, never averaged; drafts ignored)
///  - damage adjustment is presentation-time and never mutates base counts
///  - past vintages: Detailed Picking Log supersedes Basic actuals
///  - route reuse preserves site identity but strips counts
///  - financial merge is owner/manager-only projection data
final class YieldVintageReportTests: XCTestCase {

    private let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let blockA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let blockB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    private var paddocks: [Paddock] {
        [
            Paddock(
                id: blockA,
                vineyardId: vineyardId,
                name: "Shiraz North",
                vineCountOverride: 1000,
                varietyAllocations: [
                    PaddockVarietyAllocation(varietyId: UUID(), percent: 100, name: "Shiraz")
                ]
            ),
            Paddock(
                id: blockB,
                vineyardId: vineyardId,
                name: "River Block",
                vineCountOverride: 500,
                varietyAllocations: [
                    PaddockVarietyAllocation(varietyId: UUID(), percent: 100, name: "Grenache")
                ]
            )
        ]
    }

    /// Noon UTC — safe against timezone drift in date-only vintage maths.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func trip(
        id: UUID = UUID(),
        blockId: UUID,
        avgBunches: Double,
        completedAt: Date?,
        createdAt: Date? = nil,
        applyDamage: Bool = true
    ) -> YieldEstimationSession {
        YieldEstimationSession(
            id: id,
            vineyardId: vineyardId,
            createdAt: createdAt ?? date(2025, 11, 1),
            selectedPaddockIds: [blockId],
            samplesPerHectare: 20,
            sampleSites: [
                SampleSite(
                    paddockId: blockId,
                    rowNumber: 1,
                    latitude: 0,
                    longitude: 0,
                    siteIndex: 1,
                    bunchCountEntry: BunchCountEntry(bunchesPerVine: avgBunches, recordedAt: date(2025, 12, 1))
                )
            ],
            blockBunchWeightsKg: [blockId: 0.1], // 100 g bunches
            isCompleted: completedAt != nil,
            completedAt: completedAt,
            applyDamage: applyDamage
        )
    }

    private func pick(
        id: UUID = UUID(),
        blockId: UUID,
        variety: String,
        weightKg: Double,
        vintage: Int,
        sold: Bool = false
    ) -> PickingRecord {
        PickingRecord(
            id: id,
            vineyardId: vineyardId,
            pickedAt: date(2025, 2, 10),
            vintage: vintage,
            paddockId: blockId,
            paddockName: paddocks.first { $0.id == blockId }?.name ?? "Block",
            varietyName: variety,
            weightKg: weightKg,
            sold: sold
        )
    }

    // MARK: - Latest completed trip wins

    func testLatestCompletedTripDrivesTheCurrentEstimate() {
        let december = trip(id: UUID(), blockId: blockA, avgBunches: 30, completedAt: date(2025, 12, 10))
        let january = trip(id: UUID(), blockId: blockA, avgBunches: 20, completedAt: date(2026, 1, 15))
        let newerDraft = trip(blockId: blockA, avgBunches: 50, completedAt: nil, createdAt: date(2026, 2, 1))

        let rows = YieldVintageReport.estimateRows(
            sessions: [december, january, newerDraft],
            paddocks: paddocks,
            remainingYieldMultiplier: { _ in 1.0 },
            vintage: 2026,
            seasonStartMonth: 7,
            seasonStartDay: 1
        )

        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        // 1000 vines × 20 bunches × 0.1 kg = 2.0 t — the January (latest) count.
        XCTAssertEqual(row.sessionId, january.id)
        XCTAssertEqual(row.baseTonnes, 2.0, accuracy: 1e-9)
        // Never the December value (3.0), the sum (5.0) or the average (2.5).
        XCTAssertFalse([3.0, 5.0, 2.5].contains(row.baseTonnes))
        XCTAssertEqual(row.varietyLabel, "Shiraz")
    }

    func testOlderTripsRemainHistoricalPerVintage() {
        let v25 = trip(id: UUID(), blockId: blockA, avgBunches: 40, completedAt: date(2025, 1, 20), createdAt: date(2025, 1, 1))
        let v26 = trip(id: UUID(), blockId: blockA, avgBunches: 20, completedAt: date(2026, 1, 20))

        let rows25 = YieldVintageReport.estimateRows(
            sessions: [v25, v26], paddocks: paddocks, remainingYieldMultiplier: { _ in 1.0 },
            vintage: 2025, seasonStartMonth: 7, seasonStartDay: 1
        )
        let rows26 = YieldVintageReport.estimateRows(
            sessions: [v25, v26], paddocks: paddocks, remainingYieldMultiplier: { _ in 1.0 },
            vintage: 2026, seasonStartMonth: 7, seasonStartDay: 1
        )

        XCTAssertEqual(rows25.count, 1)
        XCTAssertEqual(rows25[0].sessionId, v25.id)
        XCTAssertEqual(rows25[0].baseTonnes, 4.0, accuracy: 1e-9)
        XCTAssertEqual(rows26.count, 1)
        XCTAssertEqual(rows26[0].sessionId, v26.id)
    }

    // MARK: - Damage adjustment

    func testDamageAdjustsDisplayWithoutMutatingBase() {
        let session = trip(blockId: blockA, avgBunches: 30, completedAt: date(2026, 1, 15))

        let rows = YieldVintageReport.estimateRows(
            sessions: [session], paddocks: paddocks,
            remainingYieldMultiplier: { _ in 0.8 }, // 20% recorded damage
            vintage: 2026, seasonStartMonth: 7, seasonStartDay: 1
        )
        let row = rows[0]

        XCTAssertEqual(row.baseTonnes, 3.0, accuracy: 1e-9)
        XCTAssertEqual(row.adjustedTonnes, 2.4, accuracy: 1e-9)
        XCTAssertEqual(row.displayTonnes, 2.4, accuracy: 1e-9) // applyDamage = true
        // The field observations were never touched.
        XCTAssertEqual(session.sampleSites[0].bunchCountEntry?.bunchesPerVine, 30)
    }

    func testApplyDamageFalseShowsBaseButKeepsAdjustedAvailable() {
        let session = trip(blockId: blockA, avgBunches: 30, completedAt: date(2026, 1, 15), applyDamage: false)

        let row = YieldVintageReport.estimateRows(
            sessions: [session], paddocks: paddocks,
            remainingYieldMultiplier: { _ in 0.5 },
            vintage: 2026, seasonStartMonth: 7, seasonStartDay: 1
        )[0]

        XCTAssertEqual(row.displayTonnes, 3.0, accuracy: 1e-9)
        XCTAssertEqual(row.adjustedTonnes, 1.5, accuracy: 1e-9)
    }

    // MARK: - Session vintage & available vintages

    func testSessionVintageUsesSeasonSettings() {
        let session = trip(blockId: blockA, avgBunches: 10, completedAt: date(2025, 12, 15))
        // July season start: Dec 2025 belongs to the season ending 2026.
        XCTAssertEqual(
            YieldVintageReport.sessionVintage(session, seasonStartMonth: 7, seasonStartDay: 1, calendar: utcCalendar),
            2026
        )
        // January season start: Dec 2025 is vintage 2025.
        XCTAssertEqual(
            YieldVintageReport.sessionVintage(session, seasonStartMonth: 1, seasonStartDay: 1, calendar: utcCalendar),
            2025
        )
    }

    func testAvailableVintagesLeadsWithCurrentAndSortsDescending() {
        let picks = [pick(blockId: blockA, variety: "Shiraz", weightKg: 1000, vintage: 2025)]
        let records = [
            HistoricalYieldRecord(
                vineyardId: vineyardId,
                year: 2024,
                blockResults: [HistoricalBlockResult(paddockId: blockA, paddockName: "Shiraz North", yieldTonnes: 11, actualYieldTonnes: 10)]
            )
        ]
        let vintages = YieldVintageReport.availableVintages(
            currentVintage: 2026,
            sessions: [],
            yieldRecords: records,
            pickingRecords: picks,
            seasonStartMonth: 7,
            seasonStartDay: 1
        )
        XCTAssertEqual(vintages, [2026, 2025, 2024])
    }

    // MARK: - Past vintage actuals: Detailed supersedes Basic

    func testDetailedPickingTotalsSupersedeBasicActuals() {
        let records = [
            HistoricalYieldRecord(
                vineyardId: vineyardId,
                year: 2025,
                blockResults: [
                    HistoricalBlockResult(paddockId: blockA, paddockName: "Shiraz North", areaHectares: 2, yieldTonnes: 12, actualYieldTonnes: 10),
                    HistoricalBlockResult(paddockId: blockB, paddockName: "River Block", areaHectares: 1, yieldTonnes: 6, actualYieldTonnes: 5)
                ]
            )
        ]
        let picks = [
            pick(blockId: blockA, variety: "Shiraz", weightKg: 5000, vintage: 2025),
            pick(blockId: blockA, variety: "Shiraz", weightKg: 3000, vintage: 2025)
        ]

        let rows = YieldVintageReport.actualRows(
            vintage: 2025, paddocks: paddocks, yieldRecords: records, pickingRecords: picks
        )

        // Block A: the summed picking log (8 t) IS the actual — Basic 10 t superseded.
        let a = rows.filter { $0.paddockId == blockA }
        XCTAssertEqual(a.count, 1)
        XCTAssertTrue(a[0].fromDetailed)
        XCTAssertEqual(a[0].tonnes, 8.0, accuracy: 1e-9)
        XCTAssertEqual(a[0].estimatedTonnes ?? -1, 12.0, accuracy: 1e-9)
        XCTAssertEqual(a[0].varianceTonnes ?? 0, -4.0, accuracy: 1e-9)

        // Block B keeps its Basic actual (no picks).
        let b = rows.filter { $0.paddockId == blockB }
        XCTAssertEqual(b.count, 1)
        XCTAssertFalse(b[0].fromDetailed)
        XCTAssertEqual(b[0].tonnes, 5.0, accuracy: 1e-9)
        XCTAssertEqual(b[0].varietyName, "Grenache")
    }

    func testActualRowsGroupPerBlockAndVariety() {
        let picks = [
            pick(blockId: blockA, variety: "Shiraz", weightKg: 2000, vintage: 2025),
            pick(blockId: blockA, variety: "Grenache", weightKg: 1000, vintage: 2025),
            pick(blockId: blockB, variety: "Grenache", weightKg: 500, vintage: 2025)
        ]
        let rows = YieldVintageReport.actualRows(
            vintage: 2025, paddocks: paddocks, yieldRecords: [], pickingRecords: picks
        )
        XCTAssertEqual(rows.count, 3)
        let blockARows = rows.filter { $0.paddockId == blockA }
        XCTAssertEqual(
            Set(blockARows.map { "\($0.varietyName)|\($0.tonnes)" }),
            ["Shiraz|2.0", "Grenache|1.0"]
        )
    }

    // MARK: - Financial merge

    func testFinancialMergeAppliesManagerProjection() {
        let masked = pick(blockId: blockA, variety: "Shiraz", weightKg: 2000, vintage: 2025, sold: true)
        let merged = PickingFinancialsMerge.apply(
            [PickingFinancialRow(pickingRecordId: masked.id, soldTo: "Wine Co", pricePerTonne: 1500, grapeValue: 3.0)],
            to: [masked]
        )[0]
        XCTAssertEqual(merged.soldTo, "Wine Co")
        XCTAssertEqual(merged.pricePerTonne ?? 0, 1500, accuracy: 1e-9)
        // Computed grape value mirrors the server: 2 t × 1500 = 3.0.
        XCTAssertEqual(merged.grapeValue ?? 0, 3.0, accuracy: 1e-9)

        // Operators (no projection) keep masked NULLs.
        let untouched = PickingFinancialsMerge.apply([], to: [masked])[0]
        XCTAssertNil(untouched.soldTo)
        XCTAssertNil(untouched.pricePerTonne)
        XCTAssertNil(untouched.grapeValue)
    }

    // MARK: - Bunch Count Trip lifecycle & route reuse

    private func sessionWithSites(
        id: UUID = UUID(),
        blockId: UUID,
        siteCount: Int,
        isCompleted: Bool,
        completedAt: Date? = nil,
        createdAt: Date? = nil
    ) -> YieldEstimationSession {
        YieldEstimationSession(
            id: id,
            vineyardId: vineyardId,
            createdAt: createdAt ?? date(2025, 11, 1),
            selectedPaddockIds: [blockId],
            sampleSites: (1...siteCount).map { idx in
                SampleSite(
                    id: UUID(),
                    paddockId: blockId,
                    rowNumber: idx,
                    latitude: Double(idx) * 0.001,
                    longitude: Double(idx) * 0.001,
                    siteIndex: idx,
                    bunchCountEntry: BunchCountEntry(bunchesPerVine: Double(idx) * 10, recordedAt: date(2025, 12, 1))
                )
            },
            isCompleted: isCompleted,
            completedAt: completedAt
        )
    }

    func testActiveDraftIsNewestIncompleteAndCompletedTripsSortDescending() {
        let done1 = sessionWithSites(blockId: blockA, siteCount: 2, isCompleted: true, completedAt: date(2025, 12, 1))
        let done2 = sessionWithSites(blockId: blockA, siteCount: 2, isCompleted: true, completedAt: date(2026, 1, 5))
        let draftOld = sessionWithSites(blockId: blockA, siteCount: 1, isCompleted: false, createdAt: date(2026, 1, 10))
        let draftNew = sessionWithSites(blockId: blockB, siteCount: 1, isCompleted: false, createdAt: date(2026, 2, 1))

        let all = [done1, draftOld, done2, draftNew]
        XCTAssertEqual(BunchCountTripLogic.activeDraft(sessions: all, vineyardId: vineyardId)?.id, draftNew.id)
        XCTAssertEqual(
            BunchCountTripLogic.completedTrips(sessions: all, vineyardId: vineyardId).map(\.id),
            [done2.id, done1.id]
        )
        // Other vineyard sees nothing.
        XCTAssertNil(BunchCountTripLogic.activeDraft(sessions: all, vineyardId: UUID()))
        XCTAssertTrue(BunchCountTripLogic.completedTrips(sessions: all, vineyardId: UUID()).isEmpty)
    }

    func testReusableRoutePreservesSiteIdentityAndStripsCounts() {
        let completed = sessionWithSites(blockId: blockA, siteCount: 3, isCompleted: true, completedAt: date(2025, 12, 1))
        let otherBlock = sessionWithSites(blockId: blockB, siteCount: 2, isCompleted: true, completedAt: date(2025, 11, 1))

        let route = BunchCountTripLogic.reusableRoute(
            sessions: [completed, otherBlock],
            selectedPaddockIds: [blockA, blockB],
            excludeSessionId: UUID()
        )

        XCTAssertNotNil(route)
        XCTAssertEqual(route?.sites.count, 5)
        // Original site ids preserved (comparable locations across trips).
        let originalIds = Set(completed.sampleSites.map(\.id) + otherBlock.sampleSites.map(\.id))
        XCTAssertEqual(Set(route!.sites.map(\.id)), originalIds)
        // Counts stripped, indices sequential.
        XCTAssertTrue(route!.sites.allSatisfy { $0.bunchCountEntry == nil })
        XCTAssertEqual(route!.sites.map(\.siteIndex), Array(1...5))
        XCTAssertEqual(route?.sourceSessionId, completed.id)
    }

    func testReusableRoutePrefersNewestCompletedSource() {
        let older = sessionWithSites(blockId: blockA, siteCount: 2, isCompleted: true, completedAt: date(2025, 11, 1))
        let newer = sessionWithSites(blockId: blockA, siteCount: 3, isCompleted: true, completedAt: date(2025, 12, 20))
        let route = BunchCountTripLogic.reusableRoute(sessions: [older, newer], selectedPaddockIds: [blockA])
        XCTAssertEqual(route?.sourceSessionId, newer.id)
        XCTAssertEqual(route?.sites.count, 3)
    }

    func testNoPriorRouteMeansNoPrompt() {
        let otherBlockOnly = sessionWithSites(blockId: blockB, siteCount: 2, isCompleted: true, completedAt: date(2025, 11, 1))
        // The current draft itself never counts as a prior route.
        let draft = sessionWithSites(blockId: blockA, siteCount: 2, isCompleted: false)
        XCTAssertNil(BunchCountTripLogic.reusableRoute(sessions: [otherBlockOnly], selectedPaddockIds: [blockA]))
        XCTAssertNil(BunchCountTripLogic.reusableRoute(sessions: [draft], selectedPaddockIds: [blockA], excludeSessionId: draft.id))
        XCTAssertNil(BunchCountTripLogic.reusableRoute(sessions: [], selectedPaddockIds: [blockA]))
    }

    // MARK: - Payload round-trip (additive fields)

    func testAdditivePayloadFieldsRoundTripAndDefaultForLegacyPayloads() throws {
        let source = trip(blockId: blockA, avgBunches: 12, completedAt: date(2026, 1, 15), applyDamage: false)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(YieldEstimationSession.self, from: try encoder.encode(source))
        XCTAssertFalse(decoded.applyDamage)

        // Legacy payload without the new keys → applyDamage defaults to true
        // (historical sessions keep their damage-adjusted numbers).
        var json = try JSONSerialization.jsonObject(with: try encoder.encode(source)) as! [String: Any]
        json.removeValue(forKey: "applyDamage")
        json.removeValue(forKey: "routeSourceSessionId")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let legacy = try decoder.decode(YieldEstimationSession.self, from: legacyData)
        XCTAssertTrue(legacy.applyDamage)
        XCTAssertNil(legacy.routeSourceSessionId)
    }

    // MARK: - Route preview (pre-start confirmation) controls
    // The simplified screen shows the map plus Start Sampling only, with a
    // single Regenerate Path for newly generated routes. Mirrors the Android
    // route-preview tests exactly.

    func testExistingRoutePreviewShowsOnlyMapAndStartSampling() {
        let c = BunchCountTripLogic.routePreviewControls(
            isRouteReused: true, recordedSiteCount: 0, isCompleted: false
        )
        XCTAssertTrue(c.showsStartSampling)
        XCTAssertFalse(c.startSamplingIsContinue)
        XCTAssertTrue(c.showsReuseIndicator) // subtle "Using previous sampling route"
        XCTAssertFalse(c.showsRegeneratePath) // no regeneration actions for reused routes
        XCTAssertFalse(c.showsProgress) // 0/X progress is noise before starting
        XCTAssertFalse(c.showsCompleteAction)
        XCTAssertFalse(c.showsBunchWeights) // bunch weight belongs to completion
        XCTAssertFalse(c.showsSampleSiteList) // sites are represented on the map
        XCTAssertFalse(c.deleteIsPrimaryAction) // delete lives in the overflow menu
    }

    func testNewRoutePreviewShowsSingleRegeneratePathAndStartSampling() {
        let c = BunchCountTripLogic.routePreviewControls(
            isRouteReused: false, recordedSiteCount: 0, isCompleted: false
        )
        XCTAssertTrue(c.showsStartSampling)
        XCTAssertTrue(c.showsRegeneratePath) // the ONE regeneration action
        XCTAssertFalse(c.showsReuseIndicator)
        XCTAssertFalse(c.showsProgress)
        XCTAssertFalse(c.showsCompleteAction)
        XCTAssertFalse(c.showsBunchWeights)
        XCTAssertFalse(c.showsSampleSiteList)
        XCTAssertFalse(c.deleteIsPrimaryAction)
    }

    func testActiveSamplingShowsProgressAndCompletionButNoRegeneration() {
        let c = BunchCountTripLogic.routePreviewControls(
            isRouteReused: false, recordedSiteCount: 3, isCompleted: false
        )
        XCTAssertTrue(c.showsStartSampling)
        XCTAssertTrue(c.startSamplingIsContinue) // "Continue Sampling"
        XCTAssertFalse(c.showsRegeneratePath) // route locked once counts exist
        XCTAssertTrue(c.showsProgress)
        XCTAssertTrue(c.showsCompleteAction)
        XCTAssertFalse(c.deleteIsPrimaryAction)
    }

    func testCompletedTripPreviewHidesAllActions() {
        let c = BunchCountTripLogic.routePreviewControls(
            isRouteReused: true, recordedSiteCount: 5, isCompleted: true
        )
        XCTAssertFalse(c.showsStartSampling)
        XCTAssertFalse(c.showsRegeneratePath)
        XCTAssertTrue(c.showsProgress) // final tally is meaningful history
        XCTAssertFalse(c.showsCompleteAction)
        XCTAssertFalse(c.deleteIsPrimaryAction)
    }
}

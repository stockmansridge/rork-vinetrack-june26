import Foundation

/// Vintage-driven Yield Report logic, shared by the Reports screen and
/// mirrored on Android (`YieldVintageReport.kt`) so both platforms pin the
/// same rules:
///
///  * CURRENT vintage → the Yield Estimate per Block comes from the LATEST
///    COMPLETED Bunch Count Trip for that Block in that vintage. Sessions are
///    never summed or averaged — the newest completed observation wins.
///  * PAST vintages → Actual Yield per Block + Variety: Detailed Picking Log
///    totals supersede Basic actuals for the same combination (sql/180 rule,
///    never added on top).
///  * Damage adjustment is presentation-time: the base estimate is always
///    kept and the trip's `applyDamage` flag chooses the displayed figure.
nonisolated enum YieldVintageReport {

    /// One current-vintage estimate row (per Block, from the latest completed trip).
    nonisolated struct EstimateRow: Identifiable, Sendable {
        var id: UUID { paddockId }
        let paddockId: UUID
        let blockName: String
        let varietyLabel: String
        let areaHectares: Double
        /// Raw bunch-count estimate, no damage applied. Always preserved.
        let baseTonnes: Double
        /// Base × current effective damage factor for the block.
        let adjustedTonnes: Double
        let damageFactor: Double
        let applyDamage: Bool
        let averageBunchesPerVine: Double
        let samplesRecorded: Int
        let samplesTotal: Int
        let sessionId: UUID
        let completedAt: Date?

        var displayTonnes: Double { applyDamage ? adjustedTonnes : baseTonnes }
        var tonnesPerHectare: Double? {
            guard areaHectares > 0 else { return nil }
            return displayTonnes / areaHectares
        }
    }

    /// One past-vintage actual row (per Block + Variety).
    nonisolated struct ActualRow: Identifiable, Sendable {
        var id: String { "\(paddockId.uuidString)|\(varietyName.lowercased())" }
        let paddockId: UUID
        let blockName: String
        let varietyName: String
        let tonnes: Double
        let areaHectares: Double
        /// Matching estimate for the same combination, for variance drilldown.
        let estimatedTonnes: Double?
        /// true = Detailed Picking Log total, false = Basic manual actual.
        let fromDetailed: Bool

        var varianceTonnes: Double? { estimatedTonnes.map { tonnes - $0 } }
        var tonnesPerHectare: Double? {
            guard areaHectares > 0 else { return nil }
            return tonnes / areaHectares
        }
    }

    /// Vintage a session belongs to: resolved from completedAt, else createdAt.
    static func sessionVintage(
        _ session: YieldEstimationSession,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        calendar: Calendar = .current
    ) -> Int {
        VintageResolver.vintageYear(
            for: session.completedAt ?? session.createdAt,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            calendar: calendar
        )
    }

    /// All vintages worth offering, newest first: the current vintage always
    /// leads, then every vintage that has trips, archived records or picks.
    static func availableVintages(
        currentVintage: Int,
        sessions: [YieldEstimationSession],
        yieldRecords: [HistoricalYieldRecord],
        pickingRecords: [PickingRecord],
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> [Int] {
        var all: Set<Int> = [currentVintage]
        for session in sessions where session.isCompleted {
            all.insert(sessionVintage(session, seasonStartMonth: seasonStartMonth, seasonStartDay: seasonStartDay))
        }
        for record in yieldRecords where record.year > 0 { all.insert(record.year) }
        for pick in pickingRecords where pick.vintage > 0 { all.insert(pick.vintage) }
        return all.sorted(by: >)
    }

    /// Latest completed trip that recorded sites in the block for the vintage.
    /// The critical rule: newest completed observation wins; older trips
    /// remain history and are never merged in.
    static func latestCompletedSessionForBlock(
        sessions: [YieldEstimationSession],
        paddockId: UUID,
        vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> YieldEstimationSession? {
        sessions
            .filter { $0.isCompleted }
            .filter { sessionVintage($0, seasonStartMonth: seasonStartMonth, seasonStartDay: seasonStartDay) == vintage }
            .filter { session in
                session.sampleSites.contains { $0.paddockId == paddockId && $0.isRecorded }
            }
            .max { ($0.completedAt ?? $0.createdAt) < ($1.completedAt ?? $1.createdAt) }
    }

    /// Base (no damage) estimate for one block from one session, using the
    /// canonical formula: vines × avg bunches/vine (2 dp) × bunch weight.
    static func baseEstimate(
        session: YieldEstimationSession,
        paddock: Paddock
    ) -> (tonnes: Double, averageBunchesPerVine: Double, samplesRecorded: Int, samplesTotal: Int)? {
        let sites = session.sampleSites.filter { $0.paddockId == paddock.id }
        let recorded = sites.filter(\.isRecorded)
        guard !recorded.isEmpty else { return nil }
        let avg = recorded.reduce(0.0) { $0 + ($1.bunchCountEntry?.bunchesPerVine ?? 0) } / Double(recorded.count)
        let avgRounded = (avg * 100).rounded() / 100
        let totalBunches = Double(paddock.effectiveVineCount) * avgRounded
        let yieldKg = totalBunches * session.bunchWeightKg(for: paddock.id)
        return (yieldKg / 1000.0, avgRounded, recorded.count, sites.count)
    }

    /// Current-vintage estimate rows: one per block, driven by that block's
    /// latest completed trip. Damage respects the trip's `applyDamage` flag
    /// but the base figure is always computed and returned untouched.
    static func estimateRows(
        sessions: [YieldEstimationSession],
        paddocks: [Paddock],
        damageFactor: (UUID) -> Double,
        vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> [EstimateRow] {
        var rows: [EstimateRow] = []
        for paddock in paddocks {
            guard let session = latestCompletedSessionForBlock(
                sessions: sessions,
                paddockId: paddock.id,
                vintage: vintage,
                seasonStartMonth: seasonStartMonth,
                seasonStartDay: seasonStartDay
            ) else { continue }
            guard let base = baseEstimate(session: session, paddock: paddock) else { continue }
            let factor = damageFactor(paddock.id)
            rows.append(EstimateRow(
                paddockId: paddock.id,
                blockName: paddock.name,
                varietyLabel: varietyLabel(paddock),
                areaHectares: paddock.areaHectares,
                baseTonnes: base.tonnes,
                adjustedTonnes: base.tonnes * factor,
                damageFactor: factor,
                applyDamage: session.applyDamage,
                averageBunchesPerVine: base.averageBunchesPerVine,
                samplesRecorded: base.samplesRecorded,
                samplesTotal: base.samplesTotal,
                sessionId: session.id,
                completedAt: session.completedAt
            ))
        }
        return rows.sorted { $0.displayTonnes > $1.displayTonnes }
    }

    /// Past-vintage actual rows per Block + Variety. Detailed Picking Log
    /// sums ARE the actual for their combination and supersede a Basic actual
    /// for the same Block + Variety + Vintage — never added together.
    static func actualRows(
        vintage: Int,
        paddocks: [Paddock],
        yieldRecords: [HistoricalYieldRecord],
        pickingRecords: [PickingRecord]
    ) -> [ActualRow] {
        let paddockById = Dictionary(paddocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [ActualRow] = []

        // Detailed picking totals for this vintage.
        let picksInVintage = pickingRecords.filter { $0.vintage == vintage }
        var detailedKeys: Set<String> = []
        let grouped = Dictionary(grouping: picksInVintage) { pick in
            "\(pick.paddockId.uuidString)|\(PickingYieldAggregator.normalisedVariety(pick.varietyName))"
        }
        for (key, picks) in grouped {
            detailedKeys.insert(key)
            guard let first = picks.first else { continue }
            let paddock = paddockById[first.paddockId]
            rows.append(ActualRow(
                paddockId: first.paddockId,
                blockName: first.paddockName.isEmpty ? (paddock?.name ?? "Block") : first.paddockName,
                varietyName: first.varietyName,
                tonnes: picks.reduce(0.0) { $0 + $1.weightKg } / 1000.0,
                areaHectares: varietyArea(paddock: paddock, varietyName: first.varietyName),
                estimatedTonnes: estimateFor(
                    vintage: vintage,
                    paddockId: first.paddockId,
                    varietyName: first.varietyName,
                    paddock: paddock,
                    yieldRecords: yieldRecords
                ),
                fromDetailed: true
            ))
        }

        // Basic actuals (historical block results) not superseded by picks.
        for record in yieldRecords where record.year == vintage {
            for block in record.blockResults {
                guard let actual = block.actualYieldTonnes else { continue }
                let paddock = paddockById[block.paddockId]
                let varieties = (paddock?.varietyAllocations ?? [])
                    .compactMap { $0.name?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let uniqueVarieties = Array(NSOrderedSet(array: varieties)) as? [String] ?? varieties
                let variety = uniqueVarieties.count == 1 ? uniqueVarieties[0] : ""
                let key = "\(block.paddockId.uuidString)|\(PickingYieldAggregator.normalisedVariety(variety))"
                // Superseded when picks cover the block+variety — also when the
                // block has multiple varieties and ANY of them has picks (a
                // block-level Basic actual cannot be split against them).
                let anyBlockPicks = detailedKeys.contains { $0.hasPrefix("\(block.paddockId.uuidString)|") }
                let superseded = detailedKeys.contains(key)
                    || (variety.isEmpty && anyBlockPicks)
                    || (uniqueVarieties.count > 1 && uniqueVarieties.contains {
                        detailedKeys.contains("\(block.paddockId.uuidString)|\(PickingYieldAggregator.normalisedVariety($0))")
                    })
                if superseded { continue }
                rows.append(ActualRow(
                    paddockId: block.paddockId,
                    blockName: block.paddockName,
                    varietyName: variety.isEmpty ? uniqueVarieties.joined(separator: " · ") : variety,
                    tonnes: actual,
                    areaHectares: block.areaHectares,
                    estimatedTonnes: block.yieldTonnes > 0 ? block.yieldTonnes : nil,
                    fromDetailed: false
                ))
            }
        }
        return rows.sorted { $0.tonnes > $1.tonnes }
    }

    /// Display label for a block's planted varieties.
    static func varietyLabel(_ paddock: Paddock?) -> String {
        let names = (paddock?.varietyAllocations ?? [])
            .compactMap { $0.name?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let unique = Array(NSOrderedSet(array: names)) as? [String] ?? names
        return unique.isEmpty ? "—" : unique.joined(separator: " · ")
    }

    private static func varietyArea(paddock: Paddock?, varietyName: String) -> Double {
        guard let paddock else { return 0 }
        let allocations = paddock.varietyAllocations.filter { !($0.name ?? "").isEmpty }
        guard !allocations.isEmpty else { return paddock.areaHectares }
        let totalPct = allocations.reduce(0.0) { $0 + $1.percent }
        let match = allocations.filter {
            PickingYieldAggregator.normalisedVariety($0.name ?? "") == PickingYieldAggregator.normalisedVariety(varietyName)
        }
        guard !match.isEmpty else { return 0 }
        let share = totalPct > 0
            ? match.reduce(0.0) { $0 + $1.percent } / totalPct
            : Double(match.count) / Double(allocations.count)
        return paddock.areaHectares * share
    }

    /// Estimate for a Block + Variety in a vintage, preferring archived records.
    private static func estimateFor(
        vintage: Int,
        paddockId: UUID,
        varietyName: String,
        paddock: Paddock?,
        yieldRecords: [HistoricalYieldRecord]
    ) -> Double? {
        let blocks = yieldRecords
            .filter { $0.year == vintage }
            .flatMap(\.blockResults)
            .filter { $0.paddockId == paddockId && $0.yieldTonnes > 0 }
        guard !blocks.isEmpty else { return nil }
        let estimate = blocks.reduce(0.0) { $0 + $1.yieldTonnes }
        // Split a whole-block estimate by the variety's allocation share.
        let allocations = (paddock?.varietyAllocations ?? []).filter { !($0.name ?? "").isEmpty }
        guard allocations.count > 1 else { return estimate }
        let totalPct = allocations.reduce(0.0) { $0 + $1.percent }
        let match = allocations.filter {
            PickingYieldAggregator.normalisedVariety($0.name ?? "") == PickingYieldAggregator.normalisedVariety(varietyName)
        }
        guard !match.isEmpty else { return nil }
        let share = totalPct > 0
            ? match.reduce(0.0) { $0 + $1.percent } / totalPct
            : Double(match.count) / Double(allocations.count)
        return estimate * share
    }
}

/// Bunch Count Trip session helpers — resuming drafts, listing history and
/// reusing an earlier trip's route so repeated counts through the season
/// revisit comparable sample locations. Mirrored on Android
/// (`BunchCountTripLogic` in `YieldVintageReport.kt`).
nonisolated enum BunchCountTripLogic {

    /// Route material recovered from earlier trips for the selected blocks.
    nonisolated struct ReusableRoute: Sendable {
        /// Sites with counts stripped, ORIGINAL site ids preserved, reindexed.
        let sites: [SampleSite]
        let sourceSessionId: UUID
    }

    /// The resumable in-progress trip for a vineyard, newest first.
    static func activeDraft(
        sessions: [YieldEstimationSession],
        vineyardId: UUID?
    ) -> YieldEstimationSession? {
        guard let vineyardId else { return nil }
        return sessions
            .filter { $0.vineyardId == vineyardId && !$0.isCompleted }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Completed trips for a vineyard, newest first. Preserved forever.
    static func completedTrips(
        sessions: [YieldEstimationSession],
        vineyardId: UUID?
    ) -> [YieldEstimationSession] {
        guard let vineyardId else { return [] }
        return sessions
            .filter { $0.vineyardId == vineyardId && $0.isCompleted }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    /// Recover a reusable route for the selected blocks from earlier sessions:
    /// for each selected block, the newest session (completed preferred) that
    /// generated sites for it contributes those sites with bunch counts
    /// STRIPPED but site identity (id, row, coordinates) preserved. Returns
    /// nil when no selected block has any prior route — callers then proceed
    /// straight to route generation without a meaningless prompt.
    static func reusableRoute(
        sessions: [YieldEstimationSession],
        selectedPaddockIds: [UUID],
        excludeSessionId: UUID? = nil
    ) -> ReusableRoute? {
        guard !selectedPaddockIds.isEmpty else { return nil }
        let candidates = sessions
            .filter { $0.id != excludeSessionId && !$0.sampleSites.isEmpty }
            .sorted { a, b in
                if a.isCompleted != b.isCompleted { return a.isCompleted }
                return (a.completedAt ?? a.createdAt) > (b.completedAt ?? b.createdAt)
            }
        var collected: [SampleSite] = []
        var sourceId: UUID?
        for paddockId in selectedPaddockIds {
            guard let source = candidates.first(where: { session in
                session.sampleSites.contains { $0.paddockId == paddockId }
            }) else { continue }
            if sourceId == nil { sourceId = source.id }
            let sites = source.sampleSites
                .filter { $0.paddockId == paddockId }
                .sorted { $0.siteIndex < $1.siteIndex }
                .map { site in
                    var stripped = site
                    stripped.bunchCountEntry = nil
                    return stripped
                }
            collected.append(contentsOf: sites)
        }
        guard !collected.isEmpty, let sourceId else { return nil }
        let reindexed = collected.enumerated().map { idx, site in
            var s = site
            s.siteIndex = idx + 1
            return s
        }
        return ReusableRoute(sites: reindexed, sourceSessionId: sourceId)
    }

    /// Visibility contract for the simplified pre-start route confirmation
    /// screen ("Bunch Count Trip" preview). The map is the dominant content;
    /// the only actions are Start Sampling plus a single Regenerate Path for
    /// newly generated routes. Bunch weights, the full sample-site list and
    /// delete/discard never appear here — they belong to the completion
    /// stage, the map itself, and the overflow menu respectively. Mirrored
    /// on Android (`BunchCountTripLogic.routePreviewControls`).
    nonisolated struct RoutePreviewControls: Sendable, Equatable {
        let showsStartSampling: Bool
        let startSamplingIsContinue: Bool
        let showsRegeneratePath: Bool
        let showsReuseIndicator: Bool
        let showsProgress: Bool
        let showsCompleteAction: Bool
        let showsBunchWeights: Bool
        let showsSampleSiteList: Bool
        let deleteIsPrimaryAction: Bool
    }

    static func routePreviewControls(
        isRouteReused: Bool,
        recordedSiteCount: Int,
        isCompleted: Bool
    ) -> RoutePreviewControls {
        let started = recordedSiteCount > 0
        return RoutePreviewControls(
            showsStartSampling: !isCompleted,
            startSamplingIsContinue: started,
            showsRegeneratePath: !isCompleted && !isRouteReused && !started,
            showsReuseIndicator: isRouteReused,
            showsProgress: started,
            showsCompleteAction: started && !isCompleted,
            showsBunchWeights: false,
            showsSampleSiteList: false,
            deleteIsPrimaryAction: false
        )
    }
}

/// One row of the owner/manager-only `get_picking_record_financials` RPC
/// (sql/187). Since 187 the `picking_records` base columns `sold_to`,
/// `price_per_tonne` and `grape_value` are stripped server-side and read back
/// NULL for every role — commercial values live in the RLS-protected
/// companion table and reach clients only through this projection.
nonisolated struct PickingFinancialRow: Codable, Sendable {
    let pickingRecordId: UUID
    let soldTo: String?
    let pricePerTonne: Double?
    let grapeValue: Double?

    nonisolated enum CodingKeys: String, CodingKey {
        case pickingRecordId = "picking_record_id"
        case soldTo = "sold_to"
        case pricePerTonne = "price_per_tonne"
        case grapeValue = "grape_value"
    }
}

/// Merge financial projections back into picking records for display. Pure
/// and shared with tests; records without a matching projection keep their
/// (masked) values so operators simply never see money. Mirrors the Android
/// `mergePickingFinancials`.
nonisolated enum PickingFinancialsMerge {
    static func apply(
        _ financials: [PickingFinancialRow],
        to records: [PickingRecord]
    ) -> [PickingRecord] {
        guard !financials.isEmpty else { return records }
        let byId = Dictionary(financials.map { ($0.pickingRecordId, $0) }, uniquingKeysWith: { a, _ in a })
        return records.map { record in
            guard let row = byId[record.id] else { return record }
            var merged = record
            merged.soldTo = row.soldTo
            merged.pricePerTonne = row.pricePerTonne
            return merged
        }
    }
}

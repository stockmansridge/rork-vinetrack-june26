import SwiftUI

/// Lightweight ripeness surfaces shown outside the dedicated
/// Optimal Ripeness hub:
///
/// 1. `BlockRipenessChip` — compact per-block/per-variety chip used in
///    the block detail editor so growers can see how close that
///    specific block is to its target GDD without leaving the form.
/// 2. `RipenessWatchTile` — Home dashboard summary tile that highlights
///    the variety closest to its optimal GDD, linking through to the
///    full Optimal Ripeness hub.
///
/// All maths reuse `DegreeDayService` + `GrapeVariety.optimalGDD` +
/// per-block phenology — no new schema, no changes to the underlying
/// GDD calculation.

// MARK: - Shared math helpers

/// Unified weather configuration state used by every Optimal Ripeness
/// surface. Mirrors the rest of the app's weather-source detection
/// (Weather Underground PWS, Davis WeatherLink, or vineyard coordinates
/// for Open-Meteo) so we don't falsely claim "weather station required"
/// when the vineyard already has weather configured elsewhere.
enum RipenessWeatherState {
    /// A usable GDD source was resolved. Carries the concrete source
    /// so callers can fetch and pass the matching `sourceKey` into
    /// `DegreeDayService.dailyGDDSeries`.
    case ready(source: GDDSource)
    /// No weather source configured for this vineyard at all.
    case notConfigured

    var source: GDDSource? {
        if case .ready(let source) = self { return source }
        return nil
    }
}

/// One candidate GDD source for the current vineyard. `candidates`
/// returns these in priority order so callers can cascade through them
/// when the preferred source fails.
struct RipenessSourceCandidate: Hashable {
    let source: GDDSource
    /// When true, Davis fetches should route through the davis-proxy
    /// edge function. Otherwise direct WeatherLink credentials from the
    /// device Keychain are used. Ignored for non-Davis sources.
    let usesProxy: Bool
}

enum RipenessMath {
    /// Ordered list of usable GDD sources for the current vineyard.
    /// Priority: Davis WeatherLink (configured + station selected)
    /// → Weather Underground PWS → Open-Meteo Archive (vineyard or
    /// paddock centroid coordinates).
    @MainActor
    static func candidates(store: MigratedDataStore) -> [RipenessSourceCandidate] {
        var out: [RipenessSourceCandidate] = []
        if let vid = store.selectedVineyardId {
            let cfg = WeatherProviderStore.shared.config(for: vid)
            if let sid = cfg.davisStationId, !sid.isEmpty {
                let hasShared = cfg.davisIsVineyardShared && cfg.davisVineyardHasServerCredentials
                let hasDirect = cfg.davisHasCredentials && cfg.davisConnectionTested
                if hasShared {
                    out.append(RipenessSourceCandidate(source: .davisWeatherLink(stationId: sid), usesProxy: true))
                } else if hasDirect {
                    out.append(RipenessSourceCandidate(source: .davisWeatherLink(stationId: sid), usesProxy: false))
                }
            }
        }
        if let id = store.settings.weatherStationId, !id.isEmpty {
            out.append(RipenessSourceCandidate(source: .weatherUnderground(stationId: id), usesProxy: false))
        }
        let lat = store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
        let lon = store.settings.vineyardLongitude ?? store.paddockCentroidLongitude
        if let lat, let lon {
            out.append(RipenessSourceCandidate(source: .openMeteoArchive(latitude: lat, longitude: lon), usesProxy: false))
        }
        return out
    }

    /// Best-effort resolved state for surfaces that don't perform a
    /// fetch themselves (chips, dashboard tile). Uses `lastSource` from
    /// `DegreeDayService` when it matches one of the configured
    /// candidates so the source label reflects the source we actually
    /// have data for; otherwise returns the top candidate or
    /// `.notConfigured`.
    @MainActor
    static func weatherState(store: MigratedDataStore, degreeDayService: DegreeDayService? = nil) -> RipenessWeatherState {
        let cands = candidates(store: store)
        if let svc = degreeDayService, let resolved = svc.lastSource,
           cands.contains(where: { $0.source == resolved }) {
            return .ready(source: resolved)
        }
        if let first = cands.first { return .ready(source: first.source) }
        return .notConfigured
    }

    /// Earliest date the Optimal Ripeness surfaces might query. Used to
    /// pre-fetch a comfortable temperature buffer (per-block reset
    /// dates can be up to a year back).
    @MainActor
    static func fetchRangeStart(settings: AppSettings) -> Date {
        let cal = Calendar.current
        let oneYearAgo = cal.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        return min(oneYearAgo, seasonStartDate(settings: settings))
    }

    static func seasonStartDate(settings: AppSettings) -> Date {
        let cal = Calendar.current
        let now = Date()
        let month = settings.seasonStartMonth
        let day = settings.seasonStartDay
        let currentMonth = cal.component(.month, from: now)
        let currentDay = cal.component(.day, from: now)
        let year = cal.component(.year, from: now)
        let startYear: Int
        if currentMonth > month || (currentMonth == month && currentDay >= day) {
            startYear = year
        } else {
            startYear = year - 1
        }
        return cal.date(from: DateComponents(year: startYear, month: month, day: day)) ?? now
    }

    struct BlockTotal {
        let total: Double
        let series: [(date: Date, daily: Double, cumulative: Double, interpolated: Bool)]
    }

    @MainActor
    static func blockTotal(
        block: Paddock,
        store: MigratedDataStore,
        degreeDayService: DegreeDayService,
        sourceKey: String
    ) -> BlockTotal? {
        guard !sourceKey.isEmpty else { return nil }
        let stationId = sourceKey
        let cal = Calendar.current
        let now = Date()
        let oneYearAgo = cal.date(byAdding: .year, value: -1, to: now) ?? now
        let seasonStart = seasonStartDate(settings: store.settings)
        let resetDefault = store.settings.resetMode
        let modeDefault = store.settings.calculationMode
        let resetMode = block.effectiveResetMode(defaultMode: resetDefault)
        guard let resetDate = block.resetDate(for: resetMode, seasonStart: seasonStart),
              resetDate <= now, resetDate >= oneYearAgo else { return nil }
        let calcMode = block.effectiveCalculationMode(defaultMode: modeDefault)
        let latitude = store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
        let series = degreeDayService.dailyGDDSeries(
            stationId: stationId,
            from: cal.startOfDay(for: resetDate),
            to: cal.startOfDay(for: now),
            latitude: latitude,
            useBEDD: calcMode.useBEDD
        )
        let total = series.last?.cumulative ?? 0
        return BlockTotal(total: total, series: series)
    }

    static func daysToTarget(total: Double, target: Double, series: [(date: Date, daily: Double, cumulative: Double, interpolated: Bool)]) -> Int? {
        if total >= target { return 0 }
        guard series.count >= 14 else { return nil }
        let recent = Array(series.suffix(14))
        let gained = (recent.last?.cumulative ?? 0) - (recent.first?.cumulative ?? 0)
        let perDay = gained / Double(max(recent.count - 1, 1))
        guard perDay > 0 else { return nil }
        let remaining = target - total
        return Int((remaining / perDay).rounded(.up))
    }

    static func progressColor(progress: Double) -> Color {
        switch progress {
        case 0.98...: return VineyardTheme.leafGreen
        case 0.9..<0.98: return .orange
        default: return .blue
        }
    }
}

// MARK: - Block detail chip

/// Compact ripeness chip for a single (block, variety) pair. Drops
/// into the block editor's variety list so growers can see how close
/// the block is to that variety's optimal GDD.
struct BlockRipenessChip: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(DegreeDayService.self) private var degreeDayService

    let paddockId: UUID
    let varietyId: UUID

    private var paddock: Paddock? { store.paddocks.first(where: { $0.id == paddockId }) }
    private var variety: GrapeVariety? { store.grapeVariety(for: varietyId) }

    private var resetMode: GDDResetMode? {
        guard let paddock else { return nil }
        return paddock.effectiveResetMode(defaultMode: store.settings.resetMode)
    }

    private var hasResetData: Bool {
        guard let paddock, let mode = resetMode else { return false }
        switch mode {
        case .seasonStart: return true
        case .budburst: return paddock.budburstDate != nil
        case .flowering: return paddock.floweringDate != nil
        case .veraison: return paddock.veraisonDate != nil
        }
    }

    private var blockTotal: RipenessMath.BlockTotal? {
        guard let paddock,
              let source = RipenessMath.weatherState(store: store).source else { return nil }
        return RipenessMath.blockTotal(
            block: paddock,
            store: store,
            degreeDayService: degreeDayService,
            sourceKey: source.sourceKey
        )
    }

    private var progress: Double {
        guard let target = variety?.optimalGDD, target > 0, let total = blockTotal?.total else { return 0 }
        return min(1.0, max(0, total / target))
    }

    private var caveatMessage: String? {
        switch RipenessMath.weatherState(store: store) {
        case .ready: break
        case .notConfigured:
            return "Add vineyard coordinates or a weather station to project ripeness"
        }
        if !hasResetData, let mode = resetMode {
            switch mode {
            case .budburst: return "Set budburst date to project ripeness"
            case .flowering: return "Set flowering date to project ripeness"
            case .veraison: return "Set veraison date to project ripeness"
            case .seasonStart: return "Insufficient season data"
            }
        }
        return nil
    }

    var body: some View {
        NavigationLink {
            VarietyGDDDetailView(varietyId: varietyId)
        } label: {
            content
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if let caveat = caveatMessage {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Ripeness: \(caveat)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        } else if let total = blockTotal?.total, let target = variety?.optimalGDD, target > 0 {
            let color = RipenessMath.progressColor(progress: progress)
            let series = blockTotal?.series ?? []
            let days = RipenessMath.daysToTarget(total: total, target: target, series: series)
            let projected: Date? = {
                guard let d = days, d > 0 else { return nil }
                return Calendar.current.date(byAdding: .day, value: d, to: Date())
            }()

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "thermometer.sun.fill")
                        .font(.caption)
                        .foregroundStyle(color)
                    Text("Ripeness")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if progress >= 1.0 {
                        Label("Ready", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(VineyardTheme.leafGreen.opacity(0.18), in: .capsule)
                            .foregroundStyle(VineyardTheme.leafGreen)
                    } else {
                        Text("\(Int(progress * 100))% of optimal")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(color)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(color.gradient)
                            .frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(height: 5)

                HStack(spacing: 6) {
                    Text("\(Int(total)) / \(Int(target)) GDD")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let days, days > 0, let projected {
                        Image(systemName: "calendar.badge.clock")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("~\(days)d • \(projected.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if days == nil && progress < 1.0 {
                        Text("Not enough data to project")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Ripeness: insufficient recent data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Home dashboard tile

/// Home dashboard "Ripeness Watch" tile — surfaces the variety closest
/// to its optimal GDD across allocated blocks. Tapping opens the full
/// Optimal Ripeness hub.
struct RipenessWatchTile: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(DegreeDayService.self) private var degreeDayService

    private var weatherState: RipenessWeatherState {
        RipenessMath.weatherState(store: store)
    }

    private struct VarietyStatus {
        let variety: GrapeVariety
        let total: Double
        let target: Double
        let progress: Double
        let days: Int?
        let blockCount: Int
    }

    private var allocatedVarieties: [GrapeVariety] {
        store.grapeVarieties.filter { variety in
            store.orderedPaddocks.contains(where: { p in
                p.varietyAllocations.contains(where: { $0.varietyId == variety.id })
            })
        }
    }

    private var topVariety: VarietyStatus? {
        guard case .ready(let source) = weatherState else { return nil }
        var results: [VarietyStatus] = []
        for variety in allocatedVarieties {
            let blocks = store.orderedPaddocks.filter { p in
                p.varietyAllocations.contains(where: { $0.varietyId == variety.id })
            }
            var totals: [RipenessMath.BlockTotal] = []
            for block in blocks {
                if let bt = RipenessMath.blockTotal(block: block, store: store, degreeDayService: degreeDayService, sourceKey: source.sourceKey) {
                    totals.append(bt)
                }
            }
            guard !totals.isEmpty else { continue }
            let avg = totals.map(\.total).reduce(0, +) / Double(totals.count)
            let target = variety.optimalGDD
            guard target > 0 else { continue }
            let progress = min(1.0, max(0, avg / target))
            let longest = totals.max(by: { $0.series.count < $1.series.count })?.series ?? []
            let days = RipenessMath.daysToTarget(total: avg, target: target, series: longest)
            results.append(VarietyStatus(
                variety: variety,
                total: avg,
                target: target,
                progress: progress,
                days: days,
                blockCount: blocks.count
            ))
        }
        return results.max(by: { $0.progress < $1.progress })
    }

    var body: some View {
        NavigationLink {
            OptimalRipenessHubView()
        } label: {
            VineyardCard {
                content
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "thermometer.sun.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if let status = topVariety {
                let color = RipenessMath.progressColor(progress: status.progress)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Ripeness Watch")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if status.progress >= 1.0 {
                            Label("Ready", systemImage: "checkmark.seal.fill")
                                .font(.caption2.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                    Text("\(status.variety.name) — \(Int(status.progress * 100))% of optimal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(color.gradient)
                                .frame(width: max(4, geo.size.width * status.progress))
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 6) {
                        if let days = status.days, days > 0 {
                            Image(systemName: "calendar.badge.clock")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("Est. ripeness: \(days) day\(days == 1 ? "" : "s")")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if status.progress >= 1.0 {
                            Text("Target reached — review harvest plan")
                                .font(.caption2)
                                .foregroundStyle(VineyardTheme.leafGreen)
                        } else {
                            Text("Not enough recent data to project")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Text("View Optimal Ripeness")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(VineyardTheme.info)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ripeness Watch")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(emptyTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(emptySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyTitle: String {
        switch weatherState {
        case .notConfigured: return "Weather source required"
        case .ready:
            if allocatedVarieties.isEmpty { return "No tracked varieties yet" }
            return "Awaiting season data"
        }
    }

    private var emptySubtitle: String {
        switch weatherState {
        case .notConfigured:
            return "Add vineyard coordinates or connect a weather station to track GDD and harvest timing."
        case .ready:
            break
        }
        if allocatedVarieties.isEmpty {
            return "Allocate varieties to a block to track ripeness."
        }
        return "Set block budburst dates so we can project optimal ripeness."
    }
}

import SwiftUI

/// Guided helper that fills missing rainfall days surfaced by the
/// Irrigation Advisor. Runs Davis → Weather Underground → Open-Meteo
/// in priority order using the existing proxies. Owner/Manager only.
///
/// The Davis and WU steps run a chunked 365-day backfill (Davis: 60-day
/// chunks, WU: 30-day chunks). Open-Meteo only runs after both station
/// sources finish cleanly — if Davis or WU were rate-limited mid-run we
/// stop here so Open-Meteo doesn't fill days a better source could have
/// supplied on retry.
struct IrrigationMissingRainHelperSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BackendAccessControl.self) private var accessControl

    let vineyardId: UUID?
    /// The selected actual-rain window in the Irrigation Advisor (1, 2,
    /// 7, 14). Used for context only — chunked station backfills always
    /// target the past 365 days.
    let rainfallWindowDays: Int
    /// Called after the helper finishes (success or partial). The
    /// Irrigation Advisor uses this to reload persisted rainfall and
    /// recalculate the recommendation.
    let onCompleted: () -> Void

    @State private var davisConfigured: Bool = false
    @State private var wuConfigured: Bool = false
    @State private var didLoad: Bool = false
    @State private var isLoadingConfig: Bool = false

    @State private var isRunning: Bool = false
    @State private var hasRun: Bool = false

    @State private var davis: SourceProgress = .init()
    @State private var wu: SourceProgress = .init()
    @State private var openMeteo: SourceProgress = .init()

    @State private var davisResumeOffset: Int = 0
    @State private var wuResumeOffset: Int = 0

    @State private var finalMessage: String?

    private let integrationRepository: any VineyardWeatherIntegrationRepositoryProtocol
        = SupabaseVineyardWeatherIntegrationRepository()

    private var canEdit: Bool { accessControl.canChangeSettings }

    /// Long-range chunked backfill targets the past year. Quick 14-day
    /// flows in Settings and the Weather Setup Wizard remain unchanged.
    private let totalDays: Int = 365
    private let davisChunkDays: Int = 60
    private let wuChunkDays: Int = 30

    enum StepStatus: Equatable, Sendable {
        case pending
        case skipped(String)
        case running
        case success
        case failed
        case rateLimited
    }

    /// Per-source progress used by the steps section. Holds running
    /// totals so the UI can show "X / 365 days" while the loop runs.
    struct SourceProgress: Equatable {
        var status: StepStatus = .pending
        var detail: String?
        var daysProcessed: Int = 0
        var rowsUpserted: Int = 0
        var errorsCount: Int = 0
        var chunksCompleted: Int = 0
        var resumeOffset: Int?
    }

    var body: some View {
        NavigationStack {
            Form {
                introSection
                if !canEdit {
                    readOnlyNoticeSection
                } else {
                    sourcePrioritySection
                    rangeSection
                    stepsSection
                    actionSection
                    if let finalMessage {
                        Section {
                            Text(finalMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Build rainfall history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(hasRun ? "Done" : "Cancel") {
                        if hasRun { onCompleted() }
                        dismiss()
                    }
                    .disabled(isRunning)
                }
            }
            .task {
                if !didLoad { await loadConfiguration() }
            }
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "cloud.rain.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text("Build 365-day rainfall history")
                        .font(.subheadline.weight(.semibold))
                }
                Text("VineTrack will pull rainfall from Davis, then Weather Underground, then fill remaining gaps with Open-Meteo. Better sources are never overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var readOnlyNoticeSection: some View {
        Section {
            Label("Ask an Owner or Manager to build rainfall history.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sourcePrioritySection: some View {
        Section("Source priority") {
            VStack(alignment: .leading, spacing: 6) {
                priorityRow(index: 1, name: "Manual entries", note: "Always wins. Never overwritten.")
                priorityRow(index: 2, name: "Davis WeatherLink", note: davisConfigured ? "Configured · 365 days in 60-day chunks." : "Not configured — will be skipped.")
                priorityRow(index: 3, name: "Weather Underground", note: wuConfigured ? "Configured · 365 days in 30-day chunks." : "Not configured — will be skipped.")
                priorityRow(index: 4, name: "Open-Meteo (fallback)", note: "Fills remaining gaps only.")
            }
            .padding(.vertical, 2)
        }
    }

    private func priorityRow(index: Int, name: String, note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index).")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.semibold))
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var rangeSection: some View {
        Section {
            LabeledContent("Advisor window") {
                Text(windowLabel(rainfallWindowDays))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Davis range") {
                Text("\(totalDays) days · \(davisChunkDays)d chunks")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Weather Underground range") {
                Text("\(totalDays) days · \(wuChunkDays)d chunks")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Open-Meteo range") {
                Text("\(totalDays) days · gaps only")
                    .foregroundStyle(.secondary)
            }
            if davisResumeOffset > 0 || wuResumeOffset > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if davisResumeOffset > 0 {
                        Text("Davis will resume from offset \(davisResumeOffset) days.")
                    }
                    if wuResumeOffset > 0 {
                        Text("Weather Underground will resume from offset \(wuResumeOffset) days.")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Date ranges")
        } footer: {
            Text("Station backfills target the past year so the Rain Calendar can be filled out as completely as possible. Open-Meteo only runs if Davis and Weather Underground complete without being rate-limited.")
        }
    }

    private var stepsSection: some View {
        Section("Steps") {
            stepRow(
                icon: "antenna.radiowaves.left.and.right",
                title: "Davis WeatherLink",
                progress: davis,
                target: totalDays
            )
            stepRow(
                icon: "cloud.sun.fill",
                title: "Weather Underground",
                progress: wu,
                target: totalDays
            )
            stepRow(
                icon: "tray.full.fill",
                title: "Open-Meteo (fallback)",
                progress: openMeteo,
                target: totalDays
            )
        }
    }

    private func stepRow(icon: String, title: String, progress: SourceProgress, target: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                statusBadge(progress.status)
            }
            if progress.status == .running || progress.daysProcessed > 0 {
                ProgressView(
                    value: Double(min(progress.daysProcessed, target)),
                    total: Double(max(target, 1))
                )
                .tint(.accentColor)
                Text("\(progress.daysProcessed) / \(target) days · \(progress.rowsUpserted) rows · \(progress.chunksCompleted) chunk\(progress.chunksCompleted == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let detail = progress.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Text("Pending")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        case .skipped:
            Text("Skipped")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Running…")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.tint)
        case .success:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VineyardTheme.leafGreen)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        case .rateLimited:
            Label("Rate limited", systemImage: "hourglass")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await runAll() }
            } label: {
                HStack {
                    if isRunning {
                        ProgressView()
                        Text("Building rainfall history…")
                    } else {
                        Image(systemName: "drop.fill")
                        Text(hasRun ? "Run again" : "Build rainfall history")
                    }
                    Spacer()
                }
                .font(.subheadline.weight(.semibold))
            }
            .disabled(isRunning || isLoadingConfig || vineyardId == nil)
            .buttonStyle(.borderedProminent)
        } footer: {
            Text("Runs Davis (60-day chunks) → Weather Underground (30-day chunks) → Open-Meteo gap fill. Each source only writes its own rows and never overwrites a higher-priority source.")
        }
    }

    // MARK: - Helpers

    private func windowLabel(_ days: Int) -> String {
        switch days {
        case 1: return "24h"
        case 2: return "48h"
        default: return "\(days) days"
        }
    }

    // MARK: - Configuration loading

    private func loadConfiguration() async {
        guard let vid = vineyardId else { return }
        isLoadingConfig = true
        defer { isLoadingConfig = false }
        await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vid)
        let cfg = WeatherProviderStore.shared.config(for: vid)
        let hasShared = cfg.davisIsVineyardShared && cfg.davisVineyardHasServerCredentials
        let hasStation = (cfg.davisStationId?.isEmpty == false)
        davisConfigured = hasShared && hasStation
        do {
            let integ = try await integrationRepository.fetch(
                vineyardId: vid, provider: "wunderground"
            )
            wuConfigured = !((integ?.stationId ?? "").isEmpty)
        } catch {
            wuConfigured = false
        }
        davisResumeOffset = RainfallHistoryBackfillService.loadResumeOffset(.davis, vineyardId: vid)
        wuResumeOffset = RainfallHistoryBackfillService.loadResumeOffset(.wunderground, vineyardId: vid)
        didLoad = true
    }

    // MARK: - Run

    private func runAll() async {
        guard canEdit, let vid = vineyardId, !isRunning else { return }
        isRunning = true
        finalMessage = nil
        davis = SourceProgress()
        wu = SourceProgress()
        openMeteo = SourceProgress()

        var anyRowsWritten = false
        var blockOpenMeteo = false

        // Davis
        if davisConfigured {
            await runDavis(vineyardId: vid)
            if davis.rowsUpserted > 0 { anyRowsWritten = true }
            if davis.status == .rateLimited || davis.status == .failed {
                blockOpenMeteo = true
            }
        } else {
            davis.status = .skipped("Not configured")
            davis.detail = "Davis WeatherLink isn't configured for this vineyard."
        }

        // Weather Underground
        if wuConfigured {
            await runWunderground(vineyardId: vid)
            if wu.rowsUpserted > 0 { anyRowsWritten = true }
            if wu.status == .rateLimited || wu.status == .failed {
                blockOpenMeteo = true
            }
        } else {
            wu.status = .skipped("Not configured")
            wu.detail = "No Weather Underground station saved for this vineyard."
        }

        // Open-Meteo (only if no station source was rate-limited)
        if blockOpenMeteo {
            openMeteo.status = .skipped("Held back")
            openMeteo.detail = "Skipped to avoid filling days that Davis or Weather Underground may supply on retry. Try again later to continue."
        } else {
            await runOpenMeteo(vineyardId: vid)
            if openMeteo.rowsUpserted > 0 { anyRowsWritten = true }
        }

        finalMessage = composeFinalMessage(anyRowsWritten: anyRowsWritten, blockedOpenMeteo: blockOpenMeteo)

        if anyRowsWritten {
            NotificationCenter.default.post(
                name: .rainfallCalendarShouldReload, object: nil
            )
        }

        hasRun = true
        isRunning = false
        // Notify the Advisor so it can reload its persisted rainfall and
        // refresh the recommendation card immediately, even before the
        // user dismisses the sheet.
        onCompleted()
    }

    private func composeFinalMessage(anyRowsWritten: Bool, blockedOpenMeteo: Bool) -> String {
        var parts: [String] = []
        if anyRowsWritten {
            parts.append("Rainfall data refreshed. Recalculating irrigation advice…")
        } else {
            parts.append("No new rainfall rows were written.")
        }
        if davis.status == .rateLimited {
            parts.append("Davis was rate-limited after \(davis.daysProcessed) days. Try again later to continue from offset \(davis.resumeOffset ?? davis.daysProcessed).")
        }
        if wu.status == .rateLimited {
            parts.append("Weather Underground was rate-limited after \(wu.daysProcessed) days. Try again later to continue from offset \(wu.resumeOffset ?? wu.daysProcessed).")
        }
        if blockedOpenMeteo {
            parts.append("Open-Meteo was held back so it doesn't fill days a station source could supply on retry.")
        }
        return parts.joined(separator: " ")
    }

    private func runDavis(vineyardId vid: UUID) async {
        davis.status = .running
        davis.detail = nil
        let cfg = WeatherProviderStore.shared.config(for: vid)
        guard let sid = cfg.davisStationId, !sid.isEmpty else {
            davis.status = .skipped("No station")
            davis.detail = "No Davis station ID is selected."
            return
        }
        let startOffset = RainfallHistoryBackfillService.loadResumeOffset(.davis, vineyardId: vid)
        do {
            let r = try await RainfallHistoryBackfillService.backfillDavisChunked(
                vineyardId: vid,
                stationId: sid,
                totalDays: totalDays,
                chunkDays: davisChunkDays,
                startOffset: startOffset,
                progress: { p in
                    Task { @MainActor in
                        davis.daysProcessed = p.daysProcessed
                        davis.rowsUpserted = p.rowsUpsertedTotal
                        davis.chunksCompleted = p.chunksCompleted
                    }
                }
            )
            davis.daysProcessed = r.daysProcessed
            davis.rowsUpserted = r.rowsUpserted
            davis.errorsCount = r.errorsCount
            davis.chunksCompleted = r.chunksCompleted
            davis.resumeOffset = r.resumeOffset
            RainfallHistoryBackfillService.saveResumeOffset(.davis, vineyardId: vid, offset: r.resumeOffset)
            davisResumeOffset = r.resumeOffset ?? 0
            if r.rateLimited {
                davis.status = .rateLimited
                davis.detail = "Rate-limited after \(r.daysProcessed) days · Rows: \(r.rowsUpserted) · Chunks: \(r.chunksCompleted)"
            } else if r.completed && r.errorsCount == 0 {
                davis.status = .success
                davis.detail = "Days processed: \(r.daysProcessed) · Rows upserted: \(r.rowsUpserted) · Chunks: \(r.chunksCompleted)"
            } else {
                davis.status = .failed
                davis.detail = "Days processed: \(r.daysProcessed) · Rows: \(r.rowsUpserted) · Errors: \(r.errorsCount)"
            }
        } catch let error as VineyardDavisProxyError {
            if case .rateLimited = error {
                davis.status = .rateLimited
            } else {
                davis.status = .failed
            }
            davis.detail = error.errorDescription ?? "Davis backfill failed."
        } catch {
            davis.status = .failed
            davis.detail = "Davis backfill failed — \(error.localizedDescription)"
        }
    }

    private func runWunderground(vineyardId vid: UUID) async {
        wu.status = .running
        wu.detail = nil
        let startOffset = RainfallHistoryBackfillService.loadResumeOffset(.wunderground, vineyardId: vid)
        do {
            let r = try await RainfallHistoryBackfillService.backfillWundergroundChunked(
                vineyardId: vid,
                stationId: nil,
                totalDays: totalDays,
                chunkDays: wuChunkDays,
                startOffset: startOffset,
                progress: { p in
                    Task { @MainActor in
                        wu.daysProcessed = p.daysProcessed
                        wu.rowsUpserted = p.rowsUpsertedTotal
                        wu.chunksCompleted = p.chunksCompleted
                    }
                }
            )
            wu.daysProcessed = r.daysProcessed
            wu.rowsUpserted = r.rowsUpserted
            wu.errorsCount = r.errorsCount
            wu.chunksCompleted = r.chunksCompleted
            wu.resumeOffset = r.resumeOffset
            RainfallHistoryBackfillService.saveResumeOffset(.wunderground, vineyardId: vid, offset: r.resumeOffset)
            wuResumeOffset = r.resumeOffset ?? 0
            var detailParts: [String] = []
            if let label = r.stationLabel, !label.isEmpty {
                detailParts.append("Station: \(label)")
            }
            if r.rateLimited {
                wu.status = .rateLimited
                detailParts.insert(
                    "Rate-limited after \(r.daysProcessed) days · Rows: \(r.rowsUpserted) · Chunks: \(r.chunksCompleted)",
                    at: 0
                )
            } else if r.completed && r.errorsCount == 0 {
                wu.status = .success
                detailParts.insert(
                    "Days processed: \(r.daysProcessed) · Rows upserted: \(r.rowsUpserted) · Chunks: \(r.chunksCompleted)",
                    at: 0
                )
            } else {
                wu.status = .failed
                detailParts.insert(
                    "Days processed: \(r.daysProcessed) · Rows: \(r.rowsUpserted) · Errors: \(r.errorsCount)",
                    at: 0
                )
            }
            wu.detail = detailParts.joined(separator: " · ")
        } catch let error as VineyardWundergroundProxyError {
            if case .rateLimited = error {
                wu.status = .rateLimited
            } else {
                wu.status = .failed
            }
            wu.detail = error.errorDescription ?? "Weather Underground backfill failed."
        } catch {
            wu.status = .failed
            wu.detail = "Weather Underground backfill failed — \(error.localizedDescription)"
        }
    }

    private func runOpenMeteo(vineyardId vid: UUID) async {
        openMeteo.status = .running
        openMeteo.detail = nil
        do {
            let r = try await VineyardOpenMeteoProxyService.backfillRainfallGaps(
                vineyardId: vid, days: totalDays, timezone: TimeZone.current.identifier
            )
            openMeteo.rowsUpserted = r.rowsUpserted
            openMeteo.daysProcessed = r.daysProcessed
            openMeteo.errorsCount = r.errorsCount
            openMeteo.status = r.success && r.errorsCount == 0 ? .success : .failed
            openMeteo.detail = "Rows upserted: \(r.rowsUpserted) · Skipped (better source): \(r.daysSkippedBetterSource) · Skipped (no data): \(r.daysSkippedNoData) · Errors: \(r.errorsCount)"
        } catch let error as VineyardOpenMeteoProxyError {
            openMeteo.status = .failed
            openMeteo.detail = error.errorDescription ?? "Open-Meteo gap fill failed."
        } catch {
            openMeteo.status = .failed
            openMeteo.detail = "Open-Meteo gap fill failed — \(error.localizedDescription)"
        }
    }
}

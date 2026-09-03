import Foundation
import MapKit
import Observation

/// Drives the E-L Ripeness Heatmap screen.
///
/// Responsibilities are split deliberately:
/// * **Loading** touches the network at most once per vineyard, then caches
///   everything needed to rebuild offline.
/// * **Rebuilding** is pure local computation. Scrubbing the timeline, changing
///   the block filter or switching Vintage never issues a network request.
///
/// Heat surfaces are built off the main actor and every rebuild cancels the one
/// before it, so dragging the timeline cannot pile up work.
@MainActor
@Observable
final class ELRipenessHeatmapModel {

    // MARK: - Surface state

    nonisolated enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case ready
        /// The Vintage has no observations at all, and we know that for certain.
        case emptyVintage
        /// Offline and this Vintage was never cached — we genuinely do not know
        /// whether it has observations, which is not the same as it having none.
        case unavailableOffline
        case failed(String)
    }

    /// What the map is currently able to show, beyond the raw load state.
    nonisolated enum SurfaceNotice: Equatable, Sendable {
        /// Observations exist at this date but every one of them is too old to
        /// influence the surface.
        case staleOnly
        /// One or more blocks in view have no boundary, so they can show pins
        /// but no heat.
        case missingPolygon([String])
        /// Rendering from cache with no network — tiles may be unavailable.
        case offlineCache(Date)
        /// The remote fetch or decode failed, but local and cached data were
        /// enough to still draw a surface. The operator is told the data may
        /// be behind rather than being shown a silently partial map.
        case remoteFailed
        /// No block in this vineyard has a usable boundary, so there is
        /// nothing to frame the map against.
        case noBoundaries
    }

    // MARK: - Inputs

    private let repository: any RipenessObservationRepositoryProtocol
    private let cache: any ELRipenessObservationCaching

    /// Dependencies are optional rather than defaulted so the real Supabase
    /// repository is constructed inside the initialiser's actor context.
    init(
        repository: (any RipenessObservationRepositoryProtocol)? = nil,
        cache: (any ELRipenessObservationCaching)? = nil
    ) {
        self.repository = repository ?? SupabaseRipenessObservationRepository()
        self.cache = cache ?? ELRipenessObservationCache()
    }

    // MARK: - Published state

    private(set) var loadState: LoadState = .idle
    private(set) var notices: [SurfaceNotice] = []

    /// Every observation for the vineyard, all Vintages, already normalised.
    private(set) var allObservations: [ELRipeness.Observation] = []
    private(set) var blocks: [ELRipeness.BlockInput] = []
    private(set) var coveredVintages: Set<Int> = []
    private(set) var cachedAt: Date?

    private(set) var availableVintages: [Int] = []
    private(set) var timelineDays: [CivilDate] = []
    /// Days in `timelineDays` that carry at least one observation.
    private(set) var observationDayIndices: [Int] = []

    private(set) var heatModel: ELRipeness.HeatModel?
    private(set) var overlays: [ELRipenessHeatOverlay] = []
    private(set) var isRendering: Bool = false

    var selectedVintage: Int? {
        didSet { if oldValue != selectedVintage { vintageDidChange() } }
    }

    /// `nil` means All Blocks.
    var selectedBlockId: String? {
        didSet { if oldValue != selectedBlockId { scheduleRebuild() } }
    }

    var timelineIndex: Int = 0 {
        didSet { if oldValue != timelineIndex { scheduleRebuild() } }
    }

    var isPlaying: Bool = false

    // MARK: - Derived

    var currentDay: CivilDate? {
        guard timelineIndex >= 0, timelineIndex < timelineDays.count else { return timelineDays.last }
        return timelineDays[timelineIndex]
    }

    var currentDateISO: String? { currentDay?.iso }

    /// Observations for the selected Vintage only.
    private(set) var vintageObservations: [ELRipeness.Observation] = []

    /// Full detail for observations that came from a local record or pin,
    /// registered under every id the feed might resolve them to.
    private var enrichmentByRecordId: [String: GrowthStageRecord] = [:]

    /// The Summary list, derived from the *same* merged feed as the heat
    /// surface so the two can never disagree about what exists.
    ///
    /// Every entry corresponds to exactly one observation in the current
    /// Vintage. Where a local `growth_stage_records` row or pin is known the
    /// full detail (notes, photos, variety) is used; otherwise a minimal
    /// record is synthesised from the observation so a remote-only row is
    /// still listed rather than silently dropped.
    var summaryRecords: [GrowthStageRecord] {
        vintageObservations
            .map { observation in
                if let existing = enrichmentByRecordId[observation.id] { return existing }
                return synthesisedRecord(for: observation)
            }
            .sorted { $0.observedAt > $1.observedAt }
    }

    private func synthesisedRecord(for observation: ELRipeness.Observation) -> GrowthStageRecord {
        let code = ELRipeness.formatEl(observation.el)
        let date = Self.date(fromISO: observation.dateISO) ?? Date()
        return GrowthStageRecord(
            id: UUID(uuidString: observation.id) ?? UUID(),
            vineyardId: loadedVineyardId ?? UUID(),
            paddockId: observation.paddockId.flatMap { UUID(uuidString: $0) },
            pinId: nil,
            stageCode: code,
            stageLabel: GrowthStage.allStages.first { $0.code == code }?.description,
            variety: nil,
            observedAt: date,
            latitude: observation.lat,
            longitude: observation.lng,
            rowNumber: nil,
            side: nil,
            notes: nil,
            photoPaths: [],
            recordedByName: nil,
            createdAt: date,
            updatedAt: date
        )
    }

    /// Parses the leading calendar day of an ISO timestamp without applying a
    /// timezone shift — the string already carries the field-capture day.
    static func date(fromISO iso: String) -> Date? {
        guard iso.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(iso.prefix(10)))
    }

    /// Contract section 9 counts. `recorded` includes stale and unassigned
    /// observations; `influencing` and `stale` are assigned-only, so the three
    /// are not meant to sum.
    var statusCounts: (recorded: Int, influencing: Int, stale: Int, unassigned: Int) {
        guard let heatModel else { return (0, 0, 0, 0) }
        return (
            heatModel.qualifying.count,
            heatModel.influencing.count,
            heatModel.stale.count,
            heatModel.unassigned.count
        )
    }

    /// Influencing-only median across the whole visible surface.
    var medianEl: Double? { heatModel?.medianEl }

    var hasAnyHeat: Bool {
        guard let heatModel else { return false }
        return heatModel.blocks.contains { $0.mode == .halo || $0.mode == .gradient || $0.mode == .surface }
    }

    // MARK: - Loading

    private var loadedVineyardId: UUID?
    private var renderTask: Task<Void, Never>?
    private var seasonStartMonth: Int = ELRipenessSeason.defaultSeasonStartMonth
    private var seasonStartDay: Int = ELRipenessSeason.defaultSeasonStartDay
    private var pendingSources: [ELRipenessObservationAdapter.SourceRecord] = []
    private var remoteSources: [ELRipenessObservationAdapter.SourceRecord] = []
    private var localRecordSources: [ELRipenessObservationAdapter.SourceRecord] = []
    private var vineyardIdString: String?
    private var today: CivilDate = CivilDate(year: 2000, month: 1, day: 1)

    /// Loads a vineyard. Network is attempted only when `isOnline`; otherwise
    /// the cache is authoritative and a missing cache is reported honestly.
    func load(
        vineyardId: UUID,
        paddocks: [Paddock],
        pins: [VinePin],
        localRecords: [GrowthStageRecord] = [],
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone,
        isOnline: Bool,
        force: Bool = false
    ) async {
        if loadedVineyardId == vineyardId, !force, loadState == .ready {
            refreshLocal(pins: pins, localRecords: localRecords, timeZone: timeZone)
            return
        }

        self.seasonStartMonth = seasonStartMonth
        self.seasonStartDay = seasonStartDay
        self.vineyardIdString = vineyardId.uuidString.lowercased()
        self.today = Self.civilToday(in: timeZone)
        loadState = .loading
        notices = []

        let localPaddocks = paddocks.filter { $0.vineyardId == vineyardId }
        var resolvedBlocks = ELRipenessObservationAdapter.blockInputs(localPaddocks)
        pendingSources = ELRipenessObservationAdapter.pendingRecords(
            pins: pins,
            vineyardId: vineyardId,
            timeZone: timeZone
        )
        localRecordSources = ELRipenessObservationAdapter.localRecords(
            localRecords,
            vineyardId: vineyardId,
            timeZone: timeZone
        )
        rebuildEnrichment(localRecords: localRecords, pins: pins, vineyardId: vineyardId)

        let cached = cache.load(vineyardId: vineyardId)
        var loadedFromNetwork = false
        var fetchFailure: String?

        if isOnline {
            do {
                let rows = try await repository.fetchObservations(vineyardId: vineyardId)
                remoteSources = rows.map(\.sourceRecord)
                loadedFromNetwork = true
            } catch {
                // A fetch or decode failure is a failure. It must never be
                // laundered into "no observations" — that reads to the operator
                // as a clean empty Vintage and hides a real outage.
                print("[Ripeness] remote fetch failed: \(error.localizedDescription)")
                fetchFailure = error.localizedDescription
                remoteSources = cached?.sourceRecords ?? []
            }
        } else {
            remoteSources = cached?.sourceRecords ?? []
        }

        // Blocks may be absent locally when the paddock cache has not synced;
        // fall back to the polygons captured with the observations.
        if resolvedBlocks.isEmpty, let cached {
            resolvedBlocks = cached.blockInputs
        }
        blocks = resolvedBlocks
        cachedAt = loadedFromNetwork ? Date() : cached?.cachedAt

        rebuildObservationSet()

        if loadedFromNetwork {
            coveredVintages = Set(availableVintages).union([currentVintage()])
            persistCache(vineyardId: vineyardId)
        } else if let cached {
            coveredVintages = Set(cached.coveredVintages)
            notices.append(.offlineCache(cached.cachedAt))
        } else {
            coveredVintages = []
        }

        loadedVineyardId = vineyardId

        // Only a successful fetch can prove a Vintage is genuinely empty.
        // If the fetch failed and nothing local could stand in for it, report
        // the failure rather than an empty map.
        if let fetchFailure, allObservations.isEmpty {
            loadState = .failed(fetchFailure)
            return
        }
        if fetchFailure != nil {
            notices.append(.remoteFailed)
        }
        if blocks.allSatisfy({ $0.polygon.count < 3 }) {
            notices.append(.noBoundaries)
        }

        if allObservations.isEmpty, !loadedFromNetwork, cached == nil {
            loadState = .unavailableOffline
            return
        }

        selectDefaultVintage()
        loadState = .ready
        scheduleRebuild()
    }

    /// Re-merges pending local pins without touching the network. Called when
    /// the operator drops or edits a growth-stage pin while the screen is open.
    func refreshPending(pins: [VinePin], timeZone: TimeZone) {
        refreshLocal(pins: pins, localRecords: nil, timeZone: timeZone)
    }

    /// Re-merges both local sources — unsynced pins and the synced
    /// `growth_stage_records` store the Summary reads — with no network call.
    ///
    /// Passing `nil` for `localRecords` leaves the record set as it is.
    func refreshLocal(
        pins: [VinePin],
        localRecords: [GrowthStageRecord]?,
        timeZone: TimeZone
    ) {
        guard let vineyardId = loadedVineyardId else { return }
        let next = ELRipenessObservationAdapter.pendingRecords(
            pins: pins,
            vineyardId: vineyardId,
            timeZone: timeZone
        )
        let nextRecords = localRecords.map {
            ELRipenessObservationAdapter.localRecords(
                $0,
                vineyardId: vineyardId,
                timeZone: timeZone
            )
        }
        let recordsChanged = nextRecords != nil && nextRecords != localRecordSources
        guard next != pendingSources || recordsChanged else { return }
        pendingSources = next
        if let nextRecords { localRecordSources = nextRecords }
        rebuildEnrichment(
            localRecords: localRecords ?? [],
            pins: pins,
            vineyardId: vineyardId,
            merge: localRecords == nil
        )
        let previousVintage = selectedVintage
        rebuildObservationSet()
        if let previousVintage, availableVintages.contains(previousVintage) {
            selectedVintage = previousVintage
        } else {
            selectDefaultVintage()
        }
        scheduleRebuild()
    }

    /// Indexes full record detail under every id an observation might resolve
    /// to — the record's own id and its pin's id — so the Summary can show
    /// notes, photos and variety no matter which source won the dedupe.
    private func rebuildEnrichment(
        localRecords: [GrowthStageRecord],
        pins: [VinePin],
        vineyardId: UUID,
        merge: Bool = false
    ) {
        var index: [String: GrowthStageRecord] = merge ? enrichmentByRecordId : [:]
        for pin in pins where pin.vineyardId == vineyardId {
            guard let record = GrowthStageRecord.mirroring(pin) else { continue }
            index[pin.id.uuidString.lowercased()] = record
        }
        // Synced records are indexed last so their richer server-side detail
        // wins over the pin they mirror.
        for record in localRecords where record.vineyardId == vineyardId {
            index[record.id.uuidString.lowercased()] = record
            if let pinId = record.pinId {
                index[pinId.uuidString.lowercased()] = record
            }
        }
        enrichmentByRecordId = index
    }

    private func rebuildObservationSet() {
        // Order is only a tie-break; precedence decides the winner. Local
        // records come first so a row the remote view has not published yet
        // still contributes, and is replaced in place once it has.
        allObservations = ELRipenessObservationAdapter.observations(
            from: localRecordSources + remoteSources + pendingSources,
            selectedVineyardId: vineyardIdString
        )
        availableVintages = ELRipenessSeason.availableVintages(
            allObservations,
            month: seasonStartMonth,
            day: seasonStartDay
        )
    }

    private func currentVintage() -> Int {
        ELRipenessSeason.vintage(for: today, month: seasonStartMonth, day: seasonStartDay)
    }

    private func selectDefaultVintage() {
        let preferred = ELRipenessSeason.defaultVintage(
            allObservations,
            month: seasonStartMonth,
            day: seasonStartDay,
            today: today
        )
        selectedVintage = preferred ?? currentVintage()
    }

    private func persistCache(vineyardId: UUID) {
        let payload = ELRipenessCachePayload(
            schemaVersion: ELRipenessCachePayload.currentSchemaVersion,
            vineyardId: vineyardId.uuidString.lowercased(),
            cachedAt: Date(),
            records: remoteSources.map { ELRipenessCachedRecord(from: $0) },
            blocks: blocks.map { ELRipenessCachedBlock(from: $0) },
            coveredVintages: Array(Set(availableVintages).union([currentVintage()])).sorted()
        )
        cache.save(payload)
    }

    // MARK: - Vintage & timeline

    private func vintageDidChange() {
        guard let vintage = selectedVintage else { return }
        vintageObservations = ELRipenessSeason.filter(
            allObservations,
            toVintage: vintage,
            month: seasonStartMonth,
            day: seasonStartDay
        )
        rebuildTimeline()

        if vintageObservations.isEmpty {
            overlays = []
            heatModel = nil
            loadState = coveredVintages.contains(vintage) ? .emptyVintage : .unavailableOffline
            return
        }
        if loadState == .emptyVintage || loadState == .unavailableOffline {
            loadState = .ready
        }
        scheduleRebuild()
    }

    private func rebuildTimeline() {
        // Keyed on the ISO day string so the contract core stays untouched —
        // `CivilDate` is deliberately only Equatable/Comparable there.
        let dayKeys = Set(vintageObservations.map { ELRipeness.dayKey($0.dateISO) })
        let days = dayKeys.compactMap { CivilDate(dayKey: $0) }
        guard let first = days.min(), let last = days.max() else {
            timelineDays = []
            observationDayIndices = []
            timelineIndex = 0
            return
        }
        var out: [CivilDate] = []
        var cursor = first
        while cursor <= last {
            out.append(cursor)
            cursor = cursor.adding(days: 1)
        }
        timelineDays = out
        observationDayIndices = out.enumerated().compactMap { dayKeys.contains($0.element.iso) ? $0.offset : nil }
        // Land on the most recent observation date, which is what an operator
        // opening the screen actually wants to see.
        timelineIndex = observationDayIndices.last ?? max(0, out.count - 1)
    }

    func stepToPreviousObservation() {
        guard let target = observationDayIndices.last(where: { $0 < timelineIndex }) else { return }
        timelineIndex = target
    }

    func stepToNextObservation() {
        guard let target = observationDayIndices.first(where: { $0 > timelineIndex }) else { return }
        timelineIndex = target
    }

    var canStepBack: Bool { observationDayIndices.contains { $0 < timelineIndex } }
    var canStepForward: Bool { observationDayIndices.contains { $0 > timelineIndex } }

    /// Advances one tick of playback.
    ///
    /// - Parameter reduceMotion: when the operator has Reduce Motion on, the
    ///   timeline jumps observation-to-observation instead of sweeping day by
    ///   day, so playback becomes a few discrete steps rather than a continuous
    ///   animation.
    func advancePlayback(reduceMotion: Bool) {
        guard isPlaying else { return }
        if reduceMotion {
            if canStepForward {
                stepToNextObservation()
            } else {
                isPlaying = false
            }
            return
        }
        if timelineIndex + 1 < timelineDays.count {
            timelineIndex += 1
        } else {
            isPlaying = false
        }
    }

    func togglePlayback() {
        if isPlaying {
            isPlaying = false
            return
        }
        guard !timelineDays.isEmpty else { return }
        // Restarting from the end replays the season from the beginning.
        if timelineIndex >= timelineDays.count - 1 {
            timelineIndex = observationDayIndices.first ?? 0
        }
        isPlaying = true
    }

    // MARK: - Rendering

    /// Cancels any in-flight render and schedules a new one. Pure local work.
    func scheduleRebuild() {
        renderTask?.cancel()
        guard loadState == .ready || loadState == .loading else { return }
        guard let dateISO = currentDateISO else {
            overlays = []
            heatModel = nil
            return
        }

        let observations = vintageObservations
        let blockInputs = blocks
        let filter = selectedBlockId
        isRendering = true

        renderTask = Task { [weak self] in
            let result = await Self.render(
                observations: observations,
                blocks: blockInputs,
                dateISO: dateISO,
                filter: filter
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.apply(result)
            }
        }
    }

    /// Awaits the in-flight render. Used by teardown and by tests that need a
    /// settled surface before asserting on it.
    func waitForRender() async {
        await renderTask?.value
    }

    private nonisolated struct RenderResult: Sendable {
        let heat: ELRipeness.HeatModel
        let overlays: [ELRipenessHeatOverlay]
    }

    /// Heavy work, off the main actor. Cooperatively cancellable between blocks
    /// so a fast timeline drag abandons stale surfaces instead of drawing them.
    private nonisolated static func render(
        observations: [ELRipeness.Observation],
        blocks: [ELRipeness.BlockInput],
        dateISO: String,
        filter: String?
    ) async -> RenderResult? {
        await Task.detached(priority: .userInitiated) { () -> RenderResult? in
            let heat = ELRipeness.buildHeatModel(
                observations: observations,
                blocks: blocks,
                atDateISO: dateISO,
                blockFilter: filter
            )
            if Task.isCancelled { return nil }

            var overlays: [ELRipenessHeatOverlay] = []
            overlays.reserveCapacity(heat.blocks.count)
            for block in heat.blocks {
                if Task.isCancelled { return nil }
                if let overlay = ELRipenessHeatOverlay.make(from: block) {
                    overlays.append(overlay)
                }
            }
            return RenderResult(heat: heat, overlays: overlays)
        }.value
    }

    private func apply(_ result: RenderResult?) {
        isRendering = false
        guard let result else { return }
        heatModel = result.heat
        overlays = result.overlays
        recomputeNotices()
    }

    private func recomputeNotices() {
        var next: [SurfaceNotice] = notices.filter {
            if case .offlineCache = $0 { return true }
            return false
        }
        guard let heatModel else {
            notices = next
            return
        }
        let missing = heatModel.blocks.filter { $0.mode == .noPolygon }.map { $0.paddockName ?? "Block" }
        if !missing.isEmpty { next.append(.missingPolygon(missing)) }
        if heatModel.influencing.isEmpty, !heatModel.stale.isEmpty { next.append(.staleOnly) }
        notices = next
    }

    /// Releases every overlay and cancels in-flight work. Called when the
    /// screen goes away so a season's worth of bitmaps does not linger.
    func teardown() {
        renderTask?.cancel()
        renderTask = nil
        isPlaying = false
        overlays = []
        heatModel = nil
        isRendering = false
    }

    // MARK: - Helpers

    static func civilToday(in timeZone: TimeZone) -> CivilDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        return CivilDate(
            year: parts.year ?? 2000,
            month: parts.month ?? 1,
            day: parts.day ?? 1
        )
    }

    /// Inclusive season range for the selected Vintage, for display.
    func seasonRangeText(formatter: RegionFormatter) -> String? {
        guard let vintage = selectedVintage else { return nil }
        let range = ELRipenessSeason.seasonRange(
            month: seasonStartMonth,
            day: seasonStartDay,
            vintage: vintage
        )
        return "\(range.startISO) — \(range.endISO)"
    }
}

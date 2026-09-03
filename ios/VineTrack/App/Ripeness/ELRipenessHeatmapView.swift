import CoreLocation
import SwiftUI

/// The E-L Ripeness Heatmap.
///
/// Shows how ripeness has moved across the vineyard through a Vintage: a
/// block-clipped interpolated surface, the observations that produced it, and a
/// timeline to scrub the season. Every number on screen comes from the shared
/// contract core, so it matches the Portal and Android exactly.
struct ELRipenessHeatmapView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NetworkMonitor.self) private var network

    @State private var model = ELRipenessHeatmapModel()

    private var timeZone: TimeZone { store.settings.resolvedTimeZone }

    var body: some View {
        ELRipenessHeatmapContent(
            model: model,
            isOnline: network.isOnline,
            formatter: store.settings.regionFormatter,
            timeZone: timeZone,
            onRetry: { await loadIfNeeded(force: true) }
        )
        .task(id: store.selectedVineyardId) {
            await loadIfNeeded()
        }
        .onChange(of: store.pins.count) {
            model.refreshPending(pins: store.pins, timeZone: timeZone)
        }
        .onDisappear {
            model.teardown()
        }
    }

    private func loadIfNeeded(force: Bool = false) async {
        guard let vineyardId = store.selectedVineyardId else { return }
        await model.load(
            vineyardId: vineyardId,
            paddocks: store.paddocks,
            pins: store.pins,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay,
            timeZone: timeZone,
            isOnline: network.isOnline,
            force: force
        )
    }
}

/// The screen's entire presentation, with its dependencies passed in rather
/// than read from the environment.
///
/// Splitting this out keeps `ELRipenessHeatmapView` as a thin shell that owns
/// loading, and lets the snapshot harness render the real shipped UI against a
/// controlled model instead of a mock-up of it.
struct ELRipenessHeatmapContent: View {
    let model: ELRipenessHeatmapModel
    let isOnline: Bool
    let formatter: RegionFormatter
    /// The vineyard's timezone, so timeline labels name the field-capture day.
    let timeZone: TimeZone
    var onRetry: () async -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var selectedObservation: ELRipeness.Observation?
    @State private var isShowingInfo: Bool = false

    /// Playback tick. Reduce Motion steps observation-to-observation, so it
    /// wants a slower cadence than the day-by-day sweep.
    private var playbackInterval: TimeInterval { reduceMotion ? 0.9 : 0.09 }

    private var fmt: RegionFormatter { formatter }

    /// Landscape on iPhone: move the controls beside the map so the surface
    /// keeps the height it needs.
    private var isLandscapePhone: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            switch model.loadState {
            case .idle, .loading:
                ProgressView("Loading observations…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailableOffline:
                unavailableOffline
            case .emptyVintage:
                emptyVintage
            case .failed(let message):
                failure(message)
            case .ready:
                content
            }
        }
        .navigationTitle("Ripeness Heatmap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About this map")
            }
        }
        .sheet(isPresented: $isShowingInfo) {
            ELRipenessInfoView()
        }
        .sheet(item: observationBinding) { box in
            ELRipenessObservationSheet(
                observation: box.observation,
                blockName: blockName(for: box.observation.paddockId),
                atDateISO: model.currentDateISO ?? box.observation.dateISO
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
    }

    // MARK: - Ready content

    @ViewBuilder
    private var content: some View {
        if isLandscapePhone {
            HStack(spacing: 0) {
                mapSurface
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        controls
                        statusBlock
                        ELRipenessLegendView()
                    }
                    .padding(14)
                }
                .frame(width: 300)
                .background(Color(.systemGroupedBackground))
            }
        } else {
            VStack(spacing: 0) {
                controls
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemGroupedBackground))

                mapSurface

                VStack(alignment: .leading, spacing: 12) {
                    statusBlock
                    ELRipenessTimelineBar(
                        index: timelineBinding,
                        dayCount: model.timelineDays.count,
                        observationIndices: model.observationDayIndices,
                        currentLabel: currentDateLabel,
                        isPlaying: model.isPlaying,
                        canStepBack: model.canStepBack,
                        canStepForward: model.canStepForward,
                        onStepBack: model.stepToPreviousObservation,
                        onStepForward: model.stepToNextObservation,
                        onTogglePlay: model.togglePlayback
                    )
                    ELRipenessLegendView()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(Color(.systemGroupedBackground))
            }
        }
    }

    private var mapSurface: some View {
        ZStack(alignment: .topLeading) {
            ELRipenessMapView(
                overlays: model.overlays,
                blocks: model.heatModel?.blocks ?? [],
                annotations: observationAnnotations,
                labels: blockLabels,
                selectedBlockId: model.selectedBlockId,
                isOnline: isOnline,
                onSelectObservation: { selectedObservation = $0 }
            )
            .ignoresSafeArea(edges: isLandscapePhone ? [.bottom] : [])

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.notices.indices, id: \.self) { index in
                    noticeChip(model.notices[index])
                }
                if model.isRendering {
                    noticeLabel(text: "Updating surface…", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
                }
            }
            .padding(10)

            if isLandscapePhone {
                VStack {
                    Spacer()
                    ELRipenessTimelineBar(
                        index: timelineBinding,
                        dayCount: model.timelineDays.count,
                        observationIndices: model.observationDayIndices,
                        currentLabel: currentDateLabel,
                        isPlaying: model.isPlaying,
                        canStepBack: model.canStepBack,
                        canStepForward: model.canStepForward,
                        onStepBack: model.stepToPreviousObservation,
                        onStepForward: model.stepToNextObservation,
                        onTogglePlay: model.togglePlayback
                    )
                    .padding(10)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                    .padding(10)
                }
            }
        }
        .task(id: model.isPlaying) {
            await runPlayback()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.availableVintages.count > 1 {
                Picker("Vintage", selection: vintageBinding) {
                    ForEach(model.availableVintages, id: \.self) { vintage in
                        Text(String(vintage)).tag(vintage)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Vintage")
            } else if let vintage = model.selectedVintage {
                Text("Vintage \(String(vintage))")
                    .font(.subheadline.weight(.semibold))
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    FilterChip(title: "All Blocks", isSelected: model.selectedBlockId == nil) {
                        model.selectedBlockId = nil
                    }
                    ForEach(model.blocks, id: \.id) { block in
                        FilterChip(
                            title: block.name ?? "Block",
                            isSelected: model.selectedBlockId == block.id
                        ) {
                            model.selectedBlockId = model.selectedBlockId == block.id ? nil : block.id
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var statusBlock: some View {
        let counts = model.statusCounts
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusPill(
                    value: counts.recorded,
                    label: "recorded",
                    tint: .primary,
                    hint: "Observations available at this date, including stale and unassigned"
                )
                statusPill(value: counts.influencing, label: "current", tint: .green, hint: "Influencing the surface")
                statusPill(value: counts.stale, label: "stale", tint: .secondary, hint: "Too old to influence")
                if counts.unassigned > 0 {
                    statusPill(value: counts.unassigned, label: "unassigned", tint: .orange, hint: "No block recorded")
                }
            }
            if let median = model.medianEl {
                Text("Median \(ELRipeness.formatEl(median))")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("Median stage \(ELRipeness.formatEl(median)) across influencing observations")
            } else {
                Text("No influencing observations at this date")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusPill(value: Int, label: String, tint: Color, hint: String) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityHint(hint)
    }

    @ViewBuilder
    private func noticeChip(_ notice: ELRipenessHeatmapModel.SurfaceNotice) -> some View {
        switch notice {
        case .staleOnly:
            noticeLabel(
                text: "All observations here are older than 84 days — no current surface",
                systemImage: "clock.badge.exclamationmark",
                tint: .orange
            )
        case .missingPolygon(let names):
            noticeLabel(
                text: names.count == 1
                    ? "\(names[0]) has no boundary — pins only"
                    : "\(names.count) blocks have no boundary — pins only",
                systemImage: "square.dashed",
                tint: .orange
            )
        case .offlineCache(let date):
            noticeLabel(
                text: "Offline — showing data cached \(fmt.formatDate(date))",
                systemImage: "wifi.slash",
                tint: .secondary
            )
        }
    }

    private func noticeLabel(text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - States

    private var unavailableOffline: some View {
        ContentUnavailableView {
            Label("Not available offline", systemImage: "wifi.slash")
        } description: {
            Text("This Vintage has not been downloaded to this device yet, so we cannot tell you what it contains. Connect to a network and open it once — after that it will work in the field with no signal.")
        } actions: {
            Button("Try again") {
                Task { await onRetry() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isOnline)
        }
    }

    private var emptyVintage: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("No ripeness observations", systemImage: "map")
            } description: {
                Text("No growth stage observations were recorded in this Vintage. Drop growth stage pins in the field and they will appear here — including before they sync.")
            }
            if model.availableVintages.count > 1 {
                Picker("Vintage", selection: vintageBinding) {
                    ForEach(model.availableVintages, id: \.self) { vintage in
                        Text(String(vintage)).tag(vintage)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could not load the heatmap", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                Task { await onRetry() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Bindings & derived data

    private var vintageBinding: Binding<Int> {
        Binding(
            get: { model.selectedVintage ?? model.availableVintages.first ?? 0 },
            set: { model.selectedVintage = $0 }
        )
    }

    private var timelineBinding: Binding<Int> {
        Binding(
            get: { model.timelineIndex },
            set: { model.timelineIndex = $0 }
        )
    }

    private var observationBinding: Binding<ELRipenessObservationBox?> {
        Binding(
            get: { selectedObservation.map { ELRipenessObservationBox(observation: $0) } },
            set: { selectedObservation = $0?.observation }
        )
    }

    private var currentDateLabel: String {
        guard let day = model.currentDay else { return "—" }
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return day.iso }
        return fmt.formatDate(date)
    }

    private func blockName(for paddockId: String?) -> String? {
        guard let paddockId else { return nil }
        return model.blocks.first { $0.id == paddockId }?.name
    }

    /// Observation pins for the current date, styled by influence.
    private var observationAnnotations: [ELRipenessObservationAnnotation] {
        guard let heatModel = model.heatModel, let dateISO = model.currentDateISO else { return [] }
        var out: [ELRipenessObservationAnnotation] = []

        for block in heatModel.blocks {
            for observation in block.influencing {
                out.append(annotation(observation, style: .current, dateISO: dateISO))
            }
            for observation in block.stale {
                out.append(annotation(observation, style: .stale, dateISO: dateISO))
            }
        }
        for observation in heatModel.unassigned {
            out.append(annotation(observation, style: .unassigned, dateISO: dateISO))
        }
        return out
    }

    private func annotation(
        _ observation: ELRipeness.Observation,
        style: ELRipenessObservationAnnotation.Style,
        dateISO: String
    ) -> ELRipenessObservationAnnotation {
        let age = ELRipeness.daysBetween(observation.dateISO, dateISO)
        return ELRipenessObservationAnnotation(
            observation: observation,
            style: style,
            blockName: blockName(for: observation.paddockId),
            ageDays: age,
            recencyWeight: ELRipeness.recencyWeight(ageDays: age)
        )
    }

    /// Block name plates carrying the influencing-only median.
    private var blockLabels: [ELRipenessBlockLabelAnnotation] {
        guard let heatModel = model.heatModel else { return [] }
        return heatModel.blocks.compactMap { block in
            guard block.polygon.count >= 3,
                  let centroid = ELRipenessGeometry.centroid(of: block.polygon) else { return nil }
            return ELRipenessBlockLabelAnnotation(
                paddockId: block.paddockId,
                name: block.paddockName ?? "Block",
                medianEl: block.medianEl,
                mode: block.mode,
                coordinate: centroid
            )
        }
    }

    // MARK: - Playback

    private func runPlayback() async {
        guard model.isPlaying else { return }
        while model.isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(playbackInterval))
            if Task.isCancelled { return }
            model.advancePlayback(reduceMotion: reduceMotion)
        }
    }
}

/// `Observation` is not `Identifiable`; this box lets it drive a sheet.
struct ELRipenessObservationBox: Identifiable {
    let observation: ELRipeness.Observation
    var id: String { observation.id }
}

/// Small geometry helpers that are useful to the UI but not part of the
/// contract core.
nonisolated enum ELRipenessGeometry {
    /// Area-weighted polygon centroid, falling back to the vertex mean for
    /// degenerate (zero-area) rings so a label always has somewhere to sit.
    static func centroid(of polygon: [ELRipeness.LatLng]) -> CLLocationCoordinate2D? {
        guard polygon.count >= 3 else {
            guard let first = polygon.first else { return nil }
            return CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng)
        }
        var area = 0.0
        var lat = 0.0
        var lng = 0.0
        for index in 0..<polygon.count {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            let cross = current.lng * next.lat - next.lng * current.lat
            area += cross
            lng += (current.lng + next.lng) * cross
            lat += (current.lat + next.lat) * cross
        }
        area *= 0.5
        guard abs(area) > 1e-12 else {
            let meanLat = polygon.reduce(0.0) { $0 + $1.lat } / Double(polygon.count)
            let meanLng = polygon.reduce(0.0) { $0 + $1.lng } / Double(polygon.count)
            return CLLocationCoordinate2D(latitude: meanLat, longitude: meanLng)
        }
        return CLLocationCoordinate2D(latitude: lat / (6 * area), longitude: lng / (6 * area))
    }
}

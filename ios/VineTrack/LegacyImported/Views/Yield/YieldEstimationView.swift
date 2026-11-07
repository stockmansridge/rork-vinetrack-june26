import SwiftUI
import MapKit

struct YieldEstimationView: View {
    @Environment(MigratedDataStore.self) private var store
    @State private var showCountMethod = false
    @State private var showPermanentSites = false
    @State private var confirmedSiteSets: [UUID: YieldSamplingSiteSetRow] = [:]
    @State private var confirmedSiteCounts: [UUID: Int] = [:]
    @State private var savedLocationBlocks: Set<UUID> = []
    /// Blocks already asked "fixed or dynamic?" so the prompt shows once per block.
    @State private var promptedBlocks: Set<UUID> = []
    /// Sample count mode: per hectare (shared default) or a fixed number per block (this device).
    @AppStorage("yield.sampling.perBlockMode") private var perBlockMode = false
    @AppStorage("yield.sampling.samplesPerBlock") private var samplesPerBlock = 5
    @State private var siteSourcesLoading = false
    @State private var siteRouteBusy = false
    @State private var siteRouteError: String?
    private let siteSetsRepository = SupabaseYieldSamplingSitesRepository()
    @Environment(\.accessControl) private var accessControl
    @Environment(NetworkMonitor.self) private var network
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSync
    @State private var viewModel = YieldEstimationViewModel()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showBunchCountSheet: Bool = false
    @State private var showFullScreenMap: Bool = false
    @State private var fullScreenSelectedSite: SampleSite?
    @State private var showCompleteConfirmation: Bool = false
    @State private var showSamplesPerHaEditor: Bool = false
    @State private var samplesPerHaText: String = ""
    @State private var showSampling: Bool = false
    @State private var showDeleteEstimationConfirm: Bool = false
    @State private var showHomeDraftDeleteConfirm = false
    @State private var homeDraftDeleteTarget: YieldEstimationSession?
    @State private var hardDeleteBusy = false
    @State private var hardDeleteError: String?
    private let hardDeleteRepo = SupabaseYieldEstimationHardDeleteRepository()
    /// Whether a trip (draft or completed history view) is open. False shows
    /// the Bunch Count Trip home (start / resume / history).
    @State private var tripStarted: Bool = false
    @State private var saveFailed = false
    private let samplingSettingsRepo = SupabaseYieldSamplingSettingsRepository()
    var refreshSharedDefaults = true

    private var paddocks: [Paddock] {
        store.orderedPaddocks.filter { $0.polygonPoints.count >= 3 }
    }

    private var samplesPerHa: Int {
        store.settings.samplesPerHectare
    }

    /// The vintage the in-progress / open trip belongs to. Damage is always
    /// scoped to it, so a previous season's frost can never reduce this
    /// trip's estimate.
    private var tripVintage: Int {
        VintageResolver.vintageYear(
            for: viewModel.sessionCreatedAt ?? Date(),
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private let blockColors: [Color] = [
        .blue, .green, .orange, .purple, .red, .cyan, .mint, .indigo, .pink, .teal, .yellow, .brown
    ]

    private func colorFor(_ paddock: Paddock) -> Color {
        guard let idx = paddocks.firstIndex(where: { $0.id == paddock.id }) else { return .blue }
        return blockColors[idx % blockColors.count]
    }

    var body: some View {
        Group {
            if tripStarted {
                tripContent
            } else {
                introContent
            }
        }
        .confirmationDialog("Choose Yield Estimate Count Method", isPresented: $showCountMethod, titleVisibility: .visible) {
            Button("1. Bunches Per Vine Count") { startTrip() }
            Button("2. Quadrant Count") { startQuadrantTrip() }
            Button("3. Panel Count") { startPanelTrip() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPermanentSites) {
            if let vineyardId = store.selectedVineyardId {
                YieldPermanentSamplingLocationsView(vineyardId: vineyardId, paddocks: paddocks)
            }
        }
        .task(id: viewModel.selectedPaddockIds) {
            if !tripStarted || !viewModel.isGenerated { await loadConfirmedSamplingSites() }
        }
        .alert(fixedPromptBlock.map { "\($0.name) has permanent sampling locations" } ?? "",
               isPresented: Binding(
                   get: { fixedPromptBlock != nil },
                   set: { shown in if !shown, let block = fixedPromptBlock { promptedBlocks.insert(block.id) } }
               )) {
            if let block = fixedPromptBlock {
                Button("Use Fixed Locations") {
                    savedLocationBlocks.insert(block.id); promptedBlocks.insert(block.id)
                }
                Button("Use Dynamic Sites") {
                    savedLocationBlocks.remove(block.id); promptedBlocks.insert(block.id)
                }
            }
        } message: {
            if let block = fixedPromptBlock {
                Text("Use the \(confirmedSiteCounts[block.id] ?? 0) pre-configured fixed locations for this block, or generate dynamic sample sites?")
            }
        }
        .task { if refreshSharedDefaults { await syncSamplingDefault() } }
        .alert("Hard Delete Draft?", isPresented: $showHomeDraftDeleteConfirm) {
            Button("Hard Delete", role: .destructive) {
                if let target = homeDraftDeleteTarget {
                    Task { await hardDeleteSession(target) }
                }
            }
            Button("Cancel", role: .cancel) { homeDraftDeleteTarget = nil }
        } message: {
            Text("This permanently removes the draft and all its recorded observations for everyone. It cannot be undone.")
        }
        .alert("Hard delete not confirmed", isPresented: Binding(
            get: { hardDeleteError != nil },
            set: { if !$0 { hardDeleteError = nil } }
        )) {
            Button("OK", role: .cancel) { hardDeleteError = nil }
        } message: {
            Text(hardDeleteError ?? "Check the network and your vineyard permissions.")
        }
        .modifier(YieldMasterRefresh(enabled: refreshSharedDefaults))
        .alert("Trip not saved", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The trip could not be saved on this device. Keep it open and retry.")
        }
    }

    // MARK: - Bunch Count Trip home (start / resume / history)

    private var activeDraft: YieldEstimationSession? {
        BunchCountTripLogic.activeDraft(sessions: store.yieldSessions, vineyardId: store.selectedVineyardId)
    }

    private var completedTrips: [YieldEstimationSession] {
        BunchCountTripLogic.completedTrips(sessions: store.yieldSessions, vineyardId: store.selectedVineyardId)
    }

    private var introContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Yield Estimate Trip", systemImage: "figure.walk")
                        .font(.headline)
                    Text("Choose a count method and collect yield samples by block. Permanent sampling locations are optional.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Completed trips remain in history. The current estimate selection is unchanged until the expanded methods are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))

                Button {
                    showCountMethod = true
                } label: {
                    Label("Start Yield Estimate Trip", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(paddocks.isEmpty)

                Button {
                    showPermanentSites = true
                } label: {
                    Label("Set Permanent Locations (Optional)", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(paddocks.isEmpty || store.selectedVineyardId == nil)
                .accessibilityIdentifier("yield.sites.open")

                if let draft = activeDraft {
                    Button {
                        resumeTrip(draft)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.isPanelCount ? "Resume Panel Count" : (draft.isQuadrantCount ? "Resume Quadrant Count" : "Resume trip in progress"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(draft.sampleSites.isEmpty
                                    ? "Blocks and route not confirmed yet"
                                    : "\(draft.sampleSites.filter(\.isRecorded).count) of \(draft.sampleSites.count) sample sites recorded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("yield.resume")
                    Text("Draft · Recorded Observations")
                    Button {
                        resumeTrip(draft)
                        if !draft.sampleSites.isEmpty { showSampling = true }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            if draft.isPanelCount {
                                PanelCountSummary(session: draft)
                            } else {
                                CurrentYieldEstimateSummary(estimate: currentEstimate(draft), detailed: false)
                            }
                            Label("Tap to review, correct or delete a recorded sample",
                                  systemImage: "square.and.pencil")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("yield.draft.recorded.open")
                    Button(role: .destructive) {
                        homeDraftDeleteTarget = draft
                        showHomeDraftDeleteConfirm = true
                    } label: {
                        Label("Hard Delete Draft", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityIdentifier("yield.draft.hardDelete")
                }

                if paddocks.isEmpty {
                    Text("Map at least one block boundary in Blocks before starting a yield estimate trip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !completedTrips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Completed trips", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(completedTrips) { trip in
                            let estimate = currentEstimate(trip)
                            Button {
                                resumeTrip(trip)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(estimate.blocks.map(\.name).joined(separator: ", ").isEmpty ? "Block unavailable" : estimate.blocks.map(\.name).joined(separator: ", "))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text(Array(Set(estimate.blocks.map(\.varieties).filter { !$0.isEmpty })).sorted().joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(fmt.formatDate(trip.completedAt ?? trip.createdAt))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(trip.isPanelCount
                                        ? "\(trip.sampleSites.filter { $0.panelCountEntry != nil }.count) panels"
                                        : (estimate.totalTonnes.map { String(format: "%.3f t", $0) }
                                           ?? "Bunch weight required"))
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(VineyardTheme.leafGreen)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("yield.completed.\(trip.id.uuidString.lowercased())")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle("Yield Estimate Trips")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func currentEstimate(_ trip: YieldEstimationSession) -> CurrentYieldEstimate.Trip {
        let vintage = YieldVintageReport.sessionVintage(trip, seasonStartMonth: store.settings.seasonStartMonth, seasonStartDay: store.settings.seasonStartDay)
        return CurrentYieldEstimate.trip(session: trip, paddocks: store.paddocks,
            weights: YieldMasterWeightCache.shared.weights(vineyardId: trip.vineyardId),
            remaining: { store.remainingYieldMultiplier(for: $0, vintage: vintage) })
    }

    private func isCurrent(_ trip: YieldEstimationSession) -> Bool {
        trip.selectedPaddockIds.contains { block in
            YieldVintageReport.latestCompletedSessionForBlock(sessions: store.yieldSessions.filter { $0.vineyardId == trip.vineyardId },
                paddockId: block, vintage: VintageResolver.vintageYear(for: Date(), seasonStartMonth: store.settings.seasonStartMonth, seasonStartDay: store.settings.seasonStartDay),
                seasonStartMonth: store.settings.seasonStartMonth, seasonStartDay: store.settings.seasonStartDay)?.id == trip.id
        }
    }

    private var observation: YieldEstimationSession {
        YieldEstimationSession(id: viewModel.sessionId ?? store.selectedVineyardId ?? UUID(),
            vineyardId: store.selectedVineyardId ?? UUID(), createdAt: viewModel.sessionCreatedAt ?? Date(),
            selectedPaddockIds: Array(viewModel.selectedPaddockIds), sampleSites: viewModel.sampleSites,
            blockBunchWeightsKg: viewModel.blockBunchWeightsKg, isCompleted: viewModel.isCompleted,
            completedAt: viewModel.completedAt, applyDamage: viewModel.applyDamage,
            countMethod: viewModel.countMethod, quadrantSectionLengthCm: viewModel.isQuadrantCount ? viewModel.quadrantSectionLengthCm : nil,
            siteSetVersions: viewModel.siteSetVersions)
    }

    private func startTrip() {
        viewModel.startNewTrip()
        withAnimation(.smooth(duration: 0.25)) { tripStarted = true }
        fitMap()
    }

    private func startPanelTrip() {
        viewModel.startNewTrip()
        viewModel.countMethod = "panel"
        withAnimation(.smooth(duration: 0.25)) { tripStarted = true }
        fitMap()
    }

    private func startQuadrantTrip() {
        viewModel.startNewTrip()
        viewModel.countMethod = "quadrant"
        withAnimation(.smooth(duration: 0.25)) { tripStarted = true }
        fitMap()
    }

    private func resumeTrip(_ session: YieldEstimationSession) {
        viewModel.loadSession(session)
        withAnimation(.smooth(duration: 0.25)) { tripStarted = true }
        fitMapToSites()
    }

    /// Pull the shared vineyard sampling default (sql/187) into local settings
    /// so the next trip starts from the vineyard-wide value.
    private func syncSamplingDefault() async {
        guard let vid = store.selectedVineyardId else { return }
        if let n = try? await samplingSettingsRepo.fetchDefault(vineyardId: vid),
           n > 0, n != store.settings.samplesPerHectare {
            var s = store.settings
            s.samplesPerHectare = n
            store.updateSettings(s)
        }
    }

    // MARK: - Trip content

    private var tripContent: some View {
        Group {
            if viewModel.isGenerated {
                routePreviewContent
            } else {
                setupContent
            }
        }
.navigationTitle(viewModel.isPanelCount ? "Panel Count" : (viewModel.isQuadrantCount ? "Quadrant Count" : "Yield Estimate Trip"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { tripStarted = false } label: {
                    Label("Yield Estimate Trips", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("yield.backToTrips")
            }
            if showsTripMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    tripOptionsMenu
                }
            }
        }
        .sheet(isPresented: $showBunchCountSheet) {
            if let site = viewModel.selectedSite {
                countEntrySheet(site: site)
            }
        }
        .fullScreenCover(isPresented: $showFullScreenMap) {
            FullScreenPathMapView(
                paddocks: paddocks.filter { viewModel.selectedPaddockIds.contains($0.id) },
                sampleSites: viewModel.sampleSites,
                pathWaypoints: viewModel.pathWaypoints,
                blockColors: blockColors,
                colorForPaddock: { colorFor($0) },
                onSiteSelected: { site in
                    fullScreenSelectedSite = site
                }
            )
            .sheet(item: $fullScreenSelectedSite) { site in
                countEntrySheet(site: site)
            }
        }
        .sheet(isPresented: $showSamplesPerHaEditor) {
            samplesPerHaSheet
                .presentationDetents([.medium])
        }
        .navigationDestination(isPresented: $showSampling) {
            YieldSamplingNavigationView(viewModel: viewModel, onReturnToTrips: {
                showSampling = false
                tripStarted = false
            })
        }
        .alert("Delete Trip?", isPresented: $showDeleteEstimationConfirm) {
            Button("Hard Delete", role: .destructive) {
                Task { await hardDeleteCurrentEstimation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently delete this yield estimate trip and its recorded observations for all vineyard devices? This cannot be undone. Confirmed records require Supervisor, Manager or Owner permission.")
        }
        .onAppear {
            fitMap()
        }
    }

    @ViewBuilder
    private func countEntrySheet(site: SampleSite) -> some View {
        if viewModel.isPanelCount {
            PanelCountEntrySheet(site: site,
                blockPanelLengthMetres: paddocks.first { $0.id == site.paddockId }?.intermediatePostSpacing) { measurement, recordedBy in
                viewModel.savePanelCount(siteId: site.id, measurement: measurement,
                                         recordedBy: recordedBy, persist: saveSession)
            }
        } else if viewModel.isQuadrantCount {
            let block = paddocks.first { $0.id == site.paddockId }
            QuadrantCountEntrySheet(site: site, defaultLengthCm: viewModel.quadrantSectionLengthCm,
                vineSpacingCm: block.flatMap { $0.vineSpacingIsKnown == false ? nil : $0.vineSpacing * 100 }) { measurement, name in
                    return viewModel.saveQuadrantCount(siteId: site.id, measurement: measurement,
                        recordedBy: name, persist: saveSession)
                }
        } else {
            BunchCountEntrySheet(site: site) { count, name in
                viewModel.recordBunchCount(siteId: site.id, bunchesPerVine: count, recordedBy: name)
                saveSession()
            }
        }
    }

    // MARK: - Setup (blocks + route choice)

    private var setupContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                mapSection(height: 320)
                blockSelectionSection
                sourceSelectionSection
                summarySection
                generateButton
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Route preview (pre-start confirmation)

    /// Simplified route confirmation — the map dominates the screen; the only
    /// actions are Start Sampling (plus a single Regenerate Path for newly
    /// generated routes). Bunch weights, progress and completion appear only
    /// once sampling has started; delete/change-route live in the overflow
    /// menu. Visibility rules come from the shared, tested
    /// `BunchCountTripLogic.routePreviewControls` contract (Android parity).
    private var routePreviewContent: some View {
        let controls = BunchCountTripLogic.routePreviewControls(
            isRouteReused: viewModel.routeSourceSessionId != nil,
            recordedSiteCount: viewModel.recordedSiteCount,
            isCompleted: viewModel.isCompleted
        )
        return ScrollView {
            VStack(spacing: 12) {
                if viewModel.isCompleted {
                    completedBanner
                }

                mapSection(height: 440)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            showFullScreenMap = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(.black.opacity(0.45), in: .rect(cornerRadius: 8))
                        }
                        .padding(10)
                    }

                if controls.showsReuseIndicator {
                    Label("Using previous sampling route", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                if controls.showsRegeneratePath {
                    regeneratePathButton
                }

                if controls.showsStartSampling {
                    startSamplingButton(isContinue: controls.startSamplingIsContinue)
                }

                if controls.showsProgress {
                    progressSection
                }

                if controls.showsCompleteAction {
                    completeJobButton
                }

                if viewModel.isCompleted {
                    if viewModel.isPanelCount {
                        PanelCountSummary(session: observation)
                    } else {
                        CurrentYieldEstimateSummary(estimate: currentEstimate(observation), current: isCurrent(observation))
                    }
                    startNewTripButton
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Map

    private func mapSection(height: CGFloat) -> some View {
        Group {
            if network.isOnline {
                hybridMapSection
            } else {
                offlineMapSection
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 14))
    }

    private var offlineMapSection: some View {
        OfflineVineyardMapView(
            paddocks: paddocks.map { paddock in
                let isSelected = viewModel.selectedPaddockIds.contains(paddock.id)
                let color = colorFor(paddock)
                return OfflineVineyardMapView.Paddock(
                    id: paddock.id,
                    polygon: paddock.polygonPoints.map(\.coordinate),
                    rows: isSelected ? paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] } : [],
                    strokeColor: color.opacity(isSelected ? 1.0 : 0.3),
                    fillColor: color.opacity(isSelected ? 0.3 : 0.08),
                    name: paddock.name
                )
            },
            trails: viewModel.isPathGenerated && viewModel.pathWaypoints.count >= 2
                ? [OfflineVineyardMapView.Trail(
                    id: 0,
                    coordinates: viewModel.pathWaypoints.map(\.coordinate),
                    color: .orange,
                    lineWidth: 2.5
                  )]
                : [],
            pins: viewModel.sampleSites.map { site in
                let paddock = paddocks.first { $0.id == site.paddockId }
                let color = paddock.map { colorFor($0) } ?? .red
                return OfflineVineyardMapView.Pin(
                    id: site.id,
                    coordinate: site.coordinate,
                    color: site.isRecorded ? .green : color,
                    isCompleted: site.isRecorded,
                    name: "\(site.siteIndex)"
                )
            }
        )
    }

    private var hybridMapSection: some View {
        Map(position: $mapPosition) {
            ForEach(paddocks) { paddock in
                let color = colorFor(paddock)
                let isSelected = viewModel.selectedPaddockIds.contains(paddock.id)

                MapPolygon(coordinates: paddock.polygonPoints.map(\.coordinate))
                    .foregroundStyle(color.opacity(isSelected ? 0.3 : 0.08))
                    .stroke(color.opacity(isSelected ? 1.0 : 0.3), lineWidth: isSelected ? 2.5 : 1)

                if isSelected {
                    ForEach(paddock.rows) { row in
                        MapPolyline(coordinates: [row.startPoint.coordinate, row.endPoint.coordinate])
                            .stroke(color.opacity(0.2), lineWidth: 0.5)
                    }
                }

                Annotation("", coordinate: paddock.polygonPoints.centroid) {
                    Text(paddock.name)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color.opacity(isSelected ? 0.9 : 0.4), in: .capsule)
                }
            }

            if viewModel.isPathGenerated {
                MapPolyline(coordinates: viewModel.pathWaypoints.map(\.coordinate))
                    .stroke(.orange, lineWidth: 2.5)

                if viewModel.pathWaypoints.count >= 2 {
                    let startCoord = viewModel.pathWaypoints[0].coordinate
                    let endCoord = viewModel.pathWaypoints[viewModel.pathWaypoints.count - 1].coordinate

                    Annotation("Start", coordinate: startCoord) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(4)
                            .background(.white, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 2)
                    }

                    Annotation("End", coordinate: endCoord) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.red)
                            .padding(4)
                            .background(.white, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 2)
                    }
                }
            }

            ForEach(viewModel.sampleSites) { site in
                let paddock = paddocks.first { $0.id == site.paddockId }
                let color = paddock.map { colorFor($0) } ?? .red
                let isRecorded = site.isRecorded

                Annotation("", coordinate: site.coordinate) {
                    Button {
                        if !viewModel.isCompleted {
                            viewModel.selectedSite = site
                            showBunchCountSheet = true
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isRecorded ? .green : color)
                                .frame(width: 24, height: 24)
                            Circle()
                                .fill(.white)
                                .frame(width: 16, height: 16)
                            if isRecorded {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundStyle(.green)
                            } else {
                                Text("\(site.siteIndex)")
                                    .font(.system(size: 7, weight: .heavy))
                                    .foregroundStyle(color)
                            }
                        }
                    }
                }
            }
        }
        .mapStyle(.hybrid)
    }

    // MARK: - Block Selection

    private var blockSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Select Blocks", systemImage: "checklist")
                    .font(.headline)

                Spacer()

                if viewModel.selectedPaddockIds.count == paddocks.count {
                    Button("Deselect All") {
                        viewModel.deselectAll()
                    }
                    .font(.caption.weight(.medium))
                } else {
                    Button("Select All") {
                        viewModel.selectAll(paddocks: paddocks)
                    }
                    .font(.caption.weight(.medium))
                }
            }

            if paddocks.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "map")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No blocks with boundaries found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    ForEach(paddocks) { paddock in
                        let isSelected = viewModel.selectedPaddockIds.contains(paddock.id)
                        let color = colorFor(paddock)

                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                viewModel.togglePaddock(paddock.id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(isSelected ? color : .secondary)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(paddock.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(fmt.formatArea(hectares: paddock.areaHectares))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? color.opacity(0.12) : Color(.tertiarySystemFill))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? color.opacity(0.5) : .clear, lineWidth: 1.5)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Yield sampling route source (one decision per block)

    /// First selected block with permanent locations that has not been asked yet.
    private var fixedPromptBlock: Paddock? {
        guard !viewModel.isGenerated, !siteSourcesLoading, !siteRouteBusy else { return nil }
        return paddocks.first {
            viewModel.selectedPaddockIds.contains($0.id)
                && confirmedSiteSets[$0.id] != nil && !promptedBlocks.contains($0.id)
        }
    }

    private var sourceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.selectedPaddockIds.isEmpty && !viewModel.isGenerated {
                Label("Sampling Locations by Block", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Text("Blocks with permanent sampling locations can use those fixed sites or new dynamic sites.")
                    .font(.caption).foregroundStyle(.secondary)
                if siteSourcesLoading { ProgressView("Checking confirmed sites…") }
                ForEach(paddocks.filter { viewModel.selectedPaddockIds.contains($0.id) }) { block in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(block.name).font(.subheadline.weight(.semibold))
                        if confirmedSiteSets[block.id] != nil {
                            Picker("Sampling locations for \(block.name)", selection: Binding(
                                get: { savedLocationBlocks.contains(block.id) },
                                set: { useFixed in
                                    if useFixed { savedLocationBlocks.insert(block.id) }
                                    else { savedLocationBlocks.remove(block.id) }
                                    promptedBlocks.insert(block.id)
                                }
                            )) {
                                Text("Fixed (\(confirmedSiteCounts[block.id] ?? 0))").tag(true)
                                Text("Dynamic").tag(false)
                            }
                            .pickerStyle(.segmented)
                        } else {
                            Text("Dynamic sites · no permanent locations")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                }
                if let siteRouteError {
                    Text(siteRouteError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func loadConfirmedSamplingSites() async {
        guard let vineyard = store.selectedVineyardId, !viewModel.selectedPaddockIds.isEmpty else {
            confirmedSiteSets = [:]
            confirmedSiteCounts = [:]
            savedLocationBlocks = []
            return
        }
        let selected = viewModel.selectedPaddockIds
        siteSourcesLoading = true
        defer { siteSourcesLoading = false }
        var sets: [UUID: YieldSamplingSiteSetRow] = [:]
        var counts: [UUID: Int] = [:]
        for block in paddocks where selected.contains(block.id) {
            do {
                if let (set, sites) = try await siteSetsRepository.confirmed(
                    vineyardId: vineyard, paddockId: block.id) {
                    sets[block.id] = set
                    counts[block.id] = sites.count
                }
            } catch {
                siteRouteError = "Could not verify \(block.name) locations: \(error.localizedDescription)"
            }
        }
        guard viewModel.selectedPaddockIds == selected, store.selectedVineyardId == vineyard else { return }
        confirmedSiteSets = sets
        confirmedSiteCounts = counts
        savedLocationBlocks.formIntersection(Set(sets.keys))
    }

    /// All readbacks happen before the first local trip mutation. A failed
    /// server check can never silently substitute generated points for saved ones.
    private func generateSelectedRoute() async {
        guard !siteRouteBusy, !viewModel.selectedPaddockIds.isEmpty,
              let vineyard = store.selectedVineyardId else { return }
        siteRouteBusy = true
        defer { siteRouteBusy = false }
        siteRouteError = nil
        let selectedBlocks = paddocks.filter { viewModel.selectedPaddockIds.contains($0.id) }
        let chosenSaved = savedLocationBlocks
        var saved: [UUID: (YieldSamplingSiteSetRow, [YieldSamplingSiteRow])] = [:]
        do {
            for block in selectedBlocks where chosenSaved.contains(block.id) {
                guard let verified = try await siteSetsRepository.confirmed(
                    vineyardId: vineyard, paddockId: block.id),
                    !verified.1.isEmpty,
                    verified.1.allSatisfy({
                        YieldSamplingSiteGeometry.contains(
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                            polygon: block.polygonPoints
                        )
                    }) else {
                    siteRouteError = "Saved locations for \(block.name) have changed or are outside the block. Review them before starting."
                    return
                }
                saved[block.id] = verified
            }
        } catch {
            siteRouteError = "Cannot verify saved locations. Existing route was not changed: \(error.localizedDescription)"
            return
        }
        guard store.selectedVineyardId == vineyard,
              Set(selectedBlocks.map(\.id)) == viewModel.selectedPaddockIds else {
            siteRouteError = "Vineyard or block selection changed. Please try again."
            return
        }
        viewModel.generateSampleSites(paddocks: paddocks, samplesPerHectare: samplesPerHa,
                                      samplesPerBlock: perBlockMode ? samplesPerBlock : nil)
        let generated = viewModel.sampleSites
        var combined: [SampleSite] = []
        var versions: [String: YieldSamplingSiteSource] = [:]
        var index = 1
        for block in selectedBlocks {
            if let pair = saved[block.id] {
                let (set, sites) = pair
                for site in sites.sorted(by: { $0.siteNumber < $1.siteNumber }) {
                    combined.append(SampleSite(id: site.siteId, paddockId: block.id,
                        paddockName: block.name, rowNumber: Int(site.rowNumber ?? "") ?? 0,
                        latitude: site.latitude, longitude: site.longitude, siteIndex: index,
                        yieldRowReference: site.rowNumber,
                        yieldPanelReference: site.panelNumber))
                    index += 1
                }
                versions[block.id.uuidString.lowercased()] = YieldSamplingSiteSource(
                    setKey: set.setKey, siteSetId: set.id, version: set.version)
            } else {
                for original in generated.filter({ $0.paddockId == block.id }).sorted(by: {
                    $0.siteIndex < $1.siteIndex
                }) {
                    var site = original
                    site.siteIndex = index
                    combined.append(site)
                    index += 1
                }
            }
        }
        guard !combined.isEmpty, Set(combined.map(\.id)).count == combined.count else {
            siteRouteError = "No valid unique sample sites could be prepared."
            return
        }
        viewModel.sampleSites = combined
        viewModel.siteSetVersions = versions
        viewModel.routeSourceSessionId = nil
        viewModel.generatePath(paddocks: paddocks)
        fitMapToSites()
        saveSession()
    }

    // MARK: - Summary

    private var summarySection: some View {
        Group {
            if !viewModel.selectedPaddockIds.isEmpty {
                let totalArea = viewModel.totalSelectedArea(paddocks: paddocks)
                // Fixed blocks contribute their saved sites; dynamic blocks use the chosen mode.
                let expectedSamples = viewModel.expectedSampleCount(
                    paddocks: paddocks, samplesPerHectare: samplesPerHa,
                    samplesPerBlock: perBlockMode ? samplesPerBlock : nil,
                    excluding: savedLocationBlocks
                ) + savedLocationBlocks.filter { viewModel.selectedPaddockIds.contains($0) }
                    .reduce(0) { $0 + (confirmedSiteCounts[$1] ?? 0) }

                if !viewModel.isGenerated {
                    Picker("Number of sample sites", selection: $perBlockMode) {
                        Text("Per Ha").tag(false)
                        Text("Per Block").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    if viewModel.selectedPaddockIds.isSubset(of: savedLocationBlocks) {
                        Text("All selected blocks use fixed locations, so this number is not used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 0) {
                    summaryCard(
                        title: "Area",
                        value: fmt.formatArea(hectares: totalArea),
                        icon: "square.dashed",
                        color: VineyardTheme.leafGreen
                    )
                    Button {
                        samplesPerHaText = "\(perBlockMode ? samplesPerBlock : samplesPerHa)"
                        showSamplesPerHaEditor = true
                    } label: {
                        VStack(spacing: 4) {
                            Text(perBlockMode ? "Samples/block" : "Samples/ha")
                                .font(.caption.weight(.semibold))
                            HStack(spacing: 5) {
                                Text("\(perBlockMode ? samplesPerBlock : samplesPerHa)")
                                    .font(.title2.weight(.bold))
                                    .monospacedDigit()
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                            }
                            Text(viewModel.isCompleted ? "Locked" : "Tap to change")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(viewModel.isCompleted ? Color.secondary : Color.orange)
                        .frame(maxWidth: .infinity, minHeight: 82)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(viewModel.isCompleted ? 0.04 : 0.10),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.orange.opacity(viewModel.isCompleted ? 0.25 : 0.9), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("yield.samplesPerHectare.edit")
                    .accessibilityLabel(perBlockMode
                        ? "Edit number of samples per block, currently \(samplesPerBlock)"
                        : "Edit number of samples per hectare, currently \(samplesPerHa)")
                    .disabled(viewModel.isCompleted)
                    summaryCard(
                        title: "Total Sites",
                        value: "\(expectedSamples)",
                        icon: "mappin.and.ellipse",
                        color: .purple
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func summaryCard(title: String, value: String, icon: String, color: Color, editable: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
            HStack(spacing: 4) {
                Text(value)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if editable {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Trip options (overflow menu)

    private var hasExistingSession: Bool {
        guard let sid = viewModel.sessionId else { return false }
        return store.yieldSessions.contains(where: { $0.id == sid })
    }

    private var canDeleteTrip: Bool {
        hasExistingSession && (!viewModel.isCompleted || (accessControl?.canDelete ?? false))
    }

    private var showsTripMenu: Bool {
        (viewModel.isGenerated && !viewModel.isCompleted) || canDeleteTrip
    }

    /// Secondary trip actions — deliberately kept out of the route preview so
    /// Start Sampling stays the single primary action.
    private var tripOptionsMenu: some View {
        Menu {
            if viewModel.isGenerated && !viewModel.isCompleted {
                Button {
                    withAnimation(.smooth(duration: 0.3)) {
                        viewModel.clearRoute()
                    }
                    saveSession()
                } label: {
                    Label("Change Route", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if canDeleteTrip {
                Button(role: .destructive) {
                    showDeleteEstimationConfirm = true
                } label: {
                    Label(viewModel.isCompleted ? "Hard Delete Confirmed Trip" : "Hard Delete Draft", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// Server-first physical removal: a local record is never hidden if the
    /// role/state check or the deletion receipt cannot be verified.
    private func hardDeleteSession(_ target: YieldEstimationSession) async {
        guard !hardDeleteBusy else { return }
        guard let vineyardId = store.selectedVineyardId,
              target.vineyardId == vineyardId,
              !target.isCompleted || (accessControl?.canDelete ?? false) else {
            hardDeleteError = "Only Supervisors, Managers and Owners can hard-delete a confirmed yield observation."
            return
        }
        hardDeleteBusy = true
        defer { hardDeleteBusy = false }
        do {
            let isCurrent = store.remoteApplicationCurrentCheck()
            try await hardDeleteRepo.hardDelete(target)
            guard isCurrent() else { throw CancellationError() }
            try store.applyYieldHardDeletionReceipts([target.id], vineyardId: target.vineyardId)
            yieldSync.acknowledgeHardDeletedSession(target.id)
            homeDraftDeleteTarget = nil
            if viewModel.sessionId == target.id {
                withAnimation(.smooth(duration: 0.3)) {
                    viewModel.resetForNewEstimation()
                    tripStarted = false
                    showSampling = false
                }
            }
            hardDeleteError = nil
        } catch {
            hardDeleteError = "Could not confirm permanent deletion: \(error.localizedDescription)"
        }
    }

    private func hardDeleteCurrentEstimation() async {
        guard let id = viewModel.sessionId,
              let target = store.yieldSessions.first(where: { $0.id == id }) else {
            hardDeleteError = "This yield session could not be found locally. Reload before deleting."
            return
        }
        await hardDeleteSession(target)
    }

    // MARK: - Generate Button (setup phase)

    /// Existing routes covering the current block selection, from earlier
    /// trips (site identity preserved). nil once a route is generated or when
    /// no prior trip covers any selected block — no meaningless prompt.
    private var reusableRouteCandidate: BunchCountTripLogic.ReusableRoute? {
        guard !viewModel.isGenerated, !viewModel.selectedPaddockIds.isEmpty else { return nil }
        return BunchCountTripLogic.reusableRoute(
            sessions: store.yieldSessions,
            selectedPaddockIds: Array(viewModel.selectedPaddockIds),
            excludeSessionId: viewModel.sessionId
        )
    }

    private var generateButton: some View {
        VStack(spacing: 8) {
            if let route = reusableRouteCandidate, savedLocationBlocks.isEmpty {
                Text("A previous trip already has a route for \(viewModel.selectedPaddockIds.count == 1 ? "this block" : "these blocks"). Reusing it revisits the same sample locations for comparable counts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.smooth(duration: 0.3)) {
                        viewModel.adoptRoute(route)
                                        viewModel.generatePath(paddocks: paddocks)
                    }
                    fitMapToSites()
                    saveSession()
                } label: {
                    Label("Use Existing Route (\(route.sites.count) sites)", systemImage: "arrow.triangle.branch")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }

            Button {
                Task { await generateSelectedRoute() }
            } label: {
                Label(
                    savedLocationBlocks.isEmpty
                        ? (reusableRouteCandidate != nil ? "Generate New Route" : "Generate Route")
                        : "Prepare Route (\(savedLocationBlocks.count) saved blocks)",
                    systemImage: "mappin.and.ellipse"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(VineyardTheme.leafGreen)
            .disabled(viewModel.selectedPaddockIds.isEmpty || siteRouteBusy || siteSourcesLoading)

            if viewModel.selectedPaddockIds.isEmpty {
                Text("Select one or more blocks above to generate the sampling route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Route preview actions

    private func startSamplingButton(isContinue: Bool) -> some View {
        Button {
            showSampling = true
        } label: {
            Label(
                isContinue ? "Continue Sampling" : "Start Sampling",
                systemImage: "location.north.line.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }

    /// The single regeneration action for newly generated routes — regenerates
    /// the sample locations and walking path with the existing generation
    /// logic. Never shown for reused routes (their value is site identity).
    private var regeneratePathButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                viewModel.generateSampleSites(paddocks: paddocks, samplesPerHectare: samplesPerHa,
                                              samplesPerBlock: perBlockMode ? samplesPerBlock : nil)
                viewModel.generatePath(paddocks: paddocks)
            }
            fitMapToSites()
            saveSession()
        } label: {
            Label("Regenerate Path", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }

    private var startNewTripButton: some View {
        Button {
            // Completed trips are preserved history — a new trip is a NEW
            // dated observation, never an overwrite.
            showCountMethod = true
        } label: {
            Label("Start New Yield Estimate Trip", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(VineyardTheme.leafGreen)
    }

    // MARK: - Completed Banner

    private var completedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Yield Estimate Trip Completed")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                if let completedAt = viewModel.completedAt {
                    Text(fmt.formatDateTime(completedAt))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(14)
        .background(VineyardTheme.leafGreen.gradient, in: .rect(cornerRadius: 12))
    }

    // MARK: - Complete Job Button (completion stage)

    private var completeJobButton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Complete Estimation", systemImage: "checkmark.seal.fill")
                .font(.headline)

            Text("Current weights come from shared Master Bunch Weights. Missing weights do not prevent saving the recorded observation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            CurrentYieldEstimateSummary(estimate: currentEstimate(observation))

            // Damage adjustment is presentation-time — the base bunch-count
            // estimate is always preserved and recoverable.
            Toggle(isOn: Binding(
                get: { viewModel.applyDamage },
                set: { viewModel.applyDamage = $0; saveSession() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply recorded damage")
                        .font(.subheadline.weight(.medium))
                    Text("Adjusts the displayed estimate by current damage records. The base bunch-count estimate is always kept.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))

            Button {
                showCompleteConfirmation = true
            } label: {
                Label("Save Yield Estimate Trip", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityIdentifier("yield.saveTrip")
            .confirmationDialog(
                "Save Yield Estimate Trip?",
                isPresented: $showCompleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Save Trip") {
                    if viewModel.saveCompletion(paddocks: paddocks, persist: saveSession) {
                        withAnimation(.smooth(duration: 0.3)) { tripStarted = false }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This completes the trip as a dated observation. It becomes the latest estimate for its blocks; earlier trips stay in history. Counts and weights can no longer be edited.")
            }
        }
    }

    // MARK: - Progress (shown only once sampling has started)

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Collection Progress", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.recordedSiteCount)/\(viewModel.totalSiteCount)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.recordedSiteCount == viewModel.totalSiteCount ? .green : .orange)
            }

            if viewModel.totalSiteCount > 0 {
                ProgressView(value: Double(viewModel.recordedSiteCount), total: Double(viewModel.totalSiteCount))
                    .tint(viewModel.recordedSiteCount == viewModel.totalSiteCount ? .green : .orange)
            }
        }
    }

    // MARK: - Samples per Ha Sheet

    @ViewBuilder
    private var samplesPerHaSheet: some View {
        if perBlockMode { samplesPerBlockSheet } else { samplesPerHectareSheet }
    }

    private var samplesPerBlockSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Samples per block", text: $samplesPerHaText)
                            .keyboardType(.numberPad)
                        Text("per block").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Samples per Block")
                } footer: {
                    Text("Every block using dynamic sites gets this many sample sites, whatever its size. Saved on this device.")
                }
            }
            .navigationTitle("Samples per Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSamplesPerHaEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let n = Int(samplesPerHaText), (1...200).contains(n) { samplesPerBlock = n }
                        showSamplesPerHaEditor = false
                    }
                    .fontWeight(.semibold)
                    .disabled({
                        guard let n = Int(samplesPerHaText) else { return true }
                        return !(1...200).contains(n)
                    }())
                }
            }
        }
    }

    private var samplesPerHectareSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Samples per Ha", text: $samplesPerHaText)
                            .keyboardType(.numberPad)
                        Text("per Ha")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Samples per Hectare")
                } footer: {
                    Text("Number of vine sample sites to generate per hectare. Saved as the shared default for the next Yield Estimate Trip on every device.")
                }

                if let n = Int(samplesPerHaText), n > 0, !viewModel.selectedPaddockIds.isEmpty {
                    Section {
                        let area = viewModel.totalSelectedArea(paddocks: paddocks)
                        let expected = viewModel.expectedSampleCount(paddocks: paddocks, samplesPerHectare: n)
                        HStack {
                            Text("Selected Area")
                            Spacer()
                            Text(fmt.formatArea(hectares: area)).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Total Sites")
                            Spacer()
                            Text("\(expected)").foregroundStyle(.orange).fontWeight(.semibold)
                        }
                    } header: {
                        Text("Preview")
                    }
                }
            }
            .navigationTitle("Samples per Ha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSamplesPerHaEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let n = Int(samplesPerHaText), n > 0, n <= 500 {
                            var s = store.settings
                            s.samplesPerHectare = n
                            store.updateSettings(s)
                            // Persist as the vineyard-wide default (sql/187)
                            // so the next trip on any device starts from it.
                            if let vid = store.selectedVineyardId {
                                Task { try? await samplingSettingsRepo.saveDefault(vineyardId: vid, samplesPerHectare: n) }
                            }
                        }
                        showSamplesPerHaEditor = false
                    }
                    .fontWeight(.semibold)
                    .disabled({
                        guard let n = Int(samplesPerHaText) else { return true }
                        return n <= 0 || n > 500
                    }())
                }
            }
        }
    }

    // MARK: - Persistence

    @discardableResult
    private func saveSession() -> Bool {
        guard let vid = store.selectedVineyardId else { return false }
        let session = viewModel.toSession(vineyardId: vid, samplesPerHectare: samplesPerHa)
        let accepted = store.saveYieldSession(session)
        saveFailed = !accepted
        return accepted
    }

    // MARK: - Map Helpers

    private func fitMap() {
        let allPoints = paddocks.flatMap(\.polygonPoints)
        guard !allPoints.isEmpty else { return }

        let minLat = allPoints.map(\.latitude).min()!
        let maxLat = allPoints.map(\.latitude).max()!
        let minLon = allPoints.map(\.longitude).min()!
        let maxLon = allPoints.map(\.longitude).max()!

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.001
        )
        mapPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func fitMapToSites() {
        guard !viewModel.sampleSites.isEmpty else {
            fitMap()
            return
        }

        let selectedPaddockPoints = paddocks
            .filter { viewModel.selectedPaddockIds.contains($0.id) }
            .flatMap(\.polygonPoints)

        let allLats = selectedPaddockPoints.map(\.latitude) + viewModel.sampleSites.map(\.latitude)
        let allLons = selectedPaddockPoints.map(\.longitude) + viewModel.sampleSites.map(\.longitude)

        guard let minLat = allLats.min(), let maxLat = allLats.max(),
              let minLon = allLons.min(), let maxLon = allLons.max() else { return }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.001
        )
        withAnimation(.smooth(duration: 0.4)) {
            mapPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}

import SwiftUI
import MapKit

struct YieldEstimationView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @Environment(NetworkMonitor.self) private var network
    @State private var viewModel = YieldEstimationViewModel()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showBunchCountSheet: Bool = false
    @State private var showBunchWeightEditor: Bool = false
    @State private var showReport: Bool = false
    @State private var bunchWeightText: String = "150"
    @State private var editingBunchWeightPaddockId: UUID?
    @State private var showFullScreenMap: Bool = false
    @State private var fullScreenSelectedSite: SampleSite?
    @State private var showCompleteConfirmation: Bool = false
    @State private var showSamplesPerHaEditor: Bool = false
    @State private var samplesPerHaText: String = ""
    @State private var showSampling: Bool = false
    @State private var showSampleList: Bool = false
    @State private var showDeleteEstimationConfirm: Bool = false
    /// Whether a trip (draft or completed history view) is open. False shows
    /// the Bunch Count Trip home (start / resume / history).
    @State private var tripStarted: Bool = false
    private let samplingSettingsRepo = SupabaseYieldSamplingSettingsRepository()

    private var paddocks: [Paddock] {
        store.orderedPaddocks.filter { $0.polygonPoints.count >= 3 }
    }

    private var samplesPerHa: Int {
        store.settings.samplesPerHectare
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
        .task { await syncSamplingDefault() }
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
                    Label("Bunch Count Trip", systemImage: "figure.walk")
                        .font(.headline)
                    Text("Perform a bunch count trip to update the current yield estimate. Walk the sampling route, count bunches at each sample site, then confirm bunch weights to produce the estimate for each block.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Repeat trips through the season — the latest completed trip drives the current Yield Estimate for its blocks; earlier trips stay in history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))

                if let draft = activeDraft {
                    Button {
                        resumeTrip(draft)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Resume trip in progress")
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
                }

                Button {
                    startTrip()
                } label: {
                    Label("Start Bunch Count Trip", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(VineyardTheme.leafGreen)
                .disabled(paddocks.isEmpty)

                if paddocks.isEmpty {
                    Text("Map at least one block boundary in Blocks before starting a bunch count trip.")
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
                            Button {
                                resumeTrip(trip)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fmt.formatDate(trip.completedAt ?? trip.createdAt))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text("\(trip.selectedPaddockIds.count) block\(trip.selectedPaddockIds.count == 1 ? "" : "s") · \(trip.sampleSites.filter(\.isRecorded).count) sites")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(String(format: "%.1f t", completedTripTonnes(trip)))
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(VineyardTheme.leafGreen)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle("Bunch Count Trips")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Display tonnes for a completed trip in history (respects its damage flag).
    private func completedTripTonnes(_ trip: YieldEstimationSession) -> Double {
        paddocks
            .filter { p in trip.selectedPaddockIds.contains(p.id) }
            .compactMap { paddock -> Double? in
                guard let base = YieldVintageReport.baseEstimate(session: trip, paddock: paddock) else { return nil }
                let factor = trip.applyDamage ? store.damageFactor(for: paddock.id) : 1.0
                return base.tonnes * factor
            }
            .reduce(0, +)
    }

    private func startTrip() {
        viewModel.startNewTrip()
        withAnimation(.smooth(duration: 0.25)) { tripStarted = true }
        fitMap()
    }

    private func resumeTrip(_ session: YieldEstimationSession) {
        viewModel.loadSession(session)
        applyDefaultBunchWeights()
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
        ScrollView {
            VStack(spacing: 20) {
                mapSection
                blockSelectionSection
                summarySection
                generateButton

                if viewModel.isGenerated {
                    if viewModel.isCompleted {
                        completedBanner
                    }

                    if (accessControl?.canDelete ?? false) && hasExistingSession {
                        deleteEstimationButton
                    }

                    if !viewModel.isCompleted {
                        startSamplingButton
                    }

                    bunchWeightButton

                    if !viewModel.isCompleted && viewModel.recordedSiteCount > 0 {
                        completeJobButton
                    }

                    progressSection

                    if !viewModel.isCompleted {
                        pathButton
                    }

                    if viewModel.isPathGenerated {
                        pathMapSection
                    }

                    DisclosureGroup(isExpanded: $showSampleList) {
                        sampleListSection
                            .padding(.top, 8)
                    } label: {
                        Label("All Sample Sites (\(viewModel.sampleSites.count))", systemImage: "list.number")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle("Bunch Count Trip")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBunchCountSheet) {
            if let site = viewModel.selectedSite {
                BunchCountEntrySheet(site: site) { count, name in
                    viewModel.recordBunchCount(siteId: site.id, bunchesPerVine: count, recordedBy: name)
                    saveSession()
                }
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
                BunchCountEntrySheet(site: site) { count, name in
                    viewModel.recordBunchCount(siteId: site.id, bunchesPerVine: count, recordedBy: name)
                    saveSession()
                }
            }
        }
        .sheet(isPresented: $showBunchWeightEditor) {
            bunchWeightSheet
        }
        .sheet(isPresented: $showSamplesPerHaEditor) {
            samplesPerHaSheet
                .presentationDetents([.medium])
        }
        .navigationDestination(isPresented: $showReport) {
            YieldReportView(viewModel: viewModel)
        }
        .navigationDestination(isPresented: $showSampling) {
            YieldSamplingNavigationView(viewModel: viewModel)
        }
        .alert("Delete Estimation?", isPresented: $showDeleteEstimationConfirm) {
            Button("Delete", role: .destructive) {
                deleteCurrentEstimation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete this bunch count trip? This removes its route, bunch counts and estimate. If it is the latest trip, the previous trip becomes the current estimate. This cannot be undone.")
        }
        .onAppear {
            fitMap()
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        Group {
            if network.isOnline {
                hybridMapSection
            } else {
                offlineMapSection
            }
        }
        .frame(height: 320)
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

    // MARK: - Path Map

    private var pathMapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Sample Path", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                Spacer()
                Button {
                    showFullScreenMap = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(VineyardTheme.leafGreen, in: .rect(cornerRadius: 6))
                }
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Start")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "flag.checkered")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text("End")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Group {
                if network.isOnline {
                    hybridPathMap
                } else {
                    offlinePathMap
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text("\(viewModel.pathWaypoints.count) waypoints")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(String(format: "%.0f m total", pathTotalDistanceMetres))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var offlinePathMap: some View {
        OfflineVineyardMapView(
            paddocks: paddocks
                .filter { viewModel.selectedPaddockIds.contains($0.id) }
                .map { paddock in
                    let color = colorFor(paddock)
                    return OfflineVineyardMapView.Paddock(
                        id: paddock.id,
                        polygon: paddock.polygonPoints.map(\.coordinate),
                        rows: paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] },
                        strokeColor: color.opacity(0.5),
                        fillColor: color.opacity(0.15),
                        name: paddock.name
                    )
                },
            trails: viewModel.pathWaypoints.count >= 2
                ? [OfflineVineyardMapView.Trail(
                    id: 0,
                    coordinates: viewModel.pathWaypoints.map(\.coordinate),
                    color: .orange,
                    lineWidth: 3
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

    private var hybridPathMap: some View {
        Map(initialPosition: pathMapPosition) {
            ForEach(paddocks.filter { viewModel.selectedPaddockIds.contains($0.id) }) { paddock in
                let color = colorFor(paddock)

                MapPolygon(coordinates: paddock.polygonPoints.map(\.coordinate))
                    .foregroundStyle(color.opacity(0.15))
                    .stroke(color.opacity(0.5), lineWidth: 1.5)

                ForEach(paddock.rows) { row in
                    MapPolyline(coordinates: [row.startPoint.coordinate, row.endPoint.coordinate])
                        .stroke(color.opacity(0.15), lineWidth: 0.5)
                }
            }

            MapPolyline(coordinates: viewModel.pathWaypoints.map(\.coordinate))
                .stroke(
                    .linearGradient(
                        colors: [.orange, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 3
                )

            ForEach(viewModel.sampleSites) { site in
                let paddock = paddocks.first { $0.id == site.paddockId }
                let color = paddock.map { colorFor($0) } ?? .red
                let isRecorded = site.isRecorded

                Annotation("", coordinate: site.coordinate) {
                    ZStack {
                        Circle()
                            .fill(isRecorded ? .green : color)
                            .frame(width: 20, height: 20)
                        Circle()
                            .fill(.white)
                            .frame(width: 13, height: 13)
                        Text("\(site.siteIndex)")
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(isRecorded ? .green : color)
                    }
                    .allowsHitTesting(false)
                }
            }

            if viewModel.pathWaypoints.count >= 2 {
                Annotation("Start", coordinate: viewModel.pathWaypoints[0].coordinate) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(3)
                        .background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
                Annotation("End", coordinate: viewModel.pathWaypoints[viewModel.pathWaypoints.count - 1].coordinate) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(3)
                        .background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
            }

            ForEach(pathArrowAnnotations, id: \.id) { arrow in
                Annotation("", coordinate: arrow.coordinate) {
                    Image(systemName: "arrowtriangle.forward.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .rotationEffect(.degrees(arrow.bearing))
                        .allowsHitTesting(false)
                }
            }
        }
        .mapStyle(.hybrid)
    }

    private var pathMapPosition: MapCameraPosition {
        let selectedPaddockPoints = paddocks
            .filter { viewModel.selectedPaddockIds.contains($0.id) }
            .flatMap(\.polygonPoints)

        let allLats = selectedPaddockPoints.map(\.latitude) + viewModel.sampleSites.map(\.latitude)
        let allLons = selectedPaddockPoints.map(\.longitude) + viewModel.sampleSites.map(\.longitude)

        guard let minLat = allLats.min(), let maxLat = allLats.max(),
              let minLon = allLons.min(), let maxLon = allLons.max() else {
            return .automatic
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.001
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    private struct ArrowAnnotation: Identifiable {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let bearing: Double
    }

    private var pathArrowAnnotations: [ArrowAnnotation] {
        let waypoints = viewModel.pathWaypoints
        guard waypoints.count >= 2 else { return [] }

        var arrows: [ArrowAnnotation] = []
        let step = max(1, waypoints.count / 15)

        for i in stride(from: step, to: waypoints.count, by: step) {
            let prev = waypoints[i - 1]
            let curr = waypoints[i]
            let dLat = curr.latitude - prev.latitude
            let dLon = curr.longitude - prev.longitude
            guard abs(dLat) > 1e-10 || abs(dLon) > 1e-10 else { continue }

            let bearing = atan2(dLon, dLat) * 180 / .pi
            let midLat = (prev.latitude + curr.latitude) / 2
            let midLon = (prev.longitude + curr.longitude) / 2

            arrows.append(ArrowAnnotation(
                id: i,
                coordinate: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
                bearing: bearing
            ))
        }

        return arrows
    }

    private var pathTotalDistanceMetres: Double {
        let waypoints = viewModel.pathWaypoints
        guard waypoints.count >= 2 else { return 0 }

        var total: Double = 0
        for i in 1..<waypoints.count {
            let loc1 = CLLocation(latitude: waypoints[i - 1].latitude, longitude: waypoints[i - 1].longitude)
            let loc2 = CLLocation(latitude: waypoints[i].latitude, longitude: waypoints[i].longitude)
            total += loc1.distance(from: loc2)
        }
        return total
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

    // MARK: - Summary

    private var summarySection: some View {
        Group {
            if !viewModel.selectedPaddockIds.isEmpty {
                let totalArea = viewModel.totalSelectedArea(paddocks: paddocks)
                let expectedSamples = viewModel.expectedSampleCount(paddocks: paddocks, samplesPerHectare: samplesPerHa)

                HStack(spacing: 0) {
                    summaryCard(
                        title: "Area",
                        value: fmt.formatArea(hectares: totalArea),
                        icon: "square.dashed",
                        color: VineyardTheme.leafGreen
                    )
                    Button {
                        samplesPerHaText = "\(samplesPerHa)"
                        showSamplesPerHaEditor = true
                    } label: {
                        summaryCard(
                            title: "Samples/Ha",
                            value: "\(samplesPerHa)",
                            icon: "number",
                            color: .orange,
                            editable: true
                        )
                    }
                    .buttonStyle(.plain)
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

    // MARK: - Delete Estimation

    private var hasExistingSession: Bool {
        guard let sid = viewModel.sessionId else { return false }
        return store.yieldSessions.contains(where: { $0.id == sid })
    }

    private var deleteEstimationButton: some View {
        Button(role: .destructive) {
            showDeleteEstimationConfirm = true
        } label: {
            Label("Delete Trip", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    /// Deletes ONLY the open trip — other trips (drafts or history) are never
    /// touched. If the deleted trip was the latest completed one, the previous
    /// trip becomes the current estimate again.
    private func deleteCurrentEstimation() {
        if let sid = viewModel.sessionId,
           let existing = store.yieldSessions.first(where: { $0.id == sid }) {
            store.deleteYieldSession(existing)
        }
        withAnimation(.smooth(duration: 0.3)) {
            viewModel.resetForNewEstimation()
            tripStarted = false
        }
    }

    // MARK: - Generate Button

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
            if let route = reusableRouteCandidate, !viewModel.isCompleted {
                Text("A previous trip already has a route for \(viewModel.selectedPaddockIds.count == 1 ? "this block" : "these blocks"). Reusing it revisits the same sample locations for comparable counts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.smooth(duration: 0.3)) {
                        viewModel.adoptRoute(route)
                        applyDefaultBunchWeights()
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
                withAnimation(.smooth(duration: 0.3)) {
                    viewModel.generateSampleSites(paddocks: paddocks, samplesPerHectare: samplesPerHa)
                    applyDefaultBunchWeights()
                    viewModel.generatePath(paddocks: paddocks)
                }
                fitMapToSites()
                saveSession()
            } label: {
                Label(
                    viewModel.isGenerated
                        ? "Regenerate Sample Sites"
                        : (reusableRouteCandidate != nil ? "Generate New Route" : "Generate Sample Sites"),
                    systemImage: viewModel.isGenerated ? "arrow.clockwise" : "mappin.and.ellipse"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(VineyardTheme.leafGreen)
            .disabled(viewModel.selectedPaddockIds.isEmpty || viewModel.isCompleted)

            if viewModel.isGenerated, viewModel.routeSourceSessionId != nil {
                Text("Route reused from an earlier trip — sample locations match for comparable counts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isCompleted {
                Button {
                    // Completed trips are preserved history — a new trip is a
                    // NEW dated observation, never an overwrite.
                    withAnimation(.smooth(duration: 0.3)) {
                        viewModel.startNewTrip()
                    }
                } label: {
                    Label("Start New Bunch Count Trip", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(VineyardTheme.leafGreen)
            } else if viewModel.selectedPaddockIds.isEmpty {
                Text("Select one or more blocks above to generate sample sites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Start Sampling Button

    private var startSamplingButton: some View {
        VStack(spacing: 8) {
            Button {
                showSampling = true
            } label: {
                Label(
                    viewModel.recordedSiteCount > 0 ? "Continue Sampling" : "Start Sampling",
                    systemImage: "location.north.line.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Text("Guided field workflow with map and bunch-count entry.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Path Button

    private var pathButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                viewModel.generatePath(paddocks: paddocks)
            }
            fitMapToSites()
            saveSession()
        } label: {
            Label(
                viewModel.isPathGenerated ? "Regenerate Path" : "Generate Path",
                systemImage: viewModel.isPathGenerated ? "arrow.triangle.turn.up.right.circle" : "point.topleft.down.to.point.bottomright.curvepath"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
    }

    // MARK: - Bunch Weight

    private var bunchWeightButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Bunch Weight per Block", systemImage: "scalemass.fill")
                .font(.headline)

            let selectedPaddocksList = paddocks.filter { viewModel.selectedPaddockIds.contains($0.id) }

            ForEach(selectedPaddocksList) { paddock in
                let weight = viewModel.bunchWeightKg(for: paddock.id)
                let color = colorFor(paddock)

                Button {
                    if !viewModel.isCompleted {
                        editingBunchWeightPaddockId = paddock.id
                        bunchWeightText = String(format: "%.0f", weight * 1000)
                        showBunchWeightEditor = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(color)
                            .frame(width: 10, height: 10)
                        Text(paddock.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(String(format: "%.0f g", weight * 1000))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(color)
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Report Button

    private var reportButton: some View {
        Button {
            showReport = true
        } label: {
            Label("View Yield Report", systemImage: "chart.bar.doc.horizontal.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
    }

    // MARK: - Completed Banner

    private var completedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bunch Count Trip Completed")
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

    // MARK: - Complete Job Button

    private var completeJobButton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Complete Estimation", systemImage: "checkmark.seal.fill")
                .font(.headline)

            // Per-block summary from the recorded samples — the BASE estimate
            // is always shown; damage only changes the displayed figure.
            let baseEstimates = viewModel.calculateYieldEstimates(paddocks: paddocks)
            ForEach(baseEstimates.filter { $0.samplesRecorded > 0 }, id: \.paddockId) { est in
                let factor = store.damageFactor(for: est.paddockId)
                let display = viewModel.applyDamage ? est.estimatedYieldTonnes * factor : est.estimatedYieldTonnes
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(est.paddockName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.1f t", display))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(VineyardTheme.leafGreen)
                    }
                    Text(YieldVintageReport.varietyLabel(paddocks.first { $0.id == est.paddockId }))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(est.samplesRecorded)/\(est.samplesTotal) samples · \(String(format: "%.1f", est.averageBunchesPerVine)) bunches/vine · \(String(format: "%.0f g", est.averageBunchWeightKg * 1000))/bunch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if est.areaHectares > 0 {
                        Text(fmt.formatYieldPerArea(perHectare: display / est.areaHectares))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.applyDamage, factor < 1.0 {
                        Text(String(format: "Base %.1f t → damage adjusted %.1f t", est.estimatedYieldTonnes, est.estimatedYieldTonnes * factor))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            }

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
                Label("Save Bunch Count Trip", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .confirmationDialog(
                "Save Bunch Count Trip?",
                isPresented: $showCompleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Save Trip") {
                    viewModel.markCompleted()
                    saveSession()
                    withAnimation(.smooth(duration: 0.3)) { tripStarted = false }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This completes the trip as a dated observation. It becomes the latest estimate for its blocks; earlier trips stay in history. Counts and weights can no longer be edited.")
            }
        }
    }

    // MARK: - Progress

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

    // MARK: - Sample List

    private var sampleListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(viewModel.sampleSites.count) Sample Sites", systemImage: "list.number")
                    .font(.headline)
                Spacer()
            }

            let grouped = Dictionary(grouping: viewModel.sampleSites, by: \.paddockId)
            let sortedKeys = paddocks.filter { grouped[$0.id] != nil }

            ForEach(sortedKeys) { paddock in
                let sites = grouped[paddock.id] ?? []
                let color = colorFor(paddock)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                        Text(paddock.name)
                            .font(.subheadline.weight(.semibold))
                        Text("(\(sites.count) sites)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(sites) { site in
                        Button {
                            if !viewModel.isCompleted {
                                viewModel.selectedSite = site
                                showBunchCountSheet = true
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text("#\(site.siteIndex)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(color)
                                    .frame(width: 30, alignment: .trailing)

                                Text("Row \(site.rowNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.primary)

                                if let entry = site.bunchCountEntry {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                        Text(String(format: "%.1f bunches", entry.bunchesPerVine))
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.green)
                                    }
                                }

                                Spacer()

                                if site.isRecorded {
                                    if let entry = site.bunchCountEntry {
                                        Text(entry.recordedBy)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text("Tap to record")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            }
        }
    }

    // MARK: - Bunch Weight Sheet

    private var bunchWeightSheet: some View {
        NavigationStack {
            Form {
                if let pid = editingBunchWeightPaddockId,
                   let paddock = paddocks.first(where: { $0.id == pid }) {
                    Section {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(colorFor(paddock))
                                .frame(width: 10, height: 10)
                            Text(paddock.name)
                                .font(.subheadline.weight(.semibold))
                        }
                    } header: {
                        Text("Block")
                    }
                }

                Section {
                    TextField("Weight in grams", text: $bunchWeightText)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Bunch Weight (grams)")
                } footer: {
                    Text("Enter the average bunch weight in grams for this block.")
                }

                if !viewModel.previousBunchWeights.isEmpty {
                    Section {
                        ForEach(viewModel.previousBunchWeights.sorted(by: { $0.date > $1.date }).prefix(5)) { record in
                            Button {
                                bunchWeightText = String(format: "%.0f", record.weightKg * 1000)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fmt.formatDate(record.date))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(String(format: "%.0f g", record.weightKg * 1000))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.uturn.left")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Previous Records")
                    }
                }
            }
            .navigationTitle("Bunch Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showBunchWeightEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let grams = Double(bunchWeightText), grams > 0,
                           let pid = editingBunchWeightPaddockId {
                            let kg = grams / 1000.0
                            viewModel.setBunchWeight(kg, for: pid)
                            let record = BunchWeightRecord(date: Date(), weightKg: kg)
                            viewModel.previousBunchWeights.append(record)
                            syncBunchWeightToSettings(paddockId: pid, grams: grams)
                            saveSession()
                        }
                        showBunchWeightEditor = false
                    }
                    .fontWeight(.semibold)
                    .disabled(Double(bunchWeightText) == nil || (Double(bunchWeightText) ?? 0) <= 0)
                }
            }
        }
    }

    // MARK: - Samples per Ha Sheet

    private var samplesPerHaSheet: some View {
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
                    Text("Number of vine sample sites to generate per hectare. Saved as the shared default for the next Bunch Count Trip on every device.")
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

    private func saveSession() {
        guard let vid = store.selectedVineyardId else { return }
        let session = viewModel.toSession(vineyardId: vid, samplesPerHectare: samplesPerHa)
        store.saveYieldSession(session)
    }

    private func applyDefaultBunchWeights() {
        let defaults = store.settings.defaultBlockBunchWeightsGrams
        for paddockId in viewModel.selectedPaddockIds {
            if viewModel.blockBunchWeightsKg[paddockId] == nil,
               let grams = defaults[paddockId], grams > 0 {
                viewModel.setBunchWeight(grams / 1000.0, for: paddockId)
            }
        }
    }

    private func syncBunchWeightToSettings(paddockId: UUID, grams: Double) {
        var s = store.settings
        s.defaultBlockBunchWeightsGrams[paddockId] = grams
        store.updateSettings(s)
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

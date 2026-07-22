import SwiftUI
import MapKit
import CoreLocation

/// Guided in-field sampling experience. Walks the user from one sample
/// site to the next with map, GPS bearing/distance and a fast bunch-count
/// entry panel. Reads/writes through the shared YieldEstimationViewModel
/// so values save into the existing YieldEstimationSession.
struct YieldSamplingNavigationView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(NetworkMonitor.self) private var network
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSessionSync
    @Environment(\.dismiss) private var dismiss

    let viewModel: YieldEstimationViewModel

    @State private var currentSiteId: UUID?
    @State private var bunchesText: String = ""
    @State private var recorderName: String = ""
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showCompleteConfirmation: Bool = false
    @State private var showInsufficientSamplesConfirmation: Bool = false
    @State private var showReport: Bool = false
    @State private var showSiteList: Bool = false
    @AppStorage("yieldSamplingTipDismissed_v1") private var tipDismissed: Bool = false
    @FocusState private var bunchesFocused: Bool

    private let arrivedThresholdMetres: Double = 12

    private var paddocks: [Paddock] {
        store.orderedPaddocks.filter { $0.polygonPoints.count >= 3 }
    }

    private var orderedSites: [SampleSite] {
        viewModel.sampleSites.sorted { $0.siteIndex < $1.siteIndex }
    }

    private var currentSite: SampleSite? {
        guard let id = currentSiteId else { return orderedSites.first }
        return orderedSites.first { $0.id == id } ?? orderedSites.first
    }

    private var currentIndex: Int {
        guard let site = currentSite,
              let idx = orderedSites.firstIndex(where: { $0.id == site.id }) else { return 0 }
        return idx
    }

    private var currentPaddock: Paddock? {
        guard let site = currentSite else { return nil }
        return paddocks.first { $0.id == site.paddockId }
    }

    private var recordedCount: Int { viewModel.recordedSiteCount }
    private var totalCount: Int { viewModel.totalSiteCount }
    private var remaining: Int { max(0, totalCount - recordedCount) }

    private var distanceMetres: Double? {
        guard let loc = locationService.location, let site = currentSite else { return nil }
        let target = CLLocation(latitude: site.latitude, longitude: site.longitude)
        return target.distance(from: loc)
    }

    private var bearingDegrees: Double? {
        guard let loc = locationService.location, let site = currentSite else { return nil }
        return bearing(from: loc.coordinate, to: site.coordinate)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 0) {
                headerCard
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                if !tipDismissed {
                    firstUseTip
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                bottomPanel
            }
        }
        .navigationTitle("Guided Sampling")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let sessionId = viewModel.sessionId {
                ToolbarItem(placement: .topBarLeading) {
                    RecordSyncBadge(
                        state: .forYieldSession(sessionId, yieldSync: yieldSessionSync),
                        showsLabel: false
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSiteList = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("All samples")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.isCompleted {
                    Button {
                        attemptFinish()
                    } label: {
                        Text("Finish")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(recordedCount == 0)
                }
            }
        }
        .confirmationDialog(
            "Finish with \(recordedCount) of \(totalCount) samples?",
            isPresented: $showInsufficientSamplesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Finish Anyway") {
                showCompleteConfirmation = true
            }
            Button("Keep Sampling", role: .cancel) {}
        } message: {
            Text("You haven't recorded every sample site yet. You can still finish and lock the estimate using the samples you've collected.")
        }
        .sheet(isPresented: $showSiteList) {
            siteListSheet
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: $showReport) {
            YieldReportView(viewModel: viewModel)
        }
        .confirmationDialog(
            "Complete Yield Estimation?",
            isPresented: $showCompleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Complete & Lock") {
                viewModel.markCompleted()
                saveSession()
                showReport = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will lock all values for this yield estimation job. Bunch counts and weights can no longer be edited.")
        }
        .onAppear {
            locationService.requestPermission()
            locationService.startUpdating()
            selectInitialSite()
            loadSiteIntoForm()
            recenterOnCurrent()
        }
        .onChange(of: currentSiteId) { _, _ in
            loadSiteIntoForm()
            recenterOnCurrent()
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Group {
            if network.isOnline {
                hybridMapLayer
            } else {
                offlineMapLayer
            }
        }
    }

    private var hybridMapLayer: some View {
        Map(position: $mapPosition) {
            UserAnnotation()

            ForEach(paddocks.filter { viewModel.selectedPaddockIds.contains($0.id) }) { paddock in
                MapPolygon(coordinates: paddock.polygonPoints.map(\.coordinate))
                    .foregroundStyle(.green.opacity(0.10))
                    .stroke(.green.opacity(0.45), lineWidth: 1.2)
            }

            if let site = currentSite, let loc = locationService.location {
                MapPolyline(coordinates: [loc.coordinate, site.coordinate])
                    .stroke(.blue.opacity(0.6), lineWidth: 2.5)
            }

            if viewModel.pathWaypoints.count >= 2 {
                MapPolyline(coordinates: viewModel.pathWaypoints.map(\.coordinate))
                    .stroke(.orange.opacity(0.55), lineWidth: 2)
            }

            ForEach(orderedSites) { site in
                let isCurrent = site.id == currentSite?.id
                let isRecorded = site.isRecorded

                Annotation("", coordinate: site.coordinate) {
                    Button {
                        currentSiteId = site.id
                    } label: {
                        siteMarker(site: site, isCurrent: isCurrent, isRecorded: isRecorded)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.hybrid)
    }

    private var offlineSamplingTrails: [OfflineVineyardMapView.Trail] {
        var trails: [OfflineVineyardMapView.Trail] = []
        if viewModel.pathWaypoints.count >= 2 {
            trails.append(OfflineVineyardMapView.Trail(
                id: 0,
                coordinates: viewModel.pathWaypoints.map(\.coordinate),
                color: .orange.opacity(0.6),
                lineWidth: 2
            ))
        }
        if let site = currentSite, let loc = locationService.location {
            trails.append(OfflineVineyardMapView.Trail(
                id: 1,
                coordinates: [loc.coordinate, site.coordinate],
                color: .blue.opacity(0.7),
                lineWidth: 2.5
            ))
        }
        return trails
    }

    private var offlineMapLayer: some View {
        OfflineVineyardMapView(
            paddocks: paddocks
                .filter { viewModel.selectedPaddockIds.contains($0.id) }
                .map { paddock in
                    OfflineVineyardMapView.Paddock(
                        id: paddock.id,
                        polygon: paddock.polygonPoints.map(\.coordinate),
                        rows: paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] },
                        strokeColor: .green.opacity(0.6),
                        fillColor: .green.opacity(0.12),
                        name: paddock.name
                    )
                },
            trails: offlineSamplingTrails,
            pins: orderedSites.map { site in
                OfflineVineyardMapView.Pin(
                    id: site.id,
                    coordinate: site.coordinate,
                    color: site.id == currentSite?.id ? .blue : (site.isRecorded ? .green : .orange),
                    isCompleted: site.isRecorded,
                    name: "\(site.siteIndex)"
                )
            },
            userCoordinate: locationService.location?.coordinate
        )
    }

    private func siteMarker(site: SampleSite, isCurrent: Bool, isRecorded: Bool) -> some View {
        let fillColor: Color = {
            if isCurrent { return .blue }
            if isRecorded { return .green }
            return .orange
        }()
        let size: CGFloat = isCurrent ? 36 : 22

        return ZStack {
            if isCurrent {
                Circle()
                    .fill(fillColor.opacity(0.25))
                    .frame(width: size + 18, height: size + 18)
            }
            Circle()
                .fill(fillColor)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            Circle()
                .fill(.white)
                .frame(width: size - 10, height: size - 10)
            if isRecorded && !isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.green)
            } else {
                Text("\(site.siteIndex)")
                    .font(.system(size: isCurrent ? 12 : 9, weight: .heavy))
                    .foregroundStyle(fillColor)
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample \(currentIndex + 1) of \(totalCount)")
                        .font(.headline.weight(.bold))
                    if let site = currentSite {
                        Text("\(site.paddockName) · Row \(site.rowNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    recenterOnCurrent()
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.blue, in: Circle())
                }
            }

            ProgressView(value: Double(recordedCount), total: Double(max(totalCount, 1)))
                .tint(.green)

            HStack(spacing: 12) {
                progressChip(label: "Recorded", value: "\(recordedCount)", color: .green)
                progressChip(label: "Remaining", value: "\(remaining)", color: .orange)
                if let dist = distanceMetres {
                    progressChip(label: "Distance", value: formatDistance(dist), color: .blue)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func progressChip(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - First-Use Tip

    private var firstUseTip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow)
                .padding(.top, 1)
            Text("Follow each sample point, count bunches on the selected vine, enter the value, then tap Record & Next.")
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    tipDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color(.tertiarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.yellow.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Bottom Panel

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            guidancePanel
            entryPanel
            actionRow
            if !viewModel.isCompleted && recordedCount > 0 {
                completeButton
            }
            if viewModel.isCompleted {
                viewReportButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            Color(.systemBackground)
                .clipShape(.rect(topLeadingRadius: 22, topTrailingRadius: 22))
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
        )
    }

    private var guidancePanel: some View {
        HStack(spacing: 14) {
            arrowView

            VStack(alignment: .leading, spacing: 3) {
                if let site = currentSite {
                    Text("Go to sample #\(site.siteIndex)")
                        .font(.subheadline.weight(.semibold))
                }
                if let dist = distanceMetres {
                    if dist < arrivedThresholdMetres {
                        Label("Arrived", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text(formatDistance(dist) + " away")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Location unavailable — sample by row")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private var arrowView: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.15))
                .frame(width: 52, height: 52)
            Image(systemName: arrowSymbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.blue)
                .rotationEffect(arrowRotation)
        }
    }

    private var arrowSymbol: String {
        if let dist = distanceMetres, dist < arrivedThresholdMetres {
            return "checkmark"
        }
        return "arrow.up"
    }

    private var arrowRotation: Angle {
        guard let bearing = bearingDegrees else { return .zero }
        let heading = locationService.heading?.trueHeading ?? 0
        return .degrees(bearing - heading)
    }

    private var entryPanel: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bunches per vine")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("0", text: $bunchesText)
                    .keyboardType(.decimalPad)
                    .focused($bunchesFocused)
                    .font(.system(size: 28, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Recorded by")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Name", text: $recorderName)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
            .frame(maxWidth: 160)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                goPrevious()
            } label: {
                Label("Prev", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .disabled(currentIndex == 0)

            Button {
                skipCurrent()
            } label: {
                Label("Skip", systemImage: "forward")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button {
                recordAndNext()
            } label: {
                Label("Record & Next", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(parsedBunches == nil || viewModel.isCompleted)
        }
    }

    private var completeButton: some View {
        Button {
            attemptFinish()
        } label: {
            Label(finishButtonTitle, systemImage: "checkmark.seal.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
    }

    private var finishButtonTitle: String {
        if recordedCount < totalCount {
            return "Finish Sampling (\(recordedCount)/\(totalCount))"
        }
        return "Finish Sampling"
    }

    private func attemptFinish() {
        bunchesFocused = false
        if recordedCount < totalCount {
            showInsufficientSamplesConfirmation = true
        } else {
            showCompleteConfirmation = true
        }
    }

    private var viewReportButton: some View {
        VStack(spacing: 8) {
            Button {
                showReport = true
            } label: {
                Label("View Yield Report", systemImage: "chart.bar.doc.horizontal.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            Button {
                dismiss()
            } label: {
                Text("Return to Yield Forecasting")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Site List Sheet

    private var siteListSheet: some View {
        NavigationStack {
            List {
                ForEach(orderedSites) { site in
                    Button {
                        currentSiteId = site.id
                        showSiteList = false
                    } label: {
                        HStack(spacing: 10) {
                            siteListIcon(for: site)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Site #\(site.siteIndex) · \(site.paddockName)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("Row \(site.rowNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let entry = site.bunchCountEntry {
                                Text(String(format: "%.1f", entry.bunchesPerVine))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("All Samples")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSiteList = false }
                }
            }
        }
    }

    private func siteListIcon(for site: SampleSite) -> some View {
        let isCurrent = site.id == currentSite?.id
        let color: Color = isCurrent ? .blue : (site.isRecorded ? .green : .orange)
        return ZStack {
            Circle().fill(color).frame(width: 22, height: 22)
            if site.isRecorded {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white)
            } else {
                Text("\(site.siteIndex)")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Actions

    private func selectInitialSite() {
        if currentSiteId != nil { return }
        if let firstUnrecorded = orderedSites.first(where: { !$0.isRecorded }) {
            currentSiteId = firstUnrecorded.id
        } else {
            currentSiteId = orderedSites.first?.id
        }
    }

    private func loadSiteIntoForm() {
        guard let site = currentSite else {
            bunchesText = ""
            return
        }
        if let entry = site.bunchCountEntry {
            bunchesText = String(format: "%.2f", entry.bunchesPerVine)
            if recorderName.isEmpty { recorderName = entry.recordedBy }
        } else {
            bunchesText = ""
        }
    }

    private var parsedBunches: Double? {
        let cleaned = bunchesText.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned), v >= 0 else { return nil }
        return v
    }

    private func recordAndNext() {
        guard let site = currentSite, let value = parsedBunches else { return }
        viewModel.recordBunchCount(siteId: site.id, bunchesPerVine: value, recordedBy: recorderName)
        saveSession()
        bunchesFocused = false
        advanceToNextUnrecorded(after: site.id)
    }

    private func skipCurrent() {
        guard let site = currentSite else { return }
        bunchesFocused = false
        advanceToNextUnrecorded(after: site.id)
    }

    private func goPrevious() {
        let idx = currentIndex
        guard idx > 0 else { return }
        currentSiteId = orderedSites[idx - 1].id
    }

    private func advanceToNextUnrecorded(after siteId: UUID) {
        guard let idx = orderedSites.firstIndex(where: { $0.id == siteId }) else { return }
        let after = orderedSites.suffix(from: idx + 1)
        if let next = after.first(where: { !$0.isRecorded }) {
            currentSiteId = next.id
            return
        }
        if let next = orderedSites.first(where: { !$0.isRecorded }) {
            currentSiteId = next.id
            return
        }
        if idx + 1 < orderedSites.count {
            currentSiteId = orderedSites[idx + 1].id
        }
    }

    private func saveSession() {
        guard let vid = store.selectedVineyardId else { return }
        let session = viewModel.toSession(
            vineyardId: vid,
            samplesPerHectare: store.settings.samplesPerHectare
        )
        store.saveYieldSession(session)
    }

    // MARK: - Map helpers

    private func recenterOnCurrent() {
        guard let site = currentSite else { return }
        let span = MKCoordinateSpan(latitudeDelta: 0.0015, longitudeDelta: 0.0015)
        withAnimation(.smooth(duration: 0.4)) {
            mapPosition = .region(MKCoordinateRegion(center: site.coordinate, span: span))
        }
    }

    private func formatDistance(_ metres: Double) -> String {
        if metres < 1000 {
            return String(format: "%.0f m", metres)
        }
        return String(format: "%.2f km", metres / 1000)
    }

    private func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

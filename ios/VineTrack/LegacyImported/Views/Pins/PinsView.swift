import SwiftUI
import MapKit

struct PinsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(PinSyncService.self) private var pinSync
    @Environment(GrowthStageRecordSyncService.self) private var growthStageRecordSync
    @Environment(BackendAccessControl.self) private var accessControl
    private var canDelete: Bool { accessControl.canDeleteOperationalRecords }
    private var canExport: Bool { accessControl.canExport }
    @State private var viewMode: PinsViewMode

    init(initialViewMode: PinsViewMode = .map) {
        _viewMode = State(initialValue: initialViewMode)
    }

    @State private var filterModes: Set<PinMode> = []
    @State private var completionFilter: PinCompletionFilter = .notDone
    @State private var selectedNames: Set<String> = []
    @State private var selectedPaddockIds: Set<UUID> = []
    @State private var showFilterSheet: Bool = false
    @State private var isExporting: Bool = false
    @State private var showExportOptions: Bool = false

    /// Source pins: real `store.pins` plus a fallback synthesis for any
    /// `growth_stage_records` rows that don't yet have a matching local pin.
    /// This guarantees growth-stage observations always appear in the Pins
    /// view on a second device, even if the originating `pins` row sync was
    /// missed or delayed (the mirrored growth_stage_records sync runs on a
    /// separate path).
    private var sourcePins: [VinePin] {
        guard let vineyardId = store.selectedVineyardId else { return store.pins }
        let localIds = Set(store.pins.map { $0.id })
        let synthesized: [VinePin] = growthStageRecordSync.records.compactMap { record in
            guard record.vineyardId == vineyardId else { return nil }
            // Prefer matching against the originating pin id; fall back to
            // the record id so synthesized rows are still stable.
            let pinIdCandidate = record.pinId ?? record.id
            guard !localIds.contains(pinIdCandidate),
                  let lat = record.latitude, let lon = record.longitude
            else { return nil }
            return VinePin(
                id: pinIdCandidate,
                vineyardId: record.vineyardId,
                latitude: lat,
                longitude: lon,
                heading: nil,
                buttonName: "Growth Stage \(record.stageCode)",
                buttonColor: "darkgreen",
                side: PinSide(rawValue: record.side ?? "") ?? .right,
                mode: .growth,
                paddockId: record.paddockId,
                rowNumber: record.rowNumber,
                timestamp: record.observedAt,
                createdBy: record.recordedByName,
                createdByUserId: record.createdBy,
                isCompleted: false,
                photoPath: record.photoPaths.first,
                growthStageCode: record.stageCode,
                notes: record.notes
            )
        }
        #if DEBUG
        if !synthesized.isEmpty {
            print("[PinsView] synthesized \(synthesized.count) growth pins from growth_stage_records (no matching local pin)")
        }
        let growthLocal = store.pins.filter { $0.mode == .growth }.count
        print("[PinsView] vineyard=\(vineyardId) local pins=\(store.pins.count) growth(local)=\(growthLocal) growth_records=\(growthStageRecordSync.records.filter { $0.vineyardId == vineyardId }.count) synthesized=\(synthesized.count)")
        #endif
        return store.pins + synthesized
    }

    private var filteredPins: [VinePin] {
        sourcePins.filter { pin in
            switch completionFilter {
            case .done:
                if !pin.isCompleted { return false }
            case .notDone:
                if pin.isCompleted { return false }
            case .both:
                break
            }
            if !filterModes.isEmpty && !filterModes.contains(pin.mode) { return false }
            if !selectedNames.isEmpty && !selectedNames.contains(pin.buttonName) { return false }
            if !selectedPaddockIds.isEmpty, let paddockId = pin.paddockId, !selectedPaddockIds.contains(paddockId) { return false }
            if !selectedPaddockIds.isEmpty && pin.paddockId == nil { return false }
            return true
        }
        // Newest first, mirroring the Android pin list ordering.
        .sorted { $0.timestamp > $1.timestamp }
    }

    private var activeFilterCount: Int {
        (selectedNames.isEmpty ? 0 : 1) + (selectedPaddockIds.isEmpty ? 0 : 1)
    }

    private var nameColorMap: [String: String] {
        var map: [String: String] = [:]
        for config in store.repairButtons + store.growthButtons {
            if map[config.name] == nil {
                map[config.name] = config.color
            }
        }
        return map
    }

    private var uniqueNames: [String] {
        Array(Set(sourcePins.map { $0.buttonName })).sorted()
    }

    private var uniquePaddocks: [(id: UUID, name: String)] {
        let paddockIds = Set(sourcePins.compactMap { $0.paddockId })
        return paddockIds.compactMap { id in
            guard let paddock = store.paddocks.first(where: { $0.id == id }) else { return nil }
            return (id: id, name: paddock.name)
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                switch viewMode {
                case .map:
                    PinsMapView(pins: filteredPins)
                case .list:
                    PinsListView(pins: filteredPins)
                case .summary:
                    PinsSummaryView(pins: filteredPins)
                }
            }
            .navigationTitle("Pins")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if canExport {
                        Button {
                            showExportOptions = true
                        } label: {
                            if isExporting {
                                ProgressView()
                            } else {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                        }
                        .disabled(filteredPins.isEmpty || isExporting)
                        .confirmationDialog("Export Pins", isPresented: $showExportOptions) {
                            Button("Export as PDF") { exportPins(format: .pdf) }
                            Button("Export as CSV (Excel)") { exportPins(format: .csv) }
                            Button("Export Both (PDF + CSV)") { exportPins(format: .both) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Choose export format for \(filteredPins.count) pins")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $viewMode) {
                        Image(systemName: "map").tag(PinsViewMode.map)
                        Image(systemName: "list.bullet").tag(PinsViewMode.list)
                        Image(systemName: "chart.bar.fill").tag(PinsViewMode.summary)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }
            .background(Color(.systemGroupedBackground))
            .task {
                // Force a fresh pull on entry so growth-stage pins created
                // on other devices appear without requiring a manual Sync.
                await pinSync.syncPinsForSelectedVineyard()
                await growthStageRecordSync.syncForSelectedVineyard()
            }
            .refreshable {
                await pinSync.syncPinsForSelectedVineyard()
                await growthStageRecordSync.syncForSelectedVineyard()
            }
            .sheet(isPresented: $showFilterSheet) {
                PinFilterSheet(
                    selectedNames: $selectedNames,
                    selectedPaddockIds: $selectedPaddockIds,
                    uniqueNames: uniqueNames,
                    nameColorMap: nameColorMap,
                    uniquePaddocks: uniquePaddocks
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isSelected: filterModes.isEmpty) {
                    filterModes = []
                }
                FilterChip(title: "Repairs", isSelected: filterModes.contains(.repairs)) {
                    if filterModes.contains(.repairs) {
                        filterModes.remove(.repairs)
                    } else {
                        filterModes.insert(.repairs)
                    }
                }
                FilterChip(title: "Growth", isSelected: filterModes.contains(.growth)) {
                    if filterModes.contains(.growth) {
                        filterModes.remove(.growth)
                    } else {
                        filterModes.insert(.growth)
                    }
                }

                Divider()
                    .frame(height: 20)

                Button {
                    showFilterSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.caption2)
                        Text("Filters")
                            .font(.subheadline.weight(.medium))
                        if activeFilterCount > 0 {
                            Text("\(activeFilterCount)")
                                .font(.caption2.weight(.bold))
                                .frame(width: 16, height: 16)
                                .background(Color.white)
                                .foregroundStyle(Color.accentColor)
                                .clipShape(.circle)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(activeFilterCount > 0 ? Color.accentColor : Color(.tertiarySystemBackground))
                    .foregroundStyle(activeFilterCount > 0 ? .white : .primary)
                    .clipShape(.capsule)
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(height: 20)

                ForEach(PinCompletionFilter.allCases, id: \.self) { filter in
                    FilterChip(
                        title: filter.label,
                        isSelected: completionFilter == filter,
                        systemImage: filter.icon
                    ) {
                        completionFilter = filter
                    }
                }
            }
        }
        .contentMargins(.horizontal, 16)
        .scrollIndicators(.hidden)
    }
    private func exportPins(format: ExportFormat) {
        guard !isExporting else { return }
        isExporting = true
        let pinsToExport = filteredPins
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let logoData = store.selectedVineyard?.logoData
        let exportTimeZone = store.settings.resolvedTimeZone
        let regionFormatter = store.settings.regionFormatter

        let pinReports = pinsToExport.map { pin in
            let paddockName: String
            if let paddockId = pin.paddockId {
                paddockName = store.paddocks.first { $0.id == paddockId }?.name ?? "—"
            } else {
                paddockName = "—"
            }
            return PinsPDFService.PinReport(pin: pin, paddockName: paddockName)
        }

        Task {
            var urls: [URL] = []
            let fileName = "PinsReport_\(vineyardName)_\(Date().formattedTZ(date: .numeric, time: .omitted, in: exportTimeZone))"

            if format == .pdf || format == .both {
                let snapshot = await PinsPDFService.captureMapSnapshot(pins: pinsToExport)
                let pdfData = PinsPDFService.generatePDF(pins: pinReports, vineyardName: vineyardName, mapSnapshot: snapshot, logoData: logoData, timeZone: exportTimeZone, formatter: regionFormatter)
                urls.append(PinsPDFService.savePDFToTemp(data: pdfData, fileName: fileName))
            }

            if format == .csv || format == .both {
                let csvData = PinsPDFService.generateCSV(pins: pinReports, vineyardName: vineyardName, timeZone: exportTimeZone)
                urls.append(PinsPDFService.saveCSVToTemp(data: csvData, fileName: fileName))
            }

            isExporting = false

            guard !urls.isEmpty else { return }
            let activityVC = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                var presenter = rootVC
                while let presented = presenter.presentedViewController {
                    presenter = presented
                }
                presenter.present(activityVC, animated: true)
            }
        }
    }
}

nonisolated enum ExportFormat {
    case pdf
    case csv
    case both
}

nonisolated enum PinsViewMode: String, Hashable {
    case map
    case list
    case summary
}

// MARK: - Summary / Repair Report

struct PinsSummaryView: View {
    let pins: [VinePin]
    @Environment(MigratedDataStore.self) private var store

    private struct CategoryStat: Identifiable {
        let id: String
        let name: String
        let color: String
        let total: Int
        let active: Int
        let completed: Int
    }

    private var stats: [CategoryStat] {
        var buckets: [String: (name: String, color: String, total: Int, active: Int, completed: Int)] = [:]
        for pin in pins {
            let key = pin.buttonName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var entry = buckets[key] ?? (name: pin.buttonName, color: pin.buttonColor, total: 0, active: 0, completed: 0)
            entry.total += 1
            if pin.isCompleted { entry.completed += 1 } else { entry.active += 1 }
            buckets[key] = entry
        }
        return buckets
            .map { CategoryStat(id: $0.key, name: $0.value.name, color: $0.value.color, total: $0.value.total, active: $0.value.active, completed: $0.value.completed) }
            .sorted { $0.total > $1.total }
    }

    private var modeBreakdown: (repairs: Int, growth: Int) {
        let repairs = pins.filter { $0.mode == .repairs }.count
        let growth = pins.filter { $0.mode == .growth }.count
        return (repairs, growth)
    }

    var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Total pins") {
                    Text("\(pins.count)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                LabeledContent("Active") {
                    Text("\(pins.filter { !$0.isCompleted }.count)")
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
                LabeledContent("Completed") {
                    Text("\(pins.filter { $0.isCompleted }.count)")
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .monospacedDigit()
                }
                LabeledContent("Repairs") {
                    Text("\(modeBreakdown.repairs)")
                        .monospacedDigit()
                }
                LabeledContent("Growth") {
                    Text("\(modeBreakdown.growth)")
                        .monospacedDigit()
                }
            }

            Section("By Category") {
                if stats.isEmpty {
                    Text("No pins to summarise.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stats) { stat in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.fromString(stat.color).gradient)
                                .frame(width: 14, height: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.name)
                                    .font(.subheadline.weight(.semibold))
                                HStack(spacing: 8) {
                                    if stat.active > 0 {
                                        Label("\(stat.active)", systemImage: "circle")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                    if stat.completed > 0 {
                                        Label("\(stat.completed)", systemImage: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(VineyardTheme.leafGreen)
                                    }
                                }
                            }
                            Spacer()
                            Text("\(stat.total)")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if pins.isEmpty {
                ContentUnavailableView(
                    "No Pins",
                    systemImage: "chart.bar",
                    description: Text("Drop pins to see a repair-job summary here.")
                )
            }
        }
    }
}

nonisolated enum PinCompletionFilter: String, CaseIterable, Hashable {
    case notDone
    case done
    case both

    var label: String {
        switch self {
        case .notDone: return "Not Done"
        case .done: return "Done"
        case .both: return "Both"
        }
    }

    var icon: String {
        switch self {
        case .notDone: return "circle"
        case .done: return "checkmark.circle.fill"
        case .both: return "circle.grid.2x2"
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.tertiarySystemBackground))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Map View

struct PinsMapView: View {
    let pins: [VinePin]
    @Environment(MigratedDataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(NetworkMonitor.self) private var network
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedPin: VinePin?
    @State private var hasSetInitialPosition: Bool = false
    @State private var hasFramedBlocks: Bool = false

    private var pinIDs: [UUID] {
        pins.map { $0.id }
    }

    private var allPaddocks: [Paddock] {
        store.paddocks.filter { $0.polygonPoints.count > 2 }
    }

    /// Coordinates describing the vineyard block layout. Boundary polygons come
    /// first; mapped row geometry is used when no boundaries exist yet.
    private var blockCoordinates: [CLLocationCoordinate2D] {
        let boundaryCoords = allPaddocks.flatMap { paddock in
            paddock.polygonPoints.map { $0.coordinate }
        }
        if !boundaryCoords.isEmpty { return boundaryCoords }
        return store.paddocks.flatMap { paddock in
            paddock.rows.flatMap { [$0.startPoint.coordinate, $0.endPoint.coordinate] }
        }
    }

    /// Cheap signature that changes when block geometry first loads or is edited.
    private var blockGeometrySignature: Int {
        blockCoordinates.count
    }

    /// Region framing the vineyard: block geometry first, saved pins only as a
    /// fallback when no blocks are mapped.
    private func regionForContent() -> MKCoordinateRegion? {
        let blockCoords = blockCoordinates
        let coords = blockCoords.isEmpty ? pins.map { $0.coordinate } : blockCoords
        return Self.region(fitting: coords)
    }

    private static func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty,
              let minLat = coords.map({ $0.latitude }).min(),
              let maxLat = coords.map({ $0.latitude }).max(),
              let minLon = coords.map({ $0.longitude }).min(),
              let maxLon = coords.map({ $0.longitude }).max() else { return nil }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.002),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.002)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Frames the map once when content first becomes available. Never moves
    /// the camera again after the initial fit.
    private func applyInitialFitIfNeeded(animated: Bool = false) {
        guard !hasSetInitialPosition, let region = regionForContent() else { return }
        if animated {
            withAnimation { position = .region(region) }
        } else {
            position = .region(region)
        }
        hasSetInitialPosition = true
        hasFramedBlocks = !blockCoordinates.isEmpty
    }

    private var offlineMap: some View {
        OfflineVineyardMapView(
            paddocks: allPaddocks.map { paddock in
                OfflineVineyardMapView.Paddock(
                    id: paddock.id,
                    polygon: paddock.polygonPoints.map { $0.coordinate },
                    rows: paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] },
                    strokeColor: .orange,
                    fillColor: .orange.opacity(0.1),
                    name: paddock.name
                )
            },
            pins: pins.map {
                OfflineVineyardMapView.Pin(
                    id: $0.id,
                    coordinate: $0.coordinate,
                    color: Color.fromString($0.buttonColor),
                    isCompleted: $0.isCompleted,
                    name: $0.buttonName
                )
            },
            userCoordinate: locationService.location?.coordinate
        )
    }

    private var hybridMap: some View {
        Map(position: $position) {
            ForEach(allPaddocks) { paddock in
                MapPolygon(coordinates: paddock.polygonPoints.map { $0.coordinate })
                    .foregroundStyle(.orange.opacity(0.08))
                    .stroke(.orange, lineWidth: 2)
                Annotation("", coordinate: paddock.polygonPoints.centroid) {
                    VStack(spacing: 1) {
                        Text(paddock.name)
                            .font(.caption2.weight(.semibold))
                        Text("\(paddock.rows.count) rows")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.85), in: .rect(cornerRadius: 6))
                    .allowsHitTesting(false)
                }
            }

            ForEach(pins) { pin in
                Annotation(pin.buttonName, coordinate: pin.coordinate) {
                    Button {
                        selectedPin = pin
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.fromString(pin.buttonColor).gradient)
                                .frame(width: 30, height: 30)

                            if pin.isCompleted {
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                            } else {
                                Circle()
                                    .fill(.white.opacity(0.4))
                                    .frame(width: 10, height: 10)
                            }
                        }
                    }
                }
            }

            UserAnnotation()
        }
        .mapStyle(.hybrid)
    }

    var body: some View {
        Group {
            if network.isOnline {
                hybridMap
            } else {
                offlineMap
            }
        }
        .sheet(item: $selectedPin) { pin in
            PinDetailSheet(pin: pin)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Button {
                    if let region = regionForContent() {
                        withAnimation {
                            position = .region(region)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                }

                Button {
                    if locationService.authorizationStatus == .notDetermined {
                        locationService.requestPermission()
                    }
                    locationService.startUpdating()
                    if let coordinate = locationService.location?.coordinate {
                        withAnimation {
                            position = .region(MKCoordinateRegion(
                                center: coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                            ))
                        }
                    } else {
                        withAnimation {
                            position = .userLocation(fallback: .automatic)
                        }
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .overlay {
            if pins.isEmpty && allPaddocks.isEmpty {
                ContentUnavailableView("No Pins", systemImage: "mappin.slash", description: Text("Drop pins from the Home tab to see them here."))
            }
        }
        .onAppear {
            applyInitialFitIfNeeded()
        }
        .onChange(of: pinIDs) { _, _ in
            // Pin refreshes never snap the camera — this only frames the map
            // when it opened before any content had loaded.
            applyInitialFitIfNeeded(animated: true)
        }
        .onChange(of: blockGeometrySignature) { _, newCount in
            // Block geometry newly loaded or edited: frame the block group once.
            guard newCount > 0, !hasFramedBlocks, let region = regionForContent() else { return }
            withAnimation { position = .region(region) }
            hasSetInitialPosition = true
            hasFramedBlocks = true
        }
        .task {
            if !hasSetInitialPosition {
                try? await Task.sleep(for: .milliseconds(100))
                applyInitialFitIfNeeded()
            }
        }
    }
}

// MARK: - List View

struct PinsListView: View {
    let pins: [VinePin]
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl
    private var canDelete: Bool { accessControl.canDeleteOperationalRecords }
    @State private var selectedPinForMap: VinePin?
    @State private var selectedPinForDirections: VinePin?
    @State private var selectedPinForPhoto: VinePin?
    @State private var selectedPinForDetail: VinePin?
    @State private var pinToDelete: VinePin?
    @State private var showDeleteConfirmation: Bool = false

    var body: some View {
        List {
            ForEach(pins) { pin in
                PinRowView(
                    pin: pin,
                    paddockName: paddockName(for: pin),
                    distance: distanceToPin(pin),
                    onMap: { selectedPinForMap = pin },
                    onDirections: { selectedPinForDirections = pin },
                    onPhoto: { selectedPinForPhoto = pin },
                    onComplete: { toggleCompletion(pin) },
                    onDelete: {
                        pinToDelete = pin
                        showDeleteConfirmation = true
                    },
                    onHeadingTap: { selectedPinForDetail = pin }
                )
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        toggleCompletion(pin)
                    } label: {
                        Label(
                            pin.isCompleted ? "Undo" : "Complete",
                            systemImage: pin.isCompleted ? "arrow.uturn.backward" : "checkmark"
                        )
                    }
                    .tint(pin.isCompleted ? .orange : VineyardTheme.leafGreen)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if pins.isEmpty {
                ContentUnavailableView("No Pins", systemImage: "mappin.slash", description: Text("Drop pins from the Home tab to see them here."))
            }
        }
        .sheet(item: $selectedPinForDetail) { pin in
            PinDetailSheet(pin: pin)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPinForMap) { pin in
            PinLocationMapSheet(pin: pin)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPinForDirections) { pin in
            PinDirectionsSheet(pin: pin)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $selectedPinForPhoto) { pin in
            CameraImagePicker { data in
                handlePhotoCaptured(data, for: pin)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Delete Pin?", isPresented: $showDeleteConfirmation, presenting: pinToDelete) { pin in
            if canDelete {
                Button("Delete", role: .destructive) {
                    store.deletePin(pin.id)
                    pinToDelete = nil
                }
            }
        } message: { pin in
            Text("Delete \"\(pin.buttonName)\" pin? This cannot be undone.")
        }
    }

    private func paddockName(for pin: VinePin) -> String {
        guard let paddockId = pin.paddockId else { return "—" }
        return store.paddocks.first { $0.id == paddockId }?.name ?? "—"
    }

    private func distanceToPin(_ pin: VinePin) -> Double? {
        guard let userLocation = locationService.location else { return nil }
        let pinLocation = CLLocation(latitude: pin.latitude, longitude: pin.longitude)
        return userLocation.distance(from: pinLocation)
    }

    private func toggleCompletion(_ pin: VinePin) {
        var updated = pin
        updated.isCompleted.toggle()
        if updated.isCompleted {
            updated.completedAt = Date()
            updated.completedBy = auth.userName
            updated.completedByUserId = auth.userId
        } else {
            updated.completedAt = nil
            updated.completedBy = nil
            updated.completedByUserId = nil
        }
        store.updatePin(updated)
    }

    private func handlePhotoCaptured(_ data: Data?, for pin: VinePin) {
        guard let data else { return }
        var updatedPin = pin
        updatedPin.photoData = data
        store.updatePin(updatedPin)
    }
}

// MARK: - Pin Row

struct PinRowView: View {
    let pin: VinePin
    let paddockName: String
    let distance: Double?
    let onMap: () -> Void
    let onDirections: () -> Void
    let onPhoto: () -> Void
    let onComplete: () -> Void
    let onDelete: () -> Void
    let onHeadingTap: () -> Void
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(PinSyncService.self) private var pinSync
    private var canDelete: Bool { accessControl.canDeleteOperationalRecords }
    private var fmt: RegionFormatter { store.settings.regionFormatter }
    @State private var showFullPhoto: Bool = false

    private var headingText: String {
        // No recorded compass direction — show an honest dash, not North.
        guard let h = pin.heading else { return "\u{2014}" }
        switch h {
        case 337.5..<360, 0..<22.5: return "N"
        case 22.5..<67.5: return "NE"
        case 67.5..<112.5: return "E"
        case 112.5..<157.5: return "SE"
        case 157.5..<202.5: return "S"
        case 202.5..<247.5: return "SW"
        case 247.5..<292.5: return "W"
        case 292.5..<337.5: return "NW"
        default: return "N"
        }
    }

    private var formattedDistance: String {
        guard let distance else { return "—" }
        return fmt.formatShortDistance(metres: distance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Button(action: onHeadingTap) {
                    HStack(spacing: 8) {
                        if pin.isCompleted {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                        Text(pin.buttonName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        RecordSyncBadge(
                            state: RecordSyncState.forPin(pin.id, pinSync: pinSync),
                            showsLabel: false
                        )
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.fromString(pin.buttonColor).gradient)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if let photoData = pin.photoData, let uiImage = UIImage(data: photoData) {
                    Button {
                        showFullPhoto = true
                    } label: {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                let drivingPathText: String? = {
                    if let path = pin.drivingRowNumber {
                        return path == path.rounded() ? String(format: "%.1f", path) : String(format: "%.1f", path)
                    }
                    if let legacy = pin.rowNumber { return "\(legacy).5" }
                    return nil
                }()
                let sideLabel = (pin.pinSide ?? pin.side).rawValue

                // Only claim a facing direction when one was actually recorded.
                let facingSuffix = pin.heading.map { " facing \(PinAttachmentFormatter.fullCompassName(degrees: $0))" } ?? ""
                if let drivingPathText {
                    Text("Row \(drivingPathText) — \(sideLabel) hand side\(facingSuffix)")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else {
                    Text("\(sideLabel) hand side\(facingSuffix)")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                if let pinRow = pin.pinRowNumber {
                    Text("\(paddockName) row \(pinRow)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let rowNumber = pin.rowNumber {
                    Text("\(paddockName) row \(rowNumber).5")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(paddockName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let createdBy = pin.createdBy, !createdBy.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                        Text("Dropped by \(createdBy)")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                InfoTag(icon: "location.fill", text: formattedDistance)
                Spacer()
                InfoTag(icon: "safari", text: pin.heading.map { "\(headingText) (\(Int($0))\u{00B0})" } ?? "\u{2014}")
                Spacer()
                InfoTag(icon: "clock", text: fmt.formatDateTime(pin.timestamp))
            }

            if pin.isCompleted, let completedBy = pin.completedBy, let completedAt = pin.completedAt {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text("Completed by \(completedBy) \u{2022} \(fmt.formatDateTime(completedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                ActionButton(icon: "map", label: "Map", color: .blue, action: onMap)
                Spacer()
                ActionButton(icon: "arrow.triangle.turn.up.right.diamond", label: "Directions", color: VineyardTheme.leafGreen, action: onDirections)
                Spacer()
                ActionButton(icon: "camera", label: "Photo", color: .purple, action: onPhoto)
                Spacer()
                ActionButton(
                    icon: pin.isCompleted ? "arrow.uturn.backward" : "checkmark.circle",
                    label: pin.isCompleted ? "Undo" : "Complete",
                    color: pin.isCompleted ? .orange : VineyardTheme.leafGreen,
                    action: onComplete
                )
                if canDelete {
                    Spacer()
                    ActionButton(icon: "trash", label: "Delete", color: .red, action: onDelete)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
        .opacity(pin.isCompleted ? 0.7 : 1)
        .fullScreenCover(isPresented: $showFullPhoto) {
            if let photoData = pin.photoData, let uiImage = UIImage(data: photoData) {
                PhotoViewerSheet(image: uiImage)
            }
        }
    }
}

struct PhotoViewerSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = max(1.0, value.magnification)
                            }
                            .onEnded { _ in
                                withAnimation(.spring) { scale = 1.0 }
                            }
                    )
            }
            .background(.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

struct InfoTag: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}

struct ActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(color)
            .frame(width: 64, height: 40)
            .background(color.opacity(0.1), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pin Location Map Sheet

struct PinLocationMapSheet: View {
    let pin: VinePin
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition

    init(pin: VinePin) {
        self.pin = pin
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: pin.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )))
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                Annotation(pin.buttonName, coordinate: pin.coordinate) {
                    ZStack {
                        Circle()
                            .fill(Color.fromString(pin.buttonColor).gradient)
                            .frame(width: 36, height: 36)
                        Image(systemName: "mappin")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }

                UserAnnotation()
            }
            .mapStyle(.hybrid)
            .navigationTitle("Pin Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Pin Directions Sheet

struct PinDirectionsSheet: View {
    let pin: VinePin
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var locationService
    @Environment(MigratedDataStore.self) private var store
    @State private var position: MapCameraPosition = .automatic
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var userCoordinate: CLLocationCoordinate2D? {
        locationService.location?.coordinate
    }

    private var distanceText: String {
        guard let userLocation = locationService.location else { return "—" }
        let pinLocation = CLLocation(latitude: pin.latitude, longitude: pin.longitude)
        let distance = userLocation.distance(from: pinLocation)
        return "\(fmt.formatShortDistance(metres: distance)) away"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $position) {
                    Annotation(pin.buttonName, coordinate: pin.coordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.fromString(pin.buttonColor).gradient)
                                .frame(width: 36, height: 36)
                            Image(systemName: "mappin")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                    }

                    if let userCoord = userCoordinate {
                        MapPolyline(coordinates: [userCoord, pin.coordinate])
                            .stroke(.blue, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    }

                    UserAnnotation()
                }
                .mapStyle(.hybrid)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pin.buttonName)
                            .font(.headline)
                        Text(distanceText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "location.north.line")
                        .font(.title2)
                        .foregroundStyle(VineyardTheme.info)
                        .rotationEffect(.degrees(bearingToPin()))
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
            }
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func bearingToPin() -> Double {
        guard let userCoord = userCoordinate else { return 0 }
        let lat1 = userCoord.latitude * .pi / 180
        let lat2 = pin.latitude * .pi / 180
        let dLon = (pin.longitude - userCoord.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return bearing
    }
}

// MARK: - Pin Detail Sheet (from map tap)

struct PinDetailSheet: View {
    let pin: VinePin
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(PinSyncService.self) private var pinSync
    @Environment(\.dismiss) private var dismiss
    private var canDelete: Bool { accessControl.canDeleteOperationalRecords }
    @State private var notesDraft: String = ""
    @State private var showDirections: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var showFullPhoto: Bool = false
    @State private var memberDirectory: [UUID: String] = [:]
    private let teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private func resolveDisplayName(userId: UUID?, fallbackText: String?) -> String? {
        let trimmed = fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer the locally-saved display text if it is present and not just a UUID.
        if let trimmed, !trimmed.isEmpty, UUID(uuidString: trimmed) == nil {
            return trimmed
        }
        if let userId {
            if let name = memberDirectory[userId], !name.isEmpty { return name }
            if userId == auth.userId, let me = auth.userName, !me.isEmpty { return me }
        }
        // As a last resort fall back to whatever text we have, even if empty UUID-like.
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return nil
    }

    private var paddockName: String {
        guard let paddockId = pin.paddockId else { return "—" }
        return store.paddocks.first { $0.id == paddockId }?.name ?? "—"
    }

    private var compassDirection: String {
        // No recorded compass direction — show an honest dash, not North.
        guard let h = pin.heading else { return "\u{2014}" }
        switch h {
        case 337.5..<360, 0..<22.5: return "N"
        case 22.5..<67.5: return "NE"
        case 67.5..<112.5: return "E"
        case 112.5..<157.5: return "SE"
        case 157.5..<202.5: return "S"
        case 202.5..<247.5: return "SW"
        case 247.5..<292.5: return "W"
        case 292.5..<337.5: return "NW"
        default: return "N"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle()
                            .fill(Color.fromString(pin.buttonColor).gradient)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(pin.buttonName)
                                    .font(.title3.weight(.semibold))
                                RecordSyncBadge(state: RecordSyncState.forPin(pin.id, pinSync: pinSync))
                            }
                            if let attached = PinAttachmentFormatter.attachmentLine(pin) {
                                Text("On \(attached)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(VineyardTheme.olive)
                            }
                            if let driving = PinAttachmentFormatter.drivingPathLine(pin) {
                                Text(driving)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text("Facing \(compassDirection)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    HStack(spacing: 0) {
                        ActionButton(icon: "arrow.triangle.turn.up.right.diamond", label: "Directions", color: VineyardTheme.leafGreen) {
                            showDirections = true
                        }
                        Spacer()
                        ActionButton(icon: "camera", label: "Photo", color: .purple) {
                            showPhotoPicker = true
                        }
                        Spacer()
                        ActionButton(
                            icon: pin.isCompleted ? "arrow.uturn.backward" : "checkmark.circle",
                            label: pin.isCompleted ? "Undo" : "Complete",
                            color: pin.isCompleted ? .orange : VineyardTheme.leafGreen
                        ) {
                            toggleCompletion()
                            dismiss()
                        }
                        if canDelete {
                            Spacer()
                            ActionButton(icon: "trash", label: "Delete", color: .red) {
                                store.deletePin(pin.id)
                                dismiss()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if let photoData = pin.photoData, let uiImage = UIImage(data: photoData) {
                    Section("Photo") {
                        Button {
                            showFullPhoto = true
                        } label: {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 250)
                                .clipShape(.rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                Section("Notes") {
                    TextField("Add notes…", text: $notesDraft, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: notesDraft) { _, newValue in
                            saveNotes(newValue)
                        }
                }

                Section("Details") {
                    LabeledContent(fmt.blockTermCapitalised, value: paddockName)
                    // New attachment model: prefer split row info when available.
                    // Side belongs with the driving path, not the attached vine row.
                    if pin.pinRowNumber != nil || pin.drivingRowNumber != nil {
                        if let pinRow = pin.pinRowNumber {
                            LabeledContent("On Row", value: "Row \(pinRow)")
                        }
                        if let drivingPath = pin.drivingRowNumber {
                            let side = (pin.pinSide ?? pin.side).rawValue
                            let facingSuffix = pin.heading.map { " facing \(PinAttachmentFormatter.fullCompassName(degrees: $0))" } ?? ""
                            LabeledContent(
                                "Driving path",
                                value: "Row \(String(format: "%.1f", drivingPath)) — \(side) hand side\(facingSuffix)"
                            )
                        }
                    } else if let rowNumber = pin.rowNumber {
                        // Legacy fallback only when neither new field is set.
                        LabeledContent("Row", value: "\(rowNumber).5")
                        LabeledContent("Side", value: "\(pin.side.rawValue) hand side")
                    }
                    LabeledContent("Facing", value: pin.heading.map { "\(compassDirection) (\(Int($0))\u{00B0})" } ?? "\u{2014}")
                    if let createdByName = resolveDisplayName(userId: pin.createdByUserId, fallbackText: pin.createdBy) {
                        LabeledContent("Created by", value: createdByName)
                    }
                    LabeledContent("Created", value: fmt.formatDateTime(pin.timestamp))
                    LabeledContent("Latitude", value: String(format: "%.6f", pin.latitude))
                    LabeledContent("Longitude", value: String(format: "%.6f", pin.longitude))
                    LabeledContent("Status", value: pin.isCompleted ? "Completed" : "Active")
                }

                if pin.isCompleted {
                    Section("Completion") {
                        if let completedByName = resolveDisplayName(userId: pin.completedByUserId, fallbackText: pin.completedBy) {
                            LabeledContent("Completed by", value: completedByName)
                        }
                        if let completedAt = pin.completedAt {
                            LabeledContent("Completed", value: fmt.formatDateTime(completedAt))
                        }
                    }
                }

            }
            .navigationTitle("Pin Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                notesDraft = pin.notes ?? ""
                Task { await loadMemberDirectory() }
            }
            .sheet(isPresented: $showDirections) {
                PinDirectionsSheet(pin: pin)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showPhotoPicker) {
                CameraImagePicker { data in
                    handlePhotoCaptured(data)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showFullPhoto) {
                if let photoData = pin.photoData, let uiImage = UIImage(data: photoData) {
                    PhotoViewerSheet(image: uiImage)
                }
            }
        }
    }

    private func saveNotes(_ text: String) {
        var updated = pin
        updated.notes = text.isEmpty ? nil : text
        store.updatePin(updated)
    }

    private func toggleCompletion() {
        var updated = pin
        updated.isCompleted.toggle()
        if updated.isCompleted {
            updated.completedAt = Date()
            updated.completedBy = auth.userName
            updated.completedByUserId = auth.userId
        } else {
            updated.completedAt = nil
            updated.completedBy = nil
            updated.completedByUserId = nil
        }
        store.updatePin(updated)
    }

    private func handlePhotoCaptured(_ data: Data?) {
        guard let data else { return }
        var updated = pin
        updated.photoData = data
        store.updatePin(updated)
    }

    private func loadMemberDirectory() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        do {
            let members = try await teamRepository.listMembers(vineyardId: vineyardId)
            var map: [UUID: String] = [:]
            for m in members {
                let trimmed = (m.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    map[m.userId] = trimmed
                }
            }
            memberDirectory = map
        } catch {
            // Non-fatal — fall back to text/UUID handling.
        }
    }
}

// MARK: - Pin Filter Sheet

struct PinFilterSheet: View {
    @Binding var selectedNames: Set<String>
    @Binding var selectedPaddockIds: Set<UUID>
    let uniqueNames: [String]
    let nameColorMap: [String: String]
    let uniquePaddocks: [(id: UUID, name: String)]
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var hasActiveFilters: Bool {
        !selectedNames.isEmpty || !selectedPaddockIds.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Issue / Growth") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            FilterChip(title: "All", isSelected: selectedNames.isEmpty) {
                                selectedNames = []
                            }
                            ForEach(uniqueNames, id: \.self) { name in
                                let isActive = selectedNames.contains(name)
                                Button {
                                    if isActive {
                                        selectedNames.remove(name)
                                    } else {
                                        selectedNames.insert(name)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color.fromString(nameColorMap[name] ?? "gray").gradient)
                                            .frame(width: 14, height: 14)
                                        Text(name)
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isActive ? Color.fromString(nameColorMap[name] ?? "gray").opacity(0.25) : Color(.tertiarySystemBackground))
                                    .foregroundStyle(isActive ? Color.fromString(nameColorMap[name] ?? "gray") : .primary)
                                    .clipShape(.capsule)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(isActive ? Color.fromString(nameColorMap[name] ?? "gray") : .clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section(fmt.blockTermCapitalised) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            FilterChip(title: "All", isSelected: selectedPaddockIds.isEmpty) {
                                selectedPaddockIds = []
                            }
                            ForEach(uniquePaddocks, id: \.id) { paddock in
                                FilterChip(title: paddock.name, isSelected: selectedPaddockIds.contains(paddock.id)) {
                                    if selectedPaddockIds.contains(paddock.id) {
                                        selectedPaddockIds.remove(paddock.id)
                                    } else {
                                        selectedPaddockIds.insert(paddock.id)
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasActiveFilters {
                        Button("Reset") {
                            selectedNames = []
                            selectedPaddockIds = []
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

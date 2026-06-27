import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct VineyardSetupSettingsView: View {
    @Environment(DataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(\.accessControl) private var accessControl
    @State private var showAddPaddock: Bool = false
    @State private var editingPaddock: Paddock?
    @State private var showEditRepairButtons: Bool = false
    @State private var showEditGrowthButtons: Bool = false
    @State private var showRepairTemplates: Bool = false
    @State private var showGrowthTemplates: Bool = false
    @State private var showGrowthStageConfig: Bool = false
    @State private var weatherStationService = WeatherStationService()
    @State private var manualStationId: String = ""
    @State private var showStationPicker: Bool = false
    @State private var showExportShare: Bool = false
    @State private var exportFileURL: URL?
    @State private var showImportPicker: Bool = false
    @State private var showImportPreview: Bool = false
    @State private var importData: BlockExportData?
    @State private var importError: String?

    @State private var mapSelectedPaddock: Paddock?

    var body: some View {
        Form {
            vineyardMapSection
            paddocksSection
            vineyardLocationSection
            grapeVarietiesSection
            blockExportImportSection
            buttonsSection
            growthStageSection
            weatherStationSection
        }
        .navigationTitle("Vineyard Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            manualStationId = store.settings.weatherStationId ?? ""
            if let lat = store.settings.vineyardLatitude { latitudeText = String(format: "%.5f", lat) }
            if let lon = store.settings.vineyardLongitude { longitudeText = String(format: "%.5f", lon) }
            if let elev = store.settings.vineyardElevationMetres { elevationText = String(format: "%.0f", elev) }
        }
        .sheet(isPresented: $showStationPicker) {
            NearbyStationPicker(weatherStationService: weatherStationService, onSelect: { stationId in
                manualStationId = stationId
                var s = store.settings
                s.weatherStationId = stationId
                store.updateSettings(s)
                showStationPicker = false
            })
        }
        .sheet(isPresented: $showAddPaddock) {
            EditPaddockSheet(paddock: nil)
        }
        .sheet(item: $editingPaddock) { paddock in
            EditPaddockSheet(paddock: paddock)
        }
        .onChange(of: mapSelectedPaddock) { _, newValue in
            if let paddock = newValue {
                mapSelectedPaddock = nil
                editingPaddock = paddock
            }
        }
        .sheet(isPresented: $showEditRepairButtons) {
            EditButtonsSheet(mode: .repairs)
        }
        .sheet(isPresented: $showEditGrowthButtons) {
            EditButtonsSheet(mode: .growth)
        }
        .sheet(isPresented: $showRepairTemplates) {
            ButtonTemplateListView(mode: .repairs)
        }
        .sheet(isPresented: $showGrowthTemplates) {
            ButtonTemplateListView(mode: .growth)
        }
        .sheet(isPresented: $showGrowthStageConfig) {
            GrowthStageConfigSheet()
        }
        .sheet(isPresented: $showExportShare) {
            if let url = exportFileURL {
                ShareSheet(items: [url])
            }
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try Data(contentsOf: url)
                    importData = try BlockExportImportService.parseImportData(data)
                    showImportPreview = true
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showImportPreview) {
            if let importData {
                BlockImportView(importData: importData)
            }
        }
        .alert("Import Error", isPresented: .init(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var vineyardMapSection: some View {
        Section {
            if store.orderedPaddocks.contains(where: { $0.polygonPoints.count > 2 }) {
                VineyardBlocksMapView(selectedPaddock: $mapSelectedPaddock, onAddBlock: { showAddPaddock = true })
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No block boundaries defined yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Add blocks with boundary points to see them on the map.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text("Vineyard Map")
            }
        } footer: {
            if store.orderedPaddocks.contains(where: { $0.polygonPoints.count > 2 }) {
                Text("Tap a block on the map to edit its settings.")
            }
        }
    }

    private var paddocksSection: some View {
        Section {
            Button {
                showAddPaddock = true
            } label: {
                HStack {
                    Label("Add Block", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                    Spacer()
                }
            }

            ForEach(store.orderedPaddocks) { paddock in
                Button {
                    editingPaddock = paddock
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(paddock.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            let rowNumbers = paddock.rows.map { $0.number }.sorted()
                            if let first = rowNumbers.first, let last = rowNumbers.last {
                                Text("Row \(first) to Row \(last) \u{2022} \(paddock.rows.count) rows \u{2022} \(paddock.effectiveVineCount) vines")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(paddock.rows.count) rows \u{2022} \(paddock.polygonPoints.count) boundary points")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let lhr = paddock.litresPerHour {
                                HStack(spacing: 6) {
                                    Image(systemName: "drop.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                    Text(String(format: "%.0f L/hr", lhr))
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    if let ml = paddock.mlPerHaPerHour {
                                        Text("\u{2022}")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "%.4f ML/ha/hr", ml))
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                    if let mm = paddock.mmPerHour {
                                        Text("\u{2022}")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "%.2f mm/hr", mm))
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if accessControl?.canDelete ?? false {
                        Button(role: .destructive) {
                            store.deletePaddock(paddock)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove { source, destination in
                var ordered = store.orderedPaddocks
                ordered.move(fromOffsets: source, toOffset: destination)
                store.updatePaddockOrder(ordered.map { $0.id })
            }

        } header: {
            Text("Blocks")
        } footer: {
            Text("Define block boundaries and row layouts for your vineyard.")
        }
    }

    private var grapeVarietiesSection: some View {
        Section {
            NavigationLink {
                GrapeVarietyManagementView()
            } label: {
                HStack {
                    Label("Grape Varieties", systemImage: "leaf.circle")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(store.grapeVarieties.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Varieties")
        } footer: {
            Text("Master list of grape varieties and their optimal ripeness (Growing Degree Days). Used when assigning varieties to blocks.")
        }
    }

    private var blockExportImportSection: some View {
        Section {
            if accessControl?.canExport ?? false {
                Button {
                    exportBlocks()
                } label: {
                    HStack {
                        Label("Export Blocks", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(store.paddocks.count) blocks")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(store.paddocks.isEmpty)
            }

            Button {
                showImportPicker = true
            } label: {
                HStack {
                    Label("Import Blocks", systemImage: "square.and.arrow.down")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Export / Import")
        } footer: {
            Text("Export your block data as JSON to share or back up. Import blocks from a previously exported file.")
        }
    }

    private func exportBlocks() {
        guard let vineyard = store.selectedVineyard else { return }
        do {
            let data = try BlockExportImportService.exportBlocks(
                paddocks: store.paddocks,
                vineyardName: vineyard.name
            )
            exportFileURL = try BlockExportImportService.exportFileURL(
                vineyardName: vineyard.name,
                data: data
            )
            showExportShare = true
        } catch {
            importError = "Export failed: \(error.localizedDescription)"
        }
    }

    private var buttonsSection: some View {
        Section {
            Button {
                showEditRepairButtons = true
            } label: {
                HStack {
                    Label("Repair Buttons", systemImage: "wrench")
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(store.repairButtons.prefix(4)) { btn in
                            Circle()
                                .fill(Color.fromString(btn.color))
                                .frame(width: 10, height: 10)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Button {
                showRepairTemplates = true
            } label: {
                HStack {
                    Label("Repair Templates", systemImage: "square.on.square")
                        .foregroundStyle(.primary)
                    Spacer()
                    let count = store.buttonTemplates(for: .repairs).count
                    if count > 0 {
                        Text("\(count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Button {
                showEditGrowthButtons = true
            } label: {
                HStack {
                    Label("Growth Buttons", systemImage: "leaf")
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(store.growthButtons.prefix(4)) { btn in
                            Circle()
                                .fill(Color.fromString(btn.color))
                                .frame(width: 10, height: 10)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Button {
                showGrowthTemplates = true
            } label: {
                HStack {
                    Label("Growth Templates", systemImage: "square.on.square")
                        .foregroundStyle(.primary)
                    Spacer()
                    let count = store.buttonTemplates(for: .growth).count
                    if count > 0 {
                        Text("\(count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Button Customization")
        } footer: {
            Text("Customize buttons directly or create templates to quickly switch between different button sets. Templates pair rows left and right.")
        }
    }

    @State private var latitudeText: String = ""
    @State private var longitudeText: String = ""
    @State private var elevationText: String = ""

    private var vineyardLocationSection: some View {
        Section {
            HStack {
                Label("Latitude", systemImage: "location")
                    .foregroundStyle(.primary)
                Spacer()
                TextField(autoLatPlaceholder, text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .onSubmit { saveCoords() }
                    .onChange(of: latitudeText) { _, _ in saveCoords() }
                Text("°").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Label("Longitude", systemImage: "location")
                    .foregroundStyle(.primary)
                Spacer()
                TextField(autoLonPlaceholder, text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .onSubmit { saveCoords() }
                    .onChange(of: longitudeText) { _, _ in saveCoords() }
                Text("°").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Label("Elevation", systemImage: "mountain.2")
                    .foregroundStyle(.primary)
                Spacer()
                TextField("0", text: $elevationText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .onSubmit { saveCoords() }
                    .onChange(of: elevationText) { _, _ in saveCoords() }
                Text("m").font(.caption).foregroundStyle(.secondary)
            }
            if let lat = store.paddockCentroidLatitude, let lon = store.paddockCentroidLongitude, store.settings.vineyardLatitude == nil {
                Button {
                    var s = store.settings
                    s.vineyardLatitude = lat
                    s.vineyardLongitude = lon
                    store.updateSettings(s)
                    latitudeText = String(format: "%.5f", lat)
                    longitudeText = String(format: "%.5f", lon)
                } label: {
                    Label("Use Block Centroid", systemImage: "scope")
                }
            }
            Picker(selection: Binding(
                get: { store.settings.calculationMode },
                set: { newValue in
                    var s = store.settings
                    s.calculationMode = newValue
                    s.useBEDD = newValue.useBEDD
                    store.updateSettings(s)
                }
            )) {
                ForEach(GDDCalculationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Label("Calculation", systemImage: "thermometer.sun")
            }

            Picker(selection: Binding(
                get: { store.settings.resetMode },
                set: { newValue in
                    var s = store.settings
                    s.resetMode = newValue
                    store.updateSettings(s)
                }
            )) {
                ForEach(GDDResetMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                }
            } label: {
                Label("Reset Point", systemImage: "arrow.counterclockwise")
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text("Vineyard Location")
            }
        } footer: {
            Text("Coordinates and elevation improve degree-day accuracy. Standard GDD is base 10°C. BEDD caps daily temps at 19°C, adds a diurnal-range bonus, and applies a day-length factor from latitude. Reset Point determines when accumulation starts each season (overridable per block).")
        }
    }

    private var autoLatPlaceholder: String {
        if let lat = store.paddockCentroidLatitude { return String(format: "%.5f (auto)", lat) }
        return "e.g. -33.29"
    }

    private var autoLonPlaceholder: String {
        if let lon = store.paddockCentroidLongitude { return String(format: "%.5f (auto)", lon) }
        return "e.g. 148.95"
    }

    private func saveCoords() {
        var s = store.settings
        s.vineyardLatitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        s.vineyardLongitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        s.vineyardElevationMetres = Double(elevationText.trimmingCharacters(in: .whitespacesAndNewlines))
        store.updateSettings(s)
    }

    private var weatherStationSection: some View {
        Section {
            HStack {
                Label("Station ID", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.primary)
                Spacer()
                TextField("e.g. KCASTATI123", text: $manualStationId)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .foregroundStyle(.secondary)
                    .onSubmit {
                        let trimmed = manualStationId.trimmingCharacters(in: .whitespacesAndNewlines)
                        var s = store.settings
                        s.weatherStationId = trimmed.isEmpty ? nil : trimmed
                        store.updateSettings(s)
                    }
            }

            if let stationId = store.settings.weatherStationId, !stationId.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text("Using station **\(stationId)**")
                        .font(.subheadline)
                    Spacer()
                    Button("Clear") {
                        manualStationId = ""
                        var s = store.settings
                        s.weatherStationId = nil
                        store.updateSettings(s)
                    }
                    .font(.subheadline)
                }
            }

            Button {
                if let location = locationService.location {
                    showStationPicker = true
                    Task {
                        await weatherStationService.fetchNearbyStations(
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude
                        )
                    }
                } else {
                    locationService.requestPermission()
                    locationService.startUpdating()
                }
            } label: {
                HStack {
                    Label("Find Nearest Station", systemImage: "location.magnifyingglass")
                    Spacer()
                    if locationService.location == nil {
                        Text("Requires Location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "cloud.sun.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Weather Station")
            }
        } footer: {
            Text("Enter your Weather Underground PWS Station ID, or find the nearest station to your location.")
        }
    }

    private var growthStageSection: some View {
        Section {
            Button {
                showGrowthStageConfig = true
            } label: {
                HStack {
                    Label("E-L Growth Stages", systemImage: "leaf.arrow.triangle.circlepath")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(store.settings.enabledGrowthStageCodes.count)/\(GrowthStage.allStages.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            NavigationLink {
                GrowthStageImagesSettingsView()
            } label: {
                HStack {
                    Label("Growth Stage Images", systemImage: "photo.on.rectangle.angled")
                        .foregroundStyle(.primary)
                    Spacer()
                    let customCount = GrowthStage.allStages.filter { store.hasCustomELStageImage(for: $0.code) }.count
                    if customCount > 0 {
                        Text("\(customCount) custom")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Growth Stages")
        } footer: {
            Text("Configure which E-L growth stages are available and manage reference images for visual confirmation.")
        }
    }
}

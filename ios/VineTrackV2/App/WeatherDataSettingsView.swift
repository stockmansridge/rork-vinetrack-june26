import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


struct WeatherDataSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var config: WeatherProviderConfig = .default
    @State private var showStationPicker: Bool = false
    @State private var davisApiKey: String = ""
    @State private var davisApiSecret: String = ""
    @State private var isTestingDavis: Bool = false
    @State private var davisTestMessage: String?
    @State private var davisTestSucceeded: Bool = false
    @State private var showSecret: Bool = false
    @State private var davisInfoTopic: DavisInfoTopic?
    @State private var isEditingDavisCredentials: Bool = false
    @State private var davisStations: [DavisStation] = []
    @State private var showDavisStationPicker: Bool = false
    @State private var showClearDavisCacheConfirm: Bool = false
    @State private var davisCacheClearedMessage: String?
    @State private var vineyardIntegration: VineyardWeatherIntegration?
    @State private var isLoadingVineyardIntegration: Bool = false
    @State private var vineyardIntegrationError: String?
    @State private var showMigratePrompt: Bool = false
    @State private var isMigrating: Bool = false
    @State private var migrationMessage: String?
    /// Last successfully parsed WeatherLink current-conditions response.
    /// Used purely for the on-device parser-diagnostics panel; never
    /// persisted because it can change on every fetch.
    @State private var lastDavisCurrent: DavisCurrentConditions?
    @State private var lastDavisSensorSummary: DavisSensorSummary?
    @State private var diagCopiedMessage: String?
    /// Status text for the user-triggered "Refresh Davis now" action which
    /// posts `action: current` to the davis-proxy edge function. The proxy
    /// writes `vineyard_weather_observations` and (when rain_today_mm is
    /// present) `rainfall_daily` server-side under the service-role key.
    @State private var davisForceRefreshStatus: String?
    @State private var davisForceRefreshOk: Bool = false
    @State private var isForceRefreshingDavis: Bool = false
    /// Status text for the Owner/Manager-only "Backfill Davis rainfall"
    /// action. Posts `action: backfill_rainfall` to the davis-proxy edge
    /// function which iterates closed days and upserts `rainfall_daily`
    /// using the service-role key. Davis-source rows only — manual
    /// rainfall corrections are preserved server-side.
    @State private var davisBackfillStatus: String?
    @State private var davisBackfillOk: Bool = false
    @State private var isBackfillingDavis: Bool = false
    // MARK: - Weather Underground (vineyard-shared) state
    @State private var wuIntegration: VineyardWeatherIntegration?
    @State private var isLoadingWuIntegration: Bool = false
    @State private var wuStationIdInput: String = ""
    @State private var wuStationNameInput: String = ""
    @State private var wuSaveStatus: String?
    @State private var wuSaveOk: Bool = false
    @State private var isSavingWu: Bool = false
    @State private var wuBackfillStatus: String?
    @State private var wuBackfillOk: Bool = false
    @State private var isBackfillingWu: Bool = false
    @State private var isClearingWu: Bool = false
    @State private var showWuStationPicker: Bool = false
    @State private var showSetupWizard: Bool = false
    // MARK: - Open-Meteo gap fill state
    @State private var isBackfillingOpenMeteo: Bool = false
    @State private var openMeteoBackfillStatus: String?
    @State private var openMeteoBackfillOk: Bool = false
    // MARK: - Build 365-day rainfall history (chunked Davis → WU → Open-Meteo)
    @State private var showBuildHistorySheet: Bool = false

    // MARK: - WillyWeather state
    // The WillyWeather API key is global (server-side env var); we only
    // manage the per-vineyard location selection from iOS now.
    @State private var wwIsTesting: Bool = false
    @State private var wwStatusMessage: String?
    @State private var wwStatusOk: Bool = false
    @State private var wwSearchQuery: String = ""
    @State private var wwSearchResults: [WillyWeatherLocation] = []
    @State private var wwIsSearching: Bool = false
    @State private var wwIntegration: VineyardWeatherIntegration?
    /// Guards the auto-match nearest-WillyWeather flow so it only runs
    /// once per screen load and never overwrites a user-selected location.
    @State private var wwDidAttemptAutoMatch: Bool = false
    @State private var wwIsAutoMatching: Bool = false

    private let integrationRepository: any VineyardWeatherIntegrationRepositoryProtocol
        = SupabaseVineyardWeatherIntegrationRepository()

    private var canEdit: Bool { accessControl.canChangeSettings }
    private var isOperator: Bool { !canEdit }

    enum DavisStatus: Equatable {
        case notConfigured
        case credentialsSavedNotTested
        case testing
        case connectedNoStationSelected
        case connectedNoLeafWetness
        case connectedWithLeafWetness
        case connectionFailed(String)

        var headline: String {
            switch self {
            case .notConfigured: return "Not configured"
            case .credentialsSavedNotTested: return "Credentials saved. Tap Test Connection to verify your WeatherLink account."
            case .testing: return "Testing Davis WeatherLink…"
            case .connectedNoStationSelected: return "Connected — select a station to load sensors."
            case .connectedNoLeafWetness: return "Connected — no leaf wetness sensor detected."
            case .connectedWithLeafWetness: return "Connected — measured leaf wetness available."
            case .connectionFailed(let msg): return msg
            }
        }

        var sensorsDetail: String {
            switch self {
            case .notConfigured:
                return "Save Davis credentials to begin."
            case .credentialsSavedNotTested:
                return "Sensor detection will run once you tap Test Connection."
            case .testing:
                return "Detecting available sensors…"
            case .connectedNoStationSelected:
                return "Pick a station to detect available sensors."
            case .connectedNoLeafWetness, .connectedWithLeafWetness:
                return ""
            case .connectionFailed:
                return "Sensor detection unavailable until the connection succeeds."
            }
        }
    }

    private enum DavisInfoTopic: String, Identifiable {
        case apiKey, apiSecret, stationId
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apiKey: return "Davis API Key"
            case .apiSecret: return "Davis API Secret"
            case .stationId: return "Davis Station ID"
            }
        }
        var body: String {
            switch self {
            case .apiKey:
                return "Davis WeatherLink v2 API details are created from your WeatherLink account page. The API Key identifies your account connection and is safe to display after saving.\n\nTo generate one:\n1. Sign in to weatherlink.com.\n2. Open Account Settings.\n3. Tap ‘Generate v2 Key’.\n4. Copy the API Key into VineTrack."
            case .apiSecret:
                return "The API Secret authorises access to your Davis WeatherLink data. VineTrack stores it as part of this vineyard's shared weather integration so every member uses the same station for rainfall, current conditions and disease risk. Only owners and managers can view or change credentials; operators see the configured station and status without secrets.\n\nGenerate the secret alongside the API Key from Account Settings → Generate v2 Key on weatherlink.com."
            case .stationId:
                return "VineTrack loads stations directly from WeatherLink after a successful Test Connection. If your account has more than one station, you can pick the correct vineyard station from the list. The Station ID is read from the API — you don't need to enter it manually."
            }
        }
    }

    private var vineyardId: UUID? { store.selectedVineyardId }

    var body: some View {
        Form {
            if canEdit { wizardSection }
            headerSection
            if showMigratePrompt && canEdit { migrationPromptSection }
            if let msg = migrationMessage, !msg.isEmpty {
                Section { Text(msg).font(.caption).foregroundStyle(.secondary) }
            }
            currentSourceSection

            forecastSourceSection

            willyWeatherSection

            localObservationSection

            if config.localObservationProvider == .wunderground {
                weatherUndergroundSection
            }

            if config.localObservationProvider == .davis {
                davisSection
                davisHelpSection
            }

            if systemAdmin.isSystemAdmin
                && systemAdmin.isEnabled(SystemFeatureFlagKey.showWeatherDiagnostics) {
                davisDiagnosticsSection
            }

            weatherUndergroundVineyardSection

            if canEdit {
                buildRainfallHistorySection
                openMeteoFallbackSection
            }

            historicalFallbackSection

            usageSection

            if !canEdit {
                Section {
                    Text("Only the vineyard owner or manager can change weather data settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Weather Data & Forecasting")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadConfig()
            if let vid = vineyardId {
                Task { await loadWuIntegration(for: vid) }
                Task {
                    await loadWwIntegration(for: vid)
                    await autoMatchWillyWeatherIfNeeded(for: vid)
                }
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            WeatherSetupWizardView()
                .environment(store)
                .environment(accessControl)
        }
        .sheet(isPresented: $showBuildHistorySheet) {
            IrrigationMissingRainHelperSheet(
                vineyardId: vineyardId,
                rainfallWindowDays: 14,
                onCompleted: {
                    NotificationCenter.default.post(
                        name: .rainfallCalendarShouldReload, object: nil
                    )
                }
            )
            .environment(accessControl)
        }
        .sheet(isPresented: $showStationPicker) {
            WeatherStationPickerSheet()
        }
        .sheet(isPresented: $showWuStationPicker) {
            if let vid = vineyardId {
                WundergroundStationPickerSheet(vineyardId: vid) { stationId, stationName in
                    wuStationIdInput = stationId
                    wuStationNameInput = stationName ?? ""
                    wuSaveOk = true
                    wuSaveStatus = "Weather Underground station saved."
                    Task { await loadWuIntegration(for: vid) }
                }
            }
        }
        .sheet(isPresented: $showDavisStationPicker) {
            DavisStationPickerSheet(
                stations: davisStations,
                selectedStationId: config.davisStationId
            ) { station in
                showDavisStationPicker = false
                Task { await selectDavisStation(station) }
            }
        }
        .confirmationDialog(
            "Clear cached Davis rainfall data?",
            isPresented: $showClearDavisCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                clearDavisRainfallCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove saved rainfall totals from this device. The Rainfall Calendar will refetch local station data next time it loads.")
        }
        .sheet(item: $davisInfoTopic) { topic in
            NavigationStack {
                ScrollView {
                    Text(topic.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(topic.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { davisInfoTopic = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func infoButton(_ topic: DavisInfoTopic) -> some View {
        Button {
            davisInfoTopic = topic
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(topic.title)")
    }

    // MARK: - Sections

    private var wizardSection: some View {
        Section {
            Button {
                showSetupWizard = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run Weather Setup Wizard")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Guided setup for Davis, Weather Underground and rainfall history")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var headerSection: some View {
        Section {
            Text("VineTrack uses weather data for irrigation advice, spray records, disease risk alerts and weather warnings. The app works automatically using forecast data, but you can connect a local weather station for more accurate vineyard conditions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var migrationPromptSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 32, height: 32)
                        .background(Color.orange.opacity(0.15), in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Move Davis WeatherLink setup to this vineyard?")
                            .font(.subheadline.weight(.semibold))
                        Text("This device has Davis credentials, but they are not yet shared with other vineyard members. Move them to the vineyard so every member sees the same rainfall, station and disease-risk data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button {
                        Task { await runMigrationToVineyard() }
                    } label: {
                        HStack {
                            if isMigrating { ProgressView().controlSize(.small) }
                            Text(isMigrating ? "Moving…" : "Move to vineyard")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(isMigrating)

                    Button("Not now") { showMigratePrompt = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Vineyard sharing")
        }
    }

    private var currentSourceSection: some View {
        let status = currentStatus
        return Section {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: status.provider.symbol, color: providerColor(status.provider))
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.primaryLabel)
                        .font(.subheadline.weight(.semibold))
                    Text(status.detailLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            LabeledContent("Data quality") {
                Text(status.quality.displayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Last update") {
                Text(status.lastUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Current Data Source")
        } footer: {
            Text("If this source is unavailable, VineTrack will use the default forecast.")
        }
    }

    // MARK: - Forecast Source

    private var forecastSourceSection: some View {
        Section {
            ForEach(ForecastProvider.allCases) { provider in
                Button {
                    guard canEdit else { return }
                    var c = config
                    c.forecastProvider = provider
                    config = c
                    persist()
                    Task { await syncForecastProviderToBackend(provider) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        SettingsIconTile(symbol: provider.symbol, color: forecastProviderColor(provider))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(provider.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if provider == .auto {
                                    Text("Default")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15), in: .capsule)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(provider.helpCopy)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        if config.forecastProvider == provider {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
            }
        } header: {
            Text("Forecast Source")
        } footer: {
            Text("Forecast rainfall, ET, temperature, wind and irrigation forecast. Auto uses WillyWeather when configured for this vineyard, otherwise Open-Meteo.")
        }
    }

    private func forecastProviderColor(_ provider: ForecastProvider) -> Color {
        switch provider {
        case .auto: return .green
        case .openMeteo: return .blue
        case .willyWeather: return .orange
        }
    }

    // MARK: - WillyWeather configuration

    private var willyWeatherSection: some View {
        Section {
            // Status row.
            HStack(alignment: .top, spacing: 12) {
                SettingsIconTile(symbol: "sun.rain.fill", color: .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(wwStatusHeadline)
                        .font(.subheadline.weight(.semibold))
                    Text(wwStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            // Location row — WillyWeather is globally available; users only
            // pick the location for their vineyard.
            do {
                if let locName = config.willyWeatherLocationName, !locName.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(locName).font(.subheadline.weight(.semibold))
                            if let id = config.willyWeatherLocationId {
                                Text("ID \(id)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if canEdit {
                            Button("Change") { Task { await searchNearbyWillyWeather() } }
                                .buttonStyle(.borderless)
                        }
                    }
                } else if canEdit {
                    Button {
                        Task { await searchNearbyWillyWeather() }
                    } label: {
                        Label("Find nearest WillyWeather location", systemImage: "location.magnifyingglass")
                    }
                }
            }

            // Location search results.
            if !wwSearchResults.isEmpty {
                ForEach(wwSearchResults) { loc in
                    Button {
                        Task { await selectWillyWeatherLocation(loc) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.name).font(.subheadline.weight(.semibold))
                                let detail = [loc.region, loc.state, loc.postcode].compactMap { $0 }.joined(separator: " · ")
                                if !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let km = loc.distanceKm {
                                Text(String(format: "%.1f km", km))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if config.willyWeatherLocationId == loc.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Search field.
            if canEdit {
                HStack {
                    TextField("Search by suburb or postcode", text: $wwSearchQuery)
                        .textInputAutocapitalization(.words)
                    Button {
                        Task { await searchWillyWeather(query: wwSearchQuery) }
                    } label: {
                        if wwIsSearching {
                            ProgressView()
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(wwIsSearching || wwSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            // Test + remove.
            if canEdit {
                HStack(spacing: 12) {
                    Button {
                        Task { await testWillyWeatherConnection() }
                    } label: {
                        if wwIsTesting {
                            ProgressView()
                        } else {
                            Label("Test Connection", systemImage: "checkmark.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(wwIsTesting)

                    if config.willyWeatherLocationId != nil {
                        Button(role: .destructive) {
                            Task { await deleteWillyWeather() }
                        } label: {
                            Label("Remove Location", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let msg = wwStatusMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(wwStatusOk ? .green : .red)
            }
        } header: {
            Text("WillyWeather")
        } footer: {
            Text("WillyWeather is an Australian forecast service backed by the Bureau of Meteorology. VineTrack provides the API key — just pick the nearest WillyWeather location for this vineyard. Used when Forecast Source is set to Auto (with a location selected) or WillyWeather.")
        }
    }

    private var wwStatusHeadline: String {
        if config.willyWeatherLocationId == nil { return "Pick a WillyWeather location" }
        if let err = config.willyWeatherLastTestError, !err.isEmpty { return err }
        return "Connected"
    }

    private var wwStatusDetail: String {
        if config.willyWeatherLocationId == nil {
            return "Search by suburb/postcode, or use ‘Find nearest’ to use your vineyard coordinates. The WillyWeather API key is managed by VineTrack."
        }
        if let date = config.willyWeatherLastTestSuccess {
            return "Last verified \(date.formatted(.relative(presentation: .named)))."
        }
        return "Forecasts will route through WillyWeather when enabled."
    }

    // MARK: - WillyWeather actions

    private func testWillyWeatherConnection() async {
        guard let vid = vineyardId else { return }
        wwIsTesting = true
        defer { wwIsTesting = false }
        do {
            let ok = try await VineyardWillyWeatherProxyService.testConnection(vineyardId: vid)
            wwStatusOk = ok
            wwStatusMessage = ok ? "Connection OK." : "Connection failed."
            var c = config
            if ok {
                c.willyWeatherLastTestSuccess = Date()
                c.willyWeatherLastTestError = nil
            } else {
                c.willyWeatherLastTestError = "Connection failed"
            }
            config = c
            persist()
        } catch {
            wwStatusOk = false
            wwStatusMessage = error.localizedDescription
        }
    }

    private func searchWillyWeather(query: String) async {
        guard let vid = vineyardId else { return }
        wwIsSearching = true
        defer { wwIsSearching = false }
        do {
            wwSearchResults = try await VineyardWillyWeatherProxyService
                .searchLocations(vineyardId: vid, query: query)
            if wwSearchResults.isEmpty {
                wwStatusOk = false
                wwStatusMessage = "No locations found for ‘\(query)’."
            } else {
                wwStatusMessage = nil
            }
        } catch {
            wwStatusOk = false
            wwStatusMessage = error.localizedDescription
        }
    }

    private func searchNearbyWillyWeather() async {
        guard let vid = vineyardId else { return }
        let (lat, lon) = vineyardCentroid(for: vid)
        wwIsSearching = true
        defer { wwIsSearching = false }
        do {
            let result = try await VineyardWillyWeatherProxyService
                .searchLocationsDetailed(
                    vineyardId: vid, query: nil, lat: lat, lon: lon
                )
            wwSearchResults = result.locations
            if wwSearchResults.isEmpty {
                wwStatusOk = false
                if result.reason == "no_nearest_match" {
                    wwStatusMessage = "We couldn’t automatically find a WillyWeather forecast location near this vineyard. Search for the nearest town manually."
                } else {
                    wwStatusMessage = "No nearby locations found. Try searching by suburb."
                }
            } else {
                wwStatusMessage = nil
            }
        } catch {
            wwStatusOk = false
            wwStatusMessage = error.localizedDescription
        }
    }

    /// Compute the vineyard centroid from all paddocks with polygon
    /// points. Returns `(nil, nil)` if no paddocks have geometry.
    private func vineyardCentroid(for vid: UUID) -> (Double?, Double?) {
        let paddocks = store.paddocks.filter { $0.vineyardId == vid && !$0.polygonPoints.isEmpty }
        var lats: [Double] = []
        var lons: [Double] = []
        for p in paddocks {
            let n = Double(p.polygonPoints.count)
            guard n > 0 else { continue }
            lats.append(p.polygonPoints.map(\.latitude).reduce(0, +) / n)
            lons.append(p.polygonPoints.map(\.longitude).reduce(0, +) / n)
        }
        guard !lats.isEmpty else { return (nil, nil) }
        let lat = lats.reduce(0, +) / Double(lats.count)
        let lon = lons.reduce(0, +) / Double(lons.count)
        return (lat, lon)
    }

    /// Auto-match the nearest WillyWeather forecast location from the
    /// vineyard GPS centre. Runs at most once per screen load and never
    /// overwrites an existing user-selected location.
    private func autoMatchWillyWeatherIfNeeded(for vid: UUID) async {
        guard !wwDidAttemptAutoMatch else { return }
        // Only owner/manager can change shared vineyard config.
        guard canEdit else { return }
        // Only relevant when provider is auto or willyweather.
        let provider = config.forecastProvider
        guard provider == .auto || provider == .willyWeather else { return }
        // Skip if a location is already saved for this vineyard.
        if let id = config.willyWeatherLocationId, !id.isEmpty { return }
        let (lat, lon) = vineyardCentroid(for: vid)
        guard let lat, let lon else { return }

        wwDidAttemptAutoMatch = true
        wwIsAutoMatching = true
        defer { wwIsAutoMatching = false }
        do {
            let result = try await VineyardWillyWeatherProxyService
                .searchLocationsDetailed(
                    vineyardId: vid, query: nil, lat: lat, lon: lon
                )
            guard let best = result.locations.first else {
                wwStatusOk = false
                if result.reason == "no_nearest_match" {
                    wwStatusMessage = "We couldn’t automatically find a WillyWeather forecast location near this vineyard. Search for the nearest town manually."
                }
                print("[WillyWeatherProxy] auto-match vineyardId=\(vid) result=empty reason=\(result.reason ?? "-")")
                return
            }
            // Re-check guard: do not overwrite if the user picked a
            // location while the request was in flight.
            if let existing = config.willyWeatherLocationId, !existing.isEmpty { return }
            try await VineyardWillyWeatherProxyService.setLocation(
                vineyardId: vid, location: best
            )
            var c = config
            c.willyWeatherLocationId = best.id
            c.willyWeatherLocationName = best.name
            config = c
            persist()
            wwSearchResults = []
            wwSearchQuery = ""
            wwStatusOk = true
            wwStatusMessage = "Nearest WillyWeather forecast location matched from vineyard GPS centre."
            print("[WillyWeatherProxy] auto-match vineyardId=\(vid) result=ok location=\(best.name) id=\(best.id)")
        } catch {
            wwStatusOk = false
            wwStatusMessage = error.localizedDescription
            print("[WillyWeatherProxy] auto-match vineyardId=\(vid) result=fail error=\(error.localizedDescription)")
        }
    }

    private func selectWillyWeatherLocation(_ loc: WillyWeatherLocation) async {
        guard let vid = vineyardId else { return }
        do {
            try await VineyardWillyWeatherProxyService.setLocation(vineyardId: vid, location: loc)
            var c = config
            c.willyWeatherLocationId = loc.id
            c.willyWeatherLocationName = loc.name
            config = c
            persist()
            wwSearchResults = []
            wwSearchQuery = ""
            wwStatusOk = true
            wwStatusMessage = "Location set to \(loc.name)."
        } catch {
            wwStatusOk = false
            wwStatusMessage = error.localizedDescription
        }
    }

    private func mapBackendForecastProvider(_ raw: String) -> ForecastProvider? {
        switch raw {
        case "auto": return .auto
        case "open_meteo": return .openMeteo
        case "willyweather": return .willyWeather
        default: return nil
        }
    }

    private func backendForecastProviderString(_ p: ForecastProvider) -> String {
        switch p {
        case .auto: return "auto"
        case .openMeteo: return "open_meteo"
        case .willyWeather: return "willyweather"
        }
    }

    private func syncForecastProviderToBackend(_ provider: ForecastProvider) async {
        guard canEdit, let vid = vineyardId else { return }
        do {
            try await VineyardWillyWeatherProxyService.setProviderPreference(
                vineyardId: vid,
                provider: backendForecastProviderString(provider)
            )
            print("[ForecastProvider] sync vineyardId=\(vid) provider=\(provider.rawValue) result=ok")
        } catch {
            print("[ForecastProvider] sync failed vineyardId=\(vid) provider=\(provider.rawValue) error=\(error.localizedDescription)")
        }
    }

    private func deleteWillyWeather() async {
        guard let vid = vineyardId else { return }
        do {
            try await VineyardWillyWeatherProxyService.delete(vineyardId: vid)
            var c = config
            c.willyWeatherHasApiKey = true // key is global, always available
            c.willyWeatherLocationId = nil
            c.willyWeatherLocationName = nil
            c.willyWeatherLastTestSuccess = nil
            c.willyWeatherLastTestError = nil
            if c.forecastProvider == .willyWeather { c.forecastProvider = .auto }
            config = c
            persist()
            wwSearchResults = []
            wwSearchQuery = ""
            wwStatusOk = true
            wwStatusMessage = "WillyWeather location removed for this vineyard."
        } catch {
            wwStatusOk = false
            wwStatusMessage = error.localizedDescription
        }
    }

    // MARK: - Local Observation Source (user-selectable role)

    private var localObservationSection: some View {
        Section {
            ForEach(LocalObservationProvider.allCases) { provider in
                Button {
                    guard canEdit else { return }
                    var c = config
                    c.localObservationProvider = provider
                    config = c
                    persist()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        SettingsIconTile(symbol: provider.symbol, color: localProviderColor(provider))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(provider.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if provider == .none {
                                    Text("Default")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15), in: .capsule)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(provider.helpCopy)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        if config.localObservationProvider == provider {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
            }
        } header: {
            Text("Local Observation Source")
        } footer: {
            Text("Used for actual rainfall, local station readings and measured leaf wetness where available. Forecasts still use Open-Meteo regardless of this choice.")
        }
    }

    // MARK: - Historical Fallback (read-only role)

    private var historicalFallbackSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconTile(symbol: HistoricalFallbackProvider.openMeteoArchive.symbol, color: .gray)
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.historicalFallbackProvider.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(config.historicalFallbackProvider.helpCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("No setup required.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Historical Fallback")
        } footer: {
            Text("Used for the Rainfall Calendar's older periods and as a fallback when local station history is unavailable.")
        }
    }

    private var weatherUndergroundSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: "antenna.radiowaves.left.and.right", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected station")
                        .font(.subheadline.weight(.medium))
                    Text(store.settings.weatherStationId?.isEmpty == false ? store.settings.weatherStationId! : "Auto / nearest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button {
                showStationPicker = true
            } label: {
                Label("Select Nearby Station", systemImage: "location.magnifyingglass")
            }
            .disabled(!canEdit)

            if store.settings.weatherStationId?.isEmpty == false {
                Button(role: .destructive) {
                    var s = store.settings
                    s.weatherStationId = nil
                    store.updateSettings(s)
                } label: {
                    Label("Clear / Use Nearest", systemImage: "xmark.circle")
                }
                .disabled(!canEdit)
            }
        } header: {
            Text("Weather Underground")
        } footer: {
            Text("Pick a Personal Weather Station near your vineyard. If the station is offline, VineTrack falls back to the default forecast.")
        }
    }

    private var davisSection: some View {
        let savedAndNotEditing = config.davisHasCredentials && !isEditingDavisCredentials
        // The vineyard already has a server-side secret — no need for
        // local Keychain credentials on this device. Reads go through
        // the davis-proxy Edge Function for everyone.
        let vineyardHasServerCreds = config.davisIsVineyardShared
            && config.davisVineyardHasServerCredentials
        let hasOrphanStation = !config.davisHasCredentials
            && !vineyardHasServerCreds
            && ((config.davisStationName?.isEmpty == false)
                || (config.davisStationId?.isEmpty == false))

        // TODO: Vineyard-shared weather station connections can be added later
        // using encrypted/server-side credential storage. For now Davis API
        // Key & API Secret live only in this device's iOS Keychain and are
        // never written to Supabase or vineyard settings.

        return Section {
            // Privacy / per-device notice
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(canEdit
                    ? "Davis WeatherLink is configured for this vineyard. Owners and managers can manage the station connection. All vineyard users use the same weather source for consistent rainfall and disease-risk data."
                    : "Davis WeatherLink is managed by your vineyard owner or manager. You can see the selected station and source status, but cannot view or change credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Orphan station — station metadata exists but no credentials on
            // this device (e.g. signed in on a new device, or another team
            // member). Surface a clear, actionable state.
            if hasOrphanStation {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "key.slash")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 32, height: 32)
                            .background(Color.orange.opacity(0.15), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Davis station was previously selected, but credentials are not saved on this device.")
                                .font(.subheadline.weight(.semibold))
                            if let name = config.davisStationName, !name.isEmpty {
                                Text("Last station: \(name)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Enter your Davis API Key and Secret below to reconnect on this device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    Button {
                        isEditingDavisCredentials = true
                    } label: {
                        Label("Enter Davis credentials", systemImage: "key.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(!canEdit)
                }
                .padding(.vertical, 4)
            }

            // Vineyard-shared status card — visible to owner/manager when
            // the vineyard already has a stored Davis secret on the
            // server (no local Keychain required on this device).
            if vineyardHasServerCreds && canEdit && !isEditingDavisCredentials {
                vineyardSharedStatusCard
            } else if savedAndNotEditing && canEdit {
                // Legacy local-only saved card (per-device Keychain).
                savedStatusCard
            }

            // For operators, surface the configured station and basic
            // status only — never the API key/secret or test/edit
            // controls. Reads still go through the davis-proxy edge
            // function under the hood.
            if !canEdit {
                operatorReadOnlyDavisCard
            } else {
                ownerEditableDavisControls
            }
        } header: {
            Text("Davis WeatherLink")
        } footer: {
            Text(canEdit
                ? "Credentials are stored as part of this vineyard's shared weather integration. All members use the same station; only owners and managers can change them."
                : "All vineyard members use the same Davis station via a secure server-side connection. Owners and managers can change credentials.")
        }
    }

    @ViewBuilder
    private var operatorReadOnlyDavisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                    .frame(width: 32, height: 32)
                    .background(Color.indigo.opacity(0.12), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Davis WeatherLink is configured for this vineyard.")
                        .font(.subheadline.weight(.semibold))
                    Text("Managed by your owner or manager.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let name = config.davisStationName, !name.isEmpty {
                LabeledContent("Station") {
                    Text(name).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let sid = config.davisStationId, !sid.isEmpty {
                LabeledContent("Station") {
                    Text("Station \(sid)").foregroundStyle(.secondary)
                }
            }
            if !config.davisDetectedSensors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detected sensors")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(config.davisDetectedSensors, id: \.self) { sensor in
                        Label(sensor, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            if config.davisHasLeafWetnessSensor {
                Label("Measured leaf wetness available", systemImage: "drop.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Text("Actual rainfall source: Davis WeatherLink\((config.davisStationName?.isEmpty == false) ? " — \(config.davisStationName!)" : "")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var ownerEditableDavisControls: some View {
        let savedAndNotEditing = config.davisHasCredentials && !isEditingDavisCredentials
        Group {
            // API Key row
            HStack {
                Text("API Key")
                infoButton(.apiKey)
                Spacer()
                if savedAndNotEditing {
                    HStack(spacing: 6) {
                        Text("••••••••")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Saved")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: .capsule)
                            .foregroundStyle(.green)
                    }
                } else {
                    TextField("Davis API Key", text: $davisApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220)
                }
            }

            // API Secret row
            HStack {
                Text("API Secret")
                infoButton(.apiSecret)
                Spacer()
                if savedAndNotEditing {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Saved securely")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: .capsule)
                            .foregroundStyle(.green)
                    }
                } else {
                    Group {
                        if showSecret {
                            TextField("Davis API Secret", text: $davisApiSecret)
                        } else {
                            SecureField("Davis API Secret", text: $davisApiSecret)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
                    Button {
                        showSecret.toggle()
                    } label: {
                        Image(systemName: showSecret ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Station selection — enabled once we've successfully tested
            // the connection and have at least one station available.
            if config.davisHasCredentials,
               config.davisConnectionTested,
               !(config.davisAvailableStations.isEmpty && davisStations.isEmpty) {
                Button {
                    showDavisStationPicker = true
                } label: {
                    HStack {
                        Label("Selected station", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(currentStationLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(!canEdit)
            } else if config.davisHasCredentials, config.davisConnectionTested {
                // Connection tested but no station picked yet — emphasise.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Selected station", systemImage: "antenna.radiowaves.left.and.right")
                        infoButton(.stationId)
                        Spacer()
                        Text("Station required")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                    Text("Choose which Davis station VineTrack should use for rainfall, current conditions and leaf wetness.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        showDavisStationPicker = true
                    } label: {
                        Label("Choose station", systemImage: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(!canEdit || (config.davisAvailableStations.isEmpty && davisStations.isEmpty))
                }
            } else {
                HStack {
                    Text("Station selection")
                    infoButton(.stationId)
                    Spacer()
                    Text("Run Test Connection")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: .capsule)
                }
            }

            // Save / Replace / Cancel actions
            if savedAndNotEditing {
                Button {
                    beginReplaceCredentials()
                } label: {
                    Label("Replace Credentials", systemImage: "square.and.pencil")
                }
                .disabled(!canEdit)
            } else {
                Button {
                    saveDavisCredentials()
                } label: {
                    Label("Save Credentials", systemImage: "lock.shield")
                }
                .disabled(!canEdit || davisApiKey.isEmpty || davisApiSecret.isEmpty)

                if isEditingDavisCredentials {
                    Button {
                        cancelReplaceCredentials()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
            }

            // Test Connection — live
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await testDavisConnection() }
                } label: {
                    HStack {
                        if isTestingDavis {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal")
                        }
                        Text(isTestingDavis ? "Testing…" : "Test Connection")
                        Spacer()
                    }
                }
                .disabled(!canEdit || !config.davisHasCredentials || isTestingDavis)
                if let msg = davisTestMessage, !msg.isEmpty {
                    let needsStation = davisTestSucceeded
                        && config.davisConnectionTested
                        && (config.davisStationId ?? "").isEmpty
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(needsStation ? .orange : (davisTestSucceeded ? .green : .secondary))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Verifies your WeatherLink account and loads available stations.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if config.davisHasCredentials {
                Button {
                    showClearDavisCacheConfirm = true
                } label: {
                    Label("Clear Davis rainfall cache", systemImage: "arrow.clockwise.icloud")
                }
                .disabled(!canEdit)
                if let msg = davisCacheClearedMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                Button(role: .destructive) {
                    clearDavisCredentials()
                } label: {
                    Label("Remove Credentials", systemImage: "trash")
                }
                .disabled(!canEdit)
            }

            // Detected sensors
            VStack(alignment: .leading, spacing: 8) {
                Text("Detected sensors")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                let status = davisStatus
                switch status {
                case .connectedNoLeafWetness, .connectedWithLeafWetness:
                    if config.davisDetectedSensors.isEmpty {
                        Text("No sensors detected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(config.davisDetectedSensors, id: \.self) { sensor in
                            Label(sensor, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    if status == .connectedWithLeafWetness {
                        Label("Measured leaf wetness available", systemImage: "drop.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Label("No leaf wetness sensor detected — using estimated wetness", systemImage: "drop")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .credentialsSavedNotTested:
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Not tested yet", systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Tap Test Connection to detect available sensors.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .connectedNoStationSelected:
                    Label("Select a station to detect sensors", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    Text(status.sensorsDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var vineyardSharedStatusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "icloud.and.arrow.down.fill")
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 32, height: 32)
                .background(Color.indigo.opacity(0.12), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected via vineyard-shared credentials")
                    .font(.subheadline.weight(.semibold))
                Text("This vineyard's Davis API secret is stored securely on the server. You don't need to re-enter credentials on this device — rainfall, current conditions and leaf wetness are fetched through a secure proxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let name = config.davisStationName, !name.isEmpty {
                    Text("Station: \(name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var savedStatusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .background(Color.green.opacity(0.12), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("Credentials saved securely on this device")
                    .font(.subheadline.weight(.semibold))
                Text("Live WeatherLink connection is not enabled yet, so these credentials have not been tested.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // Non-secret debug/status panel. Always visible so field testers can
    // verify Davis configuration without Xcode logs. NEVER includes the
    // api_key or api_secret values — only booleans and metadata.
    private var davisDiagnosticsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                diagRow("Vineyard ID", vineyardId?.uuidString ?? "—")
                diagRow("Provider", "davis_weatherlink")
                diagRow("Configured", (vineyardIntegration?.isFullyConfigured == true) ? "Yes" : "No")
                diagRow("Has API key", vineyardIntegration?.hasApiKey == true ? "Yes" : "No")
                diagRow("Has API secret", vineyardIntegration?.hasApiSecret == true ? "Yes" : "No")
                diagRow("Station ID", vineyardIntegration?.stationId ?? "—")
                diagRow("Station name", vineyardIntegration?.stationName ?? "—")
                diagRow("Last tested", vineyardIntegration?.lastTestedAt.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "—")
                diagRow("Last test status", vineyardIntegration?.lastTestStatus ?? "—")
                diagRow("Caller role", vineyardIntegration?.callerRole ?? "—")
                diagRow("Source", isLoadingVineyardIntegration
                        ? "Loading…"
                        : (vineyardIntegrationError == nil
                           ? "Supabase RPC"
                           : "Local fallback (\(vineyardIntegrationError ?? "error"))"))
                diagRow("Local provider", config.localObservationProvider.rawValue)
                diagRow("Vineyard-shared flag", config.davisIsVineyardShared ? "Yes" : "No")
                diagRow("Has server creds flag", config.davisVineyardHasServerCredentials ? "Yes" : "No")
                diagRow("Has local Keychain", WeatherKeychain.hasCredentials ? "Yes" : "No")
            }
            .font(.caption.monospaced())

            // Parser-level diagnostics: helps diagnose "no wind / no temp"
            // cases where the station physically supports the sensor but
            // data[] arrays are empty in the live response.
            if let summary = lastDavisSensorSummary {
                Divider().padding(.vertical, 2)
                Text("Parser detection")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    diagRow("Sensor blocks", "\(summary.sensorBlockCount)")
                    diagRow("Empty data blocks", "\(summary.emptyDataBlockCount)")
                    diagRow("Sensor types", summary.detectedSensorTypes.map(String.init).joined(separator: ", ").nilIfEmpty ?? "—")
                    diagRow("Data structure types", summary.detectedDataStructureTypes.map(String.init).joined(separator: ", ").nilIfEmpty ?? "—")
                    diagRow("Block summaries", summary.blockSummaries.joined(separator: " | ").nilIfEmpty ?? "—")
                    diagRow("Detected fields", "\(summary.detectedFields.count) field(s)")
                    diagRow("Has T/H sensor", summary.hasTemperatureHumidity ? "Yes" : "No")
                    diagRow("Has wind sensor", summary.hasWind ? "Yes" : "No")
                    diagRow("Has rain sensor", summary.hasRain ? "Yes" : "No")
                    diagRow("Has leaf wetness", summary.hasLeafWetness ? "Yes" : "No")
                    diagRow("Has soil moisture", summary.hasSoilMoisture ? "Yes" : "No")
                    if let cur = lastDavisCurrent {
                        diagRow("Current temp value", cur.temperatureC != nil ? "Available" : "Unavailable")
                        diagRow("Current humidity value", cur.humidityPercent != nil ? "Available" : "Unavailable")
                        diagRow("Current wind value", cur.windKph != nil ? "Available" : "Unavailable")
                        diagRow("Current rain value", cur.rainMmLastHour != nil ? "Available" : "Unavailable")
                    }
                }
                .font(.caption.monospaced())
            } else {
                Text("Run Test Connection or refresh current conditions to populate parser diagnostics.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                guard let vid = vineyardId else { return }
                Task {
                    await VineyardWeatherIntegrationCache.shared.refresh(for: vid)
                    await loadVineyardIntegration(for: vid)
                }
            } label: {
                Label("Reload from server", systemImage: "arrow.clockwise")
            }
            // User-facing way to force a real davis-proxy `action: current`
            // fetch from the field. Works for any vineyard member as long
            // as the vineyard has a configured Davis station (the edge
            // function enforces membership and uses the service-role key
            // server-side to update vineyard_weather_observations and
            // rainfall_daily). Owners/managers without a vineyard-shared
            // integration can still use their local Keychain path via
            // `refreshDavisParserDiagnostics()`.
            Button {
                Task { await forceRefreshDavisCurrent() }
            } label: {
                if isForceRefreshingDavis {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing Davis…")
                    }
                } else {
                    Label("Refresh Davis now", systemImage: "arrow.triangle.2.circlepath.cloud")
                }
            }
            .disabled(isForceRefreshingDavis
                      || (config.davisStationId?.isEmpty ?? true)
                      || (vineyardId == nil)
                      || (!config.davisVineyardHasServerCredentials && !config.davisHasCredentials))
            if let msg = davisForceRefreshStatus, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(davisForceRefreshOk ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Owner/Manager-only: backfill recent Davis rainfall into
            // rainfall_daily so the Rain Calendar has useful history
            // instead of only today's row. Safe and non-destructive —
            // updates Davis-source rows only and never overwrites
            // manual rainfall corrections (the server-side
            // `upsert_davis_rainfall_daily` RPC enforces this).
            if canEdit {
                Button {
                    Task { await backfillDavisRainfall() }
                } label: {
                    if isBackfillingDavis {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Backfilling Davis rainfall…")
                        }
                    } else {
                        Label("Backfill Davis rainfall", systemImage: "calendar.badge.clock")
                    }
                }
                .disabled(isBackfillingDavis
                          || (config.davisStationId?.isEmpty ?? true)
                          || (vineyardId == nil)
                          || (!config.davisVineyardHasServerCredentials && !config.davisHasCredentials))
                if let msg = davisBackfillStatus, !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(davisBackfillOk ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Imports the last 14 days of Davis rainfall into vineyard history. Safe to re-run — manual rainfall corrections are preserved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await refreshDavisParserDiagnostics() }
            } label: {
                Label("Refresh parser detection", systemImage: "sensor.tag.radiowaves.forward")
            }
            .disabled((config.davisStationId?.isEmpty ?? true)
                      || isTestingDavis
                      || (!config.davisHasCredentials
                          && !(config.davisIsVineyardShared
                               && config.davisVineyardHasServerCredentials)))
            Button {
                copyDavisDiagnostics()
            } label: {
                Label("Copy Davis diagnostics", systemImage: "doc.on.doc")
            }
            if let msg = diagCopiedMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Davis diagnostics")
        } footer: {
            Text("Non-secret status only. Used to verify Davis WeatherLink persistence and parser detection in the field. API key, secret and credential-bearing URLs are never shown, copied or logged.")
        }
    }

    // MARK: - WillyWeather debug (system-admin flag gated)

    /// Non-secret WillyWeather integration debug panel. Hidden by default;
    /// shown only when the system admin enables `show_willyweather_debug`.
    /// Never exposes the server-side API key — only per-vineyard status.
    private var willyWeatherDebugSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                diagRow("Vineyard ID", vineyardId?.uuidString ?? "—")
                diagRow("Location ID", config.willyWeatherLocationId ?? "—")
                diagRow("Location name", config.willyWeatherLocationName ?? "—")
                diagRow("Last test success", config.willyWeatherLastTestSuccess.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "—")
                diagRow("Last test error", config.willyWeatherLastTestError ?? "—")
                diagRow("Auto-match attempted", wwDidAttemptAutoMatch ? "Yes" : "No")
                diagRow("Auto-matching now", wwIsAutoMatching ? "Yes" : "No")
                diagRow("Search results loaded", "\(wwSearchResults.count)")
                diagRow("Integration row", wwIntegration == nil ? "—" : "present")
            }
            .font(.caption.monospaced())
        } header: {
            Text("WillyWeather debug")
        } footer: {
            Text("Non-secret status only. The WillyWeather API key lives server-side in Supabase secrets and is never exposed to the client.")
        }
    }

    // MARK: - Build 365-day rainfall history

    private var buildRainfallHistorySection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.subheadline)
                    .foregroundStyle(.indigo)
                    .frame(width: 22)
                Text("Build up to 365 days of rainfall history using the best available sources. VineTrack will try Davis first, then Weather Underground, then Open-Meteo for remaining gaps. Manual records are never overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Button {
                showBuildHistorySheet = true
            } label: {
                Label("Build 365-day rainfall history", systemImage: "cloud.rain.fill")
            }
            .disabled(vineyardId == nil)

            Text("Runs Davis (60-day chunks) → Weather Underground (30-day chunks) → Open-Meteo gap fill. Open-Meteo only fills days still missing after Manual, Davis and Weather Underground records. Resume support is preserved if a station source is rate-limited.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Build rainfall history")
        } footer: {
            Text("Use this for full historical fill. The 14-day quick backfill buttons above are still available for fast top-ups during setup.")
        }
    }

    // MARK: - Open-Meteo fallback (gap fill)

    private var openMeteoFallbackSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tray.full.fill")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .frame(width: 22)
                Text("Open-Meteo fills missing rainfall days only. It will not replace Manual, Davis or Weather Underground records.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Button {
                Task { await backfillOpenMeteoRainfall() }
            } label: {
                if isBackfillingOpenMeteo {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Filling rainfall gaps from Open-Meteo…")
                    }
                } else {
                    Label("Fill remaining rainfall gaps from Open-Meteo", systemImage: "calendar.badge.plus")
                }
            }
            .disabled(isBackfillingOpenMeteo || vineyardId == nil)

            if let msg = openMeteoBackfillStatus, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(openMeteoBackfillOk ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Default range: last 365 days. Today and yesterday are skipped because the archive is incomplete. Safe to re-run.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Open-Meteo fallback")
        } footer: {
            Text("Lowest priority rainfall source. Manual → Davis → Weather Underground → Open-Meteo. Only days with no better source are filled.")
        }
    }

    private func backfillOpenMeteoRainfall() async {
        guard canEdit else {
            openMeteoBackfillStatus = "Owner or manager role required."
            openMeteoBackfillOk = false
            return
        }
        guard let vid = vineyardId else {
            openMeteoBackfillStatus = "No vineyard selected."
            openMeteoBackfillOk = false
            return
        }
        isBackfillingOpenMeteo = true
        openMeteoBackfillStatus = nil
        defer { isBackfillingOpenMeteo = false }
        print("[OpenMeteoProxy] backfill requested vineyardId=\(vid) days=365")
        do {
            let result = try await VineyardOpenMeteoProxyService.backfillRainfallGaps(
                vineyardId: vid, days: 365, timezone: TimeZone.current.identifier
            )
            var lines: [String] = []
            lines.append(result.success
                ? "Open-Meteo gap fill complete."
                : "Open-Meteo gap fill finished with errors.")
            lines.append("Days requested: \(result.daysRequested). Processed: \(result.daysProcessed). Rows upserted: \(result.rowsUpserted). Skipped (better source): \(result.daysSkippedBetterSource). Skipped (no data): \(result.daysSkippedNoData). Errors: \(result.errorsCount).")
            if let src = result.coordsSource, !src.isEmpty {
                lines.append("Coordinates source: \(src).")
            }
            if let v = result.proxyVersion, !v.isEmpty {
                lines.append("Proxy version: \(v).")
            }
            openMeteoBackfillStatus = lines.joined(separator: " ")
            openMeteoBackfillOk = result.success
            if result.rowsUpserted > 0 {
                NotificationCenter.default.post(
                    name: .rainfallCalendarShouldReload, object: nil
                )
            }
        } catch let error as VineyardOpenMeteoProxyError {
            openMeteoBackfillOk = false
            openMeteoBackfillStatus = "Open-Meteo gap fill failed — \(error.errorDescription ?? "unknown error")"
            print("[OpenMeteoProxy] backfill failed vineyardId=\(vid) reason=\(error.errorDescription ?? "-")")
        } catch {
            openMeteoBackfillOk = false
            openMeteoBackfillStatus = "Open-Meteo gap fill failed — \(error.localizedDescription)"
            print("[OpenMeteoProxy] backfill failed vineyardId=\(vid) reason=\(error.localizedDescription)")
        }
    }

    // MARK: - Weather Underground (vineyard-shared)

    private var weatherUndergroundVineyardSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                Text("Uses platform Weather Underground connection. Owners and managers can set the vineyard's PWS station ID. Rainfall is backfilled into vineyard history server-side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if !canEdit {
                wuOperatorReadOnlyCard
            } else {
                wuOwnerEditableControls
            }
        } header: {
            Text("Weather Underground")
        } footer: {
            Text("Manual entries override Davis. Davis overrides Weather Underground. Weather Underground overrides Open-Meteo. Backfill only writes Weather Underground rows — Manual and Davis rows are never overwritten.")
        }
    }

    @ViewBuilder
    private var wuOperatorReadOnlyCard: some View {
        let sid = wuIntegration?.stationId ?? ""
        let name = wuIntegration?.stationName ?? ""
        VStack(alignment: .leading, spacing: 6) {
            if sid.isEmpty {
                Label("No Weather Underground station configured", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Station ID") {
                    Text(sid).foregroundStyle(.secondary)
                }
                if !name.isEmpty {
                    LabeledContent("Station name") {
                        Text(name).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text("Managed by your owner or manager.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var wuOwnerEditableControls: some View {
        let savedStationId = wuIntegration?.stationId ?? ""
        let hasSaved = !savedStationId.isEmpty
        let savedName = wuIntegration?.stationName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasCoordinates: Bool = {
            let s = store.settings
            if let lat = s.vineyardLatitude, let lon = s.vineyardLongitude,
               lat != 0 || lon != 0 { return true }
            if let lat = store.paddockCentroidLatitude,
               let lon = store.paddockCentroidLongitude,
               lat != 0 || lon != 0 { return true }
            return false
        }()

        if hasSaved {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Selected: ")
                        .foregroundStyle(.secondary)
                    + Text(savedName.isEmpty ? savedStationId : savedName)
                        .foregroundStyle(.primary)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                if !savedName.isEmpty {
                    Text(savedStationId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            .padding(.vertical, 2)
        }

        Button {
            showWuStationPicker = true
        } label: {
            Label("Find nearby WU stations", systemImage: "location.magnifyingglass")
        }
        .disabled(vineyardId == nil || !hasCoordinates)

        if !hasCoordinates {
            Text("Vineyard coordinates are required to find nearby Weather Underground stations.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Text("Station ID")
            Spacer()
            TextField("e.g. KCASANFR123", text: $wuStationIdInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 220)
        }
        HStack {
            Text("Station name")
            Spacer()
            TextField("Optional", text: $wuStationNameInput)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 220)
        }

        Button {
            Task { await saveWuStation() }
        } label: {
            HStack {
                if isSavingWu { ProgressView().controlSize(.small) }
                Label(isSavingWu ? "Saving…" : "Save station", systemImage: "externaldrive.fill.badge.icloud")
            }
        }
        .disabled(isSavingWu || wuStationIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if hasSaved {
            Button(role: .destructive) {
                Task { await clearWuStation() }
            } label: {
                if isClearingWu {
                    HStack { ProgressView().controlSize(.small); Text("Clearing…") }
                } else {
                    Label("Remove Weather Underground station", systemImage: "trash")
                }
            }
            .disabled(isClearingWu)
        }

        if let msg = wuSaveStatus, !msg.isEmpty {
            Text(msg)
                .font(.caption2)
                .foregroundStyle(wuSaveOk ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Backfill button
        Button {
            Task { await backfillWundergroundRainfall() }
        } label: {
            if isBackfillingWu {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Backfilling Weather Underground rainfall…")
                }
            } else {
                Label("Backfill Weather Underground rainfall", systemImage: "calendar.badge.clock")
            }
        }
        .disabled(isBackfillingWu || !hasSaved || (vineyardId == nil))

        if let msg = wuBackfillStatus, !msg.isEmpty {
            Text(msg)
                .font(.caption2)
                .foregroundStyle(wuBackfillOk ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("Imports the last 14 days of Weather Underground rainfall into vineyard history. Safe to re-run — Manual and Davis rainfall are preserved. Today is skipped because the daily summary is incomplete.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func loadWwIntegration(for vineyardId: UUID) async {
        do {
            let integ = try await integrationRepository.fetch(
                vineyardId: vineyardId, provider: "willyweather"
            )
            wwIntegration = integ
            var c = WeatherProviderStore.shared.config(for: vineyardId)
            // API key is global now — always treat as available.
            c.willyWeatherHasApiKey = true
            // Pull the shared forecast provider preference so iOS/Lovable stay aligned.
            if let backendProvider = try? await VineyardWillyWeatherProxyService.getProviderPreference(vineyardId: vineyardId),
               let mapped = mapBackendForecastProvider(backendProvider) {
                c.forecastProvider = mapped
            }
            if let sid = integ?.stationId, !sid.isEmpty {
                c.willyWeatherLocationId = sid
                c.willyWeatherLocationName = integ?.stationName
            }
            if let ts = integ?.lastTestedAt {
                c.willyWeatherLastTestSuccess = ts
            }
            WeatherProviderStore.shared.save(c, for: vineyardId)
            config = c
            print("[WillyWeatherConfig] load vineyardId=\(vineyardId) hasKey=\(integ?.hasApiKey ?? false) location=\(integ?.stationName ?? "-")")
        } catch {
            print("[WillyWeatherConfig] load failed vineyardId=\(vineyardId) error=\(error.localizedDescription)")
        }
    }

    private func loadWuIntegration(for vineyardId: UUID) async {
        isLoadingWuIntegration = true
        defer { isLoadingWuIntegration = false }
        do {
            let integ = try await integrationRepository.fetch(
                vineyardId: vineyardId, provider: "wunderground"
            )
            wuIntegration = integ
            wuStationIdInput = integ?.stationId ?? ""
            wuStationNameInput = integ?.stationName ?? ""
            print("[WundergroundConfig] load vineyardId=\(vineyardId) provider=wunderground stationId=\(integ?.stationId ?? "-") stationName=\(integ?.stationName ?? "-")")
        } catch {
            print("[WundergroundConfig] load failed vineyardId=\(vineyardId) error=\(error.localizedDescription)")
        }
    }

    private func saveWuStation() async {
        guard canEdit, let vid = vineyardId else { return }
        let trimmedId = wuStationIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        let trimmedName = wuStationNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingWu = true
        wuSaveStatus = nil
        defer { isSavingWu = false }
        do {
            let payload = VineyardWeatherIntegrationSave(
                p_vineyard_id: vid,
                p_provider: "wunderground",
                p_api_key: nil,
                p_api_secret: nil,
                p_station_id: trimmedId,
                p_station_name: trimmedName.isEmpty ? nil : trimmedName,
                p_station_latitude: nil,
                p_station_longitude: nil,
                p_has_leaf_wetness: nil,
                p_has_rain: true,
                p_has_wind: nil,
                p_has_temperature_humidity: nil,
                p_detected_sensors: nil,
                p_last_tested_at: nil,
                p_last_test_status: nil,
                p_is_active: true
            )
            try await integrationRepository.save(payload)
            wuSaveOk = true
            wuSaveStatus = "Weather Underground station saved."
            await loadWuIntegration(for: vid)
        } catch {
            wuSaveOk = false
            wuSaveStatus = "Could not save — \(error.localizedDescription)"
        }
    }

    private func clearWuStation() async {
        guard canEdit, let vid = vineyardId else { return }
        isClearingWu = true
        defer { isClearingWu = false }
        do {
            try await integrationRepository.delete(
                vineyardId: vid, provider: "wunderground"
            )
            wuIntegration = nil
            wuStationIdInput = ""
            wuStationNameInput = ""
            wuSaveOk = true
            wuSaveStatus = "Weather Underground station removed."
        } catch {
            wuSaveOk = false
            wuSaveStatus = "Could not remove — \(error.localizedDescription)"
        }
    }

    private func backfillWundergroundRainfall() async {
        guard canEdit else {
            wuBackfillStatus = "Owner or manager role required."
            wuBackfillOk = false
            return
        }
        guard let vid = vineyardId else {
            wuBackfillStatus = "No vineyard selected."
            wuBackfillOk = false
            return
        }
        let savedStationId = wuIntegration?.stationId ?? ""
        guard !savedStationId.isEmpty else {
            wuBackfillStatus = "Add a Weather Underground station ID first."
            wuBackfillOk = false
            return
        }
        isBackfillingWu = true
        wuBackfillStatus = nil
        defer { isBackfillingWu = false }
        print("[WundergroundProxy] backfill requested vineyardId=\(vid) stationId=\(savedStationId) days=14")
        do {
            let result = try await VineyardWundergroundProxyService.backfillRainfall(
                vineyardId: vid, stationId: nil, days: 14
            )
            var lines: [String] = []
            lines.append(result.success
                ? "Weather Underground rainfall backfill complete."
                : "Weather Underground rainfall backfill finished with errors.")
            lines.append("Days requested: \(result.daysRequested). Processed: \(result.daysProcessed). Rows upserted: \(result.rowsUpserted). Errors: \(result.errorsCount).")
            if let sid = result.stationId, !sid.isEmpty {
                let nm = result.stationName ?? ""
                lines.append("Station: \(sid)\(nm.isEmpty ? "" : " — \(nm)").")
            }
            if let v = result.proxyVersion, !v.isEmpty {
                lines.append("Proxy version: \(v).")
            }
            wuBackfillStatus = lines.joined(separator: " ")
            wuBackfillOk = result.success
            if result.rowsUpserted > 0 {
                NotificationCenter.default.post(
                    name: .rainfallCalendarShouldReload, object: nil
                )
            }
        } catch let error as VineyardWundergroundProxyError {
            wuBackfillOk = false
            wuBackfillStatus = "Weather Underground backfill failed — \(error.errorDescription ?? "unknown error")"
            print("[WundergroundProxy] backfill failed vineyardId=\(vid) reason=\(error.errorDescription ?? "-")")
        } catch {
            wuBackfillOk = false
            wuBackfillStatus = "Weather Underground backfill failed — \(error.localizedDescription)"
            print("[WundergroundProxy] backfill failed vineyardId=\(vid) reason=\(error.localizedDescription)")
        }
    }

    // MARK: - Diagnostics helpers

    /// Builds the multi-line plain-text diagnostics snapshot that the
    /// Copy button writes to the pasteboard. Excludes any secrets.
    private func buildDavisDiagnosticsText() -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        var lines: [String] = []
        lines.append("Davis WeatherLink Diagnostics")
        lines.append("Time: \(df.string(from: Date()))")
        lines.append("Vineyard ID: \(vineyardId?.uuidString ?? "-")")
        lines.append("Provider: davis_weatherlink")
        if let integ = vineyardIntegration {
            lines.append("Configured: \(integ.isFullyConfigured ? "Yes" : "No")")
            lines.append("Has API key: \(integ.hasApiKey ? "Yes" : "No")")
            lines.append("Has API secret: \(integ.hasApiSecret ? "Yes" : "No")")
            lines.append("Station ID: \(integ.stationId ?? "-")")
            lines.append("Station name: \(integ.stationName ?? "-")")
            lines.append("Last tested: \(integ.lastTestedAt.map { df.string(from: $0) } ?? "-")")
            lines.append("Last test status: \(integ.lastTestStatus ?? "-")")
            lines.append("Caller role: \(integ.callerRole ?? "-")")
        } else {
            lines.append("Configured: No (no vineyard integration row)")
        }
        lines.append("Source: \(isLoadingVineyardIntegration ? "Loading" : (vineyardIntegrationError == nil ? "Supabase RPC" : "Local fallback (\(vineyardIntegrationError ?? "error"))"))")
        lines.append("Local provider: \(config.localObservationProvider.rawValue)")
        lines.append("Vineyard-shared: \(config.davisIsVineyardShared ? "Yes" : "No")")
        lines.append("Has server creds: \(config.davisVineyardHasServerCredentials ? "Yes" : "No")")
        lines.append("Has local Keychain: \(WeatherKeychain.hasCredentials ? "Yes" : "No")")

        lines.append("")
        lines.append("Parser detection:")
        if let s = lastDavisSensorSummary {
            lines.append("  Sensor blocks: \(s.sensorBlockCount)")
            lines.append("  Empty data blocks: \(s.emptyDataBlockCount)")
            lines.append("  detectedSensorTypes: \(s.detectedSensorTypes)")
            lines.append("  detectedDataStructureTypes: \(s.detectedDataStructureTypes)")
            lines.append("  blockSummaries: \(s.blockSummaries)")
            lines.append("  detectedFields (\(s.detectedFields.count)): \(s.detectedFields.joined(separator: ","))")
            lines.append("  hasTemperatureHumiditySensor: \(s.hasTemperatureHumidity)")
            lines.append("  hasWindSensor: \(s.hasWind)")
            lines.append("  hasRainSensor: \(s.hasRain)")
            lines.append("  hasLeafWetnessSensor: \(s.hasLeafWetness)")
            lines.append("  hasSoilMoistureSensor: \(s.hasSoilMoisture)")
        } else {
            lines.append("  (not yet run on this device)")
        }
        if let cur = lastDavisCurrent {
            lines.append("")
            lines.append("Current values:")
            lines.append("  generatedAt: \(df.string(from: cur.generatedAt))")
            lines.append("  currentTemperatureAvailable: \(cur.temperatureC != nil)")
            lines.append("  currentHumidityAvailable: \(cur.humidityPercent != nil)")
            lines.append("  currentWindAvailable: \(cur.windKph != nil)")
            lines.append("  currentRainAvailable: \(cur.rainMmLastHour != nil)")
        }
        if let err = config.davisLastTestError, !err.isEmpty {
            lines.append("")
            lines.append("Last test error: \(err)")
        }
        return lines.joined(separator: "\n")
    }

    private func copyDavisDiagnostics() {
        let text = buildDavisDiagnosticsText()
#if canImport(UIKit)
        UIPasteboard.general.string = text
#endif
        diagCopiedMessage = "Diagnostics copied"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            diagCopiedMessage = nil
        }
    }

    /// User-triggered "Refresh Davis now". Posts to the `davis-proxy`
    /// edge function with `{ vineyardId, action: "current", stationId }`
    /// using the caller's member JWT. The edge function writes the
    /// resulting observation into `vineyard_weather_observations` and,
    /// when rain_today_mm is present, calls `upsert_davis_rainfall_daily`
    /// with the service-role key. After the round-trip we invalidate the
    /// integration cache so the next read sees the freshly-written row.
    private func forceRefreshDavisCurrent() async {
        guard let vid = vineyardId else {
            davisForceRefreshStatus = "No vineyard selected."
            davisForceRefreshOk = false
            return
        }
        guard let sid = config.davisStationId, !sid.isEmpty else {
            davisForceRefreshStatus = "No Davis station selected for this vineyard."
            davisForceRefreshOk = false
            return
        }
        isForceRefreshingDavis = true
        davisForceRefreshStatus = nil
        defer { isForceRefreshingDavis = false }
        print("[DavisProxy] forceRefresh requested vineyardId=\(vid) stationId=\(sid)")
        do {
            let result = try await VineyardDavisProxyService
                .fetchCurrentConditionsWithDiagnostics(
                    vineyardId: vid, stationId: sid
                )
            let cur = result.conditions
            lastDavisCurrent = cur
            lastDavisSensorSummary = cur.sensors
            // Surface freshly-written values so users can verify
            // server-side persistence without leaving the screen.
            let df = DateFormatter()
            df.dateStyle = .none
            df.timeStyle = .medium
            let parts: [String] = [
                cur.temperatureC.map { String(format: "%.1f°C", $0) },
                cur.humidityPercent.map { String(format: "%.0f%% RH", $0) },
                cur.rainMmLastHour.map { String(format: "rain %.1f mm", $0) },
            ].compactMap { $0 }
            let summary = parts.isEmpty ? "OK" : parts.joined(separator: " · ")

            // Build the persistence message strictly from the server's
            // diagnostics block. Never claim rainfall_daily was refreshed
            // unless the proxy explicitly reports success.
            let timestamp = df.string(from: Date())
            if let diag = result.diagnostics {
                let obsOk = diag.observations.success
                let rainOk = diag.rainfallDaily.success
                let rainAttempted = diag.rainfallDaily.attempted

                var lines: [String] = ["Davis updated at \(timestamp) — \(summary)."]
                if let v = diag.version, !v.isEmpty {
                    lines.append("Proxy version: \(v).")
                } else {
                    lines.append("Proxy version: unknown (older deployment).")
                }
                switch (obsOk, rainOk, rainAttempted) {
                case (true, true, _):
                    lines.append("Server refreshed vineyard_weather_observations and rainfall_daily.")
                    davisForceRefreshOk = true
                case (true, false, true):
                    let detail = diag.rainfallDaily.message ?? diag.rainfallDaily.code ?? "unknown error"
                    lines.append("Observations updated, but rainfall history was not saved: \(detail).")
                    davisForceRefreshOk = false
                case (true, false, false):
                    let detail = diag.rainfallDaily.message ?? "rain_today_mm not present in payload"
                    lines.append("Observations updated, but rainfall history was not saved (\(detail)).")
                    davisForceRefreshOk = false
                case (false, _, _):
                    let obsDetail = diag.observations.message ?? diag.observations.code ?? "unknown error"
                    lines.append("Server did not save observations: \(obsDetail).")
                    davisForceRefreshOk = false
                }
                if let date = diag.rainfallDate, let mm = diag.rainTodayMm {
                    lines.append(String(format: "Rain attempted: %.2f mm on %@.", mm, date))
                }
                davisForceRefreshStatus = lines.joined(separator: " ")
            } else {
                // Older proxy build without the `_proxy` block. Be honest
                // and tell the user we can't confirm the writes.
                davisForceRefreshStatus = "Davis updated at \(timestamp) — \(summary). Server did not return persistence diagnostics or a proxy version; the deployed davis-proxy is older than the rainfall-diagnostics build. Redeploy from GitHub Actions to confirm rainfall_daily writes."
                davisForceRefreshOk = false
            }
            // Refresh integration metadata so the cached RPC display is
            // re-pulled on next read.
            await VineyardWeatherIntegrationCache.shared.refresh(for: vid)
        } catch let error as VineyardDavisProxyError {
            davisForceRefreshOk = false
            davisForceRefreshStatus = "Davis refresh failed — \(error.errorDescription ?? "unknown error")"
            print("[DavisProxy] forceRefresh failed vineyardId=\(vid) reason=\(error.errorDescription ?? "-")")
        } catch {
            davisForceRefreshOk = false
            davisForceRefreshStatus = "Davis refresh failed — \(error.localizedDescription)"
            print("[DavisProxy] forceRefresh failed vineyardId=\(vid) reason=\(error.localizedDescription)")
        }
    }

    /// Owner/Manager-only "Backfill Davis rainfall" action. Calls the
    /// davis-proxy edge function which uses the vineyard's stored
    /// WeatherLink credentials server-side to fetch closed-day archive
    /// rainfall and upsert `rainfall_daily` rows. Defaults to 14 days.
    /// Posts `Notification.Name.rainfallCalendarShouldReload` on success
    /// so the Rain Calendar refreshes the next time it appears.
    private func backfillDavisRainfall() async {
        guard canEdit else {
            davisBackfillStatus = "Owner or manager role required."
            davisBackfillOk = false
            return
        }
        guard let vid = vineyardId else {
            davisBackfillStatus = "No vineyard selected."
            davisBackfillOk = false
            return
        }
        guard let sid = config.davisStationId, !sid.isEmpty else {
            davisBackfillStatus = "No Davis station selected for this vineyard."
            davisBackfillOk = false
            return
        }
        isBackfillingDavis = true
        davisBackfillStatus = nil
        defer { isBackfillingDavis = false }
        print("[DavisProxy] backfill requested vineyardId=\(vid) stationId=\(sid) days=14")
        do {
            let result = try await VineyardDavisProxyService.backfillRainfall(
                vineyardId: vid, stationId: sid, days: 14
            )
            var lines: [String] = []
            let headline = result.success
                ? "Davis rainfall backfill complete."
                : "Davis rainfall backfill finished with errors."
            lines.append(headline)
            lines.append("Days requested: \(result.daysRequested). Processed: \(result.daysProcessed). Rows upserted: \(result.rowsUpserted). Errors: \(result.errorsCount).")
            if let tz = result.timezone, !tz.isEmpty {
                lines.append("Timezone: \(tz).")
            }
            davisBackfillStatus = lines.joined(separator: " ")
            davisBackfillOk = result.success
            if result.rowsUpserted > 0 {
                NotificationCenter.default.post(
                    name: .rainfallCalendarShouldReload, object: nil
                )
            }
        } catch let error as VineyardDavisProxyError {
            davisBackfillOk = false
            davisBackfillStatus = "Davis backfill failed — \(error.errorDescription ?? "unknown error")"
            print("[DavisProxy] backfill failed vineyardId=\(vid) reason=\(error.errorDescription ?? "-")")
        } catch {
            davisBackfillOk = false
            davisBackfillStatus = "Davis backfill failed — \(error.localizedDescription)"
            print("[DavisProxy] backfill failed vineyardId=\(vid) reason=\(error.localizedDescription)")
        }
    }

    /// Re-fetches current conditions for the selected Davis station so the
    /// parser diagnostics panel reflects the latest WeatherLink response.
    /// Uses the vineyard proxy when available so operators / non-credential
    /// devices can also refresh.
    private func refreshDavisParserDiagnostics() async {
        guard let sid = config.davisStationId, !sid.isEmpty else { return }
        // Prefer vineyard proxy when configured (works for every member,
        // not just devices that hold local Keychain credentials).
        if let vid = vineyardId,
           config.davisVineyardHasServerCredentials || config.davisIsVineyardShared {
            do {
                let cur = try await VineyardDavisProxyService.fetchCurrentConditions(
                    vineyardId: vid, stationId: sid
                )
                lastDavisCurrent = cur
                lastDavisSensorSummary = cur.sensors
                return
            } catch {
                // Fall through to local credential path.
            }
        }
        guard let apiKey = WeatherKeychain.get(.apiKey),
              let apiSecret = WeatherKeychain.get(.apiSecret) else { return }
        do {
            let cur = try await DavisWeatherLinkService.fetchCurrentConditions(
                apiKey: apiKey, apiSecret: apiSecret, stationId: sid
            )
            lastDavisCurrent = cur
            lastDavisSensorSummary = cur.sensors
        } catch {
            // Leave previous diagnostics in place.
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private var davisHelpSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                helpStep(number: 1, text: "Sign in to your WeatherLink account at weatherlink.com.")
                helpStep(number: 2, text: "Go to Account Settings.")
                helpStep(number: 3, text: "Look for ‘Generate v2 Key’.")
                helpStep(number: 4, text: "WeatherLink will provide an API Key and API Secret.")
                helpStep(number: 5, text: "Enter both here and tap Save Credentials.")
                helpStep(number: 6, text: "Tap Test Connection to verify the account and load your stations.")
                helpStep(number: 7, text: "If you have more than one station, choose the one closest to the vineyard.")
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Label("Your API Secret is encrypted and stored as part of this vineyard's shared weather integration.", systemImage: "lock.shield")
                Label("All vineyard members see the same station and rainfall data.", systemImage: "person.3.fill")
                Label("Only owners and managers can view or replace credentials.", systemImage: "person.badge.key")
                Label("Station ID is selected automatically after connection where possible.", systemImage: "antenna.radiowaves.left.and.right")
                Label("If your station has a leaf wetness sensor, VineTrack can use measured wetness for disease risk.", systemImage: "drop.fill")
                Label("If no leaf wetness sensor is detected, VineTrack will continue using estimated wetness.", systemImage: "drop")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        } header: {
            Text("How to find your Davis API details")
        }
    }

    private func helpStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var usageSection: some View {
        Section {
            usageRow(symbol: "drop.fill", color: .teal, text: "Spray records — wind, temp, humidity at job time")
            usageRow(symbol: "leaf.fill", color: .green, text: "Irrigation Advisor — forecast ETo, rainfall")
            usageRow(symbol: "cloud.bolt.rain.fill", color: .orange, text: "Weather alerts — rain, wind, frost, heat")
            usageRow(symbol: "ladybug.fill", color: .red, text: "Disease risk alerts — humidity, dew point, wetness")
            usageRow(symbol: "thermometer.sun.fill", color: .pink, text: "Degree-day / BEDD calculations")
        } header: {
            Text("How weather data is used")
        } footer: {
            Text("When a configured local source has the required data, VineTrack uses it. If not, it falls back to the default forecast so core features continue working.")
        }
    }



    // MARK: - Helpers

    private var currentStatus: WeatherSourceStatus {
        guard let vid = vineyardId else {
            return WeatherSourceStatus(
                provider: .automatic,
                quality: .forecastOnly,
                primaryLabel: "Automatic Forecast",
                detailLabel: "Based on vineyard location",
                lastUpdated: nil
            )
        }
        return WeatherProviderResolver.resolve(for: vid, weatherStationId: store.settings.weatherStationId)
    }

    private func providerColor(_ p: WeatherProvider) -> Color {
        switch p {
        case .automatic: return .blue
        case .wunderground: return .orange
        case .davis: return .indigo
        }
    }

    private func localProviderColor(_ p: LocalObservationProvider) -> Color {
        switch p {
        case .none: return .blue
        case .wunderground: return .orange
        case .davis: return .indigo
        }
    }

    private func usageRow(symbol: String, color: Color, text: String) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: symbol, color: color, size: 28)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }

    private func fallbackRow(rank: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(rank)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadConfig() {
        guard let vid = vineyardId else { return }
        var c = WeatherProviderStore.shared.config(for: vid)
        // Reconcile local keychain state for owner/manager direct fetches.
        c.davisHasCredentials = WeatherKeychain.hasCredentials
        // Note: Do NOT clear davisConnectionTested when keychain is empty —
        // a vineyard-shared Davis integration counts as tested for every
        // member, even devices without local creds. The RPC reload below
        // will set the right value.
        config = c
        davisStations = c.davisAvailableStations
        print("[DavisConfig] loadConfig vineyardId=\(vid) localProvider=\(c.localObservationProvider.rawValue) hasKeychain=\(c.davisHasCredentials) cachedShared=\(c.davisIsVineyardShared) cachedHasServerSecret=\(c.davisVineyardHasServerCredentials) cachedStationId=\(c.davisStationId ?? "-")")
        Task { await loadVineyardIntegration(for: vid) }
    }

    private func loadVineyardIntegration(for vineyardId: UUID) async {
        isLoadingVineyardIntegration = true
        defer { isLoadingVineyardIntegration = false }
        do {
            let integ = try await integrationRepository.fetch(
                vineyardId: vineyardId,
                provider: "davis_weatherlink"
            )
            vineyardIntegration = integ
            vineyardIntegrationError = nil
            print("[DavisConfig] load vineyardId=\(vineyardId) provider=davis source=rpc configured=\(integ?.isFullyConfigured ?? false) hasKey=\(integ?.hasApiKey ?? false) hasSecret=\(integ?.hasApiSecret ?? false) stationId=\(integ?.stationId ?? "-") callerRole=\(integ?.callerRole ?? "-") lastTestStatus=\(integ?.lastTestStatus ?? "-")")
            applyIntegrationToConfig(integ)
            // If this device has Keychain credentials and the vineyard
            // doesn't yet have a server-side secret, automatically push
            // them to the vineyard so other members/devices can fetch
            // via davis-proxy. We still show a confirmation message
            // afterwards so the owner/manager knows it happened.
            if canEdit,
               WeatherKeychain.hasCredentials,
               (integ?.hasApiSecret != true) {
                await runMigrationToVineyard(silent: true)
            }
        } catch {
            vineyardIntegration = nil
            vineyardIntegrationError = error.localizedDescription
            print("[DavisConfig] load failed vineyardId=\(vineyardId) error=\(error.localizedDescription)")
        }
    }

    private func applyIntegrationToConfig(_ integ: VineyardWeatherIntegration?) {
        guard let vid = vineyardId else { return }
        var c = config
        if let integ {
            c.davisIsVineyardShared = true
            c.davisVineyardHasServerCredentials = integ.hasApiSecret
            c.davisVineyardConfiguredBy = integ.configuredBy
            c.davisVineyardUpdatedAt = integ.updatedAt
            // Shared station / sensor metadata is the source of truth
            // for every member.
            if let sid = integ.stationId, !sid.isEmpty {
                c.davisStationId = sid
                c.davisStationName = integ.stationName
                c.davisHasLeafWetnessSensor = integ.hasLeafWetness
                c.davisDetectedSensors = integ.detectedSensors
                // The vineyard-level integration counts as a tested
                // connection for read paths — every member trusts the
                // owner/manager's setup.
                let status = integ.lastTestStatus
                if status == "ok" || status == nil {
                    c.davisConnectionTested = true
                }
                // CRITICAL: if the user hasn't explicitly chosen a local
                // observation source, flip to Davis so the davisSection,
                // resolver and weather services all see the configured
                // station. Without this, a fully-configured vineyard
                // appears "not configured" in the UI on devices that
                // never opened the picker.
                if c.localObservationProvider == .none && integ.hasApiSecret {
                    c.localObservationProvider = .davis
                }
            }
            // Operators have no local creds but should still see the source
            // as configured for read-only display.
            if isOperator { c.davisHasCredentials = false }
        } else {
            c.davisIsVineyardShared = false
            c.davisVineyardHasServerCredentials = false
            c.davisVineyardConfiguredBy = nil
            c.davisVineyardUpdatedAt = nil
        }
        config = c
        WeatherProviderStore.shared.save(c, for: vid)
        print("[DavisConfig] applyIntegration vineyardId=\(vid) localProvider=\(c.localObservationProvider.rawValue) shared=\(c.davisIsVineyardShared) hasServerSecret=\(c.davisVineyardHasServerCredentials) stationId=\(c.davisStationId ?? "-") tested=\(c.davisConnectionTested)")
    }

    /// Pushes the latest station + detected sensor state to the vineyard
    /// integration so every member sees the same source. No-op if the
    /// caller doesn't have edit rights or there's no Davis station yet.
    private func pushStationStateToVineyard() async {
        guard canEdit, let vid = vineyardId,
              let sid = config.davisStationId, !sid.isEmpty else { return }
        do {
            let payload = VineyardWeatherIntegrationSave(
                p_vineyard_id: vid,
                p_provider: "davis_weatherlink",
                p_api_key: nil,
                p_api_secret: nil,
                p_station_id: sid,
                p_station_name: config.davisStationName,
                p_station_latitude: nil,
                p_station_longitude: nil,
                p_has_leaf_wetness: config.davisHasLeafWetnessSensor,
                p_has_rain: true,
                p_has_wind: nil,
                p_has_temperature_humidity: nil,
                p_detected_sensors: config.davisDetectedSensors,
                p_last_tested_at: config.davisLastTestSuccess,
                p_last_test_status: "ok",
                p_is_active: true
            )
            print("[DavisConfig] save vineyardId=\(vid) provider=davis upsert=true stationId=\(sid) hasKeyInput=false hasSecretInput=false reason=stationUpdate")
            try await integrationRepository.save(payload)
            VineyardWeatherIntegrationCache.shared.invalidate(vid)
            // Refresh the local snapshot.
            if let integ = try? await integrationRepository.fetch(
                vineyardId: vid, provider: "davis_weatherlink"
            ) {
                vineyardIntegration = integ
                applyIntegrationToConfig(integ)
            }
        } catch {
            print("[DavisConfig] save failed vineyardId=\(vid) error=\(error.localizedDescription)")
            // Don't surface a hard error — local fetch path still works.
        }
    }

    private func runMigrationToVineyard(silent: Bool = false) async {
        guard canEdit, let vid = vineyardId,
              let apiKey = WeatherKeychain.get(.apiKey),
              let apiSecret = WeatherKeychain.get(.apiSecret),
              !apiKey.isEmpty, !apiSecret.isEmpty else { return }
        if !silent { isMigrating = true }
        defer { if !silent { isMigrating = false } }
        do {
            let payload = VineyardWeatherIntegrationSave(
                p_vineyard_id: vid,
                p_provider: "davis_weatherlink",
                p_api_key: apiKey,
                p_api_secret: apiSecret,
                p_station_id: config.davisStationId,
                p_station_name: config.davisStationName,
                p_station_latitude: nil,
                p_station_longitude: nil,
                p_has_leaf_wetness: config.davisHasLeafWetnessSensor,
                p_has_rain: true,
                p_has_wind: nil,
                p_has_temperature_humidity: nil,
                p_detected_sensors: config.davisDetectedSensors,
                p_last_tested_at: config.davisLastTestSuccess,
                p_last_test_status: config.davisConnectionTested ? "ok" : nil,
                p_is_active: true
            )
            print("[DavisConfig] save vineyardId=\(vid) provider=davis upsert=true stationId=\(config.davisStationId ?? "-") hasKeyInput=true hasSecretInput=true reason=migration")
            try await integrationRepository.save(payload)
            VineyardWeatherIntegrationCache.shared.invalidate(vid)
            migrationMessage = silent
                ? "Davis credentials are now shared with this vineyard. Other members and devices will use the same station automatically."
                : "Davis setup moved to this vineyard. All members now use the same station."
            showMigratePrompt = false
            // Refresh in-place without re-triggering migration.
            if let integ = try? await integrationRepository.fetch(
                vineyardId: vid, provider: "davis_weatherlink"
            ) {
                vineyardIntegration = integ
                applyIntegrationToConfig(integ)
            }
        } catch {
            if !silent {
                migrationMessage = "Could not save vineyard integration — \(error.localizedDescription)"
            }
        }
    }

    private func persist() {
        guard let vid = vineyardId else { return }
        WeatherProviderStore.shared.save(config, for: vid)
    }

    private var davisStatus: DavisStatus {
        if !config.davisHasCredentials { return .notConfigured }
        if isTestingDavis { return .testing }
        if let err = config.davisLastTestError, !err.isEmpty {
            return .connectionFailed(err)
        }
        if !config.davisConnectionTested { return .credentialsSavedNotTested }
        guard let sid = config.davisStationId, !sid.isEmpty else {
            return .connectedNoStationSelected
        }
        return config.davisHasLeafWetnessSensor
            ? .connectedWithLeafWetness
            : .connectedNoLeafWetness
    }

    private func saveDavisCredentials() {
        guard canEdit else { return }
        WeatherKeychain.set(davisApiKey, for: .apiKey)
        WeatherKeychain.set(davisApiSecret, for: .apiSecret)
        var c = config
        c.davisHasCredentials = WeatherKeychain.hasCredentials
        // New credentials — invalidate prior test state.
        c.davisConnectionTested = false
        c.davisStationId = nil
        c.davisStationName = nil
        c.davisAvailableStations = []
        c.davisDetectedSensors = []
        c.davisHasLeafWetnessSensor = false
        c.davisLastTestError = nil
        c.davisLastTestSuccess = nil
        config = c
        persist()
        davisApiKey = ""
        davisApiSecret = ""
        davisStations = []
        showSecret = false
        isEditingDavisCredentials = false
        davisTestSucceeded = false
        davisTestMessage = "Credentials saved securely. Tap Test Connection to verify your WeatherLink account."
    }

    private func beginReplaceCredentials() {
        davisApiKey = ""
        davisApiSecret = ""
        showSecret = false
        isEditingDavisCredentials = true
        davisTestMessage = nil
    }

    private func cancelReplaceCredentials() {
        davisApiKey = ""
        davisApiSecret = ""
        showSecret = false
        isEditingDavisCredentials = false
    }

    private func clearDavisRainfallCache() {
        guard canEdit else { return }
        if let sid = config.davisStationId, !sid.isEmpty {
            DavisRainfallCache.clearAll(stationId: sid)
        } else {
            DavisRainfallCache.clearAll()
        }
        davisCacheClearedMessage = "Davis rainfall cache cleared."
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            davisCacheClearedMessage = nil
        }
    }

    private func clearDavisCredentials() {
        WeatherKeychain.clearAll()
        var c = config
        c.davisHasCredentials = false
        c.davisConnectionTested = false
        c.davisStationId = nil
        c.davisStationName = nil
        c.davisAvailableStations = []
        c.davisDetectedSensors = []
        c.davisHasLeafWetnessSensor = false
        c.davisLastTestSuccess = nil
        c.davisLastTestError = nil
        config = c
        persist()
        davisStations = []
        davisTestSucceeded = false
        isEditingDavisCredentials = false
        davisTestMessage = "Davis credentials removed."
    }

    private var currentStationLabel: String {
        if let name = config.davisStationName, !name.isEmpty { return name }
        if let sid = config.davisStationId, !sid.isEmpty { return "Station \(sid)" }
        return "Choose station"
    }

    private func testDavisConnection() async {
        guard config.davisHasCredentials else { return }
        guard let apiKey = WeatherKeychain.get(.apiKey),
              let apiSecret = WeatherKeychain.get(.apiSecret),
              !apiKey.isEmpty, !apiSecret.isEmpty else {
            davisTestSucceeded = false
            davisTestMessage = "Save credentials before testing."
            return
        }
        isTestingDavis = true
        davisTestMessage = nil
        davisTestSucceeded = false
        defer { isTestingDavis = false }

        do {
            let stations = try await DavisWeatherLinkService.fetchStations(
                apiKey: apiKey,
                apiSecret: apiSecret
            )
            davisStations = stations
            var c = config
            c.davisAvailableStations = stations
            c.davisConnectionTested = true
            c.davisLastTestSuccess = Date()
            c.davisLastTestError = nil

            // Auto-select if exactly one station, otherwise prompt user.
            if stations.count == 1 {
                c.davisStationId = stations[0].stationId
                c.davisStationName = stations[0].name
            } else if let existing = c.davisStationId,
                      stations.contains(where: { $0.stationId == existing }) {
                // Keep existing valid selection.
                if let match = stations.first(where: { $0.stationId == existing }) {
                    c.davisStationName = match.name
                }
            } else {
                c.davisStationId = nil
                c.davisStationName = nil
            }

            // If we have a selected station, fetch current to detect sensors.
            if let sid = c.davisStationId {
                do {
                    let cur = try await DavisWeatherLinkService.fetchCurrentConditions(
                        apiKey: apiKey,
                        apiSecret: apiSecret,
                        stationId: sid
                    )
                    c.davisDetectedSensors = cur.sensors.displayList
                    c.davisHasLeafWetnessSensor = cur.sensors.hasLeafWetness
                    c.lastSuccessfulUpdate = cur.generatedAt
                    lastDavisCurrent = cur
                    lastDavisSensorSummary = cur.sensors
                } catch {
                    // Station picked but current fetch failed — don't
                    // fail the whole test; just leave sensors unknown.
                    c.davisDetectedSensors = []
                    c.davisHasLeafWetnessSensor = false
                }
            } else {
                c.davisDetectedSensors = []
                c.davisHasLeafWetnessSensor = false
            }

            config = c
            persist()
            await pushStationStateToVineyard()
            davisTestSucceeded = true
            if stations.count == 1 {
                davisTestMessage = c.davisHasLeafWetnessSensor
                    ? "Connected to WeatherLink. Measured leaf wetness available."
                    : "Connected to WeatherLink. No leaf wetness sensor detected — using estimated wetness."
            } else if c.davisStationId == nil {
                davisTestMessage = "Connected. Select a station to finish setup."
                // Auto-present the picker so the next step is obvious.
                showDavisStationPicker = true
            } else {
                davisTestMessage = "Connected to WeatherLink."
            }
        } catch let e as DavisWeatherLinkError {
            var c = config
            c.davisLastTestError = e.errorDescription
            c.davisLastTestSuccess = nil
            c.davisConnectionTested = false
            config = c
            persist()
            davisTestSucceeded = false
            davisTestMessage = e.errorDescription
        } catch {
            davisTestSucceeded = false
            davisTestMessage = "WeatherLink unavailable — \(error.localizedDescription)"
        }
    }

    private func selectDavisStation(_ station: DavisStation) async {
        guard let apiKey = WeatherKeychain.get(.apiKey),
              let apiSecret = WeatherKeychain.get(.apiSecret) else { return }
        var c = config
        c.davisStationId = station.stationId
        c.davisStationName = station.name
        config = c
        persist()

        do {
            let cur = try await DavisWeatherLinkService.fetchCurrentConditions(
                apiKey: apiKey,
                apiSecret: apiSecret,
                stationId: station.stationId
            )
            var c2 = config
            c2.davisDetectedSensors = cur.sensors.displayList
            c2.davisHasLeafWetnessSensor = cur.sensors.hasLeafWetness
            c2.lastSuccessfulUpdate = cur.generatedAt
            lastDavisCurrent = cur
            lastDavisSensorSummary = cur.sensors
            config = c2
            persist()
            await pushStationStateToVineyard()
            davisTestSucceeded = true
            davisTestMessage = c2.davisHasLeafWetnessSensor
                ? "Station selected. Measured leaf wetness available."
                : "Station selected. No leaf wetness sensor detected — using estimated wetness."
        } catch let e as DavisWeatherLinkError {
            davisTestSucceeded = false
            davisTestMessage = e.errorDescription
        } catch {
            davisTestSucceeded = false
            davisTestMessage = "Could not load current conditions — \(error.localizedDescription)"
        }
    }
}

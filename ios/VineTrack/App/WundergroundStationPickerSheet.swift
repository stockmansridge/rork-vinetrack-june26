import SwiftUI
import CoreLocation

/// Owner/Manager-only picker that lists the closest Weather Underground PWS
/// stations to the current vineyard, calls the `weather-nearby-stations`
/// edge function (which keeps `WUNDERGROUND_API_KEY` server-side), and
/// saves the selected station into `vineyard_weather_integrations` with
/// provider = `wunderground` via `save_vineyard_weather_integration`.
///
/// No Weather Underground API key is referenced or stored on-device.
struct WundergroundStationPickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let vineyardId: UUID
    /// Called after the integration row has been written to Supabase so
    /// the parent can refresh its cached `wuIntegration` state.
    var onSaved: (_ stationId: String, _ stationName: String?) -> Void

    @State private var stations: [WeatherNearbyStationsService.Station] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var savingStationId: String?
    @State private var saveError: String?

    private let integrationRepository: any VineyardWeatherIntegrationRepositoryProtocol
        = SupabaseVineyardWeatherIntegrationRepository()

    var body: some View {
        NavigationStack {
            Form {
                coordinateSection
                resultsSection
            }
            .navigationTitle("Nearby WU Stations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadNearby() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var coordinateSection: some View {
        Section {
            if let coord = resolveCoordinate() {
                LabeledContent("Vineyard location") {
                    Text("\(String(format: "%.4f", coord.latitude)), \(String(format: "%.4f", coord.longitude))")
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                Button {
                    Task { await loadNearby(force: true) }
                } label: {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isLoading ? "Searching…" : "Search again")
                    }
                }
                .disabled(isLoading)
            } else {
                Label(
                    "Vineyard coordinates are required to find nearby Weather Underground stations.",
                    systemImage: "mappin.slash"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
            }
        } footer: {
            Text("Uses platform Weather Underground connection. Owner/Manager only — credentials are not exposed to the app.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            }
        }

        if !stations.isEmpty {
            Section("10 closest stations") {
                ForEach(stations.prefix(10)) { station in
                    Button {
                        Task { await save(station: station) }
                    } label: {
                        stationRow(station)
                    }
                    .foregroundStyle(.primary)
                    .disabled(savingStationId != nil)
                }
            }
        } else if !isLoading && resolveCoordinate() != nil && errorMessage == nil {
            Section {
                Label("No nearby Weather Underground stations found.",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        if let saveError, !saveError.isEmpty {
            Section {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func stationRow(_ station: WeatherNearbyStationsService.Station) -> some View {
        let trimmedName = station.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasName = !trimmedName.isEmpty
        let isSaving = savingStationId == station.stationId
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if hasName {
                    Text(trimmedName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(station.stationId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                } else {
                    Text(station.stationId)
                        .font(.subheadline.weight(.semibold))
                        .monospaced()
                    Text("Unnamed station")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let d = station.distanceKm {
                Text(String(format: "%.1f km", d))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isSaving {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func resolveCoordinate() -> CLLocationCoordinate2D? {
        let s = store.settings
        if let lat = s.vineyardLatitude, let lon = s.vineyardLongitude,
           lat != 0 || lon != 0 {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if let lat = store.paddockCentroidLatitude,
           let lon = store.paddockCentroidLongitude,
           lat != 0 || lon != 0 {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    private func loadNearby(force: Bool = false) async {
        guard !isLoading else { return }
        guard let coord = resolveCoordinate() else {
            errorMessage = nil
            stations = []
            return
        }
        if force { stations = [] }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await WeatherNearbyStationsService().nearby(coordinate: coord)
            // Closest first.
            let sorted = result.sorted { (a, b) in
                let da = a.distanceKm ?? .greatestFiniteMagnitude
                let db = b.distanceKm ?? .greatestFiniteMagnitude
                return da < db
            }
            stations = Array(sorted.prefix(10))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save(station: WeatherNearbyStationsService.Station) async {
        guard savingStationId == nil else { return }
        let trimmedName = station.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        savingStationId = station.stationId
        saveError = nil
        defer { savingStationId = nil }
        do {
            let payload = VineyardWeatherIntegrationSave(
                p_vineyard_id: vineyardId,
                p_provider: "wunderground",
                p_api_key: nil,
                p_api_secret: nil,
                p_station_id: station.stationId,
                p_station_name: trimmedName,
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
            print("[WundergroundConfig] saved nearby pick vineyardId=\(vineyardId) stationId=\(station.stationId) stationName=\(trimmedName ?? "-")")
            onSaved(station.stationId, trimmedName)
            dismiss()
        } catch {
            saveError = "Could not save station — \(error.localizedDescription)"
            print("[WundergroundConfig] save failed vineyardId=\(vineyardId) stationId=\(station.stationId) error=\(error.localizedDescription)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

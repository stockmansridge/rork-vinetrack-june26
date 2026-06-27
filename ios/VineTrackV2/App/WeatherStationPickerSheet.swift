import SwiftUI
import CoreLocation

nonisolated struct WeatherNearbyStationsService: Sendable {

    nonisolated struct Station: Sendable, Identifiable, Hashable {
        let stationId: String
        let name: String?
        let distanceKm: Double?
        var id: String { stationId }
    }

    nonisolated enum LookupError: Error, LocalizedError, Sendable {
        case missingConfig
        case network(String)

        var errorDescription: String? {
            switch self {
            case .missingConfig:
                return "Weather service is not configured."
            case .network(let m):
                return "Lookup failed: \(m)"
            }
        }
    }

    nonisolated private struct Response: Decodable, Sendable {
        let stations: [Item]?
        let error: String?

        nonisolated struct Item: Decodable, Sendable {
            let stationId: String
            let name: String?
            let distanceKm: Double?
        }
    }

    func nearby(coordinate: CLLocationCoordinate2D) async throws -> [Station] {
        guard AppConfig.isSupabaseConfigured else { throw LookupError.missingConfig }
        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/weather-nearby-stations") else {
            throw LookupError.network("Invalid URL")
        }
        let anonKey = AppConfig.supabaseAnonKey
        guard !anonKey.isEmpty else { throw LookupError.missingConfig }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LookupError.network("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let decoded = try? JSONDecoder().decode(Response.self, from: data),
               let msg = decoded.error {
                throw LookupError.network(msg)
            }
            throw LookupError.network("HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let items = decoded.stations ?? []
        return items.map { Station(stationId: $0.stationId, name: $0.name, distanceKm: $0.distanceKm) }
    }
}

struct WeatherStationPickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss

    @State private var stations: [WeatherNearbyStationsService.Station] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var manualStationId: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await loadNearby() }
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "location.magnifyingglass")
                            }
                            Text(isLoading ? "Searching…" : "Search Nearby Stations")
                            Spacer()
                        }
                    }
                    .disabled(isLoading)
                } footer: {
                    if let coord = resolveCoordinate() {
                        Text("Searching near \(String(format: "%.4f", coord.latitude)), \(String(format: "%.4f", coord.longitude))")
                            .font(.caption)
                    } else {
                        Text("No vineyard or device location available. Enter a station ID manually below.")
                            .font(.caption)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }

                if !stations.isEmpty {
                    Section("Nearby Stations") {
                        ForEach(stations) { station in
                            Button {
                                select(stationId: station.stationId, name: station.name)
                            } label: {
                                stationRow(station)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("Station ID (e.g. KCASANTA12)", text: $manualStationId)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Use") {
                            let trimmed = manualStationId.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            select(stationId: trimmed, name: nil)
                        }
                        .disabled(manualStationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Manual Entry")
                }

                if store.settings.weatherStationId?.isEmpty == false {
                    Section {
                        Button(role: .destructive) {
                            var s = store.settings
                            s.weatherStationId = nil
                            store.updateSettings(s)
                            dismiss()
                        } label: {
                            Label("Use Auto / Nearest", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Weather Station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadNearby() }
        }
    }

    private func stationRow(_ station: WeatherNearbyStationsService.Station) -> some View {
        let trimmedName = station.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasName = !trimmedName.isEmpty
        return HStack(alignment: .center, spacing: 12) {
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
            if store.settings.weatherStationId == station.stationId {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func select(stationId: String, name: String?) {
        var s = store.settings
        s.weatherStationId = stationId
        store.updateSettings(s)
        dismiss()
    }

    private func resolveCoordinate() -> CLLocationCoordinate2D? {
        let s = store.settings
        if let lat = s.vineyardLatitude, let lon = s.vineyardLongitude,
           lat != 0 || lon != 0 {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        for paddock in store.paddocks {
            let pts = paddock.polygonPoints
            guard !pts.isEmpty else { continue }
            let lat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
            let lon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
            if lat != 0 || lon != 0 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return locationService.location?.coordinate
    }

    private func loadNearby() async {
        guard !isLoading else { return }
        guard let coord = resolveCoordinate() else {
            errorMessage = "No location available. Enter a station ID manually."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await WeatherNearbyStationsService().nearby(coordinate: coord)
            stations = result
            if result.isEmpty {
                errorMessage = "No nearby PWS stations found."
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

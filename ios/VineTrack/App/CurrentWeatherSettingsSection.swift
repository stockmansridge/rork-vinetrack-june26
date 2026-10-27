import SwiftUI

/// Member-readable normalized observations, separate from forecasts and rainfall history.
struct CurrentWeatherSettingsSection: View {
    @Environment(MigratedDataStore.self) private var store
    @State private var current: WeatherCurrentService.CachedSnapshot?
    @State private var extra: MAITSupplementarySensors?
    @State private var feedback: String?
    @State private var extraFeedback: String?
    @State private var busy = false
    @State private var loadedScope: String?
    private var scope: String { "\(store.selectedVineyardId?.uuidString ?? "none")/\(YieldMasterWeightCache.shared.scopeIdentity)" }
    private var fmt: RegionFormatter { store.settings.regionFormatter }
    var body: some View {
        Section {
            if loadedScope == scope, let current {
                LabeledContent("Provider", value: current.sourceLabel)
                if let station = current.stationName { LabeledContent("Station", value: station) }
                if let id = current.stationId { LabeledContent("Station ID", value: id) }
                LabeledContent("Observed", value: current.observedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not reported")
                LabeledContent("Reading status", value: current.isStale ? "Stale · last available" : current.status == "ok" ? "Observed" : "No current reading")
                if current.status == "ok" {
                    if let v = current.temperatureC, v.isFinite { LabeledContent("Temperature", value: String(format: "%.1f °C", v)) }
                    if let v = current.humidityPct, v.isFinite { LabeledContent("Humidity", value: String(format: "%.1f %%", v)) }
                    if let v = current.windSpeedKmh, v.isFinite { LabeledContent("Wind", value: fmt.formatSpeed(kmh: v, fractionDigits: 1)) }
                    if let v = current.windDirectionDeg, v.isFinite { LabeledContent("Wind direction", value: WeatherCurrentService.compassDirection(degrees: v)) }
                    if let v = current.windGustKmh, v.isFinite { LabeledContent("Wind gust", value: fmt.formatSpeed(kmh: v, fractionDigits: 1)) }
                    if let v = current.rainTodayMm, v.isFinite { LabeledContent("Rain today", value: fmt.formatRainfall(mm: v)) }
                    if let v = current.rainRateMmPerHr, v.isFinite { LabeledContent("Rain rate", value: fmt.formatRainfall(mm: v) + "/h") }
                    if let v = current.leafWetness, v.isFinite { LabeledContent("Leaf wetness", value: v.formatted()) }
                }
                if let extra {
                    ForEach(Array(extra.modules.enumerated()), id: \.offset) { _, module in
                        DisclosureGroup(module.friendlyName) {
                            Text(module.statusLabel).font(.caption)
                            if let time = module.observedAt { Text(time).font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(module.visibleReadings.enumerated()), id: \.offset) { _, reading in
                                LabeledContent(reading.title, value: reading.displayValue ?? "Unavailable")
                            }
                        }
                    }
                }
            } else { Text("No current station observation available.").foregroundStyle(.secondary) }
            if loadedScope == scope {
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                if let extraFeedback { Text(extraFeedback).font(.caption).foregroundStyle(.secondary) }
            }
            Button { Task { await reload(force: true) } } label: {
                HStack { Text(busy ? "Refreshing…" : "Refresh current weather"); if busy { ProgressView() } }
            }.disabled(busy || store.selectedVineyardId == nil)
        } header: { Text("Current Weather") }
        footer: { Text("Available station metrics only. Missing readings are not filled from another provider. Forecasts remain separate.") }
        .task(id: scope) { await reload(force: false) }
    }
    private func reload(force: Bool) async {
        guard let vineyard = store.selectedVineyardId else { return }
        let origin = scope
        if loadedScope != origin { current = nil; extra = nil; feedback = nil; extraFeedback = nil }
        loadedScope = origin
        busy = true
        defer { if scope == origin { busy = false } }
        func isCurrent() -> Bool { scope == origin && !Task.isCancelled }
        let service = WeatherCurrentService()
        do {
            let cached = try await service.fetchCachedCurrent(vineyardId: vineyard)
            guard isCurrent() else { return }
            current = WeatherCurrentService.CachedSnapshot.retainingLastKnown(cached, previous: current)
            if force {
                let before = current
                let refreshed = try await service.refreshSelectedCurrent(vineyardId: vineyard, force: true)
                guard isCurrent() else { return }
                current = WeatherCurrentService.CachedSnapshot.retainingLastKnown(refreshed, previous: current)
                if refreshed?.status == "not_configured" {
                    feedback = "No active local observation station is configured."
                } else if refreshed == nil || refreshed?.status != "ok" {
                    feedback = "No new observation returned. Last available readings are retained."
                } else if refreshed?.source == "mait_intelliweb", let observed = before?.observedAt, refreshed?.observedAt == observed {
                    feedback = "MAIT iNTELLiWeb returned no newer reading — the station has not reported since the last update."
                } else { feedback = "Selected observations refreshed." }
            }
        } catch {
            guard isCurrent() else { return }
            feedback = current?.refreshFailureMessage ?? "Live observations not refreshed — selected source"
        }
        guard isCurrent() else { return }
        if current?.source == "mait_intelliweb" {
            do {
                let fresh = try await service.fetchSupplementaryCurrent(vineyardId: vineyard)
                guard isCurrent() else { return }
                extra = fresh; extraFeedback = fresh.warning
            } catch {
                guard isCurrent() else { return }
                extraFeedback = MAITSupplementarySensors.warning
            }
        } else { extra = nil; extraFeedback = nil }
    }
}

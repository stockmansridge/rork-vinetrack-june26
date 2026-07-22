import Foundation

/// Caches the vineyard-level weather integration metadata and reflects it
/// into the per-vineyard `WeatherProviderConfig` so that *every* call site
/// (Irrigation Advisor, Rainfall Calendar, Disease Risk Advisor, alert
/// service…) sees the shared Davis station — including operator users
/// who never open the Weather Data settings screen.
///
/// The actual API Secret never enters the client; reads are routed via
/// the `davis-proxy` Edge Function.
@MainActor
final class VineyardWeatherIntegrationCache {
    static let shared = VineyardWeatherIntegrationCache()

    private let repository: any VineyardWeatherIntegrationRepositoryProtocol
    private var cached: [UUID: VineyardWeatherIntegration] = [:]
    private var inflight: [UUID: Task<Void, Never>] = [:]
    /// Marks vineyards we've already attempted to load this session so we
    /// don't refetch on every render.
    private var loadedOnce: Set<UUID> = []

    init(repository: any VineyardWeatherIntegrationRepositoryProtocol
         = SupabaseVineyardWeatherIntegrationRepository()) {
        self.repository = repository
    }

    /// Returns the cached integration for `vineyardId`, if any.
    func integration(for vineyardId: UUID) -> VineyardWeatherIntegration? {
        cached[vineyardId]
    }

    /// Ensures the vineyard's Davis WeatherLink integration has been
    /// loaded at least once this session. Subsequent callers re-use the
    /// cached value and return immediately. Network errors are silent —
    /// the existing fallback path keeps the app working.
    func ensureLoaded(for vineyardId: UUID) async {
        if loadedOnce.contains(vineyardId) { return }
        if let task = inflight[vineyardId] {
            await task.value
            return
        }
        let task = Task { [repository] in
            do {
                let integ = try await repository.fetch(
                    vineyardId: vineyardId,
                    provider: "davis_weatherlink"
                )
                await MainActor.run {
                    self.cached[vineyardId] = integ
                    print("[DavisConfig] cache load vineyardId=\(vineyardId) source=rpc configured=\(integ?.isFullyConfigured ?? false) hasKey=\(integ?.hasApiKey ?? false) hasSecret=\(integ?.hasApiSecret ?? false) stationId=\(integ?.stationId ?? "-")")
                    self.applyToConfig(integ, for: vineyardId)
                }
            } catch {
                print("[DavisConfig] local fallback used reason=\(error.localizedDescription) vineyardId=\(vineyardId)")
                // Silent fallback: leave config untouched.
            }
            await MainActor.run {
                self.loadedOnce.insert(vineyardId)
                self.inflight.removeValue(forKey: vineyardId)
            }
        }
        inflight[vineyardId] = task
        await task.value
    }

    /// Force a refresh (e.g. after the owner saves new credentials).
    func refresh(for vineyardId: UUID) async {
        loadedOnce.remove(vineyardId)
        inflight[vineyardId]?.cancel()
        inflight.removeValue(forKey: vineyardId)
        await ensureLoaded(for: vineyardId)
    }

    /// Clears cached state for a vineyard. Use when a user signs out or
    /// switches accounts.
    func invalidate(_ vineyardId: UUID) {
        cached.removeValue(forKey: vineyardId)
        loadedOnce.remove(vineyardId)
        inflight[vineyardId]?.cancel()
        inflight.removeValue(forKey: vineyardId)
    }

    func invalidateAll() {
        cached.removeAll()
        loadedOnce.removeAll()
        for (_, t) in inflight { t.cancel() }
        inflight.removeAll()
    }

    /// Mirrors the integration onto the per-vineyard
    /// `WeatherProviderConfig`. Operators (no Keychain credentials) still
    /// see the configured station, and `davisIsVineyardShared` flips on
    /// so reads are routed through the proxy.
    private func applyToConfig(
        _ integ: VineyardWeatherIntegration?,
        for vineyardId: UUID
    ) {
        var c = WeatherProviderStore.shared.config(for: vineyardId)
        if let integ {
            c.davisIsVineyardShared = true
            c.davisVineyardHasServerCredentials = integ.hasApiSecret
            c.davisVineyardConfiguredBy = integ.configuredBy
            c.davisVineyardUpdatedAt = integ.updatedAt
            if let sid = integ.stationId, !sid.isEmpty {
                c.davisStationId = sid
                c.davisStationName = integ.stationName
                c.davisHasLeafWetnessSensor = integ.hasLeafWetness
                c.davisDetectedSensors = integ.detectedSensors
                // The vineyard-level integration counts as a "tested"
                // connection for read paths — every member trusts the
                // owner/manager's setup.
                c.davisConnectionTested = true
                // If the user hasn't explicitly chosen a local source,
                // use the vineyard's Davis as the local observation
                // source so labels/source resolution work everywhere.
                if c.localObservationProvider == .none {
                    c.localObservationProvider = .davis
                }
            }
        } else {
            c.davisIsVineyardShared = false
            c.davisVineyardHasServerCredentials = false
            c.davisVineyardConfiguredBy = nil
            c.davisVineyardUpdatedAt = nil
        }
        WeatherProviderStore.shared.save(c, for: vineyardId)
    }
}

import Foundation
import Observation

/// Canonical seasonal yield estimate state (sql/221).
///
/// This is the ONLY base-estimate authority in the app: every yield surface
/// reads ``projection(damageRecords:applyDamage:...)`` rather than deriving a
/// crop total of its own. `season_yield_estimates` is client read-only — the
/// single write path is ``refreshAfterPruningSettingsSaved(vineyardId:vintage:)``,
/// which asks the server to re-derive the vintage and then reloads.
@Observable
@MainActor
final class SeasonYieldEstimateService {
    private let repository = SupabaseSeasonYieldRepository()

    private(set) var overview: BackendSeasonYieldOverview?
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    private(set) var lastError: String?
    private(set) var loadedVineyardId: UUID?
    private(set) var loadedVintage: Int?

    /// Apply Damage is OFF by default: the canonical base estimate is what the
    /// user sees first, and damage is an explicit, reversible overlay.
    var applyDamage: Bool = false

    /// True when the loaded contract belongs to this vineyard + vintage.
    func isLoaded(vineyardId: UUID, vintage: Int) -> Bool {
        loadedVineyardId == vineyardId && loadedVintage == vintage && overview != nil
    }

    /// Load the canonical base overview. Safe to call repeatedly; pass
    /// `force: false` to skip when the same vineyard + vintage is already held.
    func load(vineyardId: UUID, vintage: Int, force: Bool = true) async {
        if !force, isLoaded(vineyardId: vineyardId, vintage: vintage) { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await repository.fetchOverview(vineyardId: vineyardId, vintage: vintage)
            overview = result
            loadedVineyardId = vineyardId
            loadedVintage = vintage
            lastError = nil
        } catch {
            // Keep whatever was already loaded — a failed refresh must not
            // blank a total the user is reading.
            if loadedVineyardId != vineyardId || loadedVintage != vintage {
                overview = nil
                loadedVineyardId = nil
                loadedVintage = nil
            }
            lastError = "Couldn't load the seasonal yield estimate. Check your connection and try again."
            print("[SeasonYieldEstimateService] load failed: \(error)")
        }
    }

    /// Called after Pruning Yield Calculator settings are saved: re-derive the
    /// vintage's pruning estimates server-side, then reload the overview so
    /// every surface shows the new numbers.
    ///
    /// The refresh never downgrades a bunch_count or manual estimate — the
    /// server skips those rows and reports them as skipped.
    @discardableResult
    func refreshAfterPruningSettingsSaved(vineyardId: UUID, vintage: Int) async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await repository.refreshPruningEstimates(vineyardId: vineyardId, vintage: vintage)
            await load(vineyardId: vineyardId, vintage: vintage)
            return lastError == nil
        } catch {
            lastError = "Couldn't update the seasonal yield estimate. Your settings were saved — pull to refresh to try again."
            print("[SeasonYieldEstimateService] refresh failed: \(error)")
            return false
        }
    }

    /// Clear on vineyard switch so one vineyard's crop total can never be read
    /// against another's.
    func reset() {
        overview = nil
        loadedVineyardId = nil
        loadedVintage = nil
        lastError = nil
    }

    /// The display model for the loaded contract, with damage applied per
    /// block when the toggle is on.
    ///
    /// - Parameter damageRecords: the app's full damage list; it is filtered
    ///   here to this vineyard AND this vintage.
    func projection(
        damageRecords: [DamageRecord],
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> SeasonYieldProjection.Result? {
        guard let overview else { return nil }
        let scoped = SeasonYieldProjection.damageRecords(
            damageRecords,
            vineyardId: overview.vineyardId,
            vintage: overview.vintage,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay
        )
        return SeasonYieldProjection.make(
            overview: overview,
            damageRecords: scoped,
            applyDamage: applyDamage
        )
    }
}

import Foundation
import Observation
import Supabase
import PostgREST

/// Only successful, authenticated resolver responses enter this account/vineyard-scoped cache.
@MainActor @Observable final class YieldMasterWeightCache {
    static let shared = YieldMasterWeightCache()
    private var snapshots: [String: [String: YieldMasterWeight]] = [:]
    private var requests: [String: UUID] = [:]
    private let defaults: UserDefaults
    private let provider: SupabaseClientProvider
    private let accountBinding: @MainActor () -> String?
    private let generation: @MainActor () -> UInt64
    private let resolve: ((UUID, UUID, String) async throws -> YieldMasterWeight)?
    init(defaults: UserDefaults = .standard, provider: SupabaseClientProvider = .shared,
         accountBinding: @escaping @MainActor () -> String? = { VineyardWriteAuthority.shared.accountBinding },
         generation: @escaping @MainActor () -> UInt64 = { VineyardWriteAuthority.shared.accountGeneration },
         resolve: ((UUID, UUID, String) async throws -> YieldMasterWeight)? = nil) {
        self.defaults = defaults
        self.provider = provider
        self.accountBinding = accountBinding
        self.generation = generation
        self.resolve = resolve
    }
    var scopeIdentity: String {
        "\(accountBinding() ?? "signed-out")/\(generation())"
    }
    private func scope(_ vineyardId: UUID) -> String? {
        accountBinding().map { "yield.master.confirmed.v1/\($0.lowercased())/\(vineyardId.uuidString.lowercased())" }
    }
    func weights(vineyardId: UUID?) -> [String: YieldMasterWeight] {
        guard let vineyardId, let scope = scope(vineyardId) else { return [:] }
        if let snapshot = snapshots[scope] { return snapshot }
        return defaults.data(forKey: scope).flatMap { try? JSONDecoder().decode([String: YieldMasterWeight].self, from: $0) } ?? [:]
    }
    /// A complete, authenticated table read is also confirmation of absence.
    func installConfirmedRows(_ rows: [YieldBunchWeightRow], vineyardId: UUID, paddocks: [Paddock]) {
        guard let scope = scope(vineyardId) else { return }
        requests[scope] = UUID() // an older resolver response must not replace a newer management read
        var snapshot: [String: YieldMasterWeight] = [:]
        for paddock in paddocks where paddock.vineyardId == vineyardId {
            for planting in CurrentYieldEstimate.plantings(paddock) {
                snapshot[CurrentYieldEstimate.key(blockId: paddock.id, varietyKey: planting.key)] = YieldBunchWeightRow.resolved(rows, vineyard: vineyardId, block: paddock.id, key: planting.key)
            }
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: scope)
        snapshots[scope] = snapshot
    }
    private nonisolated struct Args: Encodable, Sendable {
        let p_vineyard_id: UUID
        let p_paddock_id: UUID
        let p_variety_key: String
    }
    func refresh(vineyardId: UUID?, paddocks: [Paddock]) async {
        guard let vineyardId, let scope = scope(vineyardId), provider.isConfigured || resolve != nil else { return }
        let origin = scopeIdentity
        let request = UUID()
        requests[scope] = request
        var snapshot = weights(vineyardId: vineyardId)
        for paddock in paddocks {
            for planting in CurrentYieldEstimate.plantings(paddock) {
                guard !Task.isCancelled, origin == scopeIdentity, requests[scope] == request else { return }
                do {
                    let result: YieldMasterWeight
                    if let resolve {
                        result = try await resolve(vineyardId, paddock.id, planting.key)
                    } else {
                        result = try await provider.client
                            .rpc("resolve_yield_bunch_weight", params: Args(p_vineyard_id: vineyardId, p_paddock_id: paddock.id, p_variety_key: planting.key))
                            .execute().value
                    }
                    guard !Task.isCancelled, origin == scopeIdentity, requests[scope] == request else { return }
                    guard result.varietyKey == planting.key,
                          ["block_override", "variety_default", "not_configured"].contains(result.source),
                          result.source == "not_configured" || result.kg != nil else { continue }
                    // A confirmed absence replaces a former available result; errors retain last confirmed values.
                    snapshot[CurrentYieldEstimate.key(blockId: paddock.id, varietyKey: planting.key)] = result
                    let data = try JSONEncoder().encode(snapshot)
                    defaults.set(data, forKey: scope)
                    snapshots[scope] = snapshot
                } catch { /* Offline/forbidden/unparseable is not confirmation of absence. */ }
            }
        }
    }
}

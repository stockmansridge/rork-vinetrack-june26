import Foundation
import Observation
import Supabase
import PostgREST

/// Only successful, authenticated resolver responses enter this account/vineyard-scoped cache.
@MainActor @Observable final class YieldMasterWeightCache {
    static let shared = YieldMasterWeightCache()
    private var snapshots: [String: [String: YieldMasterWeight]] = [:]
    private var requests: [String: UUID] = [:]
    private var failures: [String: String] = [:]
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
    func syncError(vineyardId: UUID?) -> String? {
        guard let vineyardId, let scope = scope(vineyardId) else { return nil }
        return failures[scope]
    }

    /// Full Sync and the Yield screens share the same complete paginated read.
    /// Only a successful current-account read can replace previously confirmed weights.
    func synchronize(vineyardId: UUID, paddocks: [Paddock],
                     fetch: ((UUID) async throws -> [YieldBunchWeightRow])? = nil) async throws {
        guard let scope = scope(vineyardId) else { throw CancellationError() }
        let origin = scopeIdentity, request = UUID()
        requests[scope] = request
        do {
            let rows: [YieldBunchWeightRow]
            if let fetch { rows = try await fetch(vineyardId) }
            else { rows = try await YieldBunchWeightsRepository(provider: provider, defaults: defaults).fetch(vineyard: vineyardId) }
            try Task.checkCancellation()
            guard origin == scopeIdentity, requests[scope] == request else { throw CancellationError() }
            guard rows.allSatisfy({ $0.vineyardId == vineyardId && $0.isValid }),
                  Set(rows.map(\.id)).count == rows.count else { throw URLError(.cannotParseResponse) }
            installConfirmedRows(rows, vineyardId: vineyardId, paddocks: paddocks)
            failures.removeValue(forKey: scope)
        } catch {
            if origin == scopeIdentity, requests[scope] == request {
                failures[scope] = "Shared bunch weights could not refresh; saved values may be out of date."
            }
            throw error
        }
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
        failures.removeValue(forKey: scope)
    }
    private nonisolated struct Args: Encodable, Sendable {
        let p_vineyard_id: UUID
        let p_paddock_id: UUID
        let p_variety_key: String
    }
    func refresh(vineyardId: UUID?, paddocks: [Paddock]) async {
        if resolve == nil {
            guard let vineyardId else { return }
            do { try await synchronize(vineyardId: vineyardId, paddocks: paddocks) }
            catch { /* synchronize retains confirmed data and publishes a scoped stale warning. */ }
            return
        }
        guard let vineyardId, let scope = scope(vineyardId), provider.isConfigured || resolve != nil else { return }
        let origin = scopeIdentity
        let request = UUID()
        requests[scope] = request
        var snapshot = weights(vineyardId: vineyardId)
        for paddock in paddocks where paddock.vineyardId == vineyardId {
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

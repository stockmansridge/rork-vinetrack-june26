import Foundation
import Observation
import Supabase
import PostgREST

/// Shared rows, never historical/device-only weights. The server still enforces membership/roles.
nonisolated struct YieldBunchWeightRow: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let varietyKey: String
    let varietyName: String
    let grams: Double
    let updatedAt: String?
    enum CodingKeys: String, CodingKey {
        case id, vineyardId = "vineyard_id", paddockId = "paddock_id"
        case varietyKey = "variety_key", varietyName = "variety_name"
        case grams = "bunch_weight_grams", updatedAt = "updated_at"
    }
    var isValid: Bool { grams.isFinite && grams > 0 && grams <= 5000 && !varietyKey.isEmpty }
    static func resolved(_ rows: [Self], vineyard: UUID, block: UUID, key: String) -> YieldMasterWeight {
        let scoped = rows.filter { $0.vineyardId == vineyard && $0.varietyKey == key && $0.isValid }
        let row = scoped.first { $0.paddockId == block } ?? scoped.first { $0.paddockId == nil }
        return YieldMasterWeight(bunchWeightGrams: row?.grams, source: row.map { $0.paddockId == nil ? "variety_default" : "block_override" } ?? "not_configured", recordId: row?.id, varietyKey: key)
    }
}

@MainActor
struct YieldBunchWeightsRepository {
    private let transport: any YieldBunchWeightsTransport
    private let currentUserId: () -> UUID?
    private let defaults: UserDefaults
    let authority: VineyardWriteAuthority
    init(provider: SupabaseClientProvider = .shared, authority: VineyardWriteAuthority = .shared,
         defaults: UserDefaults = .standard, transport: (any YieldBunchWeightsTransport)? = nil,
         currentUserId: (() -> UUID?)? = nil) {
        self.transport = transport ?? SupabaseYieldBunchWeightsTransport(provider: provider)
        self.currentUserId = currentUserId ?? { provider.client.auth.currentUser?.id }
        self.defaults = defaults
        self.authority = authority
    }
    nonisolated struct Page: Sendable { let rows: [YieldBunchWeightRow]; let count: Int? }
    nonisolated struct SaveArgs: Encodable, Sendable {
        let p_vineyard_id: UUID
        let p_paddock_id: UUID?
        let p_variety_key: String
        let p_variety_name: String
        let p_bunch_weight_grams: Double
        // Explicit null is required: a variety master has no block.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(p_vineyard_id, forKey: .p_vineyard_id)
            try c.encode(p_paddock_id, forKey: .p_paddock_id)
            try c.encode(p_variety_key, forKey: .p_variety_key)
            try c.encode(p_variety_name, forKey: .p_variety_name)
            try c.encode(p_bunch_weight_grams, forKey: .p_bunch_weight_grams)
        }
        enum CodingKeys: String, CodingKey { case p_vineyard_id, p_paddock_id, p_variety_key, p_variety_name, p_bunch_weight_grams }
    }
    private var identity: String { "\(authority.accountBinding ?? "signed-out")/\(authority.accountGeneration)" }
    private func requireAccount(_ origin: String) throws {
        guard let user = currentUserId(), authority.accountBinding?.lowercased() == user.uuidString.lowercased(), origin == identity else { throw CancellationError() }
    }
    private func cacheKey(_ vineyard: UUID) -> String { "yield.management.confirmed.v1/\(authority.accountBinding?.lowercased() ?? "signed-out")/\(vineyard.uuidString.lowercased())" }
    func cached(vineyard: UUID) -> [YieldBunchWeightRow]? {
        guard authority.accountBinding != nil, let data = defaults.data(forKey: cacheKey(vineyard)),
              let rows = try? JSONDecoder().decode([YieldBunchWeightRow].self, from: data),
              rows.allSatisfy({ $0.vineyardId == vineyard && $0.isValid }) else { return nil }
        return rows
    }
    func fetch(vineyard: UUID) async throws -> [YieldBunchWeightRow] {
        let origin = identity
        try requireAccount(origin)
        var rows: [YieldBunchWeightRow] = []
        var total: Int?
        repeat {
            try Task.checkCancellation()
            let response = try await transport.page(vineyard: vineyard, offset: rows.count)
            try requireAccount(origin)
            let page = response.rows
            guard let count = response.count, count >= 0, count <= 100_000,
                  total == nil || total == count,
                  !page.isEmpty || rows.count == count else { throw URLError(.cannotParseResponse) }
            total = count
            rows.append(contentsOf: page)
            guard rows.count <= count, Set(rows.map(\.id)).count == rows.count,
                  page.allSatisfy({ $0.vineyardId == vineyard && $0.isValid }) else { throw URLError(.cannotParseResponse) }
        } while rows.count < (total ?? 0)
        try Task.checkCancellation()
        try requireAccount(origin)
        defaults.set(try JSONEncoder().encode(rows), forKey: cacheKey(vineyard))
        return rows
    }
    func save(vineyard: UUID, block: UUID?, key: String, name: String, grams: Double) async throws {
        guard grams.isFinite, grams > 0, grams <= 5000, !key.isEmpty, !name.isEmpty else { throw URLError(.badURL) }
        let origin = identity
        try requireAccount(origin)
        let admission = try VineyardMutationAdmission(currentUserId: currentUserId, authority: authority)
        try authority.requireWrite(vineyardId: vineyard.uuidString)
        do {
            _ = try await admission.send(vineyardId: vineyard) {
                try await transport.save(SaveArgs(p_vineyard_id: vineyard, p_paddock_id: block, p_variety_key: key, p_variety_name: name, p_bunch_weight_grams: grams))
            }
            try requireAccount(origin)
        } catch {
            if origin == identity, let error = error as? PostgrestError { _ = authority.handleServerCode(error.code, vineyardId: vineyard.uuidString) }
            throw error
        }
    }
    func remove(_ row: YieldBunchWeightRow) async throws {
        let origin = identity
        try requireAccount(origin)
        let admission = try VineyardMutationAdmission(currentUserId: currentUserId, authority: authority)
        try authority.requireWrite(vineyardId: row.vineyardId.uuidString)
        do {
            let vineyard = try await admission.resolve(id: row.id, expectedVineyardId: row.vineyardId) {
                try await transport.ownership(id: row.id)
            }
            _ = try await admission.send(vineyardId: vineyard) {
                try await transport.remove(id: row.id)
            }
            try requireAccount(origin)
        } catch {
            if origin == identity, let error = error as? PostgrestError { _ = authority.handleServerCode(error.code, vineyardId: row.vineyardId.uuidString) }
            throw error
        }
    }
}

/// Narrow transport boundary; tests replace requests, not admission, paging or cache logic.
@MainActor protocol YieldBunchWeightsTransport {
    func page(vineyard: UUID, offset: Int) async throws -> YieldBunchWeightsRepository.Page
    func save(_ args: YieldBunchWeightsRepository.SaveArgs) async throws
    func ownership(id: UUID) async throws -> [VineyardMutationAdmission.Ownership]
    func remove(id: UUID) async throws
}

@MainActor private struct SupabaseYieldBunchWeightsTransport: YieldBunchWeightsTransport {
    let provider: SupabaseClientProvider
    nonisolated struct DeleteArgs: Encodable, Sendable { let p_id: UUID }
    func page(vineyard: UUID, offset: Int) async throws -> YieldBunchWeightsRepository.Page {
        let response = try await provider.client.from("yield_bunch_weights")
            .select("id,vineyard_id,paddock_id,variety_key,variety_name,bunch_weight_grams,updated_at", count: .exact)
            .eq("vineyard_id", value: vineyard.uuidString).is("deleted_at", value: nil)
            .order("updated_at", ascending: false).order("id", ascending: true)
            .range(from: offset, to: offset + 199).execute()
        return .init(rows: try JSONDecoder().decode([YieldBunchWeightRow].self, from: response.data), count: response.count)
    }
    func save(_ args: YieldBunchWeightsRepository.SaveArgs) async throws {
        try await provider.client.rpc("upsert_yield_bunch_weight", params: args).execute()
    }
    func ownership(id: UUID) async throws -> [VineyardMutationAdmission.Ownership] {
        try await provider.client.from("yield_bunch_weights").select("id,vineyard_id").eq("id", value: id.uuidString).is("deleted_at", value: nil).execute().value
    }
    func remove(id: UUID) async throws {
        try await provider.client.rpc("soft_delete_yield_bunch_weight", params: DeleteArgs(p_id: id)).execute()
    }
}

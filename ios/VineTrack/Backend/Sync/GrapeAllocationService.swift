import Foundation
import Observation

/// Grape Allocation state for the selected vineyard (sql/217).
///
/// Load pulls the RLS-visible allocation rows + block splits and then merges
/// owner/manager money from `get_grape_allocation_financials`; lower roles
/// get 42501 from that RPC, which is swallowed — their `allocations` simply
/// never carry a price. Writes are direct RLS-guarded upserts (the sql/217
/// routing trigger keeps money off the base row), deletes go through the
/// soft-delete RPC.
@Observable
@MainActor
final class GrapeAllocationService {
    private let repository = SupabaseGrapeAllocationRepository()

    private(set) var allocations: [GrapeAllocation] = []
    /// true when the server actually returned financials (owner/manager).
    private(set) var hasFinancialAccess: Bool = false
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?
    private(set) var loadedVineyardId: UUID?

    func load(vineyardId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let rowsTask = repository.fetch(vineyardId: vineyardId)
            async let blocksTask = repository.fetchBlocks(vineyardId: vineyardId)
            let rows = try await rowsTask
            let blockRows = try await blocksTask

            let blocksByAllocation = Dictionary(grouping: blockRows, by: \.allocationId)
            var merged: [GrapeAllocation] = rows
                .filter { $0.deletedAt == nil }
                .map { row in
                    let blocks = (blocksByAllocation[row.id] ?? [])
                        .map { $0.toGrapeAllocationBlock() }
                        .sorted { $0.paddockName.localizedCaseInsensitiveCompare($1.paddockName) == .orderedAscending }
                    return row.toGrapeAllocation(blocks: blocks)
                }

            // Owner/manager money merge — other roles legitimately get 42501.
            do {
                let financials = try await repository.fetchFinancials(vineyardId: vineyardId)
                let priceById = Dictionary(financials.map { ($0.allocationId, $0.pricePerTonne) }, uniquingKeysWith: { a, _ in a })
                for index in merged.indices {
                    merged[index].pricePerTonne = priceById[merged[index].id] ?? nil
                }
                hasFinancialAccess = true
            } catch {
                hasFinancialAccess = false
            }

            allocations = merged
            loadedVineyardId = vineyardId
            lastError = nil
        } catch {
            lastError = "Couldn't load grape allocations. Check your connection and try again."
            print("[GrapeAllocationService] load failed: \(error)")
        }
    }

    func save(_ allocation: GrapeAllocation, createdBy: UUID?) async throws {
        let upsert = BackendGrapeAllocation.upsert(from: allocation, createdBy: createdBy, clientUpdatedAt: Date())
        try await repository.upsert(upsert)
        let blockInserts = allocation.blocks.map {
            BackendGrapeAllocationBlockInsert(
                id: $0.id,
                allocationId: allocation.id,
                vineyardId: allocation.vineyardId,
                paddockId: $0.paddockId,
                paddockName: $0.paddockName,
                quantityTonnes: $0.quantityTonnes
            )
        }
        try await repository.replaceBlocks(allocationId: allocation.id, blocks: blockInserts)

        var stored = allocation
        if !hasFinancialAccess { stored.pricePerTonne = nil }
        if stored.allocationType == .ownUse { stored.pricePerTonne = nil }
        if let index = allocations.firstIndex(where: { $0.id == allocation.id }) {
            allocations[index] = stored
        } else {
            allocations.insert(stored, at: 0)
        }
    }

    func delete(id: UUID) async throws {
        try await repository.softDelete(id: id)
        allocations.removeAll { $0.id == id }
    }
}

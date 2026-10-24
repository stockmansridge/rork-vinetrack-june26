import Foundation
import Supabase

/// Per-operation account binding for independent database/storage sends.
/// Reads and genuine successful acknowledgements are deliberately not write-gated.
@MainActor
struct VineyardMutationAdmission {
    nonisolated struct Ownership: Decodable, Sendable {
        let id: UUID
        let vineyardId: UUID
        enum CodingKeys: String, CodingKey { case id; case vineyardId = "vineyard_id" }
    }

    private let owner: UUID
    private let currentUserId: () -> UUID?
    private let authority: VineyardWriteAuthority
    private let binding: String

    init(provider: SupabaseClientProvider = .shared) throws {
        try self.init(currentUserId: { provider.client.auth.currentUser?.id }, authority: .shared)
    }

    init(currentUserId: @escaping () -> UUID?, authority: VineyardWriteAuthority) throws {
        guard let owner = currentUserId() else { throw BackendRepositoryError.missingAuthenticatedUser }
        // A restored SDK session must not outrun account binding and thereby
        // bypass a durable hold hidden behind an unbound ledger.
        guard let binding = authority.accountBinding,
              binding.lowercased() == owner.uuidString.lowercased() else {
            throw BackendRepositoryError.missingAuthenticatedUser
        }
        self.owner = owner
        self.currentUserId = currentUserId
        self.authority = authority
        self.binding = binding
    }

    private func requireAccount() throws {
        guard currentUserId() == owner, authority.accountBinding == binding else {
            throw BackendRepositoryError.missingAuthenticatedUser
        }
    }

    func requireWrite(vineyardId: UUID) throws {
        try requireAccount()
        try authority.requireWrite(vineyardId: vineyardId.uuidString)
    }

    /// Exact authenticated row ownership, never the current selection. No limit(1):
    /// duplicate/ambiguous rows must not become permission to mutate.
    func resolve(id: UUID, expectedVineyardId: UUID? = nil, allowMissingForCreate: Bool = false,
                 read: () async throws -> [Ownership]) async throws -> UUID {
        try requireAccount()
        let rows = try await read()
        try requireAccount()
        if rows.isEmpty, allowMissingForCreate, let vineyard = expectedVineyardId {
            try requireWrite(vineyardId: vineyard)
            return vineyard
        }
        guard rows.count == 1, let row = rows.first, row.id == id,
              expectedVineyardId == nil || row.vineyardId == expectedVineyardId else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        try requireWrite(vineyardId: row.vineyardId)
        return row.vineyardId
    }

    func send<T>(vineyardId: UUID, operation: () async throws -> T) async throws -> T {
        try requireWrite(vineyardId: vineyardId)
        do {
            // A successful send remains acknowledged if expiry arrives in flight.
            return try await operation()
        } catch {
            try requireAccount()
            if error is VineyardWriteAuthority.Restricted { throw error }
            if authority.handleServerCode((error as? PostgrestError)?.code, vineyardId: vineyardId.uuidString) {
                throw VineyardWriteAuthority.Restricted(reason: authority.heldReason(vineyardId: vineyardId.uuidString) ?? "VT_READ_ONLY")
            }
            throw error
        }
    }
}

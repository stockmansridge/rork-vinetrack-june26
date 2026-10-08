import Foundation
import Supabase

/// Thin directory access through the deployed member/owner-manager RLS contract.
final class SupabaseExternalResourceRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func list(vineyardId: UUID) async throws -> [VineyardExternalResource] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client.from("vineyard_external_resources").select()
            .eq("vineyard_id", value: vineyardId.uuidString).order("name").execute().value
    }

    /// Inserts only; a duplicate ID is read and compared, never converted to an update.
    func create(_ resource: VineyardExternalResource) async throws -> VineyardExternalResource {
        try validate(resource)
        do {
            let rows: [VineyardExternalResource] = try await provider.client.from("vineyard_external_resources")
                .insert(ResourceWrite(resource)).select().execute().value
            guard let row = rows.first, ResourceWrite(row) == ResourceWrite(resource) else { throw DirectoryWriteError.unacknowledged }
            return row
        } catch {
            let rows: [VineyardExternalResource] = try await provider.client.from("vineyard_external_resources").select()
                .eq("id", value: resource.id.uuidString).eq("vineyard_id", value: resource.vineyardId.uuidString).execute().value
            guard let row = rows.first, ResourceWrite(row) == ResourceWrite(resource) else { throw DirectoryWriteError.unacknowledged }
            return row
        }
    }

    /// Server-side conditional PATCH checks the entire observed editable state, not a read-before-write check.
    /// No offline replay and no automatic rebase. A zero-row result is a visible conflict.
    func update(_ resource: VineyardExternalResource, expected: VineyardExternalResource) async throws -> VineyardExternalResource {
        try validate(resource)
        guard resource.id == expected.id, resource.vineyardId == expected.vineyardId,
              let timestamp = expected.updatedAt, expected.deletedAt == nil else { throw DirectoryWriteError.conflict }
        var query = try provider.client.from("vineyard_external_resources").update(ResourceWrite(resource))
            .eq("id", value: expected.id.uuidString).eq("vineyard_id", value: expected.vineyardId.uuidString)
            .eq("updated_at", value: timestamp).is("deleted_at", value: nil)
            .eq("name", value: expected.name).eq("kind", value: expected.kind).eq("is_active", value: expected.isActive)
        for (key, value) in [("contact_name", expected.contactName), ("phone", expected.phone), ("email", expected.email), ("notes", expected.notes)] {
            if let value { query = query.eq(key, value: value) } else { query = query.is(key, value: nil) }
        }
        let rows: [VineyardExternalResource] = try await query.select().execute().value
        guard let row = rows.first, ResourceWrite(row) == ResourceWrite(resource) else { throw DirectoryWriteError.conflict }
        return row
    }

    private func validate(_ resource: VineyardExternalResource) throws {
        guard provider.isConfigured, !resource.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["crew", "contractor"].contains(resource.kind), resource.deletedAt == nil else { throw DirectoryWriteError.invalid }
    }
}

nonisolated enum DirectoryWriteError: LocalizedError {
    case conflict, unacknowledged, invalid
    var errorDescription: String? {
        switch self {
        case .conflict: "The resource changed or permission is no longer available. Your edits are retained. Close and reopen to review the latest directory before editing again."
        case .unacknowledged: "Creation was not confirmed. Your form and resource ID are retained; reconnect and retry."
        case .invalid: "Enter a resource name and select Crew or External Contractor."
        }
    }
}

/// Explicit null contact fields permit intentional clearing without altering audit columns.
nonisolated struct ResourceWrite: Encodable, Equatable {
    let resource: VineyardExternalResource
    init(_ resource: VineyardExternalResource) { self.resource = resource }
    static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.resource; let b = rhs.resource
        return a.id == b.id && a.vineyardId == b.vineyardId && a.name == b.name && a.kind == b.kind && a.contactName == b.contactName && a.phone == b.phone && a.email == b.email && a.notes == b.notes && a.isActive == b.isActive && b.deletedAt == nil && a.deletedAt == nil
    }
    enum CodingKeys: String, CodingKey { case id, name, kind, phone, email, notes; case vineyardID = "vineyard_id", contact = "contact_name", active = "is_active" }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resource.id, forKey: .id); try c.encode(resource.vineyardId, forKey: .vineyardID)
        try c.encode(resource.name, forKey: .name); try c.encode(resource.kind, forKey: .kind)
        try c.encode(resource.isActive, forKey: .active)
        try c.encode(resource.contactName, forKey: .contact); try c.encode(resource.phone, forKey: .phone)
        try c.encode(resource.email, forKey: .email); try c.encode(resource.notes, forKey: .notes)
    }
}

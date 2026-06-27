import Foundation

/// Vineyard-scoped custom Trip Function. Mirrors the
/// `public.vineyard_trip_functions` table introduced in
/// `sql/037_vineyard_trip_functions.sql`.
///
/// Built-in trip functions (e.g. Slashing, Seeding, …) live in the
/// `TripFunction` enum and are NOT stored in this table.
nonisolated struct VineyardTripFunction: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var vineyardId: UUID
    var label: String
    var slug: String
    var isActive: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        label: String,
        slug: String,
        isActive: Bool = true,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.label = label
        self.slug = slug
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

extension VineyardTripFunction {
    /// Convert a free-text label into a stable slug usable in
    /// `trips.trip_function = "custom:<slug>"`. Conforms to the SQL CHECK
    /// constraint `^[a-z0-9][a-z0-9_-]*$` and length <= 64.
    nonisolated static func slugify(_ label: String) -> String {
        let lower = label.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        var out = ""
        var lastDash = false
        for scalar in lower.unicodeScalars {
            if allowed.contains(scalar) {
                out.append(Character(scalar))
                lastDash = false
            } else if scalar == " " || scalar == "_" || scalar == "-" {
                if !lastDash, !out.isEmpty {
                    out.append("-")
                    lastDash = true
                }
            }
            // anything else is dropped
        }
        // Trim leading/trailing dashes/underscores.
        while out.first == "-" || out.first == "_" { out.removeFirst() }
        while out.last == "-" || out.last == "_" { out.removeLast() }
        if out.isEmpty { return "custom" }
        if out.count > 64 { out = String(out.prefix(64)) }
        return out
    }
}

// MARK: - Backend wire model

nonisolated struct BackendVineyardTripFunction: Codable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let label: String
    let slug: String
    let isActive: Bool
    let sortOrder: Int
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case label
        case slug
        case isActive = "is_active"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

nonisolated struct BackendVineyardTripFunctionUpsert: Codable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let label: String
    let slug: String
    let isActive: Bool
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case label
        case slug
        case isActive = "is_active"
        case sortOrder = "sort_order"
    }
}

extension VineyardTripFunction {
    nonisolated init(backend b: BackendVineyardTripFunction) {
        self.init(
            id: b.id,
            vineyardId: b.vineyardId,
            label: b.label,
            slug: b.slug,
            isActive: b.isActive,
            sortOrder: b.sortOrder,
            createdAt: b.createdAt ?? Date(),
            updatedAt: b.updatedAt ?? Date(),
            deletedAt: b.deletedAt
        )
    }

    nonisolated var upsertPayload: BackendVineyardTripFunctionUpsert {
        BackendVineyardTripFunctionUpsert(
            id: id,
            vineyardId: vineyardId,
            label: label,
            slug: slug,
            isActive: isActive,
            sortOrder: sortOrder
        )
    }
}

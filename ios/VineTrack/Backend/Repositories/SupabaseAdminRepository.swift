import Foundation
import Supabase

nonisolated struct AdminEngagementSummary: Sendable {
    let totalUsers: Int
    let totalVineyards: Int
    let totalPins: Int
    let totalSprayRecords: Int
    let totalWorkTasks: Int
    let signedInLast7Days: Int
    let signedInLast30Days: Int
    let newUsersLast30Days: Int
    let pendingInvitations: Int
}

/// Platform-wide scale metrics for the Admin dashboard. Reporting/marketing
/// only — derived from active vineyards/blocks, never affects calculations.
nonisolated struct AdminPlatformScale: Sendable {
    let totalHectaresUnderManagement: Double
    let totalVineyards: Int
    let totalActivePaddocks: Int
    let totalPaddocksWithArea: Int
    let averageHectaresPerVineyard: Double
}

nonisolated struct AdminUserRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let email: String
    let fullName: String?
    let createdAt: Date?
    let updatedAt: Date?
    let lastSignInAt: Date?
    let vineyardCount: Int
    let ownedCount: Int
    let blockCount: Int

    var displayName: String {
        if let name = fullName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return email
    }
}

nonisolated struct AdminVineyardRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let ownerId: UUID?
    let ownerEmail: String?
    let ownerFullName: String?
    let country: String?
    let createdAt: Date?
    let deletedAt: Date?
    let memberCount: Int
    let pendingInvites: Int

    var ownerDisplay: String {
        if let n = ownerFullName, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return ownerEmail ?? "—"
    }
}

nonisolated struct AdminUserVineyardRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let role: String?
    let isOwner: Bool
    let country: String?
    let createdAt: Date?
    let deletedAt: Date?
    let memberCount: Int
}

nonisolated struct AdminInvitationRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let email: String
    let role: String
    let status: String
    let vineyardId: UUID?
    let vineyardName: String?
    let invitedBy: UUID?
    let invitedByEmail: String?
    let createdAt: Date?
    let expiresAt: Date?
}

nonisolated struct AdminPinRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID?
    let vineyardName: String?
    let title: String
    let category: String?
    let status: String?
    let createdAt: Date?
    let isCompleted: Bool
}

nonisolated struct AdminSprayRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID?
    let vineyardName: String?
    let sprayReference: String?
    let operationType: String?
    let date: Date?
    let createdAt: Date?
}

nonisolated struct AdminWorkTaskRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID?
    let vineyardName: String?
    let taskType: String?
    let paddockName: String?
    let date: Date?
    let durationHours: Double?
    let createdAt: Date?
}

nonisolated struct AdminVineyardPaddockRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let polygonPoints: [CoordinatePoint]
    let rows: [PaddockRow]
    let rowCount: Int
    let rowDirection: Double?
    let rowWidth: Double?
    let vineSpacing: Double?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
}

// MARK: - DTOs

nonisolated private struct EngagementDTO: Decodable, Sendable {
    let totalUsers: Int
    let totalVineyards: Int
    let totalPins: Int
    let totalSprayRecords: Int
    let totalWorkTasks: Int
    let signedInLast7Days: Int
    let signedInLast30Days: Int
    let newUsersLast30Days: Int
    let pendingInvitations: Int

    enum CodingKeys: String, CodingKey {
        case totalUsers = "total_users"
        case totalVineyards = "total_vineyards"
        case totalPins = "total_pins"
        case totalSprayRecords = "total_spray_records"
        case totalWorkTasks = "total_work_tasks"
        case signedInLast7Days = "signed_in_last_7_days"
        case signedInLast30Days = "signed_in_last_30_days"
        case newUsersLast30Days = "new_users_last_30_days"
        case pendingInvitations = "pending_invitations"
    }
}

nonisolated private struct PlatformScaleDTO: Decodable, Sendable {
    let totalHectaresUnderManagement: Double
    let totalVineyards: Int
    let totalActivePaddocks: Int
    let totalPaddocksWithArea: Int
    let averageHectaresPerVineyard: Double

    enum CodingKeys: String, CodingKey {
        case totalHectaresUnderManagement = "total_hectares_under_management"
        case totalVineyards = "total_vineyards"
        case totalActivePaddocks = "total_active_paddocks"
        case totalPaddocksWithArea = "total_paddocks_with_area"
        case averageHectaresPerVineyard = "average_hectares_per_vineyard"
    }
}

nonisolated private struct UserDTO: Decodable, Sendable {
    let id: UUID
    let email: String
    let fullName: String?
    let createdAt: Date?
    let updatedAt: Date?
    let lastSignInAt: Date?
    let vineyardCount: Int
    let ownedCount: Int
    let blockCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, email
        case fullName = "full_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastSignInAt = "last_sign_in_at"
        case vineyardCount = "vineyard_count"
        case ownedCount = "owned_count"
        case blockCount = "block_count"
    }
}

nonisolated private struct VineyardDTO: Decodable, Sendable {
    let id: UUID
    let name: String
    let ownerId: UUID?
    let ownerEmail: String?
    let ownerFullName: String?
    let country: String?
    let createdAt: Date?
    let deletedAt: Date?
    let memberCount: Int
    let pendingInvites: Int

    enum CodingKeys: String, CodingKey {
        case id, name, country
        case ownerId = "owner_id"
        case ownerEmail = "owner_email"
        case ownerFullName = "owner_full_name"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case memberCount = "member_count"
        case pendingInvites = "pending_invites"
    }
}

nonisolated private struct UserVineyardDTO: Decodable, Sendable {
    let id: UUID
    let name: String
    let role: String?
    let isOwner: Bool
    let country: String?
    let createdAt: Date?
    let deletedAt: Date?
    let memberCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, role, country
        case isOwner = "is_owner"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case memberCount = "member_count"
    }
}

nonisolated private struct InvitationDTO: Decodable, Sendable {
    let id: UUID
    let email: String
    let role: String
    let status: String
    let vineyardId: UUID?
    let vineyardName: String?
    let invitedBy: UUID?
    let invitedByEmail: String?
    let createdAt: Date?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, email, role, status
        case vineyardId = "vineyard_id"
        case vineyardName = "vineyard_name"
        case invitedBy = "invited_by"
        case invitedByEmail = "invited_by_email"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

nonisolated private struct PinDTO: Decodable, Sendable {
    let id: UUID
    let vineyardId: UUID?
    let vineyardName: String?
    let title: String
    let category: String?
    let status: String?
    let createdAt: Date?
    let isCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, category, status
        case vineyardId = "vineyard_id"
        case vineyardName = "vineyard_name"
        case createdAt = "created_at"
        case isCompleted = "is_completed"
    }
}

nonisolated private struct SprayDTO: Decodable, Sendable {
    let id: UUID
    let vineyardId: UUID?
    let vineyardName: String?
    let sprayReference: String?
    let operationType: String?
    let date: Date?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, date
        case vineyardId = "vineyard_id"
        case vineyardName = "vineyard_name"
        case sprayReference = "spray_reference"
        case operationType = "operation_type"
        case createdAt = "created_at"
    }
}

nonisolated private struct WorkTaskDTO: Decodable, Sendable {
    let id: UUID
    let vineyardId: UUID?
    let vineyardName: String?
    let taskType: String?
    let paddockName: String?
    let date: Date?
    let durationHours: Double?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, date
        case vineyardId = "vineyard_id"
        case vineyardName = "vineyard_name"
        case taskType = "task_type"
        case paddockName = "paddock_name"
        case durationHours = "duration_hours"
        case createdAt = "created_at"
    }
}

nonisolated private struct VineyardPaddockDTO: Decodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let polygonPoints: [CoordinatePoint]
    let rows: [PaddockRow]
    let rowCount: Int?
    let rowDirection: Double?
    let rowWidth: Double?
    let vineSpacing: Double?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    /// Number of row entries that failed to decode and were skipped.
    let skippedRowCount: Int
    /// Number of polygon vertices that failed to decode and were skipped.
    let skippedPolygonPointCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, rows
        case vineyardId = "vineyard_id"
        case polygonPoints = "polygon_points"
        case rowCount = "row_count"
        case rowDirection = "row_direction"
        case rowWidth = "row_width"
        case vineSpacing = "vine_spacing"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        let polygon = Self.decodeLossy(CoordinatePoint.self, container: c, key: .polygonPoints)
        self.polygonPoints = polygon.values
        self.skippedPolygonPointCount = polygon.skipped
        let rows = Self.decodeLossy(PaddockRow.self, container: c, key: .rows)
        self.rows = rows.values
        self.skippedRowCount = rows.skipped
        self.rowCount = try? c.decodeIfPresent(Int.self, forKey: .rowCount)
        self.rowDirection = try? c.decodeIfPresent(Double.self, forKey: .rowDirection)
        self.rowWidth = try? c.decodeIfPresent(Double.self, forKey: .rowWidth)
        self.vineSpacing = try? c.decodeIfPresent(Double.self, forKey: .vineSpacing)
        self.createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.deletedAt = try? c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    /// Decode a homogeneous array tolerantly — individual elements that fail
    /// to decode are skipped and counted rather than throwing the entire
    /// paddock away. Used by the Location Troubleshooter so one bad polygon
    /// vertex or row geometry doesn't blank out global admin geometry.
    private static func decodeLossy<T: Decodable>(
        _ type: T.Type,
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> (values: [T], skipped: Int) {
        guard container.contains(key),
              (try? container.decodeNil(forKey: key)) != true else {
            return ([], 0)
        }
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else {
            return ([], 0)
        }
        var values: [T] = []
        var skipped = 0
        if let count = unkeyed.count { values.reserveCapacity(count) }
        while !unkeyed.isAtEnd {
            do {
                let v = try unkeyed.decode(T.self)
                values.append(v)
            } catch {
                skipped += 1
                _ = try? unkeyed.decode(LossyTombstone.self)
            }
        }
        return (values, skipped)
    }
}

/// Throwaway value used to advance a lossy unkeyed container past an
/// element that failed to decode.
nonisolated private struct LossyTombstone: Decodable, Sendable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

/// Per-record skip detail surfaced in the System Admin Location
/// Troubleshooter diagnostic log.
nonisolated struct AdminGeometrySkippedPaddock: Sendable {
    let vineyardName: String
    let vineyardId: UUID
    let paddockName: String
    let paddockId: UUID
    /// Short human reason, e.g. "empty polygon geometry", "8 invalid polygon vertices skipped".
    let reason: String
}

/// Diagnostic result for admin geometry loads. Surfaces per-vineyard
/// failures + skipped row/polygon counts so the Location Troubleshooter
/// can show a meaningful log instead of failing globally.
nonisolated struct AdminGeometryLoadResult: Sendable {
    let rows: [(vineyard: AdminVineyardRow, paddock: AdminVineyardPaddockRow)]
    /// Vineyards returned by `admin_list_vineyards` (all, incl. deleted).
    let vineyardsReturned: Int
    /// Active vineyards we attempted to load paddocks for.
    let vineyardsAttempted: Int
    /// Active vineyards whose paddock RPC call succeeded (decoded without throwing).
    let vineyardsSucceeded: Int
    /// Distinct vineyards represented in the final usable paddock set.
    let vineyardsUsable: Int
    /// Distinct vineyard IDs that appeared anywhere in returned paddock data
    /// (regardless of whether that paddock was usable or skipped).
    let uniqueVineyardIdsInPaddockData: Int
    /// Distinct vineyard IDs represented by paddocks that were skipped
    /// (empty geometry, invalid vertices, invalid rows).
    let uniqueVineyardIdsInSkippedPaddocks: Int
    /// Distinct vineyard IDs that appear in paddock data but were NOT
    /// returned by `admin_list_vineyards`. Almost always 0 in production;
    /// surfaced here so admins can spot RPC drift.
    let paddockVineyardsNotInVineyardRPC: Int
    let vineyardErrors: [(vineyardName: String, message: String)]
    /// Paddocks the RPC returned (before usable/empty filtering).
    let paddocksReturned: Int
    /// Rows the RPC returned, summed across all successful paddocks.
    let rowsReturned: Int
    let totalRowsLoaded: Int
    let totalSkippedRows: Int
    let totalSkippedPolygonPoints: Int
    let paddocksWithoutGeometry: Int
    /// Per-paddock skip details (empty geometry, invalid vertices, invalid rows).
    let skippedPaddocks: [AdminGeometrySkippedPaddock]
}

nonisolated private struct VineyardIdParams: Encodable, Sendable {
    let vineyardId: UUID
    enum CodingKeys: String, CodingKey { case vineyardId = "p_vineyard_id" }
}

nonisolated private struct EmptyParams: Encodable, Sendable {}

nonisolated private struct UserIdParams: Encodable, Sendable {
    let userId: UUID
    enum CodingKeys: String, CodingKey { case userId = "p_user_id" }
}

nonisolated private struct LimitParams: Encodable, Sendable {
    let limit: Int
    enum CodingKeys: String, CodingKey { case limit = "p_limit" }
}

final class SupabaseAdminRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchEngagementSummary() async throws -> AdminEngagementSummary {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [EngagementDTO] = try await provider.client
            .rpc("admin_engagement_summary")
            .execute()
            .value
        guard let r = rows.first else {
            return AdminEngagementSummary(totalUsers: 0, totalVineyards: 0, totalPins: 0, totalSprayRecords: 0, totalWorkTasks: 0, signedInLast7Days: 0, signedInLast30Days: 0, newUsersLast30Days: 0, pendingInvitations: 0)
        }
        return AdminEngagementSummary(
            totalUsers: r.totalUsers,
            totalVineyards: r.totalVineyards,
            totalPins: r.totalPins,
            totalSprayRecords: r.totalSprayRecords,
            totalWorkTasks: r.totalWorkTasks,
            signedInLast7Days: r.signedInLast7Days,
            signedInLast30Days: r.signedInLast30Days,
            newUsersLast30Days: r.newUsersLast30Days,
            pendingInvitations: r.pendingInvitations
        )
    }

    /// Lightweight platform-wide count of active blocks (paddocks). Backed by
    /// `admin_blocks_count()` so the dashboard tile doesn't have to fan out
    /// across every vineyard.
    func fetchBlocksCount() async throws -> Int {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let value: Int = try await provider.client
            .rpc("admin_blocks_count")
            .execute()
            .value
        return value
    }

    /// Platform scale summary (total hectares under management + counts) backed
    /// by `admin_platform_scale()`. Reporting/marketing metric, admin-gated.
    func fetchPlatformScale() async throws -> AdminPlatformScale {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [PlatformScaleDTO] = try await provider.client
            .rpc("admin_platform_scale")
            .execute()
            .value
        guard let r = rows.first else {
            return AdminPlatformScale(totalHectaresUnderManagement: 0, totalVineyards: 0, totalActivePaddocks: 0, totalPaddocksWithArea: 0, averageHectaresPerVineyard: 0)
        }
        return AdminPlatformScale(
            totalHectaresUnderManagement: r.totalHectaresUnderManagement,
            totalVineyards: r.totalVineyards,
            totalActivePaddocks: r.totalActivePaddocks,
            totalPaddocksWithArea: r.totalPaddocksWithArea,
            averageHectaresPerVineyard: r.averageHectaresPerVineyard
        )
    }

    func fetchAllUsers() async throws -> [AdminUserRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [UserDTO] = try await provider.client
            .rpc("admin_list_users")
            .execute()
            .value
        return rows.map {
            AdminUserRow(
                id: $0.id,
                email: $0.email,
                fullName: $0.fullName,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                lastSignInAt: $0.lastSignInAt,
                vineyardCount: $0.vineyardCount,
                ownedCount: $0.ownedCount,
                blockCount: $0.blockCount ?? 0
            )
        }
    }

    func fetchAllVineyards() async throws -> [AdminVineyardRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [VineyardDTO] = try await provider.client
            .rpc("admin_list_vineyards")
            .execute()
            .value
        return rows.map {
            AdminVineyardRow(
                id: $0.id, name: $0.name,
                ownerId: $0.ownerId, ownerEmail: $0.ownerEmail, ownerFullName: $0.ownerFullName,
                country: $0.country, createdAt: $0.createdAt, deletedAt: $0.deletedAt,
                memberCount: $0.memberCount, pendingInvites: $0.pendingInvites
            )
        }
    }

    func fetchUserVineyards(userId: UUID) async throws -> [AdminUserVineyardRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [UserVineyardDTO] = try await provider.client
            .rpc("admin_list_user_vineyards", params: UserIdParams(userId: userId))
            .execute()
            .value
        return rows.map {
            AdminUserVineyardRow(
                id: $0.id, name: $0.name, role: $0.role, isOwner: $0.isOwner,
                country: $0.country, createdAt: $0.createdAt, deletedAt: $0.deletedAt,
                memberCount: $0.memberCount
            )
        }
    }

    func fetchInvitations() async throws -> [AdminInvitationRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [InvitationDTO] = try await provider.client
            .rpc("admin_list_invitations")
            .execute()
            .value
        return rows.map {
            AdminInvitationRow(
                id: $0.id, email: $0.email, role: $0.role, status: $0.status,
                vineyardId: $0.vineyardId, vineyardName: $0.vineyardName,
                invitedBy: $0.invitedBy, invitedByEmail: $0.invitedByEmail,
                createdAt: $0.createdAt, expiresAt: $0.expiresAt
            )
        }
    }

    func fetchPins(limit: Int = 500) async throws -> [AdminPinRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [PinDTO] = try await provider.client
            .rpc("admin_list_pins", params: LimitParams(limit: limit))
            .execute()
            .value
        return rows.map {
            AdminPinRow(
                id: $0.id, vineyardId: $0.vineyardId, vineyardName: $0.vineyardName,
                title: $0.title, category: $0.category, status: $0.status,
                createdAt: $0.createdAt, isCompleted: $0.isCompleted
            )
        }
    }

    func fetchSprayRecords(limit: Int = 500) async throws -> [AdminSprayRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [SprayDTO] = try await provider.client
            .rpc("admin_list_spray_records", params: LimitParams(limit: limit))
            .execute()
            .value
        return rows.map {
            AdminSprayRow(
                id: $0.id, vineyardId: $0.vineyardId, vineyardName: $0.vineyardName,
                sprayReference: $0.sprayReference, operationType: $0.operationType,
                date: $0.date, createdAt: $0.createdAt
            )
        }
    }

    func fetchVineyardPaddocks(vineyardId: UUID) async throws -> [AdminVineyardPaddockRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [VineyardPaddockDTO] = try await provider.client
            .rpc("admin_list_vineyard_paddocks", params: VineyardIdParams(vineyardId: vineyardId))
            .execute()
            .value
        return rows.map {
            AdminVineyardPaddockRow(
                id: $0.id,
                vineyardId: $0.vineyardId,
                name: $0.name,
                polygonPoints: $0.polygonPoints,
                rows: $0.rows,
                rowCount: $0.rowCount ?? $0.rows.count,
                rowDirection: $0.rowDirection,
                rowWidth: $0.rowWidth,
                vineSpacing: $0.vineSpacing,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                deletedAt: $0.deletedAt
            )
        }
    }

    /// Fetches paddocks across every vineyard the current admin can access.
    /// Issues one call per vineyard in parallel. Annotates rows with vineyard name
    /// for display in admin lists.
    func fetchAllPaddocks() async throws -> [(vineyard: AdminVineyardRow, paddock: AdminVineyardPaddockRow)] {
        try await fetchAllPaddocksDiagnostic().rows
    }

    /// Variant of `fetchAllPaddocks` that does NOT abort on a single
    /// vineyard's failure. Returns the rows that decoded successfully
    /// together with per-vineyard error messages and lossy-decoding
    /// counts so admin diagnostic surfaces can show what worked vs. what
    /// was skipped. Used by the System Admin Location Troubleshooter.
    func fetchAllPaddocksDiagnostic() async throws -> AdminGeometryLoadResult {
        let vineyards = try await fetchAllVineyards()
        let activeVineyards = vineyards.filter { $0.deletedAt == nil }
        let byId: [UUID: AdminVineyardRow] = Dictionary(uniqueKeysWithValues: vineyards.map { ($0.id, $0) })

        struct Per: Sendable {
            let vineyardName: String
            let result: Result<[AdminVineyardPaddockDiagnostic], Error>
        }

        var perVineyard: [Per] = []
        await withTaskGroup(of: Per.self) { group in
            for v in activeVineyards {
                let vid = v.id
                let name = v.name
                group.addTask {
                    do {
                        let rows = try await self.fetchVineyardPaddocksDiagnostic(vineyardId: vid)
                        return Per(vineyardName: name, result: .success(rows))
                    } catch {
                        return Per(vineyardName: name, result: .failure(error))
                    }
                }
            }
            for await item in group { perVineyard.append(item) }
        }

        var rows: [(AdminVineyardRow, AdminVineyardPaddockRow)] = []
        var errors: [(String, String)] = []
        var succeeded = 0
        var skippedRows = 0
        var skippedPoints = 0
        var withoutGeometry = 0
        var paddocksReturnedTotal = 0
        var rowsReturnedTotal = 0
        var skippedDetails: [AdminGeometrySkippedPaddock] = []
        var paddockVineyardIds = Set<UUID>()
        var skippedPaddockVineyardIds = Set<UUID>()
        for entry in perVineyard {
            switch entry.result {
            case .success(let diags):
                succeeded += 1
                paddocksReturnedTotal += diags.count
                for d in diags {
                    skippedRows += d.skippedRows
                    skippedPoints += d.skippedPolygonPoints
                    rowsReturnedTotal += d.row.rows.count
                    paddockVineyardIds.insert(d.row.vineyardId)
                    let vineyardName = byId[d.row.vineyardId]?.name ?? entry.vineyardName
                    var wasSkipped = false
                    if d.row.polygonPoints.isEmpty && d.row.rows.isEmpty {
                        withoutGeometry += 1
                        wasSkipped = true
                        skippedDetails.append(AdminGeometrySkippedPaddock(
                            vineyardName: vineyardName,
                            vineyardId: d.row.vineyardId,
                            paddockName: d.row.name,
                            paddockId: d.row.id,
                            reason: "empty polygon geometry"
                        ))
                    } else if d.row.polygonPoints.isEmpty {
                        wasSkipped = true
                        skippedDetails.append(AdminGeometrySkippedPaddock(
                            vineyardName: vineyardName,
                            vineyardId: d.row.vineyardId,
                            paddockName: d.row.name,
                            paddockId: d.row.id,
                            reason: "no polygon (\(d.row.rows.count) rows only)"
                        ))
                    }
                    if d.skippedPolygonPoints > 0 {
                        wasSkipped = true
                        skippedDetails.append(AdminGeometrySkippedPaddock(
                            vineyardName: vineyardName,
                            vineyardId: d.row.vineyardId,
                            paddockName: d.row.name,
                            paddockId: d.row.id,
                            reason: "\(d.skippedPolygonPoints) invalid polygon vertices skipped"
                        ))
                    }
                    if d.skippedRows > 0 {
                        wasSkipped = true
                        skippedDetails.append(AdminGeometrySkippedPaddock(
                            vineyardName: vineyardName,
                            vineyardId: d.row.vineyardId,
                            paddockName: d.row.name,
                            paddockId: d.row.id,
                            reason: "\(d.skippedRows) invalid row geometries skipped"
                        ))
                    }
                    if wasSkipped { skippedPaddockVineyardIds.insert(d.row.vineyardId) }
                    // A paddock is "usable" if it has at least one polygon point
                    // or one row. We still append it to the rows array so the
                    // troubleshooter can use whatever geometry exists.
                    if !(d.row.polygonPoints.isEmpty && d.row.rows.isEmpty),
                       let v = byId[d.row.vineyardId] {
                        rows.append((v, d.row))
                    }
                }
            case .failure(let err):
                errors.append((entry.vineyardName, err.localizedDescription))
            }
        }
        let usableVineyardIds = Set(rows.map { $0.1.vineyardId })
        let vineyardsUsable = usableVineyardIds.count
        let returnedVineyardIds = Set(byId.keys)
        let extraVineyards = paddockVineyardIds.subtracting(returnedVineyardIds).count

        rows.sort { lhs, rhs in
            if lhs.0.name.lowercased() == rhs.0.name.lowercased() {
                return lhs.1.name.lowercased() < rhs.1.name.lowercased()
            }
            return lhs.0.name.lowercased() < rhs.0.name.lowercased()
        }

        return AdminGeometryLoadResult(
            rows: rows,
            vineyardsReturned: vineyards.count,
            vineyardsAttempted: activeVineyards.count,
            vineyardsSucceeded: succeeded,
            vineyardsUsable: vineyardsUsable,
            uniqueVineyardIdsInPaddockData: paddockVineyardIds.count,
            uniqueVineyardIdsInSkippedPaddocks: skippedPaddockVineyardIds.count,
            paddockVineyardsNotInVineyardRPC: extraVineyards,
            vineyardErrors: errors,
            paddocksReturned: paddocksReturnedTotal,
            rowsReturned: rowsReturnedTotal,
            totalRowsLoaded: rows.reduce(0) { $0 + $1.1.rows.count },
            totalSkippedRows: skippedRows,
            totalSkippedPolygonPoints: skippedPoints,
            paddocksWithoutGeometry: withoutGeometry,
            skippedPaddocks: skippedDetails
        )
    }

    private struct AdminVineyardPaddockDiagnostic: Sendable {
        let row: AdminVineyardPaddockRow
        let skippedRows: Int
        let skippedPolygonPoints: Int
    }

    private func fetchVineyardPaddocksDiagnostic(
        vineyardId: UUID
    ) async throws -> [AdminVineyardPaddockDiagnostic] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let dtos: [VineyardPaddockDTO] = try await provider.client
            .rpc("admin_list_vineyard_paddocks", params: VineyardIdParams(vineyardId: vineyardId))
            .execute()
            .value
        return dtos.map { dto in
            AdminVineyardPaddockDiagnostic(
                row: AdminVineyardPaddockRow(
                    id: dto.id,
                    vineyardId: dto.vineyardId,
                    name: dto.name,
                    polygonPoints: dto.polygonPoints,
                    rows: dto.rows,
                    rowCount: dto.rowCount ?? dto.rows.count,
                    rowDirection: dto.rowDirection,
                    rowWidth: dto.rowWidth,
                    vineSpacing: dto.vineSpacing,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt
                ),
                skippedRows: dto.skippedRowCount,
                skippedPolygonPoints: dto.skippedPolygonPointCount
            )
        }
    }

    func fetchWorkTasks(limit: Int = 500) async throws -> [AdminWorkTaskRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [WorkTaskDTO] = try await provider.client
            .rpc("admin_list_work_tasks", params: LimitParams(limit: limit))
            .execute()
            .value
        return rows.map {
            AdminWorkTaskRow(
                id: $0.id, vineyardId: $0.vineyardId, vineyardName: $0.vineyardName,
                taskType: $0.taskType, paddockName: $0.paddockName,
                date: $0.date, durationHours: $0.durationHours, createdAt: $0.createdAt
            )
        }
    }
}

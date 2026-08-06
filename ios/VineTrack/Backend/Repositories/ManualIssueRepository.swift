import Foundation
import Supabase

/// Server-authoritative access to the sql/169 manual-issue RPCs. Every write
/// (create / update / status / cancel / delete) goes through an RPC so the
/// database — not Swift — enforces permissions, validation, and the
/// no-labour/no-Work-Task contract. Reads return the canonical
/// `manual_issue_json` shape.
final class ManualIssueRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// Idempotent create keyed by the client-generated id — a replay of the
    /// same create returns the existing canonical issue.
    func create(_ params: ManualIssueCreateParams) async throws -> ManualIssueRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("create_manual_issue", params: params)
            .execute()
            .value
    }

    /// Full-field update with server-side last-write-wins on
    /// `client_updated_at` — a stale replay returns the newer server issue.
    func update(_ params: ManualIssueUpdateParams) async throws -> ManualIssueRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("update_manual_issue", params: params)
            .execute()
            .value
    }

    func get(id: UUID) async throws -> ManualIssueRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("get_manual_issue", params: ManualIssueIdParams(id: id))
            .execute()
            .value
    }

    /// nil statuses = server default (open + in_progress).
    func list(
        vineyardId: UUID,
        statuses: [String]? = nil,
        paddockId: UUID? = nil,
        includeDeleted: Bool = false
    ) async throws -> [ManualIssueRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "list_manual_issues",
                params: ManualIssueListParams(
                    vineyardId: vineyardId,
                    statuses: statuses,
                    paddockId: paddockId,
                    includeDeleted: includeDeleted
                )
            )
            .execute()
            .value
    }

    /// Server-authoritative status change: completing stamps completed_at /
    /// completed_by; reopening clears them.
    func setStatus(id: UUID, status: String, clientUpdatedAt: String) async throws -> ManualIssueRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "set_manual_issue_status",
                params: ManualIssueStatusParams(id: id, status: status, clientUpdatedAt: clientUpdatedAt)
            )
            .execute()
            .value
    }

    /// action = "cancel" (keeps history) or "delete" (soft delete,
    /// owner/manager/supervisor only — matching soft_delete_pin).
    func deleteOrCancel(id: UUID, action: String) async throws -> ManualIssueRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "delete_or_cancel_manual_issue",
                params: ManualIssueDeleteParams(id: id, action: action)
            )
            .execute()
            .value
    }
}

nonisolated private struct ManualIssueIdParams: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey { case id = "p_id" }
}

nonisolated private struct ManualIssueListParams: Encodable, Sendable {
    let vineyardId: UUID
    let statuses: [String]?
    let paddockId: UUID?
    let includeDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case statuses = "p_statuses"
        case paddockId = "p_paddock_id"
        case includeDeleted = "p_include_deleted"
    }
}

nonisolated private struct ManualIssueStatusParams: Encodable, Sendable {
    let id: UUID
    let status: String
    let clientUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case status = "p_status"
        case clientUpdatedAt = "p_client_updated_at"
    }
}

nonisolated private struct ManualIssueDeleteParams: Encodable, Sendable {
    let id: UUID
    let action: String

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case action = "p_action"
    }
}

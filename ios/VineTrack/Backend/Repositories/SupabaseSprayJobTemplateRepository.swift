import Foundation
import Supabase

/// Reads reusable spray Program Steps from `public.spray_jobs`, and updates
/// the ones the signed-in user is authorised to change.
///
/// Filter contract (mirrors the portal/template model from sql/032):
///   * `vineyard_id = selected vineyard`
///   * `is_template = true`
///   * `deleted_at IS NULL`
///   * NO status filter — portal templates are typically `status = 'draft'`
///   * NO planned_date filter — templates have no planned date
///   * NO created_by filter — RLS grants read by vineyard membership, and
///     Lovable-created templates have `created_by = null`
///
/// A Program Step is a SHARED vineyard resource: the portal and mobile edit
/// the same row. Mobile therefore updates in place (`update` + `id` filter) and
/// never inserts a parallel copy. Authorisation is the database's, not the
/// client's — `spray_jobs_update_managers` (sql/032) already restricts UPDATE to
/// owner/manager, and a denied write returns zero rows rather than an error.
final class SupabaseSprayJobTemplateRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchTemplates(vineyardId: UUID) async throws -> [BackendSprayJobTemplate] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("spray_jobs")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("is_template", value: true)
            .is("deleted_at", value: nil)
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Update one existing Program Step row and return it as the server now
    /// holds it.
    ///
    /// The filter chain is the safety contract:
    ///   * `id` — the SAME Program Step, never a new row
    ///   * `vineyard_id` — a cross-vineyard write is impossible even if an id leaks
    ///   * `is_template = true` — this path can never touch an operational job
    ///   * `deleted_at IS NULL` — an archived step is not silently resurrected
    ///
    /// `is_template` is filtered on but never written, so the row cannot change
    /// what kind of thing it is.
    ///
    /// - Throws: `SprayProgramStepWriteError.notPermitted` when the statement
    ///   affects no rows. Under RLS that is indistinguishable from "row not
    ///   found", and both mean the same thing to the operator: this save did not
    ///   reach `spray_jobs`. Reporting success would be the one unacceptable
    ///   outcome.
    func updateTemplate(
        id: UUID,
        vineyardId: UUID,
        payload: BackendSprayJobTemplateUpdate
    ) async throws -> BackendSprayJobTemplate {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [BackendSprayJobTemplate] = try await provider.client
            .from("spray_jobs")
            .update(payload)
            .eq("id", value: id.uuidString)
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("is_template", value: true)
            .is("deleted_at", value: nil)
            .select()
            .execute()
            .value
        guard let row = rows.first else { throw SprayProgramStepWriteError.notPermitted }
        return row
    }
}

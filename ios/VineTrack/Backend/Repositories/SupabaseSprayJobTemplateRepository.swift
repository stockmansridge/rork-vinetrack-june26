import Foundation
import Supabase

/// Read-only fetch of reusable spray templates from `public.spray_jobs`.
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
/// Mobile never writes to `spray_jobs`; templates are managed in the portal.
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
}

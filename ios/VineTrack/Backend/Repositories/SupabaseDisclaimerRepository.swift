import Foundation
import Supabase

final class SupabaseDisclaimerRepository: DisclaimerRepositoryProtocol {
    private let provider: SupabaseClientProvider
    private let currentVersion: String

    init(provider: SupabaseClientProvider = .shared, currentVersion: String = "1.0") {
        self.provider = provider
        self.currentVersion = currentVersion
    }

    func hasAcceptedCurrentDisclaimer() async throws -> Bool {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard let userId = provider.client.auth.currentUser?.id else { return false }
        let acceptances: [DisclaimerAcceptanceRow] = try await provider.client
            .from("disclaimer_acceptances")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .eq("version", value: currentVersion)
            .limit(1)
            .execute()
            .value
        return !acceptances.isEmpty
    }

    func acceptCurrentDisclaimer(version: String, displayName: String?, email: String?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard let userId = provider.client.auth.currentUser?.id else { throw BackendRepositoryError.missingAuthenticatedUser }
        try await provider.client
            .from("disclaimer_acceptances")
            .insert(DisclaimerAcceptanceInsert(userId: userId, version: version, displayName: displayName, email: email))
            .execute()
    }
}

nonisolated private struct DisclaimerAcceptanceRow: Decodable, Sendable {
    let id: UUID
}

nonisolated private struct DisclaimerAcceptanceInsert: Encodable, Sendable {
    let userId: UUID
    let version: String
    let displayName: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case version
        case displayName = "display_name"
        case email
    }
}

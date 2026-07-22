import Foundation
import Supabase

final class SupabaseProfileRepository: ProfileRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func getMyProfile() async throws -> BackendProfile? {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard let userId = provider.client.auth.currentUser?.id else { return nil }
        let profiles: [BackendProfile] = try await provider.client
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
        return profiles.first
    }

    func upsertMyProfile(fullName: String?, email: String?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard let user = provider.client.auth.currentUser else { throw BackendRepositoryError.missingAuthenticatedUser }
        try await provider.client
            .from("profiles")
            .upsert(ProfileUpsert(id: user.id, email: email ?? user.email ?? "", fullName: fullName, avatarURL: nil))
            .execute()
    }

    func updateDefaultVineyard(vineyardId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard provider.client.auth.currentUser != nil else { throw BackendRepositoryError.missingAuthenticatedUser }
        try await provider.client
            .rpc("set_default_vineyard", params: SetDefaultVineyardParams(p_vineyard_id: vineyardId))
            .execute()
    }
}

nonisolated private struct ProfileUpsert: Encodable, Sendable {
    let id: UUID
    let email: String
    let fullName: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName = "full_name"
        case avatarURL = "avatar_url"
    }
}

nonisolated private struct SetDefaultVineyardParams: Encodable, Sendable {
    let p_vineyard_id: UUID?
}

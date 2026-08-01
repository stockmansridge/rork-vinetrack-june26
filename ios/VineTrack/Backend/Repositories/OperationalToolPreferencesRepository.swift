import Foundation
import Supabase

/// The caller's saved Operational Tools layout (`sql/159`).
///
/// `hasPreference == false` means "no record yet" — the app must use the
/// VineTrack default order and show every authorised tool. A record is only
/// created once the user actually customises something.
nonisolated struct OperationalToolPreferences: Codable, Sendable, Equatable {
    let hasPreference: Bool
    let version: Int
    let visibleToolIds: [String]
    let hiddenToolIds: [String]
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case hasPreference = "has_preference"
        case version
        case visibleToolIds = "visible_tool_ids"
        case hiddenToolIds = "hidden_tool_ids"
        case updatedAt = "updated_at"
    }

    init(hasPreference: Bool, version: Int, visibleToolIds: [String], hiddenToolIds: [String], updatedAt: Date?) {
        self.hasPreference = hasPreference
        self.version = version
        self.visibleToolIds = visibleToolIds
        self.hiddenToolIds = hiddenToolIds
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasPreference = (try? c.decodeIfPresent(Bool.self, forKey: .hasPreference)) ?? false
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        visibleToolIds = (try? c.decodeIfPresent([String].self, forKey: .visibleToolIds)) ?? []
        hiddenToolIds = (try? c.decodeIfPresent([String].self, forKey: .hiddenToolIds)) ?? []
        // Timestamp formats vary between PostgREST configurations; the layout
        // must never fail to load because of a date string.
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    static let empty = OperationalToolPreferences(
        hasPreference: false,
        version: 1,
        visibleToolIds: [],
        hiddenToolIds: [],
        updatedAt: nil
    )
}

/// Data source for the caller's Operational Tools layout. Abstracted so the
/// layout store can be unit-tested without a network round trip.
nonisolated protocol OperationalToolPreferencesProviding: Sendable {
    func fetch() async throws -> OperationalToolPreferences
    func save(visibleToolIds: [String], hiddenToolIds: [String]) async throws -> OperationalToolPreferences
    func reset() async throws -> OperationalToolPreferences
}

/// Reads and writes the caller's own Operational Tools layout. Every RPC is
/// SECURITY DEFINER and derives the user from `auth.uid()` — the layout is
/// per-user and shared across iOS, Android and the portal.
nonisolated struct OperationalToolPreferencesRepository: OperationalToolPreferencesProviding {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetch() async throws -> OperationalToolPreferences {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        return try await provider.client
            .rpc("get_my_operational_tool_preferences")
            .execute()
            .value
    }

    func save(visibleToolIds: [String], hiddenToolIds: [String]) async throws -> OperationalToolPreferences {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let params = SetPreferencesParams(
            visible: visibleToolIds,
            hidden: hiddenToolIds,
            version: 1
        )
        return try await provider.client
            .rpc("set_my_operational_tool_preferences", params: params)
            .execute()
            .value
    }

    func reset() async throws -> OperationalToolPreferences {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        return try await provider.client
            .rpc("reset_my_operational_tool_preferences")
            .execute()
            .value
    }
}

nonisolated private struct SetPreferencesParams: Encodable, Sendable {
    let visible: [String]
    let hidden: [String]
    let version: Int

    enum CodingKeys: String, CodingKey {
        case visible = "p_visible_tool_ids"
        case hidden = "p_hidden_tool_ids"
        case version = "p_preference_version"
    }
}

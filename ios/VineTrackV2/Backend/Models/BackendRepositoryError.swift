import Foundation

nonisolated enum BackendRepositoryError: LocalizedError, Sendable {
    case missingSupabaseConfiguration
    case missingAuthenticatedUser
    case invalidSupabaseURL
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingSupabaseConfiguration:
            "Supabase is not configured."
        case .missingAuthenticatedUser:
            "You must be signed in to perform this action."
        case .invalidSupabaseURL:
            "The Supabase project URL is invalid."
        case .emptyResponse:
            "The backend returned no data."
        }
    }
}

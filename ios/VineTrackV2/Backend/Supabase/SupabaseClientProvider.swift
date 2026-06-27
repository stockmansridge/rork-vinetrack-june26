import Foundation
import Supabase

final class SupabaseClientProvider: Sendable {
    static let shared = SupabaseClientProvider()

    let client: SupabaseClient
    let supabaseURL: URL
    let isConfigured: Bool
    let configurationSummary: String

    private init() {
        let url = AppConfig.supabaseURL
        let anonKey = AppConfig.supabaseAnonKey
        supabaseURL = url
        isConfigured = AppConfig.isSupabaseConfigured
        configurationSummary = "url=\(url.absoluteString), anonKeyPresent=\(AppConfig.isSupabaseConfigured)"
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}

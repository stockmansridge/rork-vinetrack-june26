import Foundation
import Supabase

final class SupabaseClientProvider: Sendable {
    nonisolated static let shared = SupabaseClientProvider()

    let client: SupabaseClient
    let supabaseURL: URL
    let isConfigured: Bool
    let configurationSummary: String

    private init() {
        #if DEBUG
        // Fail closed: this explicit fixture process can never address the production backend.
        if SprayLifecycleSandbox.runID != nil {
            let url = URL(string: "https://isolated-lifecycle.invalid")!
            supabaseURL = url
            isConfigured = false
            configurationSummary = "Isolated lifecycle sandbox; production transport disabled"
            client = SupabaseClient(supabaseURL: url, supabaseKey: "isolated-no-credentials")
            return
        }
        #endif
        let url = AppConfig.supabaseURL
        let anonKey = AppConfig.supabaseAnonKey
        supabaseURL = url
        isConfigured = AppConfig.isSupabaseConfigured
        configurationSummary = "url=\(url.absoluteString), anonKeyPresent=\(AppConfig.isSupabaseConfigured)"
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}

import Foundation

/// Centralised configuration layer for VineTrackV2.
///
/// Reads values in this priority order:
///   1. Generated `Config` (build-time injected EXPO_PUBLIC_* values)
///   2. `Info.plist` keys (for native Xcode-injected build settings)
///   3. `ProcessInfo.environment` (DEBUG only — Xcode scheme env vars)
///   4. `UserDefaults` (development overrides only — e.g. Wunderground key entered in-app)
///
/// ──────────────────────────────────────────────────────────────────────
/// Client-safe keys (OK to ship in the iOS app):
///   - SUPABASE_URL
///   - SUPABASE_ANON_KEY
///   - REVENUECAT_IOS_API_KEY
///   - REVENUECAT_TEST_API_KEY
///   - GOOGLE_IOS_CLIENT_ID
///
/// Server-side ONLY (NEVER place in app/source/Info.plist):
///   - RESEND_API_KEY               → Supabase Edge Function
///   - SUPABASE_SERVICE_ROLE_KEY    → Supabase Edge Function / server
///   - WUNDERGROUND_API_KEY         → Move behind a Supabase Edge Function
///                                    long-term. Currently still callable
///                                    from the app via UserDefaults override
///                                    for development only.
/// ──────────────────────────────────────────────────────────────────────
nonisolated enum AppConfig {

    // MARK: - Supabase (client-safe)

    static var supabaseURL: URL {
        let raw = string(for: "SUPABASE_URL", expoFallbackKey: "EXPO_PUBLIC_SUPABASE_URL")
            ?? "https://tbafuqwruefgkbyxrxyb.supabase.co"
        return URL(string: raw) ?? URL(string: "https://tbafuqwruefgkbyxrxyb.supabase.co")!
    }

    static var supabaseAnonKey: String {
        string(for: "SUPABASE_ANON_KEY", expoFallbackKey: "EXPO_PUBLIC_SUPABASE_ANON_KEY") ?? ""
    }

    static var isSupabaseConfigured: Bool {
        !supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - RevenueCat (client-safe, placeholders for later)

    /// Production RevenueCat iOS public SDK key. Placeholder until paywall is enabled.
    static var revenueCatIOSAPIKey: String {
        string(for: "REVENUECAT_IOS_API_KEY", expoFallbackKey: "EXPO_PUBLIC_REVENUECAT_IOS_API_KEY") ?? ""
    }

    /// Sandbox / test RevenueCat key. Placeholder until paywall is enabled.
    static var revenueCatTestAPIKey: String {
        string(for: "REVENUECAT_TEST_API_KEY", expoFallbackKey: "EXPO_PUBLIC_REVENUECAT_TEST_API_KEY") ?? ""
    }

    // MARK: - Google Sign-In (client-safe, placeholder for later)

    /// Google iOS OAuth client ID. Placeholder until Google login is enabled.
    static var googleIOSClientID: String {
        string(for: "GOOGLE_IOS_CLIENT_ID") ?? ""
    }

    // MARK: - Wunderground (transitional — to be moved server-side)

    /// Wunderground PWS API key. Read from UserDefaults so users can paste a
    /// dev key during development. Long-term this call MUST move behind a
    /// Supabase Edge Function and this key must never ship in the app.
    static var wundergroundAPIKey: String {
        if let v = string(for: "WUNDERGROUND_API_KEY"), !v.isEmpty { return v }
        return UserDefaults.standard.string(forKey: Self.wundergroundUserDefaultsKey) ?? ""
    }

    static let wundergroundUserDefaultsKey = "vinetrack_wunderground_api_key"

    // MARK: - Diagnostics

    static var summary: String {
        """
        supabaseURL=\(supabaseURL.absoluteString)
        supabaseAnonKeyPresent=\(isSupabaseConfigured)
        revenueCatIOSAPIKeyPresent=\(!revenueCatIOSAPIKey.isEmpty)
        revenueCatTestAPIKeyPresent=\(!revenueCatTestAPIKey.isEmpty)
        googleIOSClientIDPresent=\(!googleIOSClientID.isEmpty)
        wundergroundAPIKeyPresent=\(!wundergroundAPIKey.isEmpty)
        """
    }

    // MARK: - Resolver

    private static func string(for key: String, expoFallbackKey: String? = nil) -> String? {
        if let v = Config.allValues[key]?.nonEmptyTrimmed { return v }
        if let expoKey = expoFallbackKey,
           let v = Config.allValues[expoKey]?.nonEmptyTrimmed {
            return v
        }
        if let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let trimmed = v.nonEmptyTrimmed {
            return trimmed
        }
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment[key]?.nonEmptyTrimmed {
            return v
        }
        if let expoKey = expoFallbackKey,
           let v = ProcessInfo.processInfo.environment[expoKey]?.nonEmptyTrimmed {
            return v
        }
        #endif
        return nil
    }
}

nonisolated private extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

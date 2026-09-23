import Foundation
import Observation
import Supabase

/// Best-effort release notice; it never participates in auth or startup routing.
@Observable
@MainActor
final class AppReleasePolicyService {
    private(set) var prompt: AppReleasePolicy?
    private(set) var decision: AppReleasePolicy.Decision = .none
    private let provider: SupabaseClientProvider
    private let defaults: UserDefaults
    private let fetchPolicy: @MainActor () async throws -> AppReleasePolicy?
    private let canFetch: Bool
    private var lastAttempt: Date?
    private var isChecking: Bool = false
    private let refreshInterval: TimeInterval = 60 * 60
    private let reminderInterval: TimeInterval = 24 * 60 * 60

    init(
        provider: SupabaseClientProvider = .shared,
        defaults: UserDefaults = .standard,
        fetchPolicy: (@MainActor () async throws -> AppReleasePolicy?)? = nil
    ) {
        self.provider = provider
        self.defaults = defaults
        self.canFetch = provider.isConfigured || fetchPolicy != nil
        self.fetchPolicy = fetchPolicy ?? {
            try await provider.client.rpc("get_app_release_policy", params: ["p_platform": "ios"])
                .execute().value
        }
    }

    func refreshIfNeeded(now: Date = Date()) async {
        guard canFetch, !isChecking,
              lastAttempt.map({ now.timeIntervalSince($0) >= refreshInterval }) ?? true else { return }
        lastAttempt = now
        isChecking = true
        defer { isChecking = false }
        guard let installedBuild = Int64(AppBuildInfo.buildNumber) else { return }
        do {
            let policy = try await fetchPolicy()
            guard let policy, policy.officialStoreURL != nil else {
                prompt = nil
                decision = .none
                return
            }
            let outcome = policy.decision(installedBuild: installedBuild)
            let dismissedBuild = (defaults.object(forKey: "release.ios.dismissedBuild") as? NSNumber)?.int64Value
            let dismissedAt = defaults.object(forKey: "release.ios.dismissedAt") as? Date
            let isSnoozed = outcome == .optional && dismissedBuild == policy.latestBuild &&
                dismissedAt.map { (0..<reminderInterval).contains(now.timeIntervalSince($0)) } ?? false
            decision = isSnoozed ? .none : outcome
            prompt = decision == .none ? nil : policy
        } catch {
            // Offline or unavailable policy is never a reason to block the app.
            prompt = nil
            decision = .none
        }
    }

    func dismissOptional() {
        guard decision == .optional else { return }
        prompt = nil
        decision = .none
    }

    func later(now: Date = Date()) {
        guard decision == .optional, let prompt else { return }
        defaults.set(prompt.latestBuild, forKey: "release.ios.dismissedBuild")
        defaults.set(now, forKey: "release.ios.dismissedAt")
        self.prompt = nil
        decision = .none
    }
}

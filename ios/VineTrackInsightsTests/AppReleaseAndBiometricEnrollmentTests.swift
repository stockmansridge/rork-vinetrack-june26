import Foundation
import Testing
@testable import VineTrack

struct AppReleaseAndBiometricEnrollmentTests {
    private func policy(latestBuild: Int64 = 12, minimumBuild: Int64 = 9, latestVersion: String = "3.1.3") -> AppReleasePolicy {
        AppReleasePolicy(
            platform: "ios", latestVersion: latestVersion, latestBuild: latestBuild,
            minimumSupportedVersion: "3.0", minimumSupportedBuild: minimumBuild,
            updateTitle: "Update available", updateMessage: "A newer version of VineTrack is available.",
            storeURL: "https://apps.apple.com/app/id6761143377", active: true,
            updatedAt: "2026-09-23T00:00:00Z"
        )
    }

    @Test func restoredFaceIDSessionOffersEnrollmentOnce() {
        #expect(BiometricEnrollmentEligibility.shouldOffer(isInMainShell: true, supportsDeviceAuth: true, isEnabled: false, hasPrompted: false))
        #expect(!BiometricEnrollmentEligibility.shouldOffer(isInMainShell: false, supportsDeviceAuth: true, isEnabled: false, hasPrompted: false))
        #expect(!BiometricEnrollmentEligibility.shouldOffer(isInMainShell: true, supportsDeviceAuth: true, isEnabled: false, hasPrompted: true))
    }

    @Test func notNowFlagStopsOfferOnNextLaunch() {
        let service = BiometricAuthService()
        let original = service.hasShownEnrollmentPrompt
        defer { if !original { service.resetEnrollmentPromptForTesting() } }
        service.markEnrollmentPromptShown()
        #expect(!BiometricEnrollmentEligibility.shouldOffer(isInMainShell: true, supportsDeviceAuth: true, isEnabled: false, hasPrompted: service.hasShownEnrollmentPrompt))
    }

    @Test func enabledRestoredSessionLocksButSignedOutSessionDoesNot() {
        #expect(BiometricEnrollmentEligibility.shouldLock(hasRestoredSession: true, isEnabled: true, supportsDeviceAuth: true))
        #expect(!BiometricEnrollmentEligibility.shouldLock(hasRestoredSession: false, isEnabled: true, supportsDeviceAuth: true))
        #expect(!BiometricEnrollmentEligibility.shouldOffer(isInMainShell: true, supportsDeviceAuth: true, isEnabled: true, hasPrompted: false))
    }

    @Test func numericBuildDecisionsIgnoreMarketingString() {
        let release = policy(latestBuild: 12, minimumBuild: 9, latestVersion: "1.0")
        #expect(release.decision(installedBuild: 12) == .none)
        #expect(release.decision(installedBuild: 10) == .optional)
        #expect(release.decision(installedBuild: 8) == .required)
        #expect(release.decision(installedBuild: 13) == .none)
        #expect(release.officialStoreURL != nil)
    }

    @Test func offlinePolicyCheckNeverProducesRequiredPrompt() async {
        enum Offline: Error { case unavailable }
        let service = AppReleasePolicyService(fetchPolicy: { throw Offline.unavailable })
        await service.refreshIfNeeded()
        #expect(service.decision == .none)
        #expect(service.prompt == nil)
    }

    @Test func laterSuppressesSameReleaseForOneDayAcrossInstances() async {
        let name = "release-policy-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let installed = Int64(AppBuildInfo.buildNumber) ?? 1
        let release = policy(latestBuild: installed + 1, minimumBuild: installed)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AppReleasePolicyService(defaults: defaults, fetchPolicy: { release })
        await first.refreshIfNeeded(now: day)
        #expect(first.decision == .optional)
        first.later(now: day)
        let second = AppReleasePolicyService(defaults: defaults, fetchPolicy: { release })
        await second.refreshIfNeeded(now: day.addingTimeInterval(60 * 60))
        #expect(second.prompt == nil)
        let third = AppReleasePolicyService(defaults: defaults, fetchPolicy: { release })
        await third.refreshIfNeeded(now: day.addingTimeInterval(25 * 60 * 60))
        #expect(third.decision == .optional)
    }
}

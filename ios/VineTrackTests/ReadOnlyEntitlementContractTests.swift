import Foundation
import Testing
@testable import VineTrack

/// Contract/cache preparation only. Does NOT assert that UI actions or replay
/// are guarded; those integration acceptance cases remain outstanding.
struct ReadOnlyEntitlementContractTests {
    private let vineyard = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    private let owner = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!

    private func entry(_ fields: String) throws -> VineyardAccessEntry {
        try JSONDecoder().decode(VineyardAccessEntry.self, from: Data("{\"vineyard_id\":\"\(vineyard.uuidString)\",\(fields)}".utf8))
    }

    @Test func missingWriteFieldPreservesLegacyWritableCapability() throws {
        let row = try entry("\"has_vineyard_access\":true")
        #expect(row.canWrite == nil)
        #expect(row.operationalAccess.canEnter && row.operationalAccess.canWrite)
    }

    @Test func explicitNullWriteFieldAlsoPreservesCompatibility() throws {
        let access = try entry("\"has_vineyard_access\":true,\"can_write\":null").operationalAccess
        #expect(access.canWrite)
        #expect(access.readOnlyReason == nil)
    }

    @Test func expiredContractSeparatesEntryFromWriteWithoutChangingLegacyRoutingFlag() throws {
        let row = try entry("\"has_vineyard_access\":false,\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"")
        #expect(!row.hasVineyardAccess)
        #expect(row.operationalAccess.canEnter)
        #expect(!row.operationalAccess.canWrite)
        #expect(row.operationalAccess.isTrialExpiredReadOnly)
    }

    @Test func explicitEntryDenialCannotBecomeWritable() throws {
        let access = try entry("\"has_vineyard_access\":true,\"can_enter_vineyard\":false,\"can_write\":true,\"read_only_reason\":\"trial_expired\"").operationalAccess
        #expect(!access.canEnter && !access.canWrite)
        #expect(access.readOnlyReason == nil)
        #expect(!access.isTrialExpiredReadOnly)
    }

    @Test func absentEntryFieldsDoNotInventMembership() throws {
        let access = try entry("\"can_write\":true").operationalAccess
        #expect(!access.canEnter && !access.canWrite)
    }

    @Test func reasonAloneCannotInferReadOnly() throws {
        let access = try entry("\"has_vineyard_access\":true,\"read_only_reason\":\"trial_expired\"").operationalAccess
        #expect(access.canWrite)
        #expect(!access.isTrialExpiredReadOnly)
    }

    @Test func historicalTrialMetadataCannotOverrideEffectiveGrant() throws {
        let access = try entry("\"has_vineyard_access\":true,\"is_trial\":true,\"subscription_status\":\"expired\"").operationalAccess
        #expect(access.canWrite)
    }

    @Test(arguments: ["active_trial", "paid", "legacy", "manual", "internal_unlimited", "billing_grant", "migrated"])
    func existingGrantSourcesRemainWritable(source: String) throws {
        let access = try entry("\"has_vineyard_access\":true,\"vineyard_access_source\":\"\(source)\"").operationalAccess
        #expect(access.canEnter && access.canWrite)
    }

    @Test func personalTrialDenialDoesNotContaminatePaidVineyardCapability() throws {
        let account = try JSONDecoder().decode(BackendVineTrackAccess.self, from: Data("{\"has_access\":false,\"can_write\":false,\"can_enter_vineyard\":true,\"read_only_reason\":\"trial_expired\"}".utf8))
        let row = try entry("\"has_vineyard_access\":true,\"can_write\":true,\"vineyard_access_source\":\"paid_vineyard\"")
        #expect(account.canWrite == false && account.canEnterVineyard == true)
        #expect(account.readOnlyReason == "trial_expired")
        #expect(!account.grantsSupabaseAccess)
        #expect(row.operationalAccess.canWrite)
    }

    @Test func missingAccountFieldsDoNotChangeExistingAppDecision() throws {
        let account = try JSONDecoder().decode(BackendVineTrackAccess.self, from: Data("{\"has_access\":true}".utf8))
        #expect(account.canEnterVineyard == nil && account.canWrite == nil && account.readOnlyReason == nil)
        #expect(account.grantsSupabaseAccess && account.grantsIOSAppAccess)
    }

    @Test func matrixKeepsVineyardsIndependentAndUnlistedVineyardUnknown() throws {
        let expired = try entry("\"has_vineyard_access\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"")
        let second = UUID()
        let paid = try JSONDecoder().decode(VineyardAccessEntry.self, from: Data("{\"vineyard_id\":\"\(second)\",\"has_vineyard_access\":true,\"can_write\":true}".utf8))
        let matrix = VineyardAccessMatrix(account: nil, vineyards: [expired, paid])
        #expect(matrix.operationalAccessByVineyard[vineyard.uuidString]?.isTrialExpiredReadOnly == true)
        #expect(matrix.operationalAccessByVineyard[second.uuidString]?.canWrite == true)
        #expect(matrix.entry(for: UUID()) == nil)
        #expect(VineyardAccessMatrix(account: nil, vineyards: []).operationalAccessByVineyard.isEmpty)
    }

    @Test func oldSnapshotDecodesWithoutCapabilities() throws {
        let snapshot = try JSONDecoder().decode(EntitlementVerificationSnapshot.self, from: Data("{\"lastVerifiedAt\":0,\"wasEntitled\":true}".utf8))
        #expect(snapshot.operationalAccessByVineyard == nil)
    }

    @Test func cachedReadOnlySurvivesRoundTripWithoutBecomingAnAccountGrant() throws {
        let access = try entry("\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"").operationalAccess
        let original = EntitlementVerificationSnapshot(userId: owner.uuidString, lastVerifiedAt: .distantPast, wasEntitled: false, knownExpiresAt: .distantPast, operationalAccessByVineyard: [vineyard.uuidString: access])
        let restored = try JSONDecoder().decode(EntitlementVerificationSnapshot.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.operationalAccess(for: vineyard, userId: owner)?.isTrialExpiredReadOnly == true)
        #expect(!restored.wasEntitled)
        #expect(restored.operationalAccess(for: vineyard, userId: UUID()) == nil)
    }

    @Test func unownedLegacySnapshotCannotSupplyScopedCapabilities() {
        let access = VineyardOperationalAccess(legacyCanEnter: true)
        let unowned = EntitlementVerificationSnapshot(userId: nil, lastVerifiedAt: Date(), wasEntitled: true, operationalAccessByVineyard: [vineyard.uuidString: access])
        #expect(unowned.operationalAccess(for: vineyard, userId: owner) == nil)
    }

    @MainActor private func withStore(_ body: (EntitlementVerificationStore) throws -> Void) rethrows {
        let suite = "ReadOnlyEntitlementContractTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(EntitlementVerificationStore(defaults: defaults))
    }

    @Test @MainActor func matrixVerificationDoesNotRenewAccountGraceOrChangeAccountResult() throws {
        try withStore { store in
            let before = EntitlementVerificationSnapshot(userId: owner.uuidString, lastVerifiedAt: .distantPast, wasEntitled: true, knownExpiresAt: .distantPast)
            store.save(before)
            let access = try entry("\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"").operationalAccess
            store.recordOperationalAccess(userId: owner, capabilities: [vineyard.uuidString: access])
            let after = try #require(store.load())
            #expect(after.lastVerifiedAt == before.lastVerifiedAt && after.wasEntitled == before.wasEntitled)
            #expect(after.knownExpiresAt == before.knownExpiresAt)
            #expect(after.operationalAccess(for: vineyard, userId: owner) == access)
        }
    }

    @Test @MainActor func providerRefreshPreservesReadOnlyAndFreshEmptyMatrixClearsOnlyCapabilities() throws {
        try withStore { store in
            let access = try entry("\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"").operationalAccess
            store.recordOperationalAccess(userId: owner, capabilities: [vineyard.uuidString: access])
            store.recordVerification(userId: owner.uuidString, entitled: true, productStatus: "active:pro")
            #expect(store.load()?.operationalAccess(for: vineyard, userId: owner) == access)
            store.recordOperationalAccess(userId: owner, capabilities: [:])
            #expect(store.load()?.operationalAccessByVineyard == [:])
            #expect(store.load()?.wasEntitled == true)
        }
    }

    @Test @MainActor func freshGrantReplacesReadOnlyAndAccountSwitchDoesNotInheritIt() throws {
        try withStore { store in
            let expired = try entry("\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"").operationalAccess
            store.recordOperationalAccess(userId: owner, capabilities: [vineyard.uuidString: expired])
            let writable = VineyardOperationalAccess(legacyCanEnter: true, canWrite: true)
            store.recordOperationalAccess(userId: owner, capabilities: [vineyard.uuidString: writable])
            #expect(store.load()?.operationalAccess(for: vineyard, userId: owner)?.canWrite == true)
            store.recordVerification(userId: UUID().uuidString, entitled: false, productStatus: nil)
            #expect(store.load()?.operationalAccessByVineyard == nil)
        }
    }
}

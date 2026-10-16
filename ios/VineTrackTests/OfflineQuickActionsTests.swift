import Foundation
import Testing
import CoreLocation
@testable import VineTrack

@MainActor
@Suite("Offline verified Quick Actions")
struct OfflineQuickActionsTests {
    @Test(arguments: [BackendRole.owner, .manager, .supervisor, .operator])
    func verifiedRolesSurviveSwitchAndStoreRecreation(_ role: BackendRole) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = NewBackendAuthService()
        auth.userId = UUID(); auth.isSignedIn = true
        let user = try #require(auth.userId)
        let a = UUID(), b = UUID()
        let cache = VerifiedVineyardRoleCache(persistence: PersistenceStore(directory: root))
        let online = BackendAccessControl(roleCache: cache, membershipRead: { vineyard in
            [BackendVineyardMember(id: UUID(), vineyardId: vineyard, userId: user, role: role)]
        })
        await online.refresh(for: a, auth: auth)
        await online.refresh(for: b, auth: auth)
        let offline = BackendAccessControl(roleCache: VerifiedVineyardRoleCache(persistence: PersistenceStore(directory: root)),
            membershipRead: { _ in throw URLError(.notConnectedToInternet) })
        for vineyard in [a, b, a, b, a] {
            await offline.refresh(for: vineyard, auth: auth)
            #expect(offline.currentRole == role)
            #expect(offline.canCreateOperationalRecords)
            #expect(offline.loadedUserId == user)
            #expect(offline.loadedVineyardId == vineyard)
            #expect(!offline.isLoading)
        }
        await offline.refresh(for: UUID(), auth: auth)
        #expect(!offline.canCreateOperationalRecords)
        auth.userId = UUID()
        await offline.refresh(for: a, auth: auth)
        #expect(!offline.canCreateOperationalRecords)
        auth.isSignedIn = false
        await offline.refresh(for: a, auth: auth)
        #expect(offline.loadedUserId == nil)
    }

    @Test func definitiveRevocationSurvivesOfflineRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = NewBackendAuthService(); auth.userId = UUID(); auth.isSignedIn = true
        let vineyard = UUID(), user = try #require(auth.userId)
        let session = try #require(auth.legacySprayScope(vineyard: vineyard)?.session)
        let cache = VerifiedVineyardRoleCache(persistence: PersistenceStore(directory: root))
        try cache.save(.init(userId: user, vineyardId: vineyard, sessionId: session, role: .operator, workerTypeId: nil))
        let access = BackendAccessControl(roleCache: cache, membershipRead: { _ in [] })
        await access.refresh(for: vineyard, auth: auth)
        #expect(!access.canCreateOperationalRecords)
        let offline = BackendAccessControl(roleCache: cache, membershipRead: { _ in throw URLError(.timedOut) })
        await offline.refresh(for: vineyard, auth: auth)
        #expect(!offline.canCreateOperationalRecords)
        #expect(cache.load(userId: user, vineyardId: vineyard, sessionId: UUID()) == nil)
    }

    @Test(arguments: [-1001, -1003, 500, 503, 403])
    func connectivityErrorsDoNotRevokeButOnlineDenialDoes(_ code: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = NewBackendAuthService(); auth.userId = UUID(); auth.isSignedIn = true
        let vineyard = UUID(), user = try #require(auth.userId)
        let session = try #require(auth.legacySprayScope(vineyard: vineyard)?.session)
        let cache = VerifiedVineyardRoleCache(persistence: PersistenceStore(directory: root))
        try cache.save(.init(userId: user, vineyardId: vineyard, sessionId: session, role: .supervisor, workerTypeId: nil))
        let access = BackendAccessControl(roleCache: cache, membershipRead: { _ in
            throw NSError(domain: code < 0 ? NSURLErrorDomain : "HTTP", code: code)
        })
        await access.refresh(for: vineyard, auth: auth)
        #expect(access.canCreateOperationalRecords == (code != 403))
        auth.userId = UUID()
        #expect(!access.canCreateOperationalRecords)
        auth.userId = user
        auth.isSignedIn = false
        #expect(!access.canCreateOperationalRecords)
        auth.isSignedIn = true
        // Explicit sign-out rotates this existing durable session fence.
        try PersistenceStore.shared.saveOrThrow(UUID(), key: "legacy_spray_session_\(user.uuidString)")
        await access.refresh(for: vineyard, auth: auth)
        #expect(!access.canCreateOperationalRecords)
    }

    @Test(arguments: [false, true])
    func lateAResponseCannotReplaceB(_ failure: Bool) async throws {
        let auth = NewBackendAuthService(); auth.userId = UUID(); auth.isSignedIn = true
        let user = try #require(auth.userId), a = UUID(), b = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var started = false
        let access = BackendAccessControl(roleCache: VerifiedVineyardRoleCache(persistence: PersistenceStore(directory: root)), membershipRead: { vineyard in
            if vineyard == a {
                started = true
                try? await Task.sleep(for: .milliseconds(100))
                if failure { throw URLError(.cannotFindHost) }
                return [BackendVineyardMember(id: UUID(), vineyardId: a, userId: user, role: .owner)]
            }
            return [BackendVineyardMember(id: UUID(), vineyardId: b, userId: user, role: .supervisor)]
        })
        let first = Task { await access.refresh(for: a, auth: auth) }
        for _ in 0..<100 where !started { await Task.yield() }
        #expect(started)
        await access.refresh(for: b, auth: auth)
        if failure { first.cancel() }
        await first.value
        #expect(access.loadedVineyardId == b)
        #expect(access.currentRole == .supervisor)
        #expect(access.canCreateOperationalRecords)
        #expect(access.errorMessage == nil)
    }

    @Test func actualSignOutInvalidatesGrantEvenForSameUserSigningBackInOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = NewBackendAuthService(authRepository: OfflineSignOutRepository())
        let actor = UUID(), vineyard = UUID()
        auth.userId = actor; auth.isSignedIn = true
        let cache = VerifiedVineyardRoleCache(persistence: PersistenceStore(directory: root))
        let online = BackendAccessControl(roleCache: cache, membershipRead: { scope in
            [BackendVineyardMember(id: UUID(), vineyardId: scope, userId: actor, role: .owner)]
        })
        await online.refresh(for: vineyard, auth: auth)
        #expect(online.canCreateOperationalRecords)
        await auth.signOut()
        #expect(!auth.isSignedIn)
        #expect(!online.canCreateOperationalRecords)
        #expect(auth.completedSignOutSequence == 1)
        auth.userId = actor; auth.isSignedIn = true
        let offline = BackendAccessControl(roleCache: cache, membershipRead: { _ in throw URLError(.notConnectedToInternet) })
        await offline.refresh(for: vineyard, auth: auth)
        #expect(!offline.canCreateOperationalRecords)
    }

    @Test func localRepairGrowthAndManualPointKeepIdentityAcrossVineyards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceStore(directory: root)
        let store = MigratedDataStore(persistence: persistence)
        let actor = UUID(), a = UUID(), b = UUID()
        var ids: [UUID] = []
        let metadata = PinSyncMetadata(persistence: persistence)
        store.currentUserIdProvider = { actor }
        store.onPinCreateWillPersist = { id, date in try metadata.markDirtyDurably(id, at: date) }
        for vineyard in [a, b] {
            store.selectedVineyardId = vineyard
            store.reloadCurrentVineyardData()
            for mode in [PinMode.repairs, .growth] {
                let button = ButtonConfig(vineyardId: vineyard, name: "Synthetic action", color: "red", index: 0, mode: mode)
                let pin = try #require(store.createPinFromButton(button: button,
                    coordinate: CLLocationCoordinate2D(latitude: -34, longitude: 138), heading: nil,
                    createdByUserId: actor, notes: "Offline evidence", locationScope: "point"))
                ids.append(pin.id)
            }
        }
        let reloaded = try PinRepository(persistence: PersistenceStore(directory: root)).loadAllForDurableUpdate()
        #expect(Set(reloaded.map(\.id)) == Set(ids))
        #expect(reloaded.filter { $0.vineyardId == a }.count == 2)
        #expect(reloaded.filter { $0.vineyardId == b }.count == 2)
        #expect(reloaded.allSatisfy { $0.createdByUserId == actor && $0.notes == "Offline evidence" })
        #expect(PinSyncMetadata(persistence: PersistenceStore(directory: root)).pendingUpserts.count == 4)
    }
}

private struct OfflineSignOutRepository: AuthRepository {
    var currentUserId: UUID? { nil }
    func restoreSession() async throws -> AppUser? { nil }
    func signOut() async throws {}
    func signInWithEmail(email: String, password: String) async throws -> AppUser { throw BackendRepositoryError.missingAuthenticatedUser }
    func signUpWithEmail(name: String, email: String, password: String) async throws -> AppUser? { throw BackendRepositoryError.missingAuthenticatedUser }
    func sendPasswordReset(email: String, redirectTo: URL?) async throws { throw BackendRepositoryError.missingAuthenticatedUser }
    func verifyPasswordResetPin(email: String, pin: String) async throws -> AppUser { throw BackendRepositoryError.missingAuthenticatedUser }
    func updatePassword(_ newPassword: String) async throws { throw BackendRepositoryError.missingAuthenticatedUser }
    func resetPasswordWithPin(email: String, pin: String, newPassword: String) async throws -> AppUser { throw BackendRepositoryError.missingAuthenticatedUser }
    func handlePasswordRecoveryURL(_ url: URL) async throws -> AppUser { throw BackendRepositoryError.missingAuthenticatedUser }
    func signInWithApple(idToken: String, nonce: String?) async throws -> AppUser { throw BackendRepositoryError.missingAuthenticatedUser }
}

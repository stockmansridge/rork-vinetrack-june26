import SwiftUI

struct NewBackendRootView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(SubscriptionService.self) private var subscription
    @Environment(BiometricAuthService.self) private var biometric
    @Environment(SystemAdminService.self) private var systemAdmin
    @Environment(\.scenePhase) private var scenePhase

    @State private var didAttemptRestore: Bool = false
    @State private var showBiometricEnrollment: Bool = false
    @State private var lastSignedInState: Bool = false
    @State private var onboardingCompleted: Bool = OnboardingState.isCompleted
    @State private var disclaimerAccepted: Bool = false
    @State private var didCheckDisclaimer: Bool = false
    @State private var isCheckingDisclaimer: Bool = false
    @State private var disclaimerError: String?
    @State private var didApplyDefaultVineyard: Bool = false
    @State private var isLoadingVineyards: Bool = false
    /// True when the membership/vineyard load failed AND we have no cached
    /// vineyards to fall back on. This is NOT the same as "genuinely zero
    /// vineyards" — it means we couldn't confirm membership, so we must show a
    /// retryable state rather than the no-vineyards onboarding screen.
    @State private var vineyardLoadFailedNoCache: Bool = false
    @State private var lastScenePhase: ScenePhase = .active
    @State private var didEnterBackground: Bool = false
    @State private var showInvitationsSheet: Bool = false
    @State private var deferredInvitationIds: Set<UUID> = []

    private let disclaimerRepository: any DisclaimerRepositoryProtocol = SupabaseDisclaimerRepository(currentVersion: DisclaimerInfo.version)
    private let vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository()
    private let grapeVarietyRepository = SupabaseGrapeVarietyCatalogRepository()
    private let teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()

    var body: some View {
        Group {
            // 1. Splash while we restore the Supabase session. Never show
            //    the disclaimer or any auth-dependent UI during this window —
            //    the auth state is still indeterminate.
            if !didAttemptRestore {
                loadingView
            } else if auth.isSignedIn && biometric.requiresUnlock {
                BiometricLockView()
            } else if !auth.isSignedIn {
                // 2. Logged out — login screen only. Disclaimer must never
                //    appear over the login screen.
                NewBackendLoginView()
            } else if !onboardingCompleted {
                OnboardingView {
                    OnboardingState.markCompleted()
                    onboardingCompleted = true
                }
            } else if !didApplyDefaultVineyard {
                // 3. Load the user's vineyards so we know they are in the
                //    authenticated app shell before evaluating the disclaimer.
                vineyardLoadingView
            } else if store.selectedVineyard == nil && vineyardLoadFailedNoCache {
                // 3a. We are authenticated but could NOT confirm membership
                //     (offline / transient backend error) and have no cached
                //     vineyards. Showing the no-vineyards onboarding here would
                //     be wrong — the user may well have vineyards we just can't
                //     see yet. Offer a retry instead.
                vineyardLoadFailedView
            } else if store.selectedVineyard == nil {
                // 3b. Membership load completed and the user genuinely has no
                //     vineyard access — invite/create onboarding.
                BackendVineyardListView()
            } else if !didCheckDisclaimer {
                // 4. Now that the user is signed in and inside a vineyard,
                //    check whether the current disclaimer version has been
                //    accepted. The local per-user cache short-circuits this
                //    so a transient network/JWT race never re-prompts a user
                //    who has already accepted.
                disclaimerLoadingView
            } else if !disclaimerAccepted {
                DisclaimerAcceptanceView {
                    markDisclaimerAcceptedLocally()
                    disclaimerAccepted = true
                }
            } else if subscription.hasAccess {
                NewMainTabView()
            } else if !subscription.hasResolvedStatus {
                subscriptionLoadingView
            } else if subscription.shouldShowOfflineAccessNotice {
                // Offline and we can't confirm access locally (grace expired or
                // no prior verification). Show a clear "connect to verify"
                // message instead of the paywall, which can't transact offline.
                OfflineAccessUnavailableView()
            } else {
                NavigationStack {
                    SubscriptionPaywallView(allowDismiss: false)
                }
            }
        }
        .onChange(of: currentRoute) { _, newRoute in
            StartupDiagnostics.route(newRoute)
        }
        .task {
            if !didAttemptRestore {
                StartupDiagnostics.log("auth restore started")
                await auth.restoreSession()
                StartupDiagnostics.log("auth restore completed: signedIn=\(auth.isSignedIn)")
                if auth.isSignedIn {
                    biometric.lockIfEnabled()
                    biometric.updateSavedEmailIfEnabled(auth.userEmail)
                }
                lastSignedInState = auth.isSignedIn
                didAttemptRestore = true
                // Kick off the post-restore work explicitly. The
                // `.task(id: auth.isSignedIn)` modifier won't refire here
                // because `isSignedIn` flipped while `didAttemptRestore`
                // was still false (and was guarded out).
                if auth.isSignedIn, let userId = auth.userId {
                    await subscription.login(userId: userId, userCreatedAt: auth.userCreatedAt)
                    if !didApplyDefaultVineyard {
                        await loadVineyardsAndApplyDefault()
                    }
                }
            }
        }
        .onChange(of: auth.isSignedIn) { _, newValue in
            handleSignedInChange(newValue: newValue)
        }
        .sheet(isPresented: $showBiometricEnrollment) {
            BiometricEnrollmentSheet()
        }
        .sheet(isPresented: $showInvitationsSheet) {
            PendingInvitationsSheet(
                onAccepted: { invitation in
                    await loadVineyardsAndApplyDefault(forceReload: true)
                    if store.vineyards.contains(where: { $0.id == invitation.vineyardId }),
                       let joined = store.vineyards.first(where: { $0.id == invitation.vineyardId }) {
                        store.selectVineyard(joined)
                    }
                },
                onDeferred: {
                    deferredInvitationIds.formUnion(auth.pendingInvitations.map { $0.id })
                }
            )
        }
        .onChange(of: auth.pendingInvitations.map { $0.id }) { _, _ in
            evaluateInvitationsSheet()
        }
        .onChange(of: isInMainAppShell) { _, _ in
            evaluateInvitationsSheet()
        }
        .task(id: auth.isSignedIn) {
            // Only react to a confirmed signed-in transition AFTER session
            // restoration has completed. This prevents the disclaimer / vineyard
            // load from racing against `restoreSession()` on cold start.
            guard didAttemptRestore else { return }
            if auth.isSignedIn {
                if let userId = auth.userId {
                    await subscription.login(userId: userId, userCreatedAt: auth.userCreatedAt)
                }
                if !didApplyDefaultVineyard {
                    await loadVineyardsAndApplyDefault()
                }
            } else {
                disclaimerAccepted = false
                didCheckDisclaimer = false
                disclaimerError = nil
                didApplyDefaultVineyard = false
                vineyardLoadFailedNoCache = false
                await subscription.logout()
            }
        }
        .task(id: didApplyDefaultVineyard) {
            // Evaluate disclaimer only once the user is fully inside the
            // authenticated app shell (signed in + vineyards loaded).
            guard didAttemptRestore,
                  auth.isSignedIn,
                  auth.userId != nil,
                  didApplyDefaultVineyard,
                  !didCheckDisclaimer else { return }
            await checkDisclaimer()
        }
        .task(id: store.selectedVineyardId) {
            if let vid = store.selectedVineyardId {
                DefaultDataSeeder.seedIfNeeded(store: store)
                // Refresh shared grape-variety catalogue when a vineyard is
                // selected so pickers and resolvers can use Supabase as the
                // source of truth. Falls back to the cached/built-in copy.
                await SharedGrapeVarietyCatalogCache.shared.refresh()
                await syncVineyardGrapeVarieties(vineyardId: vid)
                await syncVineyardLocation(vineyardId: vid)
                await syncVineyardRegionSettings(vineyardId: vid)
            }
        }
        .task(id: auth.isSignedIn) {
            if auth.isSignedIn {
                await auth.loadPendingInvitations()
                await systemAdmin.refresh()
                // Warm the shared grape-variety catalogue right after sign-in
                // so the cache is ready before any block screen renders.
                await SharedGrapeVarietyCatalogCache.shared.refresh()
            } else {
                systemAdmin.clearOnSignOut()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-arm the biometric lock only when returning from a true
            // background state. The Face ID system prompt itself causes a
            // brief `.inactive` phase; re-locking on `.inactive -> .active`
            // would create an unlock loop.
            if newPhase == .background {
                didEnterBackground = true
            } else if newPhase == .active && auth.isSignedIn {
                if didEnterBackground {
                    biometric.lockIfEnabled()
                    didEnterBackground = false
                }
                Task { await auth.loadPendingInvitations() }
            }
            lastScenePhase = newPhase
        }
    }

    private func handleSignedInChange(newValue: Bool) {
        defer { lastSignedInState = newValue }
        // Only react on transitions, not initial value.
        guard newValue != lastSignedInState else { return }
        if newValue {
            // User just signed in.
            biometric.updateSavedEmailIfEnabled(auth.userEmail)
            // Offer biometric enrollment once if supported and not enabled.
            if (biometric.deviceSupportsBiometrics || biometric.deviceSupportsAnyAuth),
               !biometric.isEnabled,
               !biometric.hasShownEnrollmentPrompt {
                // Defer slightly so the login screen dismiss animation completes.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    if auth.isSignedIn && !biometric.isEnabled {
                        showBiometricEnrollment = true
                    }
                }
            }
        } else {
            // Signed out — clear the unlock gate so a future sign-in starts fresh.
            biometric.markUnlocked()
        }
    }

    private var subscriptionLoadingView: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                Text("Checking subscription…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var vineyardLoadingView: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                Text(isLoadingVineyards ? "Loading vineyards…" : "Preparing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Local fast-path: if this user previously accepted the current
    /// disclaimer version on this device, treat it as accepted immediately
    /// (we still revalidate against Supabase in the background).
    private func loadCachedDisclaimerAcceptance() -> Bool {
        guard let userId = auth.userId?.uuidString else { return false }
        let key = Self.disclaimerCacheKey(userId: userId)
        let stored = UserDefaults.standard.string(forKey: key)
        return stored == DisclaimerInfo.version
    }

    private func markDisclaimerAcceptedLocally() {
        guard let userId = auth.userId?.uuidString else { return }
        let key = Self.disclaimerCacheKey(userId: userId)
        UserDefaults.standard.set(DisclaimerInfo.version, forKey: key)
    }

    private static func disclaimerCacheKey(userId: String) -> String {
        "disclaimerAcceptedVersion.\(userId)"
    }

    private func loadVineyardsAndApplyDefault(forceReload: Bool = false) async {
        isLoadingVineyards = true
        StartupDiagnostics.log("vineyard sync started (forceReload=\(forceReload))")
        defer { isLoadingVineyards = false }
        do {
            let backendVineyards = try await vineyardRepository.listMyVineyards()
            store.mapBackendVineyardsIntoLocal(backendVineyards)
            if !forceReload {
                store.applyDefaultVineyardSelection(defaultId: auth.defaultVineyardId)
            }
            // If profile pointed at a vineyard the user no longer belongs to, clear it remotely.
            if let defaultId = auth.defaultVineyardId,
               !store.vineyards.contains(where: { $0.id == defaultId }) {
                _ = await auth.setDefaultVineyard(nil)
            }
            vineyardLoadFailedNoCache = false
            StartupDiagnostics.log("vineyard sync completed: membershipCount=\(store.vineyards.count)")
            didApplyDefaultVineyard = true
        } catch {
            // The membership load failed. Decide *why* before routing.
            if SupabaseAuthRepository.isAuthRejection(error) {
                // The session was rejected by the server (e.g. refresh token
                // expired between restore and this call). Sign out so the app
                // routes to login — never to the no-vineyards onboarding.
                StartupDiagnostics.log("vineyard sync failed: auth rejected — signing out")
                await auth.signOut()
                return
            }
            // Offline / transient backend error — fall back to local cache.
            if !forceReload {
                store.applyDefaultVineyardSelection(defaultId: auth.defaultVineyardId)
            }
            // Only treat this as a genuine "no vineyards" state if we actually
            // have cached vineyards. Otherwise flag it as a retryable failure so
            // routing shows a retry screen, not invite/create onboarding.
            vineyardLoadFailedNoCache = store.vineyards.isEmpty
            StartupDiagnostics.log("vineyard sync failed offline: cachedVineyards=\(store.vineyards.count), retryable=\(vineyardLoadFailedNoCache)")
            didApplyDefaultVineyard = true
        }
    }

    /// Reset state and re-run the membership load. Used by the retry button on
    /// the vineyard-load-failed screen.
    private func retryVineyardLoad() async {
        vineyardLoadFailedNoCache = false
        didApplyDefaultVineyard = false
        await loadVineyardsAndApplyDefault()
    }

    /// True once the user has cleared auth/onboarding/disclaimer/vineyard
    /// gates and is viewing the main tab shell. Invitations should only
    /// surface as a modal once we're past these gates — the no-vineyard
    /// case is already covered by `BackendVineyardListView`.
    private var isInMainAppShell: Bool {
        auth.isSignedIn
            && !biometric.requiresUnlock
            && onboardingCompleted
            && didCheckDisclaimer
            && disclaimerAccepted
            && didApplyDefaultVineyard
            && store.selectedVineyard != nil
            && subscription.hasAccess
    }

    private func evaluateInvitationsSheet() {
        guard isInMainAppShell else { return }
        // Apply the same filtering rules used by PendingInvitationsSheet so we
        // don't surface the modal with an empty card list (e.g. an invite for
        // a vineyard the caller already owns, or an alias email that doesn't
        // match the active auth email). Matches sql/081 RLS guard.
        let authEmail = (auth.userEmail ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let memberIds = Set(store.vineyards.map { $0.id })
        let surfaceable = auth.pendingInvitations.filter { invitation in
            guard invitation.status.lowercased() == "pending" else { return false }
            if !authEmail.isEmpty && invitation.email.lowercased() != authEmail { return false }
            if memberIds.contains(invitation.vineyardId) { return false }
            return true
        }
        let pendingIds = surfaceable.map { $0.id }
        // Drop any deferrals for invites that are no longer pending so a
        // fresh invite created later in the session still surfaces.
        deferredInvitationIds.formIntersection(pendingIds)
        let undeferred = pendingIds.contains { !deferredInvitationIds.contains($0) }
        if undeferred && !showInvitationsSheet {
            showInvitationsSheet = true
        }
    }

    private var loadingView: some View {
        LoadingSplashView()
    }

    /// Shown when the user is authenticated but we couldn't confirm vineyard
    /// membership and have nothing cached. Distinct from the no-vineyards
    /// onboarding so we never imply the user has no access when we simply
    /// couldn't reach the backend.
    private var vineyardLoadFailedView: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Couldn't load your vineyards")
                    .font(.headline)
                Text("We couldn't reach the server to confirm your vineyard access. Check your connection and try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") {
                    Task { await retryVineyardLoad() }
                }
                .buttonStyle(.vineyardPrimary)
                .padding(.horizontal, 40)
                Button("Sign out") {
                    Task { await auth.signOut() }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Pure, side-effect-free derivation of the screen the body is presenting.
    /// Logged on change for startup diagnostics.
    private var currentRoute: StartupDiagnostics.Route {
        if !didAttemptRestore { return .sessionRestoring }
        if auth.isSignedIn && biometric.requiresUnlock { return .biometricLock }
        if !auth.isSignedIn { return .login }
        if !onboardingCompleted { return .onboarding }
        if !didApplyDefaultVineyard { return .vineyardLoading }
        if store.selectedVineyard == nil && vineyardLoadFailedNoCache { return .vineyardLoadFailed }
        if store.selectedVineyard == nil { return .noVineyards }
        if !didCheckDisclaimer { return .disclaimer }
        if !disclaimerAccepted { return .disclaimer }
        if subscription.hasAccess { return .dashboard }
        if !subscription.hasResolvedStatus { return .subscriptionLoading }
        if subscription.shouldShowOfflineAccessNotice { return .offlineAccessNotice }
        return .paywall
    }

    private var disclaimerLoadingView: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                if isCheckingDisclaimer {
                    ProgressView()
                    Text("Checking disclaimer status…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let disclaimerError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Couldn't verify disclaimer")
                        .font(.headline)
                    Text(disclaimerError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Retry") {
                        Task { await checkDisclaimer() }
                    }
                    .buttonStyle(.vineyardPrimary)
                    .padding(.horizontal, 40)
                }
            }
        }
    }

    /// Pull the vineyard-scoped location (lat/long/elevation/timezone) from
    /// Supabase and merge it into local `AppSettings`. If the server still has
    /// nulls but the local copy has values (e.g. legacy device with the old
    /// local-only elevation), push them back as a one-time backfill so other
    /// devices and Lovable see them.
    private func syncVineyardLocation(vineyardId: UUID) async {
        do {
            let remote = try await vineyardRepository.getVineyardLocation(vineyardId: vineyardId)
            let merged: MigratedDataStore.VineyardLocationMergeResult
            if let remote {
                merged = store.applyRemoteVineyardLocation(remote, vineyardId: vineyardId)
            } else {
                let s = store.settings
                merged = MigratedDataStore.VineyardLocationMergeResult(
                    needsBackfill: s.vineyardLatitude != nil
                        || s.vineyardLongitude != nil
                        || s.vineyardElevationMetres != nil,
                    latitude: s.vineyardLatitude,
                    longitude: s.vineyardLongitude,
                    elevationMetres: s.vineyardElevationMetres,
                    timezone: s.timezone
                )
            }
            if merged.needsBackfill {
                _ = try? await vineyardRepository.setVineyardLocation(
                    vineyardId: vineyardId,
                    latitude: merged.latitude,
                    longitude: merged.longitude,
                    elevationMetres: merged.elevationMetres,
                    timezone: merged.timezone
                )
            }
        } catch {
            // Offline / RPC missing / not a member — keep existing local settings.
        }
    }

    /// Pull the vineyard-scoped organisation region settings (country/units/
    /// date format/terminology) from Supabase and merge them into local
    /// `AppSettings.regionSettings`. Server values win; any null server field
    /// keeps the local fallback (AU default unless changed by owner/manager).
    ///
    /// Backfill safety: if the server has *no* region values but the local
    /// copy diverges from AU defaults, push the local copy up exactly once —
    /// but ONLY if the current user is an owner or manager. Staff/operators
    /// must never set organisation-level region settings by automatic
    /// backfill (the server RPC also enforces this; this is the client guard).
    private func syncVineyardRegionSettings(vineyardId: UUID) async {
        do {
            guard let remote = try await vineyardRepository.getVineyardRegionSettings(vineyardId: vineyardId) else {
                return
            }
            let merged = store.applyRemoteVineyardRegionSettings(remote, vineyardId: vineyardId)
            guard merged.needsBackfill else { return }

            // Owner/manager-only backfill guard.
            guard await currentUserCanManageSettings(vineyardId: vineyardId) else { return }

            let region = merged.settingsToBackfill
            _ = try? await vineyardRepository.setVineyardRegionSettings(
                BackendVineyardRegionSettings(
                    vineyardId: vineyardId,
                    countryCode: region.countryCode,
                    currencyCode: region.currencyCode,
                    timezone: region.timezone,
                    areaUnit: region.areaUnit,
                    volumeUnit: region.volumeUnit,
                    distanceUnit: region.distanceUnit,
                    fuelUnit: region.fuelUnit,
                    sprayRateAreaUnit: region.sprayRateAreaUnit,
                    dateFormat: region.dateFormat,
                    terminologyRegion: region.terminologyRegion
                )
            )
        } catch {
            // Offline / RPC missing / not a member — keep existing local settings.
        }
    }

    /// Returns true only when the current signed-in user holds owner or manager
    /// role for the vineyard. Used to gate organisation-level region backfill.
    private func currentUserCanManageSettings(vineyardId: UUID) async -> Bool {
        guard let userId = auth.userId else { return false }
        do {
            let members = try await teamRepository.listMembers(vineyardId: vineyardId)
            return members.first { $0.userId == userId }?.role.canChangeSettings ?? false
        } catch {
            return false
        }
    }

    /// Pull the vineyard's custom + selected grape varieties from Supabase
    /// (`list_vineyard_grape_varieties`) and merge them into the local store
    /// so custom varieties created elsewhere (e.g. the Lovable web portal)
    /// appear in iOS pickers and the Grape Varieties screen.
    private func syncVineyardGrapeVarieties(vineyardId: UUID) async {
        do {
            let rows = try await grapeVarietyRepository.listVineyardVarieties(vineyardId: vineyardId)
            store.applyRemoteVineyardGrapeVarieties(rows, vineyardId: vineyardId)
        } catch {
            // Offline / RPC missing — keep existing local varieties.
        }
    }

    private func checkDisclaimer() async {
        isCheckingDisclaimer = true
        disclaimerError = nil
        defer { isCheckingDisclaimer = false }

        // Fast-path: trust the per-user local cache so the acceptance screen
        // never flashes if the user has already accepted this version on this
        // device. We still verify against Supabase below and overwrite the
        // cache if the server disagrees.
        let cached = loadCachedDisclaimerAcceptance()
        if cached {
            disclaimerAccepted = true
            didCheckDisclaimer = true
        }

        do {
            let accepted = try await disclaimerRepository.hasAcceptedCurrentDisclaimer()
            disclaimerAccepted = accepted
            didCheckDisclaimer = true
            if accepted {
                markDisclaimerAcceptedLocally()
            }
        } catch {
            // Network/RLS error. If we already have a cached acceptance,
            // keep the user in the app — don't kick them back to the
            // disclaimer screen. Otherwise surface a retry UI.
            if cached {
                didCheckDisclaimer = true
            } else {
                disclaimerError = error.localizedDescription
                didCheckDisclaimer = false
            }
        }
    }
}

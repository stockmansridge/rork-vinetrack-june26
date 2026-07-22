#if DEBUG
import Foundation
import SwiftUI
import Supabase
import UIKit

struct BackendDiagnosticView: View {
    private let provider: SupabaseClientProvider = .shared
    private let authRepository = SupabaseAuthRepository()
    private let profileRepository = SupabaseProfileRepository()
    private let vineyardRepository = SupabaseVineyardRepository()
    private let teamRepository = SupabaseTeamRepository()
    private let auditRepository = SupabaseAuditRepository()

    @Environment(MigratedDataStore.self) private var migratedStore
    @Environment(OperatorCategorySyncService.self) private var operatorCategorySync
    @Environment(SubscriptionService.self) private var subscription

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var resetPin: String = ""
    @State private var resetNewPassword: String = ""
    @State private var vineyardName: String = "Test Vineyard"
    @State private var country: String = ""
    @State private var invitedEmail: String = ""
    @State private var selectedRoleValue: String = "operator"
    @State private var disclaimerVersion: String = "1.0"
    @State private var currentUserId: UUID?
    @State private var currentEmail: String?
    @State private var currentVineyardId: UUID?
    @State private var vineyards: [BackendVineyard] = []
    @State private var pendingInvitations: [BackendInvitation] = []
    @State private var members: [BackendVineyardMember] = []
    @State private var logMessages: [String] = []
    @State private var isRunning: Bool = false
    @State private var currentAction: String?
    @State private var lastStatus: String = "Ready"

    // VineTrack access resolution (read-only diagnostics).
    @State private var accessOutcome: VineTrackAccessResolver.Outcome?
    @State private var accessIsResolving: Bool = false
    @State private var accessError: String?
    @State private var accessDidRun: Bool = false

    private var selectedRole: BackendRole {
        BackendRole(rawValue: selectedRoleValue) ?? .owner
    }

    private var logText: String {
        logMessages.joined(separator: "\n")
    }

    var body: some View {
        Form {
            connectionSection
            authSection
            passwordResetSection
            profileSection
            vineyardSection
            teamSection
            vineTrackAccessSection
            disclaimerSection
            auditSection
            pinSyncDiagnosticsSection
            operatorCategoryDiagnosticsSection
            outputSection
        }
        .navigationTitle("Backend Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshAuthState()
            if logMessages.isEmpty {
                appendLog("READY Supabase configured: \(provider.isConfigured) — \(provider.configurationSummary)")
            }
        }
    }

    private var connectionSection: some View {
        Section("Supabase Connection") {
            LabeledContent("URL", value: provider.supabaseURL.absoluteString)
            LabeledContent("Configured", value: provider.isConfigured ? "true" : "false")
            Text(provider.configurationSummary)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            LabeledContent("Current User ID", value: currentUserId?.uuidString ?? "Not signed in")
            LabeledContent("Current Email", value: currentEmail ?? "Not available")
            LabeledContent("Last Status", value: lastStatus)
            if let currentAction {
                LabeledContent("Running", value: currentAction)
            }
            if let currentVineyardId {
                LabeledContent("Current Vineyard ID", value: currentVineyardId.uuidString)
            }
            Button("Refresh Status", systemImage: "arrow.clockwise") {
                Task {
                    await perform("Refresh Status") {
                        refreshAuthState()
                        return "configured=\(provider.isConfigured), \(provider.configurationSummary), user=\(currentUserId?.uuidString ?? "none")"
                    }
                }
            }
        }
    }

    private var authSection: some View {
        Section("Email / Password") {
            TextField("Name", text: $name)
                .textContentType(.name)
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
            HStack {
                Button("Sign Up") {
                    Task { await signUp() }
                }
                Button("Sign In") {
                    Task { await signIn() }
                }
                Button("Sign Out", role: .destructive) {
                    Task { await signOut() }
                }
            }
            .buttonStyle(.bordered)
            Text(lastStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Restore Session") {
                Task { await restoreSession() }
            }
        }
        .disabled(isRunning)
    }

    private var passwordResetSection: some View {
        Section("Password Reset PIN") {
            Text("Reset emails should use the 6-digit {{ .Token }} PIN, not {{ .ConfirmationURL }} links.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Reset PIN", text: $resetPin)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
            SecureField("New Password", text: $resetNewPassword)
                .textContentType(.newPassword)
            Button("Send Reset PIN Email") {
                Task { await sendResetPin() }
            }
            Button("Verify Reset PIN") {
                Task { await verifyResetPin() }
            }
            Button("Reset Password With PIN") {
                Task { await resetPasswordWithPin() }
            }
        }
        .disabled(isRunning)
    }

    private var profileSection: some View {
        Section("Profile Tests") {
            Button("Get My Profile") {
                Task { await getMyProfile() }
            }
            Button("Upsert My Profile") {
                Task { await upsertMyProfile() }
            }
        }
        .disabled(isRunning)
    }

    private var vineyardSection: some View {
        Section("Vineyard Tests") {
            TextField("Vineyard Name", text: $vineyardName)
                .textContentType(.organizationName)
            TextField("Country", text: $country)
                .textContentType(.countryName)
            Button("Create Vineyard") {
                Task { await createVineyard() }
            }
            Button("List My Vineyards") {
                Task { await listMyVineyards() }
            }
            if !vineyards.isEmpty {
                Text("Loaded vineyards: \(vineyards.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(vineyards) { vineyard in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vineyard.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(vineyard.country ?? "no country") • \(vineyard.id.uuidString)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(isRunning)
    }

    private var teamSection: some View {
        Section("Team / Invitation Tests") {
            TextField("Invited Email", text: $invitedEmail)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
            Picker("Role", selection: $selectedRoleValue) {
                ForEach(BackendRole.allCases, id: \.rawValue) { role in
                    Text(role.rawValue.capitalized).tag(role.rawValue)
                }
            }
            Button("Invite Member") {
                Task { await inviteMember() }
            }
            Button("List Pending Invitations") {
                Task { await listPendingInvitations() }
            }
            Button("Accept First Pending Invitation") {
                Task { await acceptFirstPendingInvitation() }
            }
            Button("Decline First Pending Invitation") {
                Task { await declineFirstPendingInvitation() }
            }
            Button("List Members For Current Vineyard") {
                Task { await listMembersForCurrentVineyard() }
            }
            if !pendingInvitations.isEmpty {
                Text("Pending invitations loaded: \(pendingInvitations.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(pendingInvitations) { invitation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.email)
                            .font(.subheadline.weight(.semibold))
                        Text("\(invitation.role.rawValue) • \(invitation.status)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !members.isEmpty {
                Text("Members loaded: \(members.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(members, id: \.userId) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName ?? "(no display name)")
                            .font(.subheadline.weight(.semibold))
                        Text("\(member.role.rawValue) • \(member.userId.uuidString)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(isRunning)
    }

    private var vineTrackAccessSection: some View {
        Section {
            Text("Read-only preview of VineTrackAccessResolver. Does NOT enforce access or replace the RevenueCat gate.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !provider.isConfigured {
                Label("Supabase not configured — the RPC will fall back to RevenueCat.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if currentUserId == nil {
                Label("Not signed in — sign in above to resolve backend access.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if accessIsResolving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Resolving access…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let outcome = accessOutcome {
                accessOutcomeRows(outcome)
            } else if accessDidRun {
                Text("No result.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap Resolve to run the resolver.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let accessError {
                Text(accessError)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Button("Resolve VineTrack Access", systemImage: "arrow.clockwise") {
                Task { await resolveVineTrackAccess() }
            }
            .disabled(accessIsResolving)
        } header: {
            Text("VineTrack Access Resolution")
        }
    }

    @ViewBuilder
    private func accessOutcomeRows(_ outcome: VineTrackAccessResolver.Outcome) -> some View {
        let access = outcome.backendAccess
        LabeledContent("Access granted", value: outcome.hasAccess ? "yes" : "no")
        LabeledContent("Access source", value: accessSourceLabel(outcome.source))
        LabeledContent("Fallback on RPC error", value: outcome.didFallBackOnError ? "yes" : "no")

        LabeledContent("Plan code", value: access?.planCode ?? "—")
        LabeledContent("Plan name", value: access?.planName ?? "—")
        LabeledContent("Billing provider", value: access?.billingProvider ?? access?.provider ?? "—")
        LabeledContent("Subscription status", value: access?.subscriptionStatus ?? "—")
        LabeledContent("Role", value: access?.role ?? "—")
        LabeledContent("Portal access level", value: access?.portalAccessLevel ?? "—")

        LabeledContent("Can use iOS app", value: boolLabel(access?.canUseIOSApp))
        LabeledContent("Can use portal", value: boolLabel(access?.canUsePortal))
        LabeledContent("Solo check required", value: access == nil ? "—" : (access!.requiresSoloCheck ? "yes" : "no"))

        LabeledContent("Trial end", value: dateLabel(access?.trialEnd))
        LabeledContent("Current period end", value: dateLabel(access?.currentPeriodEnd))

        LabeledContent("Included licences", value: intLabel(access?.includedLicences))
        LabeledContent("Active licences", value: intLabel(access?.activeLicences))
        LabeledContent("Additional licences", value: intLabel(access?.additionalLicences))

        LabeledContent("Vineyard ID", value: shortId(access?.vineyardId))
        LabeledContent("Subscription ID", value: shortId(access?.subscriptionId))
        LabeledContent("Licence ID", value: shortId(access?.licenceId))

        if !outcome.hasAccess, let reason = access?.reason, !reason.isEmpty {
            LabeledContent("Reason", value: reason)
        }
    }

    private func resolveVineTrackAccess() async {
        guard !accessIsResolving else { return }
        accessIsResolving = true
        accessError = nil
        accessDidRun = true
        let resolver = VineTrackAccessResolver(subscription: subscription)
        let outcome = await resolver.resolve()
        accessOutcome = outcome
        if outcome.source == .none && outcome.didFallBackOnError {
            accessError = "Backend RPC failed; fell back to RevenueCat, which is not active."
        }
        accessIsResolving = false
        appendLog("INFO VineTrack access resolved: granted=\(outcome.hasAccess), source=\(accessSourceLabel(outcome.source)), fallback=\(outcome.didFallBackOnError)")
    }

    private func accessSourceLabel(_ source: VineTrackAccessResolver.Source) -> String {
        switch source {
        case .supabaseTeam:       return "backend · team"
        case .supabaseEnterprise: return "backend · enterprise"
        case .supabaseLegacy:     return "backend · legacy"
        case .supabaseOther:      return "backend"
        case .revenueCat:         return "revenuecat"
        case .none:               return "none"
        }
    }

    private func boolLabel(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? "yes" : "no"
    }

    private func intLabel(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)"
    }

    private func dateLabel(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(.dateTime.year().month().day().hour().minute())
    }

    private func shortId(_ id: UUID?) -> String {
        guard let id else { return "—" }
        return String(id.uuidString.prefix(8)) + "…"
    }

    private var disclaimerSection: some View {
        Section("Disclaimer Tests") {
            TextField("Disclaimer Version", text: $disclaimerVersion)
            Button("Check Disclaimer Acceptance") {
                Task { await checkDisclaimerAcceptance() }
            }
            Button("Accept Disclaimer") {
                Task { await acceptDisclaimer() }
            }
        }
        .disabled(isRunning)
    }

    private var auditSection: some View {
        Section("Audit Test") {
            Button("Write Test Audit Event") {
                Task { await writeTestAuditEvent() }
            }
        }
        .disabled(isRunning)
    }

    private var pinSyncDiagnosticsSection: some View {
        Section("Pin Sync Diagnostics") {
            let diag = PinSyncDiagnostics.shared
            if let snap = diag.last {
                LabeledContent("Pin ID", value: snap.pinId.uuidString)
                LabeledContent("Title", value: snap.title ?? "nil")
                LabeledContent("createdBy text", value: snap.createdByText ?? "nil")
                LabeledContent("createdByUserId", value: snap.createdByUserId?.uuidString ?? "nil")
                LabeledContent("auth.userId", value: snap.authUserId?.uuidString ?? "nil")
                LabeledContent("payload.created_by", value: snap.payloadCreatedBy?.uuidString ?? "nil")
                LabeledContent("completed_by_user_id", value: snap.completedByUserId?.uuidString ?? "nil")
                LabeledContent("Pushed at", value: snap.pushedAt.formatted(.dateTime.hour().minute().second()))
                LabeledContent("Result", value: snap.success ? "success" : "failed")
                if let err = snap.errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else {
                Text("No pin push recorded in this session yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Copy Last Pin Sync Diagnostics", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = PinSyncDiagnostics.shared.formattedReport
                appendLog("INFO Copied last pin sync diagnostics to clipboard")
            }
            .disabled(diag.last == nil)
        }
    }

    private var operatorCategoryDiagnosticsSection: some View {
        Section("Worker Types Diagnostics") {
            LabeledContent("Selected Vineyard ID", value: migratedStore.selectedVineyardId?.uuidString ?? "none")
            LabeledContent("Local count (this vineyard)", value: "\(localOperatorCategoriesForSelectedVineyard.count)")
            LabeledContent("Local count (all vineyards)", value: "\(migratedStore.operatorCategories.count)")
            LabeledContent("Pending upserts", value: "\(operatorCategorySync.pendingUpsertCount)")
            LabeledContent("Pending deletes", value: "\(operatorCategorySync.pendingDeleteCount)")
            LabeledContent("Sync status", value: describe(operatorCategorySync.syncStatus))
            LabeledContent("Last sync", value: operatorCategorySync.lastSyncDate?.formatted(.dateTime.hour().minute().second()) ?? "never")
            if let err = operatorCategorySync.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !localOperatorCategoriesForSelectedVineyard.isEmpty {
                DisclosureGroup("Local rows") {
                    ForEach(localOperatorCategoriesForSelectedVineyard) { cat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.name).font(.subheadline.weight(.semibold))
                            Text("id=\(cat.id.uuidString)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text("vineyard=\(cat.vineyardId.uuidString) • $\(String(format: "%.2f", cat.costPerHour))/hr")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Sync Worker Types Now", systemImage: "arrow.triangle.2.circlepath") {
                Task { await runOperatorCategorySync() }
            }
            Button("Fetch Remote Worker Types", systemImage: "icloud.and.arrow.down") {
                Task { await fetchRemoteOperatorCategories() }
            }
            Button("Force Re-push Local → Supabase", systemImage: "icloud.and.arrow.up") {
                Task { await forceRepushOperatorCategories() }
            }
        }
        .disabled(isRunning)
    }

    private var localOperatorCategoriesForSelectedVineyard: [OperatorCategory] {
        guard let vid = migratedStore.selectedVineyardId else { return [] }
        return migratedStore.operatorCategories.filter { $0.vineyardId == vid }
    }

    private func describe(_ status: ManagementSyncStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .syncing: return "syncing"
        case .success: return "success"
        case .failure(let message): return "failure: \(message)"
        }
    }

    private func runOperatorCategorySync() async {
        await perform("Sync Worker Types") {
            await operatorCategorySync.syncForSelectedVineyard()
            return "status=\(describe(operatorCategorySync.syncStatus)); last=\(operatorCategorySync.lastSyncDate?.description ?? "nil"); pendingUpserts=\(operatorCategorySync.pendingUpsertCount); pendingDeletes=\(operatorCategorySync.pendingDeleteCount)"
        }
    }

    private func fetchRemoteOperatorCategories() async {
        await perform("Fetch Remote Worker Types") {
            let remote = try await operatorCategorySync.fetchRemoteForSelectedVineyard()
            let vid = migratedStore.selectedVineyardId?.uuidString ?? "none"
            if remote.isEmpty {
                return "remote=0 rows for vineyard \(vid)"
            }
            var lines: [String] = ["remote=\(remote.count) row(s) for vineyard \(vid)"]
            for r in remote {
                lines.append(" • \(r.name ?? "(no name)") | id=\(r.id.uuidString) | vineyard=\(r.vineyardId.uuidString) | deletedAt=\(r.deletedAt?.description ?? "nil") | cost=\(r.costPerHour ?? 0)")
            }
            return lines.joined(separator: "\n")
        }
    }

    private func forceRepushOperatorCategories() async {
        await perform("Force Re-push Worker Types") {
            let result = await operatorCategorySync.forceRepushLocalForSelectedVineyard()
            return result
        }
    }

    private var outputSection: some View {
        Section("Output Log") {
            if isRunning {
                ProgressView("Running test…")
            }
            ScrollView {
                Text(logText.isEmpty ? "No diagnostic output yet." : logText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(logText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 220)
            Button("Clear Log", role: .destructive) {
                logMessages.removeAll()
            }
        }
    }

    private func signUp() async {
        await perform("Sign Up") {
            let trimmedName = trimmed(name)
            let trimmedEmail = trimmed(email)
            try validateAuthFields(email: trimmedEmail, password: password)
            do {
                let user = try await authRepository.signUpWithEmail(name: trimmedName, email: trimmedEmail, password: password)
                refreshAuthState()
                guard let user else { return "sign-up returned no user; check email confirmation settings" }
                currentUserId = user.id
                currentEmail = user.email
                let hasSession = provider.client.auth.currentSession != nil
                return "\(describe(user)); session=\(hasSession ? "yes" : "no"); if session=no, Supabase still requires email confirmation"
            } catch {
                guard isAlreadyRegisteredError(error) else { throw error }
                appendLog("INFO Sign Up: account already exists; attempting Sign In with the same email/password")
                do {
                    let user = try await authRepository.signInWithEmail(email: trimmedEmail, password: password)
                    refreshAuthState()
                    currentUserId = user.id
                    currentEmail = user.email
                    return "account already existed; signed in instead. \(describe(user))"
                } catch {
                    throw BackendDiagnosticError.alreadyRegisteredSignInFailed(detailedErrorMessage(error))
                }
            }
        }
    }

    private func signIn() async {
        await perform("Sign In") {
            let trimmedEmail = trimmed(email)
            try validateAuthFields(email: trimmedEmail, password: password)
            let user = try await authRepository.signInWithEmail(email: trimmedEmail, password: password)
            clearBackendSessionState()
            refreshAuthState()
            currentUserId = user.id
            currentEmail = user.email
            return describe(user)
        }
    }

    private func signOut() async {
        await perform("Sign Out") {
            try await authRepository.signOut()
            clearBackendSessionState()
            refreshAuthState()
            return "signed out"
        }
    }

    private func restoreSession() async {
        await perform("Restore Session") {
            let user = try await authRepository.restoreSession()
            refreshAuthState()
            guard let user else { return "no saved session" }
            currentUserId = user.id
            currentEmail = user.email
            return describe(user)
        }
    }

    private func sendResetPin() async {
        await perform("Send Reset PIN Email") {
            try await authRepository.sendPasswordReset(email: trimmed(email), redirectTo: nil)
            return "reset email requested for \(trimmed(email)); Supabase reset-password template must show {{ .Token }}"
        }
    }

    private func verifyResetPin() async {
        await perform("Verify Reset PIN") {
            let user = try await authRepository.verifyPasswordResetPin(email: trimmed(email), pin: trimmed(resetPin))
            refreshAuthState()
            currentUserId = user.id
            currentEmail = user.email
            return describe(user)
        }
    }

    private func resetPasswordWithPin() async {
        await perform("Reset Password With PIN") {
            let user = try await authRepository.resetPasswordWithPin(email: trimmed(email), pin: trimmed(resetPin), newPassword: resetNewPassword)
            refreshAuthState()
            currentUserId = user.id
            currentEmail = user.email
            return "password updated for \(user.email)"
        }
    }

    private func getMyProfile() async {
        await perform("Get My Profile") {
            let profile = try await profileRepository.getMyProfile()
            guard let profile else { return "profile not found" }
            return describe(profile)
        }
    }

    private func upsertMyProfile() async {
        await perform("Upsert My Profile") {
            try await profileRepository.upsertMyProfile(fullName: trimmed(name).nilIfEmpty, email: trimmed(email).nilIfEmpty)
            return "profile upserted"
        }
    }

    private func createVineyard() async {
        await perform("Create Vineyard") {
            let vineyard = try await vineyardRepository.createVineyard(name: trimmed(vineyardName), country: trimmed(country).nilIfEmpty)
            currentVineyardId = vineyard.id
            return describe(vineyard)
        }
    }

    private func listMyVineyards() async {
        await perform("List My Vineyards") {
            vineyards = try await vineyardRepository.listMyVineyards()
            currentVineyardId = vineyards.first?.id
            return vineyards.isEmpty ? "no vineyards returned" : vineyards.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
        }
    }

    private func inviteMember() async {
        await perform("Invite Member") {
            let vineyardId = try requireCurrentVineyardId()
            let invitation = try await teamRepository.inviteMember(vineyardId: vineyardId, email: trimmed(invitedEmail), role: selectedRole)
            pendingInvitations.insert(invitation, at: 0)
            return describe(invitation)
        }
    }

    private func listPendingInvitations() async {
        await perform("List Pending Invitations") {
            pendingInvitations = try await teamRepository.listPendingInvitations()
            return pendingInvitations.isEmpty ? "no pending invitations" : pendingInvitations.map { "\($0.email) / \($0.role.rawValue) / \($0.id.uuidString)" }.joined(separator: ", ")
        }
    }

    private func acceptFirstPendingInvitation() async {
        await perform("Accept First Pending Invitation") {
            guard let invitation = pendingInvitations.first else { throw BackendDiagnosticError.missingPendingInvitation }
            try await teamRepository.acceptInvitation(invitationId: invitation.id)
            currentVineyardId = invitation.vineyardId
            pendingInvitations.removeFirst()
            return "accepted invitation \(invitation.id.uuidString); current vineyard=\(invitation.vineyardId.uuidString)"
        }
    }

    private func declineFirstPendingInvitation() async {
        await perform("Decline First Pending Invitation") {
            guard let invitation = pendingInvitations.first else { throw BackendDiagnosticError.missingPendingInvitation }
            try await teamRepository.declineInvitation(invitationId: invitation.id)
            pendingInvitations.removeFirst()
            return "declined invitation \(invitation.id.uuidString)"
        }
    }

    private func listMembersForCurrentVineyard() async {
        await perform("List Members For Current Vineyard") {
            let vineyardId = try requireCurrentVineyardId()
            members = try await teamRepository.listMembers(vineyardId: vineyardId)
            return members.isEmpty ? "no members returned" : members.map { "\($0.displayName ?? "(no name)") / \($0.role.rawValue) / \($0.userId.uuidString)" }.joined(separator: ", ")
        }
    }

    private func checkDisclaimerAcceptance() async {
        await perform("Check Disclaimer Acceptance") {
            let repository = SupabaseDisclaimerRepository(currentVersion: trimmed(disclaimerVersion))
            let accepted = try await repository.hasAcceptedCurrentDisclaimer()
            return "accepted=\(accepted) for version \(trimmed(disclaimerVersion))"
        }
    }

    private func acceptDisclaimer() async {
        await perform("Accept Disclaimer") {
            try await SupabaseDisclaimerRepository(currentVersion: trimmed(disclaimerVersion)).acceptCurrentDisclaimer(version: trimmed(disclaimerVersion), displayName: trimmed(name).nilIfEmpty, email: trimmed(email).nilIfEmpty)
            return "accepted version \(trimmed(disclaimerVersion))"
        }
    }

    private func writeTestAuditEvent() async {
        await perform("Write Test Audit Event") {
            await auditRepository.log(vineyardId: currentVineyardId, action: "backend_diagnostic_test", entityType: "diagnostic", entityId: currentVineyardId, details: "Backend diagnostic audit event from DEBUG screen")
            return "audit event write requested"
        }
    }

    private func perform(_ title: String, operation: () async throws -> String) async {
        guard !isRunning else {
            let message = "SKIPPED \(title): another diagnostic action is running"
            lastStatus = message
            appendLog(message)
            return
        }
        isRunning = true
        currentAction = title
        lastStatus = "Running \(title)…"
        appendLog("START \(title)")
        do {
            let message = try await operation()
            lastStatus = "SUCCESS \(title)"
            appendLog("SUCCESS \(title): \(message)")
        } catch {
            let message = detailedErrorMessage(error)
            lastStatus = "ERROR \(title): \(error.localizedDescription)"
            appendLog("ERROR \(title): \(message)")
        }
        refreshAuthState()
        currentAction = nil
        isRunning = false
    }

    private func refreshAuthState() {
        let user = provider.client.auth.currentUser
        currentUserId = authRepository.currentUserId ?? user?.id
        currentEmail = user?.email
    }

    private func clearBackendSessionState() {
        currentVineyardId = nil
        vineyards.removeAll()
        pendingInvitations.removeAll()
        members.removeAll()
    }

    private func requireCurrentVineyardId() throws -> UUID {
        guard let currentVineyardId else { throw BackendDiagnosticError.missingCurrentVineyard }
        return currentVineyardId
    }

    private func validateAuthFields(email: String, password: String) throws {
        guard !email.isEmpty else { throw BackendDiagnosticError.missingEmail }
        guard !password.isEmpty else { throw BackendDiagnosticError.missingPassword }
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        let localizedDescription = error.localizedDescription
        let reflectedDescription = String(reflecting: error)
        if localizedDescription == reflectedDescription {
            return localizedDescription
        }
        return "\(localizedDescription) — \(reflectedDescription)"
    }

    private func isAlreadyRegisteredError(_ error: Error) -> Bool {
        let message = detailedErrorMessage(error).lowercased()
        return message.contains("user already registered") || message.contains("already registered")
    }

    private func appendLog(_ message: String) {
        let timestamp = Date().formatted(.dateTime.hour().minute().second())
        logMessages.append("[\(timestamp)] \(message)")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func describe(_ user: AppUser) -> String {
        "user id=\(user.id.uuidString), email=\(user.email), displayName=\(user.displayName)"
    }

    private func describe(_ profile: BackendProfile) -> String {
        "profile id=\(profile.id.uuidString), email=\(profile.email), fullName=\(profile.fullName ?? "nil")"
    }

    private func describe(_ vineyard: BackendVineyard) -> String {
        "vineyard id=\(vineyard.id.uuidString), name=\(vineyard.name), country=\(vineyard.country ?? "nil")"
    }

    private func describe(_ invitation: BackendInvitation) -> String {
        "invitation id=\(invitation.id.uuidString), email=\(invitation.email), role=\(invitation.role.rawValue), status=\(invitation.status)"
    }
}

struct BackendDiagnosticHostView: View {
    var body: some View {
        NavigationStack {
            BackendDiagnosticView()
        }
    }
}

nonisolated private enum BackendDiagnosticError: LocalizedError, Sendable {
    case missingCurrentVineyard
    case missingPendingInvitation
    case missingEmail
    case missingPassword
    case alreadyRegisteredSignInFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCurrentVineyard:
            "Create or list a vineyard first so there is a current vineyard ID."
        case .missingPendingInvitation:
            "List pending invitations first, or create an invitation before accepting or declining one."
        case .missingEmail:
            "Enter an email address before running this auth test."
        case .missingPassword:
            "Enter a password before running this auth test."
        case .alreadyRegisteredSignInFailed(let message):
            "This email is already registered, but automatic sign-in failed. Check the password or use the reset PIN flow. Sign-in error: \(message)"
        }
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
#endif

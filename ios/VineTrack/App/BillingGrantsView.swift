import SwiftUI

/// System-admin screen for granting / revoking internal "unlimited licences"
/// access. This is the manual licensing path — no Stripe, Apple, or RevenueCat.
///
/// Backed by `admin_list_manual_unlimited_grants`, `admin_grant_unlimited_access`
/// and `admin_revoke_unlimited_access` (sql/096). All gated by
/// `public.is_system_admin()`.
struct BillingGrantsView: View {
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var grants: [ManualUnlimitedGrant] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var pendingId: UUID?

    @State private var showGrantSheet: Bool = false
    @State private var confirmRevoke: ManualUnlimitedGrant?

    private let repository = SupabaseBillingGrantsRepository()

    private var activeGrants: [ManualUnlimitedGrant] { grants.filter { $0.isActive } }
    private var inactiveGrants: [ManualUnlimitedGrant] { grants.filter { !$0.isActive } }

    var body: some View {
        List {
            if !systemAdmin.isSystemAdmin {
                Section {
                    Label("You are not a system administrator.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                    Button("Retry") { Task { await load() } }
                }
            }

            Section {
                LabeledContent("Active grants") { Text("\(activeGrants.count)") }
                LabeledContent("Total grants") { Text("\(grants.count)") }
            } header: {
                Text("Internal Access")
            } footer: {
                Text("Manually granted unlimited licences for internal accounts and power testers. Not customer billing — no Stripe, Apple, or RevenueCat.")
            }

            if !activeGrants.isEmpty {
                Section("Active") {
                    ForEach(activeGrants) { grant in
                        grantRow(grant)
                    }
                }
            } else if !isLoading {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "infinity.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No active unlimited grants.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }

            if !inactiveGrants.isEmpty {
                Section("Revoked / Expired") {
                    ForEach(inactiveGrants) { grant in
                        grantRow(grant)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Billing Grants")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showGrantSheet = true
                } label: {
                    Label("Grant", systemImage: "plus")
                }
                .disabled(!systemAdmin.isSystemAdmin)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if isLoading && grants.isEmpty {
                ProgressView()
            }
        }
        .sheet(isPresented: $showGrantSheet) {
            GrantUnlimitedSheet { ownerId, scope, vineyardId, reason, expiresAt in
                await grant(ownerId: ownerId, scope: scope, vineyardId: vineyardId, reason: reason, expiresAt: expiresAt)
            }
        }
        .confirmationDialog(
            "Revoke unlimited access?",
            isPresented: Binding(
                get: { confirmRevoke != nil },
                set: { if !$0 { confirmRevoke = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmRevoke
        ) { grant in
            Button("Revoke", role: .destructive) {
                Task { await revoke(grant) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { grant in
            Text("\(grant.ownerDisplay) will lose unlimited access immediately and their licences will be revoked.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func grantRow(_ grant: ManualUnlimitedGrant) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((grant.isActive ? VineyardTheme.leafGreen : Color.gray).opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: grant.isActive ? "infinity" : "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(grant.isActive ? VineyardTheme.leafGreen : Color.gray)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(grant.ownerDisplay)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let email = grant.ownerEmail, !email.isEmpty, email != grant.ownerDisplay {
                    Text(email)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(grant.isActive ? "Unlimited" : (grant.isExpired ? "Expired" : "Revoked"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(grant.isActive ? VineyardTheme.leafGreen : .secondary)
                    if let vy = grant.vineyardName, !vy.isEmpty {
                        Text("• \(vy)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if grant.activeLicences > 0 {
                        Text("• \(grant.activeLicences) licence\(grant.activeLicences == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let reason = grant.manualGrantReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if let expiry = grant.manualGrantExpiresAt {
                    Text("Expires \(expiry.formatted(.dateTime.month().day().year()))")
                        .font(.caption2)
                        .foregroundStyle(grant.isExpired ? Color.orange : Color.secondary)
                }
            }

            Spacer()

            if pendingId == grant.subscriptionId {
                ProgressView()
            } else if grant.isActive {
                Button(role: .destructive) {
                    confirmRevoke = grant
                } label: {
                    Text("Revoke").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!systemAdmin.isSystemAdmin)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        loadError = nil
        actionError = nil
        defer { isLoading = false }
        do {
            grants = try await repository.listGrants()
        } catch {
            loadError = friendlyMessage(from: error)
        }
    }

    private func grant(ownerId: UUID, scope: BillingGrantScope, vineyardId: UUID?, reason: String, expiresAt: Date?) async -> String? {
        actionError = nil
        do {
            _ = try await repository.createUnlimitedGrant(
                ownerUserId: ownerId,
                scope: scope,
                vineyardId: vineyardId,
                reason: reason,
                expiresAt: expiresAt
            )
            await load()
            return nil
        } catch {
            return friendlyMessage(from: error)
        }
    }

    private func revoke(_ grant: ManualUnlimitedGrant) async {
        actionError = nil
        pendingId = grant.subscriptionId
        defer { pendingId = nil }
        do {
            _ = try await repository.revokeUnlimited(subscriptionId: grant.subscriptionId)
            await load()
        } catch {
            actionError = friendlyMessage(from: error)
        }
    }

    private func friendlyMessage(from error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("user_not_found") {
            return "No VineTrack account exists for that user."
        }
        if raw.contains("internal_unlimited_plan_missing") {
            return "The Internal Unlimited plan is missing. Apply migration sql/096 first."
        }
        if raw.contains("owner_required") {
            return "Please select an owner."
        }
        if raw.contains("subscription_not_found") {
            return "That grant no longer exists. Refresh and try again."
        }
        if raw.contains("system admin required") || raw.contains("42501") {
            return "System admin required. Sign in as a system admin to continue."
        }
        if raw.contains("could not find the function") || raw.contains("pgrst202") {
            return "Backend RPCs not found. Apply migrations sql/141 and sql/155 to Supabase."
        }
        if raw.contains("reason_required") {
            return "A reason is required for every grant."
        }
        if raw.contains("vineyard_required_for_vineyard_scope") {
            return "Select the vineyard this grant should cover."
        }
        if raw.contains("grant_scope_not_allowed_for_type") {
            return "That grant type does not support the selected scope."
        }
        if raw.contains("vineyard_not_found") {
            return "That vineyard no longer exists."
        }
        return error.localizedDescription
    }
}

// MARK: - Grant Sheet

private struct GrantUnlimitedSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// (ownerId, scope, vineyardId?, reason, expiresAt?) -> error string or nil
    let onSubmit: (UUID, BillingGrantScope, UUID?, String, Date?) async -> String?

    @State private var users: [AdminUserRow] = []
    @State private var userVineyards: [AdminUserVineyardRow] = []
    @State private var isLoadingLists: Bool = false
    @State private var isLoadingVineyards: Bool = false
    @State private var listError: String?
    @State private var vineyardError: String?

    @State private var selectedUserId: UUID?
    @State private var selectedVineyardId: UUID?
    @State private var grantScope: BillingGrantScope = .user
    @State private var reason: String = ""
    @State private var setExpiry: Bool = false
    @State private var expiresAt: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()

    @State private var userQuery: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    private let adminRepository = SupabaseAdminRepository()

    private var filteredUsers: [AdminUserRow] {
        let q = userQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter {
            $0.email.lowercased().contains(q) ||
            ($0.fullName?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedUser: AdminUserRow? {
        users.first { $0.id == selectedUserId }
    }

    /// Active vineyards the selected owner belongs to (any role).
    private var ownerVineyards: [AdminUserVineyardRow] {
        userVineyards
            .filter { $0.deletedAt == nil }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// User-scoped grants need a user + reason; vineyard-scoped grants also
    /// require the vineyard every member will inherit access from.
    private var canSubmit: Bool {
        guard selectedUserId != nil, !isSubmitting else { return false }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if grantScope == .vineyard {
            return selectedVineyardId != nil
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let user = selectedUser {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.subheadline.weight(.medium))
                                if !user.email.isEmpty {
                                    Text(user.email).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Change") { selectedUserId = nil }
                                .font(.caption.weight(.semibold))
                        }
                    } else {
                        TextField("Search users by name or email", text: $userQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        if isLoadingLists && users.isEmpty {
                            HStack { ProgressView(); Text("Loading users…").foregroundStyle(.secondary) }
                        }
                        ForEach(filteredUsers.prefix(25)) { user in
                            Button {
                                selectedUserId = user.id
                                userQuery = ""
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if !user.email.isEmpty {
                                        Text(user.email)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Owner")
                } footer: {
                    Text("The account that receives unlimited access. They must already have a VineTrack account.")
                }

                if selectedUser != nil {
                    Section {
                        Picker("Grant applies to", selection: $grantScope) {
                            Text("This user only").tag(BillingGrantScope.user)
                            Text("An entire vineyard").tag(BillingGrantScope.vineyard)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Grant applies to")
                    } footer: {
                        Text(grantScope == .vineyard
                             ? "Every active member of the selected vineyard inherits access while the grant is valid. New members inherit it automatically."
                             : "Only this account receives access. Other members of their vineyards are unaffected.")
                    }
                }

                if selectedUser != nil && grantScope == .vineyard {
                    Section {
                        if isLoadingVineyards {
                            HStack { ProgressView(); Text("Loading vineyards…").foregroundStyle(.secondary) }
                        } else if let vineyardError {
                            Label(vineyardError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.footnote)
                            Button {
                                guard let id = selectedUserId else { return }
                                Task { await loadVineyards(for: id) }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        } else if ownerVineyards.isEmpty {
                            Label("No eligible vineyards — this user is not linked to any vineyard yet.", systemImage: "leaf.circle")
                                .foregroundStyle(.secondary).font(.footnote)
                        } else {
                            Picker("Vineyard", selection: $selectedVineyardId) {
                                Text("Select a vineyard").tag(UUID?.none)
                                ForEach(ownerVineyards) { v in
                                    Text(v.isOwner ? "\(v.name) (owner)" : v.name)
                                        .tag(UUID?.some(v.id))
                                }
                            }
                        }
                    } header: {
                        Text("Vineyard")
                    } footer: {
                        Text("Only vineyards this user belongs to are shown. All active members of the chosen vineyard inherit access.")
                    }
                }

                Section {
                    TextField("Reason / note", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Reason (required)")
                } footer: {
                    Text("Required internal note, e.g. \"Stockman Admin\" or \"Power tester\".")
                }

                Section {
                    Toggle("Set expiry date", isOn: $setExpiry)
                    if setExpiry {
                        DatePicker("Expires", selection: $expiresAt, in: Date()..., displayedComponents: .date)
                    }
                } footer: {
                    Text(setExpiry ? "Access ends automatically on this date." : "No expiry — access stays until manually revoked.")
                }

                if let listError {
                    Section {
                        Label(listError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.footnote)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.footnote)
                    }
                }
            }
            .navigationTitle("Grant Unlimited")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("Grant").fontWeight(.semibold) }
                    }
                    .disabled(!canSubmit)
                }
            }
            .task { await loadUsers() }
            .onChange(of: selectedUserId) { _, newValue in
                selectedVineyardId = nil
                userVineyards = []
                vineyardError = nil
                guard let newValue else { return }
                Task { await loadVineyards(for: newValue) }
            }
        }
    }

    private func loadUsers() async {
        isLoadingLists = true
        listError = nil
        defer { isLoadingLists = false }
        do {
            users = try await adminRepository.fetchAllUsers()
        } catch {
            listError = error.localizedDescription
        }
    }

    /// Loads only the vineyards the selected owner belongs to, then
    /// auto-selects when there is exactly one. A valid EMPTY result shows
    /// "No eligible vineyards"; a transport/decoding failure shows the error
    /// with a Retry option (the underlying error is kept for diagnostics).
    private func loadVineyards(for userId: UUID) async {
        isLoadingVineyards = true
        vineyardError = nil
        defer { isLoadingVineyards = false }
        do {
            let rows = try await adminRepository.fetchUserVineyards(userId: userId)
            // Ignore a stale response if the owner selection changed mid-flight.
            guard selectedUserId == userId else { return }
            userVineyards = rows
            let active = rows.filter { $0.deletedAt == nil }
            if active.count == 1 {
                selectedVineyardId = active.first?.id
            }
        } catch {
            guard selectedUserId == userId else { return }
            print("[BillingGrants] fetchUserVineyards failed: \(error)")
            vineyardError = "Couldn't load this user's vineyards. \(error.localizedDescription)"
        }
    }

    private func submit() async {
        guard let ownerId = selectedUserId else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let result = await onSubmit(
            ownerId,
            grantScope,
            grantScope == .vineyard ? selectedVineyardId : nil,
            reason.trimmingCharacters(in: .whitespacesAndNewlines),
            setExpiry ? expiresAt : nil
        )
        if let result {
            errorMessage = result
        } else {
            dismiss()
        }
    }
}

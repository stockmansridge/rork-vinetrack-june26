import SwiftUI

/// Platform-admin management screen for adding / activating / deactivating
/// VineTrack system administrators.
///
/// Backed by the `list_system_admins`, `add_system_admin`, and
/// `set_system_admin_active` RPCs in `sql/063_system_admin_management_rpcs.sql`.
/// All access is gated by `SystemAdminService.isSystemAdmin`; no hardcoded
/// email checks are used.
struct SystemAdminUsersView: View {
    @Environment(SystemAdminService.self) private var systemAdmin
    @Environment(NewBackendAuthService.self) private var auth

    @State private var admins: [SystemAdminUser] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var pendingUserId: UUID?

    @State private var showAddSheet: Bool = false
    @State private var confirmDeactivate: SystemAdminUser?

    private var activeCount: Int { admins.filter { $0.isActive }.count }

    var body: some View {
        Form {
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

            if !admins.isEmpty {
                Section {
                    ForEach(admins) { admin in
                        adminRow(admin)
                    }
                } header: {
                    Text("System Admins")
                } footer: {
                    Text("Active admins can manage platform-wide diagnostics, notices, feature flags and other system admins. Soft-deactivate keeps history; the last active admin cannot be deactivated.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !isLoading {
                Section {
                    Text("No system admins found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Active") { Text("\(activeCount)") }
                LabeledContent("Total") { Text("\(admins.count)") }
            } header: {
                Text("Status")
            }
        }
        .navigationTitle("System Admin Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(!systemAdmin.isSystemAdmin)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if isLoading && admins.isEmpty {
                ProgressView()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSystemAdminSheet { email in
                await add(email: email)
            }
        }
        .confirmationDialog(
            "Deactivate this system admin?",
            isPresented: Binding(
                get: { confirmDeactivate != nil },
                set: { if !$0 { confirmDeactivate = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmDeactivate
        ) { admin in
            Button("Deactivate", role: .destructive) {
                Task { await setActive(admin: admin, isActive: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { admin in
            Text("\(admin.email.isEmpty ? "This user" : admin.email) will lose access to platform admin tools. They can be reactivated later.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func adminRow(_ admin: SystemAdminUser) -> some View {
        let isSelf = admin.userId == auth.userId
        let isOnlyActive = admin.isActive && activeCount <= 1
        let canToggle = systemAdmin.isSystemAdmin && !isOnlyActive

        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((admin.isActive ? Color.green : Color.gray).opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: admin.isActive ? "person.fill.checkmark" : "person.fill.xmark")
                    .foregroundStyle(admin.isActive ? Color.green : Color.gray)
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(admin.email.isEmpty ? "—" : admin.email)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isSelf {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue, in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(admin.isActive ? "Active" : "Inactive")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(admin.isActive ? .green : .secondary)
                    if let created = admin.createdAt {
                        Text("• added \(created.formatted(.dateTime.month().day().year()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if pendingUserId == admin.userId {
                ProgressView()
            } else if admin.isActive {
                Button(role: .destructive) {
                    if isOnlyActive {
                        actionError = "Cannot deactivate the last active system admin."
                    } else {
                        confirmDeactivate = admin
                    }
                } label: {
                    Text("Deactivate")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canToggle)
            } else {
                Button {
                    Task { await setActive(admin: admin, isActive: true) }
                } label: {
                    Text("Reactivate")
                        .font(.caption.weight(.semibold))
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
            let repo = SupabaseSystemAdminRepository()
            admins = try await repo.listSystemAdmins()
        } catch {
            loadError = friendlyMessage(from: error)
        }
    }

    private func add(email: String) async -> String? {
        actionError = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Please enter an email." }
        do {
            let repo = SupabaseSystemAdminRepository()
            _ = try await repo.addSystemAdmin(email: trimmed)
            await load()
            return nil
        } catch {
            return friendlyMessage(from: error)
        }
    }

    private func setActive(admin: SystemAdminUser, isActive: Bool) async {
        actionError = nil
        pendingUserId = admin.userId
        defer { pendingUserId = nil }
        do {
            let repo = SupabaseSystemAdminRepository()
            _ = try await repo.setSystemAdminActive(userId: admin.userId, isActive: isActive)
            await load()
        } catch {
            actionError = friendlyMessage(from: error)
        }
    }

    private func friendlyMessage(from error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("user_not_found") {
            return "No VineTrack account exists for that email. Ask them to sign in once before promoting them."
        }
        if raw.contains("email_required") {
            return "Please enter an email."
        }
        if raw.contains("admin_not_found") {
            return "That admin record no longer exists. Refresh and try again."
        }
        if raw.contains("cannot_deactivate_last_admin") {
            return "Cannot deactivate the last active system admin. Add another admin first."
        }
        if raw.contains("system admin required") || raw.contains("42501") {
            return "System admin required. Sign in as a system admin to continue."
        }
        return error.localizedDescription
    }
}

// MARK: - Add Sheet

private struct AddSystemAdminSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSubmit: (String) async -> String?

    @State private var email: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("name@example.com", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Email")
                } footer: {
                    Text("The user must already have a VineTrack account. They will gain platform-admin access immediately.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Add System Admin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Add").fontWeight(.semibold)
                        }
                    }
                    .disabled(isSubmitting || email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let result = await onSubmit(email)
        if let result {
            errorMessage = result
        } else {
            dismiss()
        }
    }
}

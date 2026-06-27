import SwiftUI

struct BackendInviteMemberSheet: View {
    let vineyardId: UUID
    let vineyardName: String
    var onSent: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @State private var email: String = ""
    @State private var role: BackendRole = .operator
    @State private var operatorCategoryId: UUID?
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @State private var showSuccess: Bool = false

    private let teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()

    private var availableRoles: [BackendRole] {
        BackendRole.allCases.filter { $0 != .owner }
    }

    private var vineyardOperatorCategories: [OperatorCategory] {
        store.operatorCategories
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite Details") {
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Role", selection: $role) {
                        ForEach(availableRoles, id: \.self) { role in
                            Text(role.rawValue.capitalized).tag(role)
                        }
                    }

                    NavigationLink {
                        RolesPermissionsInfoView()
                    } label: {
                        Label("Learn more about roles", systemImage: "info.circle")
                            .font(.footnote)
                    }
                } header: {
                    Text("Role")
                } footer: {
                    Text("Some features and values are hidden based on the assigned role.")
                }

                Section {
                    Picker("Operator Category", selection: $operatorCategoryId) {
                        Text("None").tag(UUID?.none)
                        ForEach(vineyardOperatorCategories) { cat in
                            Text(cat.name).tag(UUID?.some(cat.id))
                        }
                    }
                } header: {
                    Text("Default Operator Category")
                } footer: {
                    if vineyardOperatorCategories.isEmpty {
                        Text("Create operator categories in Spray Management → Operator Categories to assign a default hourly rate at invite time.")
                    } else {
                        Text("Optional. Applied to the new member's profile on accept and used as a fallback for trip cost calculations.")
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(VineyardTheme.info)
                        Text("No email is sent yet. The invited person will see the invite for \(vineyardName) when they sign in with this email address.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showSuccess {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(VineyardTheme.leafGreen)
                            Text("Invitation sent successfully!")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("Error")
                    }
                }
            }
            .navigationTitle("Invite Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await send() }
                    }
                    .disabled(email.isEmpty || isSending)
                }
            }
        }
    }

    private func send() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("@") else {
            errorMessage = "Please enter a valid email"
            return
        }
        errorMessage = nil
        showSuccess = false
        isSending = true
        defer { isSending = false }
        do {
            _ = try await teamRepository.inviteMember(
                vineyardId: vineyardId,
                email: trimmed,
                role: role,
                operatorCategoryId: operatorCategoryId,
                expiresAt: nil
            )
            showSuccess = true
            email = ""
            operatorCategoryId = nil
            onSent?()
            // First-invite milestone: surface the web portal prompt for
            // managers so they discover desktop team management.
            PortalPromptTracker.requestIfUnseen(.firstInvite)
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

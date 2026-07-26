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
    @State private var successMessage: String = ""

    private let teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()
    private let invitationEmailService = InvitationEmailService()

    private var availableRoles: [BackendRole] {
        BackendRole.allCases.filter { $0 != .owner }
    }

    private var vineyardOperatorCategories: [OperatorCategory] {
        store.operatorCategories
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var requiresWorkerType: Bool { role == .operator }

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

                if requiresWorkerType {
                    Section {
                        if vineyardOperatorCategories.isEmpty {
                            Text("No worker types are configured for this vineyard. Add one in Vineyard Settings before inviting an operator.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Worker Type", selection: $operatorCategoryId) {
                                Text("Select worker type").tag(UUID?.none)
                                ForEach(vineyardOperatorCategories) { cat in
                                    Text(cat.name).tag(UUID?.some(cat.id))
                                }
                            }
                        }
                    } header: {
                        Text("Worker Type")
                    } footer: {
                        Text("A worker type is required for operator invitations and must belong to this vineyard.")
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(VineyardTheme.info)
                        Text("An email invitation will be sent to this address. They can also see the invite for \(vineyardName) when they sign in with this email address.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showSuccess {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(VineyardTheme.leafGreen)
                            Text(successMessage)
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
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
        .onChange(of: role) { _, newRole in
            if newRole != .operator {
                operatorCategoryId = nil
            }
        }
        .onChange(of: vineyardOperatorCategories.map(\.id)) { _, categoryIDs in
            if let selected = operatorCategoryId, !categoryIDs.contains(selected) {
                operatorCategoryId = nil
            }
        }
        .onDisappear {
            operatorCategoryId = nil
        }
    }

    private func send() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("@") else {
            errorMessage = "Please enter a valid email"
            return
        }
        if requiresWorkerType && vineyardOperatorCategories.isEmpty {
            errorMessage = "No worker types are configured for this vineyard. Add one in Vineyard Settings before inviting an operator."
            return
        }
        if requiresWorkerType && operatorCategoryId == nil {
            errorMessage = "Select a worker type before inviting an operator."
            return
        }
        if let selected = operatorCategoryId, !vineyardOperatorCategories.contains(where: { $0.id == selected }) {
            operatorCategoryId = nil
            errorMessage = "This worker type is no longer available for this vineyard. Select another worker type and try again."
            return
        }
        errorMessage = nil
        showSuccess = false
        isSending = true
        defer { isSending = false }
        do {
            let invitation = try await teamRepository.inviteMember(
                vineyardId: vineyardId,
                email: trimmed,
                role: role,
                operatorCategoryId: requiresWorkerType ? operatorCategoryId : nil,
                expiresAt: nil
            )
            // Best-effort email notification — never fatal. The invite is
            // already stored, so the invitee can always accept in-app.
            let emailStatus = await invitationEmailService.send(
                invitationId: invitation.id,
                sourcePlatform: "ios",
                context: "new"
            )
            successMessage = emailStatus == "sent"
                ? "Invitation email sent to \(trimmed)."
                : "The invitation was created, but the email could not be sent. They can still accept it after signing in with the invited email address."
            showSuccess = true
            email = ""
            operatorCategoryId = nil
            onSent?()
            // First-invite milestone: surface the web portal prompt for
            // managers so they discover desktop team management.
            PortalPromptTracker.requestIfUnseen(.firstInvite)
            try? await Task.sleep(for: .seconds(2.0))
            dismiss()
        } catch {
            let message = error.localizedDescription
            errorMessage = message.localizedCaseInsensitiveContains("worker type not found")
                ? "This worker type is no longer available for this vineyard. Select another worker type and try again."
                : message
        }
    }
}

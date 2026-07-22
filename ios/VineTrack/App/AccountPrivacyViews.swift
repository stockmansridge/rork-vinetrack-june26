import SwiftUI

struct DisclaimerInfoView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @State private var acceptedRemotely: Bool?
    @State private var isChecking: Bool = false
    @State private var checkError: String?

    private let repository: any DisclaimerRepositoryProtocol = SupabaseDisclaimerRepository(currentVersion: DisclaimerInfo.version)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VineyardCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                            Text(DisclaimerInfo.title)
                                .font(.headline)
                        }
                        Text("Version \(DisclaimerInfo.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VineyardCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Acceptance status")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if isChecking {
                                ProgressView().controlSize(.mini)
                            } else if let acceptedRemotely {
                                VineyardStatusBadge(
                                    text: acceptedRemotely ? "Accepted" : "Not accepted",
                                    icon: acceptedRemotely ? "checkmark.circle.fill" : "xmark.circle.fill",
                                    kind: acceptedRemotely ? .success : .warning
                                )
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        if let checkError {
                            Text(checkError)
                                .font(.caption)
                                .foregroundStyle(VineyardTheme.destructive)
                        }
                    }
                }

                VineyardCard {
                    Text(DisclaimerInfo.bodyText)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Disclaimer")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private func refresh() async {
        isChecking = true
        checkError = nil
        defer { isChecking = false }
        do {
            acceptedRemotely = try await repository.hasAcceptedCurrentDisclaimer()
        } catch {
            checkError = error.localizedDescription
        }
    }
}

struct AccountDeletionRequestView: View {
    @Environment(NewBackendAuthService.self) private var auth

    private let supportEmail: String = "jonathan@stockmansridge.com.au"
    private let vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository()

    @State private var preflight: AccountDeletionPreflight?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var isSubmitting: Bool = false
    @State private var submissionMessage: String?
    @State private var showFinalConfirm: Bool = false

    private var blockingVineyards: [AccountDeletionPreflight.OwnedVineyard] {
        preflight?.ownedVineyards.filter { $0.transferRequired } ?? []
    }

    private var soloOwnedVineyards: [AccountDeletionPreflight.OwnedVineyard] {
        preflight?.ownedVineyards.filter { !$0.transferRequired } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                if isLoading {
                    VineyardCard {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Checking shared vineyards…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    VineyardCard {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(VineyardTheme.destructive)
                    }
                }

                if !blockingVineyards.isEmpty {
                    blockerCard
                }

                if !soloOwnedVineyards.isEmpty {
                    soloOwnedCard
                }

                accountInfoCard

                if let submissionMessage {
                    VineyardCard {
                        Label(submissionMessage, systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(VineyardTheme.leafGreen)
                    }
                }

                actionButton

                Text("Support: \(supportEmail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(16)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runPreflight() }
        .refreshable { await runPreflight() }
        .alert("Delete account?", isPresented: $showFinalConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Submit Request", role: .destructive) {
                Task { await submitDeletionRequest() }
            }
        } message: {
            Text("This submits a deletion request to support. Your account will be removed after manual review. This cannot be undone.")
        }
    }

    private var headerCard: some View {
        VineyardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .foregroundStyle(.red)
                    Text("Delete Account")
                        .font(.headline)
                }
                Text("Account deletion is irreversible. Before deleting, transfer ownership of any shared vineyards so other members keep their access.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var blockerCard: some View {
        VineyardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Transfer Ownership Required")
                        .font(.subheadline.weight(.semibold))
                }
                Text("You own vineyards that other people use. Transfer ownership before deleting your account.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    ForEach(blockingVineyards) { vineyard in
                        HStack {
                            Image(systemName: "leaf.fill")
                                .foregroundStyle(VineyardTheme.leafGreen)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vineyard.vineyardName)
                                    .font(.subheadline.weight(.medium))
                                Text("\(vineyard.otherActiveMembers) other member\(vineyard.otherActiveMembers == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(10)
                        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                    }
                }
                Text("Open Settings → Vineyard → Team & Access on each vineyard to transfer ownership.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var soloOwnedCard: some View {
        VineyardCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Solo Vineyards")
                        .font(.subheadline.weight(.semibold))
                }
                Text("These vineyards have no other members. They will be archived along with your account:")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(soloOwnedVineyards) { vineyard in
                    HStack {
                        Image(systemName: "leaf")
                            .foregroundStyle(VineyardTheme.leafGreen)
                        Text(vineyard.vineyardName)
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
        }
    }

    private var accountInfoCard: some View {
        VineyardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your account")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                VineyardInfoRow(label: "Name", value: auth.userName ?? "—", icon: "person.fill", iconColor: .gray)
                VineyardInfoRow(label: "Email", value: auth.userEmail ?? "—", icon: "envelope.fill", iconColor: .blue)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if !blockingVineyards.isEmpty {
            Button {
                openMail()
            } label: {
                Label("Email Support", systemImage: "envelope.fill")
            }
            .buttonStyle(.vineyardPrimary(tint: .blue))
            .disabled(isSubmitting)
        } else if preflight?.safeToDelete == true {
            Button {
                showFinalConfirm = true
            } label: {
                if isSubmitting {
                    ProgressView()
                } else {
                    Label("Request Account Deletion", systemImage: "trash.fill")
                }
            }
            .buttonStyle(.vineyardPrimary(tint: VineyardTheme.destructive))
            .disabled(isSubmitting)
        }
    }

    private func runPreflight() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            preflight = try await vineyardRepository.accountDeletionPreflight()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submitDeletionRequest() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await vineyardRepository.submitAccountDeletionRequest(reason: nil)
            if result.submitted {
                submissionMessage = "Deletion request submitted. Support will follow up via email."
            } else {
                errorMessage = result.message ?? "Could not submit request."
                await runPreflight()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openMail() {
        let subject = "VineTrack account deletion request"
        let body = """
Please delete my VineTrack account.

Name: \(auth.userName ?? "—")
Email: \(auth.userEmail ?? "—")
"""
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

import SwiftUI

/// Onboarding screen presented when an authenticated user has no accessible
/// vineyards yet and chooses "I'm waiting for an invite" instead of creating
/// one. Lets them poll for invites, fall back to creating a vineyard, or sign
/// out if they logged into the wrong account.
struct WaitingForInviteView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Triggered by the "Check for Invites" button. Should run the same sync /
    /// vineyard-refresh logic used elsewhere — typically the host view's
    /// `refresh()`. If vineyards become available after the sync the view pops
    /// automatically so the normal vineyard-selection flow can take over.
    let onCheckForInvites: () async -> Void
    /// Triggered by the secondary "Create a Vineyard" button on this screen.
    let onCreateVineyard: () -> Void

    @State private var isChecking: Bool = false
    @State private var lastCheckedAt: Date?
    @State private var statusMessage: String?
    @State private var showSignOutConfirm: Bool = false

    var body: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    actions
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(VineyardTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    Spacer(minLength: 16)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Waiting for Invite")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.vineyards.count) { _, newCount in
            // If a sync surfaced vineyards, pop back so the normal selection /
            // home flow can take over.
            if newCount > 0 {
                dismiss()
            }
        }
        .confirmationDialog(
            "Sign out of VineTrack?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await auth.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign back in any time with the correct account.")
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(VineyardTheme.primaryAccent.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "envelope.badge")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(VineyardTheme.primaryAccent)
            }
            brandedText("Waiting for Vineyard Invite")
                .font(.title2.weight(.semibold))
                .foregroundStyle(VineyardTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("You don\u{2019}t currently have access to any vineyards. If your manager has invited you, your vineyard will appear here after the invite is accepted and the app syncs.")
                .font(.subheadline)
                .foregroundStyle(VineyardTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await runCheck() }
            } label: {
                HStack(spacing: 8) {
                    if isChecking {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isChecking ? "Checking\u{2026}" : "Check for Invites")
                }
            }
            .buttonStyle(.vineyardPrimary)
            .disabled(isChecking)

            Button {
                onCreateVineyard()
            } label: {
                Label("Create a Vineyard", systemImage: "plus")
            }
            .buttonStyle(.vineyardSecondary)

            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.vineyardSecondary(tint: VineyardTheme.destructive))
        }
        .padding(.horizontal, 32)
    }

    private func runCheck() async {
        isChecking = true
        statusMessage = nil
        await onCheckForInvites()
        // Reload pending invitations explicitly in case the host's refresh
        // didn't surface any (e.g. an alias-email invite). This mirrors the
        // sync logic used on the vineyard list screen.
        await auth.loadPendingInvitations()
        isChecking = false
        lastCheckedAt = Date()

        if !store.vineyards.isEmpty {
            // The `onChange(of:)` above will dismiss; no extra message needed.
            return
        }
        let pendingCount = auth.pendingInvitations.filter { $0.status.lowercased() == "pending" }.count
        if pendingCount > 0 {
            statusMessage = "\(pendingCount) pending invitation\(pendingCount == 1 ? "" : "s") found. Accept on the previous screen to join."
        } else {
            statusMessage = "No vineyard access found yet. Ask your manager to send or confirm your invite."
        }
    }
}

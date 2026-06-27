import SwiftUI

struct AccountSettingsView: View {
    @Environment(AuthService.self) private var authService
    @Environment(DataStore.self) private var store
    @State private var showDeleteAccountAlert: Bool = false

    var body: some View {
        Form {
            Section {
                if !authService.userName.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "person.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(authService.userName)
                                .font(.subheadline.weight(.medium))
                            Text(authService.userEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button(role: .destructive) {
                    authService.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } header: {
                Text("Account")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteAccountAlert = true
                } label: {
                    HStack {
                        Label("Delete Account", systemImage: "person.crop.circle.badge.minus")
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete Everything", role: .destructive) {
                        Task {
                            await authService.deleteAccount(dataStore: store)
                        }
                    }
                } message: {
                    Text("This will permanently delete your account, all vineyards, blocks, pins, trips, and settings. This action cannot be undone.")
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Danger Zone")
                }
            } footer: {
                Text("Permanently delete your account and all associated data.")
            }
        }
        .navigationTitle("Account")
        .overlay {
            if authService.isDeletingAccount {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Deleting account...")
                            .font(.headline)
                        Text("Removing all your data from our servers")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .background(.ultraThickMaterial)
                    .clipShape(.rect(cornerRadius: 16))
                }
            }
        }
        .allowsHitTesting(!authService.isDeletingAccount)
    }
}

import SwiftUI

/// Phase 2F restricted-vineyard experience.
///
/// Shown when the ACCOUNT still has usable access but the server matrix
/// confirms the previously selected vineyard has lost its entitlement.
/// This is deliberately NOT the paywall: the user can switch to another
/// accessible vineyard, restore purchases, or (owners only) review billing —
/// pending invitations keep surfacing through the existing sheet.
struct RestrictedVineyardView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(EntitlementGate.self) private var entitlementGate
    @Environment(SubscriptionService.self) private var subscription

    @State private var isRestoring: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var showBillingSheet: Bool = false
    @State private var restoreMessage: String?

    private var selectedEntry: VineyardAccessEntry? {
        guard let vid = store.selectedVineyardId else { return nil }
        return entitlementGate.accessMatrix?.entry(for: vid)
    }

    private var selectedName: String {
        selectedEntry?.vineyardName
            ?? store.selectedVineyard?.name
            ?? "this vineyard"
    }

    /// The signed-in user owns the restricted vineyard (billing is theirs to fix).
    private var isOwnerOfRestricted: Bool {
        (selectedEntry?.membershipRole ?? "").lowercased() == "owner"
    }

    /// Accessible vineyards from the live matrix, joined to locally cached
    /// vineyards so switching uses the existing selection flow.
    private var accessibleVineyards: [Vineyard] {
        guard let matrix = entitlementGate.accessMatrix else { return [] }
        let accessibleIds = Set(matrix.accessibleVineyardIds)
        return store.vineyards.filter { accessibleIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text("Access to \(selectedName) has expired")
                                .font(.headline)
                        } icon: {
                            Image(systemName: "lock.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(explanationText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if !accessibleVineyards.isEmpty {
                    Section {
                        ForEach(accessibleVineyards, id: \.id) { vineyard in
                            Button {
                                store.selectVineyard(vineyard)
                            } label: {
                                HStack {
                                    Image(systemName: "leaf.circle.fill")
                                        .foregroundStyle(VineyardTheme.leafGreen)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(vineyard.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if let entry = entitlementGate.accessMatrix?.entry(for: vineyard.id),
                                           let role = entry.membershipRole {
                                            Text(role.capitalized)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        Text("Choose another vineyard")
                    } footer: {
                        Text("You still have access to these vineyards.")
                    }
                }

                Section {
                    if isOwnerOfRestricted {
                        Button {
                            showBillingSheet = true
                        } label: {
                            Label("Review billing", systemImage: "creditcard")
                        }
                    }
                    Button {
                        Task { await restorePurchases() }
                    } label: {
                        if isRestoring {
                            HStack { ProgressView(); Text("Restoring…") }
                        } else {
                            Label("Restore Purchases", systemImage: "arrow.clockwise.circle")
                        }
                    }
                    .disabled(isRestoring)
                    Button {
                        Task { await refreshAccess() }
                    } label: {
                        if isRefreshing {
                            HStack { ProgressView(); Text("Checking access…") }
                        } else {
                            Label("Check access again", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isRefreshing)
                } footer: {
                    if let restoreMessage {
                        Text(restoreMessage)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Vineyard Access")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showBillingSheet) {
                NavigationStack {
                    SubscriptionPaywallView(allowDismiss: true)
                }
            }
        }
    }

    private var explanationText: String {
        if isOwnerOfRestricted {
            return "This vineyard no longer has an active subscription, trial, or grant. Review billing to restore access for you and your team. Your other vineyards are unaffected."
        }
        return "Access for this vineyard is managed by its Vineyard Owner. You can keep working in your other vineyards, and any pending invitations remain available."
    }

    private func restorePurchases() async {
        isRestoring = true
        restoreMessage = nil
        defer { isRestoring = false }
        let restored = await subscription.restorePurchases()
        await entitlementGate.syncAfterStorePurchase()
        restoreMessage = restored
            ? "Purchases restored — access has been re-checked."
            : "No purchases to restore on this Apple ID."
    }

    private func refreshAccess() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await entitlementGate.refresh(force: true)
    }
}

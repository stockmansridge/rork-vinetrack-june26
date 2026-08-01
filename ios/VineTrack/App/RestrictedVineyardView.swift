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

    /// Role-aware copy + allowed actions (Phase 2F.2). The upgrade / billing
    /// state only appears once the server matrix has loaded AND confirmed the
    /// denial — `message.audience == .unresolved` covers every other case.
    private var message: RestrictedVineyardMessage {
        RestrictedVineyardMessage.make(
            vineyardName: selectedName,
            entry: selectedEntry,
            isMatrixResolved: entitlementGate.accessMatrix != nil
        )
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
                            Text(message.title)
                                .font(.headline)
                        } icon: {
                            Image(systemName: message.audience == .unresolved
                                  ? "clock.arrow.circlepath"
                                  : "lock.circle.fill")
                                .foregroundStyle(message.audience == .unresolved
                                                 ? Color.secondary
                                                 : Color.orange)
                        }
                        Text(message.body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let footnote = message.footnote {
                            Text(footnote)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
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
                    // Owners with billing authority only: Managers, Supervisors,
                    // Operators and co-Owners are never offered a purchase.
                    if message.showsUpgradeToTeam {
                        Button {
                            showBillingSheet = true
                        } label: {
                            Label(RestrictedVineyardMessage.upgradeActionTitle,
                                  systemImage: "person.3.sequence.fill")
                        }
                    } else if message.showsReviewBilling {
                        Button {
                            showBillingSheet = true
                        } label: {
                            Label(RestrictedVineyardMessage.reviewBillingActionTitle,
                                  systemImage: "creditcard")
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

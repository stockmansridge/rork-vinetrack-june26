import SwiftUI
import CoreLocation

/// Read-only field-readiness screen. Surfaces whether the device has
/// everything cached locally to keep working in a vineyard with no mobile
/// network: signed-in session, the selected vineyard, its paddocks/rows,
/// the saved chemicals/equipment catalogues, GPS permission, and the
/// current sync backlog. Purely diagnostic — it never changes access or
/// sync behaviour.
struct OfflineReadinessView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(SubscriptionService.self) private var subscription
    // Single source of truth for the aggregated sync backlog and timings,
    // kept current by the main shell's full sweep across every service.
    @Environment(SyncStatusCenter.self) private var syncCenter
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        Form {
            overallSection
            essentialsSection
            accessSection
            dataSection
            gpsSection
            syncSection
            refreshSection
            footerSection
        }
        .navigationTitle("Offline Readiness")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Overall banner

    private var overallSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: isFieldReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(isFieldReady ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isFieldReady ? "Ready for the field" : "Not fully ready")
                        .font(.headline)
                    Text(isFieldReady
                         ? "This device has everything cached to keep working without mobile network."
                         : "Some items below need attention while you still have signal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Essentials

    private var essentialsSection: some View {
        Section {
            ReadinessRow(
                title: "Signed in",
                detail: auth.userEmail ?? (auth.isSignedIn ? "Active session" : "Not signed in"),
                state: auth.isSignedIn ? .good : .bad
            )
            ReadinessRow(
                title: "Vineyard downloaded",
                detail: store.selectedVineyard?.name ?? "None selected",
                state: store.selectedVineyard != nil ? .good : .bad
            )
        } header: {
            Text("Essentials")
        } footer: {
            Text("Your session and the selected vineyard are stored on this device, so the app opens and runs even when Supabase is unreachable.")
        }
    }

    // MARK: - Subscription access

    private var accessSection: some View {
        Section {
            ReadinessRow(
                title: "Access verified",
                detail: accessVerifiedDetail,
                state: accessVerifiedState
            )
            LabeledContent("Last verified", value: lastVerifiedText)
                .font(.footnote)
            LabeledContent("Offline grace remaining", value: graceRemainingText)
                .font(.footnote)
        } header: {
            Text("Subscription access")
        } footer: {
            Text("Your last successful subscription check is stored on this device. If you go offline, a verified subscriber keeps full access for \(SubscriptionService.offlineGraceDays) days before a fresh check is needed.")
        }
    }

    // MARK: - Downloaded data

    private var dataSection: some View {
        Section {
            ReadinessRow(
                title: "Blocks & rows",
                detail: "\(paddockCount) block\(paddockCount == 1 ? "" : "s")",
                state: paddockCount > 0 ? .good : .warn
            )
            ReadinessRow(
                title: "Saved chemicals",
                detail: "\(store.savedChemicals.count) saved",
                state: store.savedChemicals.isEmpty ? .warn : .good
            )
            ReadinessRow(
                title: "Equipment",
                detail: "\(equipmentCount) item\(equipmentCount == 1 ? "" : "s")",
                state: equipmentCount > 0 ? .good : .warn
            )
        } header: {
            Text("Downloaded for offline use")
        } footer: {
            Text("These come from your last sync and are cached on disk. A warning here just means none are set up yet — it won't stop you working offline.")
        }
    }

    // MARK: - GPS

    private var gpsSection: some View {
        Section {
            ReadinessRow(
                title: "GPS permission",
                detail: gpsDetail,
                state: gpsState
            )
            if location.lastUpdateTimestamp != nil {
                LabeledContent("Last GPS fix", value: location.lastUpdateTimestamp?.formatted(date: .omitted, time: .standard) ?? "—")
                    .font(.footnote)
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Trip tracking and pin placement work fully offline — GPS does not require a network connection. \"Always\" allows tracking to continue when the screen locks.")
        }
    }

    // MARK: - Sync backlog

    private var syncSection: some View {
        Section {
            ReadinessRow(
                title: network.isOnline ? "Online" : "Offline",
                detail: syncCenter.label(isOnline: network.isOnline),
                state: network.isOnline ? .good : .warn
            )
            ReadinessRow(
                title: "Pending uploads",
                detail: pendingCount == 0 ? "All changes uploaded" : "\(pendingCount) waiting to sync",
                state: pendingCount == 0 ? .good : .warn
            )
            LabeledContent("Pending upload / delete", value: "\(syncCenter.pendingUpserts) / \(syncCenter.pendingDeletes)")
                .font(.footnote)
            if syncCenter.failedTotal > 0 {
                ReadinessRow(
                    title: "Records awaiting retry",
                    detail: syncCenter.retrySummary ?? "\(syncCenter.failedTotal) need retry",
                    state: .warn
                )
                LabeledContent("Failed uploads", value: "\(syncCenter.failedUpserts)")
                    .font(.footnote)
                LabeledContent("Failed deletes", value: "\(syncCenter.failedDeletes)")
                    .font(.footnote)
            }
            LabeledContent("Last full sync", value: lastFullSyncText)
                .font(.footnote)
            LabeledContent("Last successful sync", value: lastSyncText)
                .font(.footnote)
            if let error = syncCenter.lastError {
                LabeledContent("Last sync error", value: error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Sync status")
        } footer: {
            Text("Anything you create offline is saved locally and queued. It uploads automatically the next time the device has signal — nothing is lost if you stay out of range. Records awaiting retry stay saved and editable, and retry on reconnect.")
        }
    }

    // MARK: - Refresh

    private var refreshSection: some View {
        Section {
            Button {
                syncCenter.requestManualSync()
            } label: {
                HStack {
                    Label(syncCenter.isSyncing ? "Syncing…" : "Refresh & sync now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if syncCenter.isSyncing { ProgressView() }
                }
            }
            .disabled(syncCenter.isSyncing || !network.isOnline || !auth.isSignedIn || store.selectedVineyardId == nil)
        } footer: {
            Text("Run this while you still have signal to push pending changes and pull the latest paddocks, chemicals and equipment before heading out.")
        }
    }

    private var footerSection: some View {
        Section {
            Text("This screen is read-only and never changes app access. Use it as a pre-trip checklist before working in no-service areas.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived state

    private var accessVerifiedState: ReadinessRow.State {
        if subscription.hasAccess { return .good }
        if subscription.offlineGraceAnchorDate != nil { return .warn }
        return .bad
    }

    private var accessVerifiedDetail: String {
        if subscription.isSubscribed { return "Subscription active" }
        if subscription.isInInitialFreeAccessPeriod { return "Free access period" }
        if subscription.isOffline && subscription.isWithinOfflineGracePeriod {
            return "Offline grace active"
        }
        if subscription.offlineGraceAnchorDate != nil { return "Needs an online check" }
        return "Not verified yet"
    }

    private var lastVerifiedText: String {
        guard let date = subscription.lastVerifiedEntitlementAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var graceRemainingText: String {
        guard let remaining = subscription.offlineGraceRemaining else {
            return subscription.offlineGraceAnchorDate == nil ? "—" : "Expired"
        }
        let days = Int(remaining / 86_400)
        if days >= 1 { return "\(days) day\(days == 1 ? "" : "s")" }
        let hours = max(1, Int(remaining / 3_600))
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    private var paddockCount: Int {
        guard let vineyardId = store.selectedVineyardId else { return 0 }
        return store.paddocks.filter { $0.vineyardId == vineyardId }.count
    }

    private var equipmentCount: Int {
        guard let vineyardId = store.selectedVineyardId else { return store.equipmentItems.count }
        return store.equipmentItems.filter { $0.vineyardId == vineyardId }.count
    }

    private var pendingCount: Int {
        syncCenter.pendingTotal
    }

    private var lastSyncText: String {
        guard let date = syncCenter.lastSuccessfulSyncAt else { return "Never this session" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var lastFullSyncText: String {
        guard let date = syncCenter.lastFullSyncAt else { return "Not yet" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var gpsState: ReadinessRow.State {
        switch location.authorizationStatus {
        case .authorizedAlways: return .good
        case .authorizedWhenInUse: return .good
        case .notDetermined: return .warn
        default: return .bad
        }
    }

    private var gpsDetail: String {
        switch location.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using the app"
        case .notDetermined: return "Not requested yet"
        case .denied: return "Denied — enable in Settings"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    /// True when the must-haves for offline work are present. Saved
    /// chemicals/equipment are optional, so they don't block readiness.
    private var isFieldReady: Bool {
        auth.isSignedIn
            && store.selectedVineyard != nil
            && paddockCount > 0
            && (gpsState == .good)
    }

}

/// A single readiness line with a coloured status indicator.
private struct ReadinessRow: View {
    enum State {
        case good, warn, bad

        var symbol: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.circle.fill"
            case .bad: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .good: return .green
            case .warn: return .orange
            case .bad: return .red
            }
        }
    }

    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title3)
                .foregroundStyle(state.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

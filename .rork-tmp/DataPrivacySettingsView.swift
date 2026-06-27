import SwiftUI

struct DataPrivacySettingsView: View {
    @Environment(DataStore.self) private var store
    @Environment(CloudSyncService.self) private var cloudSync
    @Environment(\.accessControl) private var accessControl
    @State private var showDeletePinsAlert: Bool = false
    @State private var showDeleteTripsAlert: Bool = false
    @State private var isSyncing: Bool = false

    var body: some View {
        Form {
            cloudSyncSection
            Section {
                HStack {
                    Label("Pins", systemImage: "mappin")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(store.pins.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Trips", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(store.trips.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Current Data")
            }

            if accessControl?.canDelete ?? false {
                Section {
                    Button(role: .destructive) {
                        showDeletePinsAlert = true
                    } label: {
                        Label("Delete All Pins", systemImage: "mappin.slash")
                    }
                    .alert("Delete All Pins?", isPresented: $showDeletePinsAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Delete All", role: .destructive) {
                            store.deleteAllPins()
                        }
                    } message: {
                        Text("This will permanently delete all \(store.pins.count) pin\(store.pins.count == 1 ? "" : "s") in the current vineyard. This cannot be undone.")
                    }

                    Button(role: .destructive) {
                        showDeleteTripsAlert = true
                    } label: {
                        Label("Delete All Trips", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .alert("Delete All Trips?", isPresented: $showDeleteTripsAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Delete All", role: .destructive) {
                            store.deleteAllTrips()
                        }
                    } message: {
                        Text("This will permanently delete all \(store.trips.count) trip\(store.trips.count == 1 ? "" : "s") in the current vineyard. This cannot be undone.")
                    }
                } header: {
                    Text("Delete Data")
                } footer: {
                    Text("Permanently remove pins or trips from the current vineyard.")
                }
            }
        }
        .navigationTitle("Data Management")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var cloudSyncSection: some View {
        Section {
            HStack(spacing: 12) {
                Group {
                    switch cloudSync.syncStatus {
                    case .idle:
                        Image(systemName: "cloud")
                            .foregroundStyle(.secondary)
                    case .syncing:
                        ProgressView()
                            .controlSize(.small)
                    case .synced:
                        Image(systemName: "checkmark.icloud.fill")
                            .foregroundStyle(VineyardTheme.leafGreen)
                    case .error:
                        Image(systemName: "exclamationmark.icloud.fill")
                            .foregroundStyle(.red)
                    }
                }
                .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    switch cloudSync.syncStatus {
                    case .idle:
                        Text("Cloud Sync")
                            .font(.subheadline)
                        Text(cloudSync.isConfigured ? "Ready to sync" : "Not configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .syncing:
                        Text("Syncing...")
                            .font(.subheadline)
                    case .synced:
                        Text("Synced")
                            .font(.subheadline)
                        if let date = cloudSync.lastSyncDate {
                            Text("Last synced \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .error(let msg):
                        Text("Sync Error")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }

            if cloudSync.isConfigured {
                Button {
                    isSyncing = true
                    Task {
                        await cloudSync.syncAllData(from: store)
                        isSyncing = false
                    }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "icloud.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text("Cloud Backup")
            }
        } footer: {
            Text("Your data is stored locally and synced to the cloud. Sign in on any device to access your vineyards.")
        }
    }
}

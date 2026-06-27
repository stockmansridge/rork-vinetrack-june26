import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Environment(DataStore.self) private var store
    @Environment(AuthService.self) private var authService
    @Environment(AnalyticsService.self) private var analytics
    @Environment(AdminService.self) private var adminService
    @Environment(StoreViewModel.self) private var storeVM
    @Environment(\.accessControl) private var accessControl
    @State private var selectedLogoItem: PhotosPickerItem?
    @State private var showAdminDashboard: Bool = false
    @State private var showVineyardList: Bool = false
    @State private var showVineyardDetail: Bool = false
    @State private var showSupportForm: Bool = false
    @State private var showPaywall: Bool = false


    private var canChange: Bool { accessControl?.canChangeSettings ?? false }
    private var isManager: Bool { accessControl?.isManager ?? false }
    private var canManageUsers: Bool { accessControl?.canManageUsers ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if adminService.isAdmin {
                    adminSection
                }

                PendingInvitationsView()

                vineyardGroupSection

                if canChange {
                    operationsSetupGroupSection
                }

                preferencesGroupSection

                accountSupportGroupSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAdminDashboard) {
                AdminDashboardView()
            }
            .sheet(isPresented: $showVineyardList) {
                VineyardListView()
            }
            .sheet(isPresented: $showVineyardDetail) {
                if let vineyard = store.selectedVineyard {
                    VineyardDetailSheet(vineyard: vineyard)
                }
            }
            .sheet(isPresented: $showSupportForm) {
                SupportFormView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .task {
                await adminService.checkAdminStatus()
            }
        }
    }

    private var adminSection: some View {
        Section {
            Button {
                showAdminDashboard = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.red.gradient)
                            .frame(width: 32, height: 32)
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Admin Dashboard")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("View all users & analytics")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "shield.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("Administration")
            }
        }
    }

    @ViewBuilder
    private var vineyardGroupSection: some View {
        Section {
            if let vineyard = store.selectedVineyard {
                HStack(spacing: 12) {
                    if let logoData = vineyard.logoData,
                       let uiImage = UIImage(data: logoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(.rect(cornerRadius: 8))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.green.gradient)
                                .frame(width: 40, height: 40)
                            GrapeLeafIcon(size: 18)
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(vineyard.name)
                            .font(.headline)
                        Text("\(vineyard.users.count) user\(vineyard.users.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }

            Button {
                showVineyardList = true
            } label: {
                Label("Switch Vineyard", systemImage: "arrow.triangle.swap")
                    .foregroundStyle(.primary)
            }

            if canChange {
                PhotosPicker(selection: $selectedLogoItem, matching: .images) {
                    Label(store.selectedVineyard?.logoData != nil ? "Change Logo" : "Add Logo", systemImage: "photo.badge.plus")
                        .foregroundStyle(.primary)
                }
                .onChange(of: selectedLogoItem) { _, newItem in
                    handleLogoSelection(newItem)
                }

                if store.selectedVineyard?.logoData != nil && (accessControl?.canDelete ?? false) {
                    Button(role: .destructive) {
                        store.updateVineyardLogo(nil)
                    } label: {
                        Label("Remove Logo", systemImage: "trash")
                    }
                }
            }

            if canManageUsers || isManager {
                Button {
                    showVineyardDetail = true
                } label: {
                    Label("Team & Access", systemImage: "person.2.fill")
                        .foregroundStyle(.primary)
                }
            }

            if isManager {
                subscriptionRow
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .font(.caption)
                Text("Vineyard")
            }
        }
    }

    @ViewBuilder
    private var subscriptionRow: some View {
        if storeVM.isPremium {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.green.gradient)
                        .frame(width: 28, height: 28)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text("VineTrack Pro")
                    .font(.subheadline)
                Spacer()
                Text("Active")
                    .font(.caption.bold())
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.green.gradient)
                            .frame(width: 28, height: 28)
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Text("Upgrade to Pro")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var operationsSetupGroupSection: some View {
        Section {
            NavigationLink {
                OperationsSetupHubView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(VineyardTheme.leafGreen.gradient)
                            .frame(width: 32, height: 32)
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Operations Setup")
                            .font(.subheadline.weight(.medium))
                        Text("Blocks, spray, equipment & operators")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.adjustable.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Operations")
            }
        }
    }

    @ViewBuilder
    private var preferencesGroupSection: some View {
        Section {
            NavigationLink {
                PreferencesSettingsView()
            } label: {
                settingsRow(
                    title: "Preferences",
                    subtitle: "Appearance, season, tracking & photos",
                    symbol: "slider.horizontal.3",
                    color: .indigo
                )
            }

            if canChange {
                NavigationLink {
                    DataPrivacySettingsView()
                } label: {
                    settingsRow(
                        title: "Data & Backup",
                        subtitle: "Cloud sync, pins & trips",
                        symbol: "externaldrive.fill",
                        color: .blue
                    )
                }
            }

            if isManager {
                NavigationLink {
                    AuditLogView()
                } label: {
                    settingsRow(
                        title: "Audit Log",
                        subtitle: "Deletes, role & settings changes",
                        symbol: "list.bullet.clipboard.fill",
                        color: .gray
                    )
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.indigo)
                    .font(.caption)
                Text("Preferences & Data")
            }
        }
    }

    @ViewBuilder
    private var accountSupportGroupSection: some View {
        Section {
            NavigationLink {
                AccountSettingsView()
            } label: {
                settingsRow(
                    title: "Account",
                    subtitle: authService.userName.isEmpty ? "Sign out & manage account" : authService.userName,
                    symbol: "person.circle.fill",
                    color: .gray
                )
            }

            Button {
                showSupportForm = true
            } label: {
                settingsRow(
                    title: "Contact Support",
                    subtitle: "Report an issue or send feedback",
                    symbol: "envelope.fill",
                    color: .blue
                )
            }

            NavigationLink {
                RolesPermissionsInfoView()
            } label: {
                settingsRow(
                    title: "Roles & Permissions",
                    subtitle: "How access works for your team",
                    symbol: "person.badge.shield.checkmark.fill",
                    color: .purple
                )
            }

            Link(destination: AppLinks.termsOfUse) {
                HStack {
                    Text("Terms of Use (EULA)")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Link(destination: AppLinks.privacyPolicy) {
                HStack {
                    Text("Privacy Policy")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            LabeledContent("Version", value: "\(appVersion) (\(appBuild))")
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .foregroundStyle(.gray)
                    .font(.caption)
                Text("Account & Support")
            }
        }
    }

    private func settingsRow(title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func handleLogoSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                let maxSize: CGFloat = 200
                let scale = min(maxSize / uiImage.size.width, maxSize / uiImage.size.height, 1.0)
                let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                let resized = renderer.image { _ in
                    uiImage.draw(in: CGRect(origin: .zero, size: newSize))
                }
                if let compressed = resized.jpegData(compressionQuality: 0.7) {
                    store.updateVineyardLogo(compressed)
                }
            }
            selectedLogoItem = nil
        }
    }
}

struct TimezonePicker: View {
    @Binding var selectedTimezone: String
    @State private var searchText: String = ""

    private var timezones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(timezones, id: \.self) { tz in
                Button {
                    selectedTimezone = tz
                } label: {
                    HStack {
                        Text(tz.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(.primary)
                        Spacer()
                        if tz == selectedTimezone {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search timezones")
        .navigationTitle("Timezone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NearbyStationPicker: View {
    let weatherStationService: WeatherStationService
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if weatherStationService.isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Searching for nearby stations...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = weatherStationService.errorMessage {
                    ContentUnavailableView {
                        Label("Unable to Find Stations", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if weatherStationService.nearbyStations.isEmpty {
                    ContentUnavailableView {
                        Label("No Stations Found", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text("No Weather Underground personal weather stations were found near your location.")
                    }
                } else {
                    List {
                        ForEach(weatherStationService.nearbyStations) { station in
                            Button {
                                onSelect(station.id)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(station.id)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        if !station.name.isEmpty && station.name != station.id {
                                            Text(station.name)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(station.localizedDistance)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nearby Stations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

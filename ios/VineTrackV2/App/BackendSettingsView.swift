import SwiftUI

struct BackendSettingsView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BiometricAuthService.self) private var biometric
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(SubscriptionService.self) private var subscription
    @Environment(PinSyncService.self) private var pinSync
    @Environment(PaddockSyncService.self) private var paddockSync
    @Environment(TripSyncService.self) private var tripSync
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(ButtonConfigSyncService.self) private var buttonConfigSync
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var showVineyardSwitcher: Bool = false
    @State private var showVineyardDetail: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var refreshMessage: String?
    @State private var searchText: String = ""

    #if DEBUG
    @State private var showBackendDiagnostic: Bool = false
    @State private var showStoreDiagnostic: Bool = false
    #endif

    private let vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository()

    @Environment(\.openURL) private var openURL

    private var pendingInvitationCount: Int {
        let userEmail = (auth.userEmail ?? "").lowercased()
        let memberIds = Set(store.vineyards.map { $0.id })
        return auth.pendingInvitations
            .filter { $0.status.lowercased() == "pending" }
            .filter { userEmail.isEmpty || $0.email.lowercased() == userEmail }
            .filter { !memberIds.contains($0.vineyardId) }
            .count
    }

    var body: some View {
        NavigationStack {
            Form {
                if isSearchActive {
                    searchResultsSection
                } else {
                accountSection
                vineyardSection
                operationsSection
                if let vineyard = store.selectedVineyard {
                    teamSection(vineyard: vineyard)
                }

                Section {
                    NavigationLink {
                        SubscriptionSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Subscription",
                            subtitle: subscriptionSubtitle,
                            symbol: "creditcard.fill",
                            color: .pink
                        )
                    }
                    NavigationLink {
                        PreferencesHubView()
                    } label: {
                        SettingsRow(
                            title: "Preferences",
                            subtitle: "Appearance, season, tracking & photos",
                            symbol: "slider.horizontal.3",
                            color: .indigo
                        )
                    }
                    NavigationLink {
                        AlertSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Alerts & Notifications",
                            subtitle: "Irrigation, pins, weather & spray reminders",
                            symbol: "bell.badge.fill",
                            color: .red
                        )
                    }
                    NavigationLink {
                        WeatherDataSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Weather Data & Forecasting",
                            subtitle: "Forecast source, station & sensors",
                            symbol: "cloud.sun.fill",
                            color: .orange
                        )
                    }
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        SettingsRow(
                            title: "Sync",
                            subtitle: "Cloud sync for pins, paddocks & trips",
                            symbol: "icloud.and.arrow.up",
                            color: .blue
                        )
                    }
                    NavigationLink {
                        OfflineReadinessView()
                    } label: {
                        SettingsRow(
                            title: "Offline Readiness",
                            subtitle: "Check this device is ready for no-service areas",
                            symbol: "wifi.slash",
                            color: .green
                        )
                    }
                    if systemAdmin.isEnabled(SystemFeatureFlagKey.showSyncDiagnostics) {
                        NavigationLink {
                            SyncDiagnosticsView()
                        } label: {
                            SettingsRow(
                                title: "Sync Diagnostics",
                                subtitle: "Pending uploads, last sync & status",
                                symbol: "stethoscope",
                                color: .teal
                            )
                        }
                    }
                    if let portalURL = VineTrackPortal.url {
                        Link(destination: portalURL) {
                            SettingsRow(
                                title: "VineTrack Web Portal",
                                subtitle: "Manage setup, reports and team access from desktop.",
                                symbol: "laptopcomputer.and.iphone",
                                color: VineyardTheme.leafGreen
                            )
                        }
                    }
                } header: {
                    SettingsSectionHeader(title: "Preferences & Data", symbol: "gearshape.fill", color: .indigo)
                }

                if systemAdmin.isSystemAdmin {
                    systemAdminSection
                }

                supportSection
                accountPrivacySection
                aboutSection

                #if DEBUG
                debugSection
                #endif

                signOutSection
                }
            }
            .navigationTitle("Settings")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
            .refreshable { await refreshVineyards() }
            .sheet(isPresented: $showVineyardSwitcher) {
                BackendVineyardListView()
            }
            .sheet(isPresented: $showVineyardDetail) {
                if let vineyard = store.selectedVineyard {
                    BackendVineyardDetailSheet(vineyard: vineyard)
                }
            }
            #if DEBUG
            .sheet(isPresented: $showBackendDiagnostic) {
                BackendDiagnosticHostView()
            }
            .sheet(isPresented: $showStoreDiagnostic) {
                MigratedDataStoreDiagnosticView()
            }
            #endif
        }
    }

    // MARK: - Settings search (UI-only)

    /// A single searchable destination row. Search matches against the
    /// title, subtitle and keyword list — display/navigation only, no
    /// changes to data, sync, exports or settings logic.
    private struct SettingsSearchItem: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let keywords: [String]
        let symbol: String
        let color: Color
        let destination: AnyView
        /// Parent top-level card this screen lives under, shown as a
        /// breadcrumb path in search results (nil for top-level cards).
        var parent: String? = nil
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchableItems: [SettingsSearchItem] {
        var items: [SettingsSearchItem] = [
            SettingsSearchItem(
                title: "Vineyard Setup",
                subtitle: "Blocks, Region & Growth Stages",
                keywords: ["blocks", "paddocks", "buttons", "growth stages", "region", "regional", "country", "currency", "units", "hectares", "acres", "litres", "gallons", "date", "reports", "exports", "international"],
                symbol: "square.grid.2x2.fill",
                color: VineyardTheme.leafGreen,
                destination: AnyView(VineyardSetupHubView())
            ),
            SettingsSearchItem(
                title: "Spray & Equipment",
                subtitle: "Spray Management, Equipment & Tractors, Chemicals",
                keywords: ["spray", "chemicals", "equipment", "tractors", "tank", "presets"],
                symbol: "drop.fill",
                color: .teal,
                destination: AnyView(SprayEquipmentHubView())
            ),
            SettingsSearchItem(
                title: "Team Operations",
                subtitle: "Operator Categories",
                keywords: ["operators", "categories", "team", "operations"],
                symbol: "person.2.fill",
                color: .blue,
                destination: AnyView(TeamOperationsHubView())
            ),
            SettingsSearchItem(
                title: "Trip Functions",
                subtitle: "Built-ins and custom vineyard trip functions",
                keywords: ["trips", "functions", "jobs"],
                symbol: "wrench.and.screwdriver.fill",
                color: VineyardTheme.earthBrown,
                destination: AnyView(TripFunctionsSettingsView())
            ),
            SettingsSearchItem(
                title: "Operation Preferences",
                subtitle: "Season E-L, spray/tank, yield",
                keywords: ["season", "spray", "tank", "yield", "el stage"],
                symbol: "slider.horizontal.3",
                color: .orange,
                destination: AnyView(OperationPreferencesView())
            ),
            SettingsSearchItem(
                title: "Subscription",
                subtitle: subscriptionSubtitle,
                keywords: ["subscription", "billing", "plan", "pro", "payment", "upgrade"],
                symbol: "creditcard.fill",
                color: .pink,
                destination: AnyView(SubscriptionSettingsView())
            ),
            SettingsSearchItem(
                title: "Preferences",
                subtitle: "Appearance, season, tracking & photos",
                keywords: ["appearance", "theme", "dark mode", "season", "tracking", "photos"],
                symbol: "slider.horizontal.3",
                color: .indigo,
                destination: AnyView(PreferencesHubView())
            ),
            SettingsSearchItem(
                title: "Alerts & Notifications",
                subtitle: "Irrigation, pins, weather & spray reminders",
                keywords: ["alerts", "notifications", "reminders", "irrigation", "weather", "spray"],
                symbol: "bell.badge.fill",
                color: .red,
                destination: AnyView(AlertSettingsView())
            ),
            SettingsSearchItem(
                title: "Weather Data & Forecasting",
                subtitle: "Forecast source, station & sensors",
                keywords: ["weather", "forecast", "station", "sensors", "rainfall"],
                symbol: "cloud.sun.fill",
                color: .orange,
                destination: AnyView(WeatherDataSettingsView())
            ),
            SettingsSearchItem(
                title: "Sync",
                subtitle: "Cloud sync for pins, paddocks & trips",
                keywords: ["sync", "cloud", "backup", "upload"],
                symbol: "icloud.and.arrow.up",
                color: .blue,
                destination: AnyView(SyncSettingsView())
            ),
            SettingsSearchItem(
                title: "Offline Readiness",
                subtitle: "Check this device is ready for no-service areas",
                keywords: ["offline", "no service", "readiness"],
                symbol: "wifi.slash",
                color: .green,
                destination: AnyView(OfflineReadinessView())
            ),
            SettingsSearchItem(
                title: "Contact Support",
                subtitle: "Send feedback, feature requests or report an issue",
                keywords: ["support", "help", "feedback", "contact", "bug"],
                symbol: "envelope.fill",
                color: .green,
                destination: AnyView(SupportRequestView())
            ),
            SettingsSearchItem(
                title: "Disclaimer",
                subtitle: "Important usage notes",
                keywords: ["disclaimer", "legal", "usage"],
                symbol: "exclamationmark.shield.fill",
                color: .orange,
                destination: AnyView(DisclaimerInfoView())
            ),
            SettingsSearchItem(
                title: "Request Account Deletion",
                subtitle: "Permanently remove your account",
                keywords: ["delete account", "remove account", "privacy"],
                symbol: "person.crop.circle.badge.xmark",
                color: .red,
                destination: AnyView(AccountDeletionRequestView())
            )
        ]
        // Child setup screens — indexed so search can navigate one level
        // deeper than the top-level cards. Display/navigation only.
        items.append(contentsOf: childSettingsItems)
        if let vineyard = store.selectedVineyard {
            items.append(SettingsSearchItem(
                title: "Team & Access",
                subtitle: "Manage members and invitations",
                keywords: ["team", "members", "invitations", "access"],
                symbol: "person.2.fill",
                color: .teal,
                destination: AnyView(BackendTeamAccessView(vineyardId: vineyard.id, vineyardName: vineyard.name))
            ))
            items.append(SettingsSearchItem(
                title: "Roles & Permissions",
                subtitle: "How access works for your team",
                keywords: ["roles", "permissions", "access"],
                symbol: "person.badge.shield.checkmark.fill",
                color: .purple,
                destination: AnyView(RolesPermissionsInfoView())
            ))
        }
        return items
    }

    /// Child setup screens that live under the top-level cards. Each
    /// carries its parent breadcrumb so search can deep-link directly.
    private var childSettingsItems: [SettingsSearchItem] {
        var items: [SettingsSearchItem] = [
            // Under Vineyard Setup
            SettingsSearchItem(
                title: "Region & Units",
                subtitle: "Country, currency & units",
                keywords: ["region", "regional", "currency", "units", "country", "acres", "gallons", "date format", "hectares", "litres", "terminology", "international"],
                symbol: "ruler",
                color: .teal,
                destination: AnyView(RegionUnitsSettingsView()),
                parent: "Vineyard Setup"
            ),
            SettingsSearchItem(
                title: "Blocks",
                subtitle: "Map, rows & vine counts",
                keywords: ["blocks", "paddocks", "rows", "vines", "map"],
                symbol: "square.grid.2x2.fill",
                color: VineyardTheme.leafGreen,
                destination: AnyView(VineyardSetupHubView()),
                parent: "Vineyard Setup"
            ),
            SettingsSearchItem(
                title: "Grape Varieties",
                subtitle: "Master & custom varieties",
                keywords: ["varieties", "grapes", "cultivar", "clone"],
                symbol: "leaf.circle",
                color: VineyardTheme.leafGreen,
                destination: AnyView(GrapeVarietyManagementView()),
                parent: "Vineyard Setup"
            ),
            SettingsSearchItem(
                title: "Growth Stage Images",
                subtitle: "Reference images for E-L stages",
                keywords: ["growth stages", "images", "el stage", "phenology"],
                symbol: "photo.on.rectangle.angled",
                color: VineyardTheme.leafGreen,
                destination: AnyView(GrowthStageImagesSettingsView()),
                parent: "Vineyard Setup"
            ),
            // Under Spray & Equipment
            SettingsSearchItem(
                title: "Spray Management",
                subtitle: "Presets and programs",
                keywords: ["spray", "presets", "programs", "tank"],
                symbol: "drop.fill",
                color: .teal,
                destination: AnyView(SprayManagementSettingsView()),
                parent: "Spray & Equipment"
            ),
            SettingsSearchItem(
                title: "Equipment & Tractors",
                subtitle: "Sprayers, tractors, fuel",
                keywords: ["equipment", "tractors", "sprayers", "fuel", "machinery"],
                symbol: "wrench.and.screwdriver.fill",
                color: VineyardTheme.earthBrown,
                destination: AnyView(EquipmentManagementView()),
                parent: "Spray & Equipment"
            ),
            SettingsSearchItem(
                title: "Chemicals",
                subtitle: "Saved chemical library",
                keywords: ["chemicals", "library", "products", "sprays"],
                symbol: "flask.fill",
                color: .purple,
                destination: AnyView(ChemicalsManagementView()),
                parent: "Spray & Equipment"
            ),
            SettingsSearchItem(
                title: "Saved Inputs",
                subtitle: "Seed, fertiliser & inputs library",
                keywords: ["saved inputs", "seed", "fertiliser", "fertilizer", "inputs"],
                symbol: "leaf.fill",
                color: VineyardTheme.leafGreen,
                destination: AnyView(SavedInputsManagementView()),
                parent: "Spray & Equipment"
            ),
            // Under Team Operations
            SettingsSearchItem(
                title: "Operator Categories",
                subtitle: "Operator labour categories",
                keywords: ["operators", "categories", "labour", "labor", "team"],
                symbol: "person.badge.clock.fill",
                color: .blue,
                destination: AnyView(OperatorCategoriesView()),
                parent: "Team Operations"
            )
        ]
        return items
    }

    private var searchResults: [SettingsSearchItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return searchableItems.filter { item in
            item.title.lowercased().contains(query)
                || item.subtitle.lowercased().contains(query)
                || item.keywords.contains { $0.lowercased().contains(query) }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if searchResults.isEmpty {
            Section {
                Text("No settings found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(searchResults) { item in
                    NavigationLink {
                        item.destination
                    } label: {
                        searchResultLabel(for: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultLabel(for item: SettingsSearchItem) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: item.symbol, color: item.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if let parent = item.parent {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(parent)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            NavigationLink {
                EditDisplayNameView()
            } label: {
                SettingsRow(
                    title: "Name",
                    subtitle: auth.userName ?? "—",
                    symbol: "person.crop.circle.fill",
                    color: .gray
                )
            }
            HStack(spacing: 12) {
                SettingsIconTile(symbol: "envelope.fill", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email")
                        .font(.subheadline.weight(.medium))
                    Text(auth.userEmail ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                BiometricSettingsView()
            } label: {
                SettingsRow(
                    title: "Face ID / Touch ID",
                    subtitle: biometricSubtitle,
                    symbol: biometricSymbol,
                    color: VineyardTheme.leafGreen
                )
            }
        } header: {
            SettingsSectionHeader(title: "Account", symbol: "person.fill", color: .gray)
        }
    }

    private var biometricSubtitle: String {
        if !(biometric.deviceSupportsBiometrics || biometric.deviceSupportsAnyAuth) {
            return "Not available on this device"
        }
        return biometric.isEnabled ? "\(biometric.displayName) sign-in enabled" : "Sign in faster with \(biometric.displayName)"
    }

    private var biometricSymbol: String {
        switch biometric.biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.shield.fill"
        }
    }

    private var vineyardSection: some View {
        Section {
            if let vineyard = store.selectedVineyard {
                Button {
                    showVineyardDetail = true
                } label: {
                    HStack(spacing: 12) {
                        vineyardThumbnail(vineyard)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(vineyard.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                if vineyard.id == auth.defaultVineyardId {
                                    Label("Default", systemImage: "star.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15), in: Capsule())
                                }
                            }
                            if !vineyard.country.isEmpty {
                                Text(vineyard.country)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let defaultId = auth.defaultVineyardId,
                   let defaultVineyard = store.vineyards.first(where: { $0.id == defaultId }),
                   defaultId != vineyard.id {
                    HStack(spacing: 12) {
                        SettingsIconTile(symbol: "star.fill", color: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default Vineyard")
                                .font(.subheadline.weight(.medium))
                            Text(defaultVineyard.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else if auth.defaultVineyardId == nil {
                    Button {
                        Task { await auth.setDefaultVineyard(vineyard.id) }
                    } label: {
                        Label("Make this vineyard default", systemImage: "star")
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("No vineyard selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                showVineyardSwitcher = true
            } label: {
                HStack {
                    Label("Change Vineyard", systemImage: "arrow.triangle.swap")
                        .foregroundStyle(.primary)
                    Spacer()
                    let count = pendingInvitationCount
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .accessibilityLabel("\(count) pending invitations")
                    }
                }
            }
        } header: {
            SettingsSectionHeader(title: "Vineyard", symbol: "building.2.fill", color: VineyardTheme.leafGreen)
        }
    }

    @ViewBuilder
    private func vineyardThumbnail(_ vineyard: Vineyard) -> some View {
        if let data = vineyard.logoData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 8))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(VineyardTheme.leafGreen.gradient)
                    .frame(width: 40, height: 40)
                GrapeLeafIcon(size: 20, color: .white)
            }
        }
    }

    private var operationsSection: some View {
        Section {
            NavigationLink {
                VineyardSetupHubView()
            } label: {
                SettingsRow(
                    title: "Vineyard Setup",
                    subtitle: "Blocks, Region & Growth Stages",
                    symbol: "square.grid.2x2.fill",
                    color: VineyardTheme.leafGreen
                )
            }
            NavigationLink {
                SprayEquipmentHubView()
            } label: {
                SettingsRow(
                    title: "Spray & Equipment",
                    subtitle: "Spray Management, Equipment & Tractors, Chemicals",
                    symbol: "drop.fill",
                    color: .teal
                )
            }
            NavigationLink {
                TeamOperationsHubView()
            } label: {
                SettingsRow(
                    title: "Team Operations",
                    subtitle: "Operator Categories",
                    symbol: "person.2.fill",
                    color: .blue
                )
            }
            NavigationLink {
                TripFunctionsSettingsView()
            } label: {
                SettingsRow(
                    title: "Trip Functions",
                    subtitle: "Built-ins and custom vineyard trip functions",
                    symbol: "wrench.and.screwdriver.fill",
                    color: VineyardTheme.earthBrown
                )
            }
            NavigationLink {
                OperationPreferencesView()
            } label: {
                SettingsRow(
                    title: "Operation Preferences",
                    subtitle: "Season E-L, spray/tank, yield",
                    symbol: "slider.horizontal.3",
                    color: .orange
                )
            }
        } header: {
            SettingsSectionHeader(title: "Operations", symbol: "wrench.adjustable.fill", color: .orange)
        }
    }

    private func teamSection(vineyard: Vineyard) -> some View {
        Section {
            NavigationLink {
                BackendTeamAccessView(vineyardId: vineyard.id, vineyardName: vineyard.name)
            } label: {
                SettingsRow(
                    title: "Team & Access",
                    subtitle: "Manage members and invitations",
                    symbol: "person.2.fill",
                    color: .teal
                )
            }
            NavigationLink {
                RolesPermissionsInfoView()
            } label: {
                SettingsRow(
                    title: "Roles & Permissions",
                    subtitle: "How access works for your team",
                    symbol: "person.badge.shield.checkmark.fill",
                    color: .purple
                )
            }
        } header: {
            SettingsSectionHeader(title: "Team", symbol: "person.2.fill", color: .teal)
        }
    }

    private var systemAdminSection: some View {
        Section {
            NavigationLink {
                AdminDashboardView()
            } label: {
                SettingsRow(
                    title: "Admin Dashboard",
                    subtitle: "Engagement summary & user support",
                    symbol: "shield.lefthalf.filled",
                    color: .purple
                )
            }
            NavigationLink {
                AdminAppNoticesView()
            } label: {
                SettingsRow(
                    title: "App Notices",
                    subtitle: "App-wide banners shown on Home",
                    symbol: "megaphone.fill",
                    color: .orange
                )
            }
            NavigationLink {
                SystemFeatureFlagsView()
            } label: {
                SettingsRow(
                    title: "Feature Flags",
                    subtitle: "Diagnostics & beta controls (platform-wide)",
                    symbol: "flag.2.crossed.fill",
                    color: .purple
                )
            }
            NavigationLink {
                SystemAdminUsersView()
            } label: {
                SettingsRow(
                    title: "System Admin Users",
                    subtitle: "Add or deactivate platform administrators",
                    symbol: "person.badge.key.fill",
                    color: .purple
                )
            }
            NavigationLink {
                BillingGrantsView()
            } label: {
                SettingsRow(
                    title: "Billing Grants / Internal Access",
                    subtitle: "Grant or revoke manual unlimited licences",
                    symbol: "infinity.circle.fill",
                    color: .purple
                )
            }
            NavigationLink {
                SystemAdminUserActivityView()
            } label: {
                SettingsRow(
                    title: "User Activity / Logins",
                    subtitle: "View user login recency, roles & devices",
                    symbol: "person.2.wave.2.fill",
                    color: .purple
                )
            }
            NavigationLink {
                LocationTroubleshooterView()
            } label: {
                SettingsRow(
                    title: "Location Troubleshooter",
                    subtitle: "Diagnose GPS, block, row snap & offset issues",
                    symbol: "scope",
                    color: .purple
                )
            }
            NavigationLink {
                AlertDiagnosticsView()
            } label: {
                SettingsRow(
                    title: "Alert Diagnostics",
                    subtitle: "Inspect alert preferences, generation & fetch",
                    symbol: "stethoscope.circle.fill",
                    color: .purple
                )
            }
        } header: {
            SettingsSectionHeader(title: "System Admin", symbol: "key.fill", color: .purple)
        } footer: {
            Text("Visible only to VineTrack platform administrators. Controls diagnostics, notices and admin tools across iOS and the web portal.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: AppBuildInfo.displayVersion)
            LabeledContent("Disclaimer", value: "v\(DisclaimerInfo.version)")
            LabeledContent("Backend", value: SupabaseClientProvider.shared.isConfigured ? "Connected" : "Not configured")
        } header: {
            SettingsSectionHeader(title: "About", symbol: "info.circle.fill", color: .gray)
        }
    }

    private var accountPrivacySection: some View {
        Section {
            Button {
                if let url = URL(string: "https://vinetrack.com.au/privacy") {
                    openURL(url)
                }
            } label: {
                externalLinkRow(
                    title: "Privacy Policy",
                    subtitle: "How we handle your data",
                    symbol: "hand.raised.fill",
                    color: .blue
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            Button {
                if let url = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                    openURL(url)
                }
            } label: {
                externalLinkRow(
                    title: "Terms of Use (EULA)",
                    subtitle: "Apple standard end-user license",
                    symbol: "doc.text.fill",
                    color: .gray
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            NavigationLink {
                DisclaimerInfoView()
            } label: {
                SettingsRow(
                    title: "Disclaimer",
                    subtitle: "Important usage notes",
                    symbol: "exclamationmark.shield.fill",
                    color: .orange
                )
            }
            NavigationLink {
                AccountDeletionRequestView()
            } label: {
                SettingsRow(
                    title: "Request Account Deletion",
                    subtitle: "Permanently remove your account",
                    symbol: "person.crop.circle.badge.xmark",
                    color: .red
                )
            }
        } header: {
            SettingsSectionHeader(title: "Account & Privacy", symbol: "lock.shield.fill", color: .blue)
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Button {
                showBackendDiagnostic = true
            } label: {
                Label("Backend Diagnostic", systemImage: "stethoscope")
            }
            Button {
                showStoreDiagnostic = true
            } label: {
                Label("MigratedDataStore Diagnostic", systemImage: "tray.full")
            }
        } header: {
            Text("Diagnostics")
        }
    }
    #endif

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                Task {
                    await auth.signOut()
                    store.clearInMemoryState()
                }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - Support

    private var supportSection: some View {
        Section {
            NavigationLink {
                SupportRequestView()
            } label: {
                SettingsRow(
                    title: "Contact Support",
                    subtitle: "Send feedback, feature requests or report an issue",
                    symbol: "envelope.fill",
                    color: .green
                )
            }
        } header: {
            SettingsSectionHeader(title: "Help & Support", symbol: "questionmark.circle.fill", color: .green)
        } footer: {
            Text("We read every message — your feedback shapes what we build next.")
        }
    }

    private func externalLinkRow(title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private var subscriptionSubtitle: String {
        if subscription.isSubscribed { return "Vineyard Tracker Pro — active" }
        if subscription.isInInitialFreeAccessPeriod {
            if let freeAccessEndsAt = subscription.freeAccessEndsAt {
                return "Free access until \(freeAccessEndsAt.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Free access active"
        }
        switch subscription.status {
        case .loading, .unknown: return "Checking…"
        default: return "Manage your plan"
        }
    }

    private func refreshVineyards() async {
        isRefreshing = true
        refreshMessage = nil
        defer { isRefreshing = false }
        do {
            let backendVineyards = try await vineyardRepository.listMyVineyards()
            store.mapBackendVineyardsIntoLocal(backendVineyards)
            refreshMessage = "Loaded \(backendVineyards.count) vineyard\(backendVineyards.count == 1 ? "" : "s")."
        } catch {
            refreshMessage = error.localizedDescription
        }
    }
}

// MARK: - Sync Settings (extracted)

struct SyncSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SyncStatusCenter.self) private var syncCenter
    @Environment(NetworkMonitor.self) private var network
    @Environment(PinSyncService.self) private var pinSync
    @Environment(PaddockSyncService.self) private var paddockSync
    @Environment(TripSyncService.self) private var tripSync
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(ButtonConfigSyncService.self) private var buttonConfigSync
    @Environment(SavedChemicalSyncService.self) private var savedChemicalSync
    @Environment(SavedInputSyncService.self) private var savedInputSync
    @Environment(TripCostAllocationSyncService.self) private var tripCostAllocationSync
    @Environment(SavedSprayPresetSyncService.self) private var savedSprayPresetSync
    @Environment(SprayEquipmentSyncService.self) private var sprayEquipmentSync
    @Environment(TractorSyncService.self) private var tractorSync
    @Environment(VineyardMachineSyncService.self) private var vineyardMachineSync
    @Environment(FuelPurchaseSyncService.self) private var fuelPurchaseSync
    @Environment(TractorFuelLogSyncService.self) private var tractorFuelLogSync
    @Environment(OperatorCategorySyncService.self) private var operatorCategorySync
    @Environment(WorkTaskTypeSyncService.self) private var workTaskTypeSync
    @Environment(GrowthStageImageSyncService.self) private var growthStageImageSync
    @Environment(GrowthStageRecordSyncService.self) private var growthStageRecordSync
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(WorkTaskLabourLineSyncService.self) private var workTaskLabourLineSync
    @Environment(WorkTaskPaddockSyncService.self) private var workTaskPaddockSync
    @Environment(MaintenanceLogSyncService.self) private var maintenanceLogSync
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSessionSync
    @Environment(DamageRecordSyncService.self) private var damageRecordSync
    @Environment(HistoricalYieldRecordSyncService.self) private var historicalYieldSync

    var body: some View {
        Form {
            statusSection
            Section {
                Button {
                    Task { await pinSync.syncPinsForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Pins", icon: "mappin.and.ellipse", isSyncing: isSyncing(pinSync.syncStatus))
                }
                .disabled(isSyncing(pinSync.syncStatus))
                VineyardSyncStatusRow(label: "pins", state: pinStateFrom(pinSync.syncStatus, lastSync: pinSync.lastSyncDate))

                Button {
                    Task { await paddockSync.syncPaddocksForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Paddocks", icon: "square.grid.2x2", isSyncing: isSyncing(paddockSync.syncStatus))
                }
                .disabled(isSyncing(paddockSync.syncStatus))
                VineyardSyncStatusRow(label: "paddocks", state: paddockStateFrom(paddockSync.syncStatus, lastSync: paddockSync.lastSyncDate))

                Button {
                    Task { await tripSync.syncTripsForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Trips", icon: "map", isSyncing: isSyncing(tripSync.syncStatus))
                }
                .disabled(isSyncing(tripSync.syncStatus))
                VineyardSyncStatusRow(label: "trips", state: tripStateFrom(tripSync.syncStatus, lastSync: tripSync.lastSyncDate))

                Button {
                    Task { await sprayRecordSync.syncSprayRecordsForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Spray Records", icon: "drop.fill", isSyncing: isSyncing(sprayRecordSync.syncStatus))
                }
                .disabled(isSyncing(sprayRecordSync.syncStatus))
                VineyardSyncStatusRow(label: "spray records", state: sprayStateFrom(sprayRecordSync.syncStatus, lastSync: sprayRecordSync.lastSyncDate))

                Button {
                    Task { await buttonConfigSync.syncButtonConfigForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Button Config", icon: "square.grid.2x2", isSyncing: isSyncing(buttonConfigSync.syncStatus))
                }
                .disabled(isSyncing(buttonConfigSync.syncStatus))
                VineyardSyncStatusRow(label: "button config", state: buttonConfigStateFrom(buttonConfigSync.syncStatus, lastSync: buttonConfigSync.lastSyncDate))
            } footer: {
                Text("Pins, paddocks, trips, spray records, and button config sync to Supabase.")
            }

            Section {
                Button {
                    Task { await savedChemicalSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Saved Chemicals", icon: "flask.fill", isSyncing: isSyncingMgmt(savedChemicalSync.syncStatus))
                }
                .disabled(isSyncingMgmt(savedChemicalSync.syncStatus))
                VineyardSyncStatusRow(label: "saved chemicals", state: mgmtStateFrom(savedChemicalSync.syncStatus, lastSync: savedChemicalSync.lastSyncDate))

                Button {
                    Task { await savedSprayPresetSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Spray Presets", icon: "slider.horizontal.3", isSyncing: isSyncingMgmt(savedSprayPresetSync.syncStatus))
                }
                .disabled(isSyncingMgmt(savedSprayPresetSync.syncStatus))
                VineyardSyncStatusRow(label: "spray presets", state: mgmtStateFrom(savedSprayPresetSync.syncStatus, lastSync: savedSprayPresetSync.lastSyncDate))

                Button {
                    Task { await sprayEquipmentSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Spray Equipment", icon: "sprinkler.and.droplets.fill", isSyncing: isSyncingMgmt(sprayEquipmentSync.syncStatus))
                }
                .disabled(isSyncingMgmt(sprayEquipmentSync.syncStatus))
                VineyardSyncStatusRow(label: "spray equipment", state: mgmtStateFrom(sprayEquipmentSync.syncStatus, lastSync: sprayEquipmentSync.lastSyncDate))

                Button {
                    Task { await tractorSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Tractors", icon: "car.fill", isSyncing: isSyncingMgmt(tractorSync.syncStatus))
                }
                .disabled(isSyncingMgmt(tractorSync.syncStatus))
                VineyardSyncStatusRow(label: "tractors", state: mgmtStateFrom(tractorSync.syncStatus, lastSync: tractorSync.lastSyncDate))
                TractorSyncDiagnosticsRows()

                Button {
                    Task { await vineyardMachineSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Vineyard Machines", icon: "gearshape.2.fill", isSyncing: isSyncingMgmt(vineyardMachineSync.syncStatus))
                }
                .disabled(isSyncingMgmt(vineyardMachineSync.syncStatus))
                VineyardSyncStatusRow(label: "vineyard machines", state: mgmtStateFrom(vineyardMachineSync.syncStatus, lastSync: vineyardMachineSync.lastSyncDate))

                Button {
                    Task { await fuelPurchaseSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Fuel Purchases", icon: "fuelpump.fill", isSyncing: isSyncingMgmt(fuelPurchaseSync.syncStatus))
                }
                .disabled(isSyncingMgmt(fuelPurchaseSync.syncStatus))
                VineyardSyncStatusRow(label: "fuel purchases", state: mgmtStateFrom(fuelPurchaseSync.syncStatus, lastSync: fuelPurchaseSync.lastSyncDate))

                Button {
                    Task { await tractorFuelLogSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Fuel Logs", icon: "gauge.with.needle", isSyncing: isSyncingMgmt(tractorFuelLogSync.syncStatus))
                }
                .disabled(isSyncingMgmt(tractorFuelLogSync.syncStatus))
                VineyardSyncStatusRow(label: "fuel logs", state: mgmtStateFrom(tractorFuelLogSync.syncStatus, lastSync: tractorFuelLogSync.lastSyncDate))

                Button {
                    Task { await operatorCategorySync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Operator Categories", icon: "person.2.fill", isSyncing: isSyncingMgmt(operatorCategorySync.syncStatus))
                }
                .disabled(isSyncingMgmt(operatorCategorySync.syncStatus))
                VineyardSyncStatusRow(label: "operator categories", state: mgmtStateFrom(operatorCategorySync.syncStatus, lastSync: operatorCategorySync.lastSyncDate))

                Button {
                    Task { await workTaskTypeSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Work Task Types", icon: "tag.fill", isSyncing: isSyncingMgmt(workTaskTypeSync.syncStatus))
                }
                .disabled(isSyncingMgmt(workTaskTypeSync.syncStatus))
                VineyardSyncStatusRow(label: "work task types", state: mgmtStateFrom(workTaskTypeSync.syncStatus, lastSync: workTaskTypeSync.lastSyncDate))

                Button {
                    Task { await savedInputSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Saved Inputs", icon: "leaf.fill", isSyncing: isSyncingMgmt(savedInputSync.syncStatus))
                }
                .disabled(isSyncingMgmt(savedInputSync.syncStatus))
                VineyardSyncStatusRow(label: "saved inputs", state: mgmtStateFrom(savedInputSync.syncStatus, lastSync: savedInputSync.lastSyncDate))

                Button {
                    Task { await tripCostAllocationSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Cost Allocations", icon: "dollarsign.circle.fill", isSyncing: isSyncingMgmt(tripCostAllocationSync.syncStatus))
                }
                .disabled(isSyncingMgmt(tripCostAllocationSync.syncStatus))
                VineyardSyncStatusRow(label: "cost allocations", state: mgmtStateFrom(tripCostAllocationSync.syncStatus, lastSync: tripCostAllocationSync.lastSyncDate))
            } header: {
                Text("Spray Management")
            } footer: {
                Text("Saved chemicals, presets, equipment, tractors, fuel and operator categories sync across vineyard members.")
            }

            Section {
                Button {
                    Task { await workTaskSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Work Tasks", icon: "person.2.badge.gearshape.fill", isSyncing: isSyncingOps(workTaskSync.syncStatus))
                }
                .disabled(isSyncingOps(workTaskSync.syncStatus))
                VineyardSyncStatusRow(label: "work tasks", state: opsStateFrom(workTaskSync.syncStatus, lastSync: workTaskSync.lastSyncDate))

                Button {
                    Task { await workTaskLabourLineSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Work Task Labour Lines", icon: "clock.badge.checkmark.fill", isSyncing: isSyncingOps(workTaskLabourLineSync.syncStatus))
                }
                .disabled(isSyncingOps(workTaskLabourLineSync.syncStatus))
                VineyardSyncStatusRow(label: "work task labour lines", state: opsStateFrom(workTaskLabourLineSync.syncStatus, lastSync: workTaskLabourLineSync.lastSyncDate))

                Button {
                    Task { await workTaskPaddockSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Work Task Paddocks", icon: "square.grid.2x2", isSyncing: isSyncingOps(workTaskPaddockSync.syncStatus))
                }
                .disabled(isSyncingOps(workTaskPaddockSync.syncStatus))
                VineyardSyncStatusRow(label: "work task paddocks", state: opsStateFrom(workTaskPaddockSync.syncStatus, lastSync: workTaskPaddockSync.lastSyncDate))

                Button {
                    Task { await maintenanceLogSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Maintenance Logs", icon: "wrench.and.screwdriver.fill", isSyncing: isSyncingOps(maintenanceLogSync.syncStatus))
                }
                .disabled(isSyncingOps(maintenanceLogSync.syncStatus))
                VineyardSyncStatusRow(label: "maintenance logs", state: opsStateFrom(maintenanceLogSync.syncStatus, lastSync: maintenanceLogSync.lastSyncDate))

                Button {
                    Task { await yieldSessionSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Yield Sessions", icon: "chart.bar.fill", isSyncing: isSyncingOps(yieldSessionSync.syncStatus))
                }
                .disabled(isSyncingOps(yieldSessionSync.syncStatus))
                VineyardSyncStatusRow(label: "yield sessions", state: opsStateFrom(yieldSessionSync.syncStatus, lastSync: yieldSessionSync.lastSyncDate))

                Button {
                    Task { await damageRecordSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Damage Records", icon: "exclamationmark.triangle.fill", isSyncing: isSyncingOps(damageRecordSync.syncStatus))
                }
                .disabled(isSyncingOps(damageRecordSync.syncStatus))
                VineyardSyncStatusRow(label: "damage records", state: opsStateFrom(damageRecordSync.syncStatus, lastSync: damageRecordSync.lastSyncDate))

                Button {
                    Task { await historicalYieldSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Historical Yields", icon: "calendar.badge.clock", isSyncing: isSyncingOps(historicalYieldSync.syncStatus))
                }
                .disabled(isSyncingOps(historicalYieldSync.syncStatus))
                VineyardSyncStatusRow(label: "historical yields", state: opsStateFrom(historicalYieldSync.syncStatus, lastSync: historicalYieldSync.lastSyncDate))
            } header: {
                Text("Operations")
            } footer: {
                Text("Work tasks, maintenance logs, yield sessions, damage records and historical yields sync across vineyard members.")
            }

            Section {
                Button {
                    Task { await growthStageImageSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Growth Stage Images", icon: "photo.on.rectangle", isSyncing: isSyncingMgmt(growthStageImageSync.syncStatus))
                }
                .disabled(isSyncingMgmt(growthStageImageSync.syncStatus))
                VineyardSyncStatusRow(label: "E-L stage images", state: mgmtStateFrom(growthStageImageSync.syncStatus, lastSync: growthStageImageSync.lastSyncDate))
            } header: {
                Text("Reference Images")
            } footer: {
                Text("Custom E-L growth stage reference images are shared with all vineyard members. Pin photos sync automatically with each pin.")
            }

            Section {
                Button {
                    Task { await growthStageRecordSync.syncForSelectedVineyard() }
                } label: {
                    syncButtonLabel(title: "Sync Growth Stage Records", icon: "leaf.fill", isSyncing: isSyncingGrowthRecord(growthStageRecordSync.syncStatus))
                }
                .disabled(isSyncingGrowthRecord(growthStageRecordSync.syncStatus))
                VineyardSyncStatusRow(label: "growth stage records", state: growthRecordStateFrom(growthStageRecordSync.syncStatus, lastSync: growthStageRecordSync.lastSyncDate))
                HStack {
                    Text("Local records")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(growthStageRecordSync.records.filter { $0.vineyardId == store.selectedVineyardId }.count)")
                        .font(.footnote.monospacedDigit())
                }
                HStack {
                    Text("Pending upload / delete")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(growthStageRecordSync.pendingUpsertCount) / \(growthStageRecordSync.pendingDeleteCount)")
                        .font(.footnote.monospacedDigit())
                }
            } header: {
                Text("Growth Stage Records")
            } footer: {
                Text("E-L growth observations. Mirrored from growth-stage pins via pin_id for back-compat, plus any records added directly. Shared with all vineyard members.")
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Overall status header

    private var statusSection: some View {
        let state = syncCenter.displayState(isOnline: network.isOnline)
        return Section {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol(state))
                    .font(.title3)
                    .foregroundStyle(statusTint(state))
                    .symbolEffect(.pulse, options: .repeating, isActive: state == .syncing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(syncCenter.label(isOnline: network.isOnline))
                        .font(.subheadline.weight(.semibold))
                    Text(network.isOnline ? "Connected" : "No network — changes are saved on this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)

            LabeledContent("Pending uploads", value: "\(syncCenter.pendingUpserts)")
                .font(.footnote)
            LabeledContent("Pending deletes", value: "\(syncCenter.pendingDeletes)")
                .font(.footnote)
            if let retrySummary = syncCenter.retrySummary {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                    Text(retrySummary)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("Last full sync", value: syncCenter.lastFullSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                .font(.footnote)
            if syncCenter.lastSuccessfulSyncAt != syncCenter.lastFullSyncAt {
                LabeledContent("Last successful sync", value: syncCenter.lastSuccessfulSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                    .font(.footnote)
            }
            if let error = syncCenter.lastError {
                LabeledContent("Last sync error", value: error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                syncCenter.requestManualSync()
            } label: {
                HStack {
                    Label(syncCenter.isSyncing ? "Syncing…" : "Refresh & sync now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if syncCenter.isSyncing { ProgressView() }
                }
            }
            .disabled(syncCenter.isSyncing || !network.isOnline)
        } header: {
            Text("Status")
        } footer: {
            Text(network.isOnline
                 ? "Everything you record is queued and uploaded automatically. Tap Refresh & sync now to push immediately."
                 : "You're offline. Records keep saving locally and will sync as soon as you reconnect.")
        }
    }

    private func statusSymbol(_ state: SyncStatusCenter.DisplayState) -> String {
        switch state {
        case .offline: return "wifi.slash"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .pending: return "clock.arrow.circlepath"
        case .synced: return "checkmark.icloud.fill"
        }
    }

    private func statusTint(_ state: SyncStatusCenter.DisplayState) -> Color {
        switch state {
        case .offline: return .secondary
        case .syncing: return .blue
        case .error: return .red
        case .pending: return .orange
        case .synced: return .green
        }
    }

    private func syncButtonLabel(title: String, icon: String, isSyncing: Bool) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
            Spacer()
            if isSyncing { ProgressView() }
        }
    }

    private func isSyncing(_ status: PinSyncService.Status) -> Bool { if case .syncing = status { return true }; return false }
    private func isSyncing(_ status: PaddockSyncService.Status) -> Bool { if case .syncing = status { return true }; return false }
    private func isSyncing(_ status: TripSyncService.Status) -> Bool { if case .syncing = status { return true }; return false }
    private func isSyncing(_ status: SprayRecordSyncService.Status) -> Bool { if case .syncing = status { return true }; return false }
    private func isSyncing(_ status: ButtonConfigSyncService.Status) -> Bool { if case .syncing = status { return true }; return false }

    private func pinStateFrom(_ status: PinSyncService.Status, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }
    private func tripStateFrom(_ status: TripSyncService.Status, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }
    private func paddockStateFrom(_ status: PaddockSyncService.Status, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }
    private func sprayStateFrom(_ status: SprayRecordSyncService.Status, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }
    private func buttonConfigStateFrom(_ status: ButtonConfigSyncService.Status, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }

    private func isSyncingMgmt(_ status: ManagementSyncStatus) -> Bool {
        if case .syncing = status { return true }
        return false
    }

    private func mgmtStateFrom(_ status: ManagementSyncStatus, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }

    private func isSyncingGrowthRecord(_ status: GrowthStageRecordSyncService.Status) -> Bool {
        if case .syncing = status { return true }
        return false
    }

    private func growthRecordStateFrom(_ status: GrowthStageRecordSyncService.Status, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }

    private func isSyncingOps(_ status: OperationsSyncStatus) -> Bool {
        if case .syncing = status { return true }
        return false
    }

    private func opsStateFrom(_ status: OperationsSyncStatus, lastSync: Date?) -> VineyardSyncState {
        switch status {
        case .idle: return .idle
        case .syncing: return .syncing
        case .success: return .success(lastSync)
        case .failure(let m): return .failure(m)
        }
    }
}

/// Compact diagnostics rows for the Tractor sync service. Shows the
/// local active-tractor count for the selected vineyard, a fetched
/// remote count, and the pending upsert/delete queue depth.
private struct TractorSyncDiagnosticsRows: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(TractorSyncService.self) private var tractorSync
    @State private var remoteCount: Int?
    @State private var isFetching: Bool = false

    var body: some View {
        Group {
            HStack {
                Text("Local tractors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(localCount)")
                    .font(.footnote.monospacedDigit())
            }
            HStack {
                Text("Remote tractors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if isFetching {
                    ProgressView()
                } else if let remoteCount {
                    Text("\(remoteCount)")
                        .font(.footnote.monospacedDigit())
                } else {
                    Text("—")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await refreshRemote() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .disabled(isFetching || store.selectedVineyardId == nil)
            }
            HStack {
                Text("Pending upload / delete")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(tractorSync.pendingUpsertCount) / \(tractorSync.pendingDeleteCount)")
                    .font(.footnote.monospacedDigit())
            }
        }
        .task(id: store.selectedVineyardId) {
            await refreshRemote()
        }
    }

    private var localCount: Int {
        guard let vid = store.selectedVineyardId else { return 0 }
        return store.tractors.filter { $0.vineyardId == vid }.count
    }

    private func refreshRemote() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        remoteCount = await tractorSync.fetchRemoteCountForSelectedVineyard()
    }
}

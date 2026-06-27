import SwiftUI

struct DashboardView: View {
    @Environment(DataStore.self) private var store
    @Environment(AuthService.self) private var authService
    @Environment(\.accessControl) private var accessControl

    @State private var showPinDrop: Bool = false
    @State private var pinDropMode: PinMode = .repairs
    @State private var showYieldHub: Bool = false
    @State private var showGrowthStageReport: Bool = false
    @State private var showTripTypeChoice: Bool = false
    @State private var showStartSheet: Bool = false
    @State private var showSprayTripSetup: Bool = false
    @State private var showSprayCalculator: Bool = false
    @State private var showVineyardDetails: Bool = false
    @State private var showMaintenanceLog: Bool = false
    @State private var showWorkTasks: Bool = false
    @State private var showYieldDeterminationCalculator: Bool = false
    @State private var showIrrigationRecommendation: Bool = false
    @State private var showAuditLog: Bool = false
    @State private var showManageUsers: Bool = false
    @State private var showVineyardSetup: Bool = false

    private var vineyard: Vineyard? { store.selectedVineyard }

    // MARK: - Role helpers

    private var isManager: Bool { accessControl?.isManager ?? false }
    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }
    private var isOperator: Bool { accessControl?.isOperator ?? true }

    private var roleTitle: String {
        guard let role = accessControl?.currentUserRole else { return "" }
        return role.displayName
    }

    // MARK: - Derived data

    private var totalAreaHa: Double {
        store.paddocks.reduce(0) { $0 + $1.areaHectares }
    }

    private var totalVines: Int {
        store.paddocks.reduce(0) { $0 + $1.effectiveVineCount }
    }

    private var unresolvedPins: [VinePin] {
        store.pins.filter { !$0.isCompleted && $0.mode == .repairs }
    }

    private var lastCompletedTrip: Trip? {
        store.trips.filter { !$0.isActive }.sorted { $0.startTime > $1.startTime }.first
    }

    private var lastSprayRecord: SprayRecord? {
        store.sprayRecords.filter { !$0.isTemplate }.sorted { $0.date > $1.date }.first
    }

    private var activeTrip: Trip? { store.activeTrip }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    todaySection
                    if isManager {
                        vineyardOverviewCard
                    }
                    quickActionsSection
                    operationalToolsSection
                    if isManager {
                        managementToolsSection
                    }
                    recentActivitySection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if let logoData = vineyard?.logoData,
                           let uiImage = UIImage(data: logoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 28, height: 28)
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        Text(vineyard?.name ?? "VineTrack")
                            .font(.headline)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showPinDrop) {
                PinDropView(initialMode: pinDropMode)
            }
            .navigationDestination(isPresented: $showYieldHub) {
                YieldHubView()
            }
            .navigationDestination(isPresented: $showGrowthStageReport) {
                GrowthStageReportView()
            }
            .navigationDestination(isPresented: $showVineyardDetails) {
                VineyardDetailsView()
            }
            .navigationDestination(isPresented: $showMaintenanceLog) {
                MaintenanceLogListView()
            }
            .navigationDestination(isPresented: $showWorkTasks) {
                WorkTasksHubView()
            }
            .navigationDestination(isPresented: $showYieldDeterminationCalculator) {
                YieldDeterminationCalculatorView()
            }
            .navigationDestination(isPresented: $showIrrigationRecommendation) {
                IrrigationRecommendationView()
            }
            .navigationDestination(isPresented: $showAuditLog) {
                AuditLogView()
            }
            .navigationDestination(isPresented: $showVineyardSetup) {
                VineyardSetupSettingsView()
            }
            .sheet(isPresented: $showTripTypeChoice) {
                TripTypeChoiceSheet { tripType in
                    showTripTypeChoice = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        switch tripType {
                        case .maintenance:
                            showStartSheet = true
                        case .spray:
                            showSprayTripSetup = true
                        }
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showStartSheet) {
                StartTripSheet()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSprayTripSetup) {
                SprayTripSetupSheet(
                    onSelectProgram: { _ in
                        showSprayCalculator = true
                    },
                    onCreateNew: {
                        showSprayCalculator = true
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSprayCalculator, onDismiss: {
                showSprayTripSetup = false
            }) {
                SprayCalculatorView()
            }
            .sheet(isPresented: $showManageUsers) {
                if let vineyard {
                    VineyardDetailSheet(vineyard: vineyard)
                }
            }
        }
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.title2.weight(.bold))
                Spacer()
                if !roleTitle.isEmpty {
                    Text(roleTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }

            VStack(spacing: 10) {
                if let trip = activeTrip {
                    activeTripCard(trip: trip)
                }

                if !unresolvedPins.isEmpty {
                    attentionCard(
                        icon: "mappin.circle.fill",
                        color: .red,
                        title: "\(unresolvedPins.count) pin\(unresolvedPins.count == 1 ? "" : "s") need attention",
                        subtitle: "Repairs pending across your blocks"
                    ) {
                        store.selectedTab = 1
                    }
                }

                if activeTrip == nil && unresolvedPins.isEmpty {
                    allClearCard
                }
            }
        }
    }

    private func activeTripCard(trip: Trip) -> some View {
        Button {
            store.selectedTab = 2
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "steeringwheel")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("Trip Active")
                            .font(.subheadline.weight(.bold))
                    }
                    Text(trip.paddockName.isEmpty ? "In progress" : trip.paddockName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func attentionCard(icon: String, color: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var allClearCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(VineyardTheme.leafGreen.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear")
                    .font(.subheadline.weight(.semibold))
                Text("No pins need attention right now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                quickActionButton(
                    title: "Repairs",
                    icon: "wrench.fill",
                    gradient: [Color.orange, Color.orange.opacity(0.8)]
                ) {
                    pinDropMode = .repairs
                    showPinDrop = true
                }

                quickActionButton(
                    title: "Growth",
                    iconView: AnyView(
                        GrapeLeafIcon(size: 22)
                            .foregroundStyle(.white)
                    ),
                    gradient: [VineyardTheme.leafGreen, VineyardTheme.olive]
                ) {
                    pinDropMode = .growth
                    showPinDrop = true
                }

                quickActionButton(
                    title: activeTrip != nil ? "Live Trip" : "Start Trip",
                    icon: "steeringwheel",
                    gradient: [Color.blue, Color.blue.opacity(0.8)]
                ) {
                    if activeTrip != nil {
                        store.selectedTab = 2
                    } else {
                        showTripTypeChoice = true
                    }
                }

                // Spray Program — Supervisor+ (Operators don't plan sprays)
                if !isOperator {
                    quickActionButton(
                        title: "Spray Program",
                        icon: "sprinkler.and.droplets.fill",
                        gradient: [Color.purple, Color.purple.opacity(0.8)]
                    ) {
                        store.selectedTab = 3
                    }
                }
            }
        }
    }

    private func quickActionButton(
        title: String,
        icon: String? = nil,
        iconView: AnyView? = nil,
        gradient: [Color],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let iconView {
                    iconView
                } else if let icon {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Operational Tools

    private var operationalToolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isOperator ? "My Work" : "Operational Tools")
                .font(.headline)

            // Operators: keep it focused — Work Tasks, Maintenance Log, Growth Stage Report
            // Supervisors: add Yield Estimation + Irrigation + Yield Determination (operational reports)
            // Managers: also get these; admin/setup moved to Management Tools below

            HStack(spacing: 12) {
                toolCard(
                    title: "Work Tasks",
                    subtitle: workTasksSubtitle,
                    icon: "person.2.badge.gearshape.fill",
                    color: .indigo
                ) {
                    showWorkTasks = true
                }

                toolCard(
                    title: "Maintenance Log",
                    subtitle: maintenanceLogSubtitle,
                    icon: "wrench.and.screwdriver.fill",
                    color: VineyardTheme.earthBrown
                ) {
                    showMaintenanceLog = true
                }
            }

            if !isOperator {
                HStack(spacing: 12) {
                    toolCard(
                        title: "Growth Stage Report",
                        subtitle: growthReportSubtitle,
                        icon: "chart.line.uptrend.xyaxis",
                        color: VineyardTheme.leafGreen
                    ) {
                        showGrowthStageReport = true
                    }

                    toolCard(
                        title: "Yield Estimation",
                        subtitle: yieldToolSubtitle,
                        icon: "chart.bar.fill",
                        color: .orange
                    ) {
                        showYieldHub = true
                    }
                }

                HStack(spacing: 12) {
                    toolCard(
                        title: "Irrigation Advisor",
                        subtitle: "5-day runtime recommendation",
                        icon: "drop.fill",
                        color: .cyan
                    ) {
                        showIrrigationRecommendation = true
                    }

                    toolCard(
                        title: "Yield Determination",
                        subtitle: "Calculate yield per ha",
                        icon: "scalemass.fill",
                        color: .purple
                    ) {
                        showYieldDeterminationCalculator = true
                    }
                }
            } else {
                // Operators: growth report + yield estimation (they do the collection)
                HStack(spacing: 12) {
                    toolCard(
                        title: "Growth Stage Report",
                        subtitle: growthReportSubtitle,
                        icon: "chart.line.uptrend.xyaxis",
                        color: VineyardTheme.leafGreen
                    ) {
                        showGrowthStageReport = true
                    }

                    toolCard(
                        title: "Yield Estimation",
                        subtitle: yieldToolSubtitle,
                        icon: "chart.bar.fill",
                        color: .orange
                    ) {
                        showYieldHub = true
                    }
                }
            }
        }
    }

    // MARK: - Management Tools (Manager/Owner only)

    private var managementToolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Management")
                .font(.headline)

            HStack(spacing: 12) {
                toolCard(
                    title: "Manage Users",
                    subtitle: usersSubtitle,
                    icon: "person.2.fill",
                    color: .blue
                ) {
                    showManageUsers = true
                }

                toolCard(
                    title: "Vineyard Setup",
                    subtitle: "Blocks, tracking & defaults",
                    icon: "gearshape.2.fill",
                    color: .gray
                ) {
                    showVineyardSetup = true
                }
            }

            HStack(spacing: 12) {
                toolCard(
                    title: "Audit Log",
                    subtitle: "Sensitive actions history",
                    icon: "doc.text.magnifyingglass",
                    color: .pink
                ) {
                    showAuditLog = true
                }

                toolCard(
                    title: "Full Overview",
                    subtitle: financialOverviewSubtitle,
                    icon: "chart.pie.fill",
                    color: VineyardTheme.olive
                ) {
                    showVineyardDetails = true
                }
            }
        }
    }

    private var vineyardOverviewCard: some View {
        Button {
            showVineyardDetails = true
        } label: {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vineyard Overview")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                        if let name = vineyard?.name, !name.isEmpty {
                            Text(name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 16)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    summaryMetric(
                        value: "\(store.paddocks.count)",
                        label: "Blocks",
                        icon: "square.grid.2x2",
                        color: VineyardTheme.olive
                    )
                    summaryMetric(
                        value: String(format: "%.1f", totalAreaHa),
                        label: "Hectares",
                        icon: "map",
                        color: VineyardTheme.leafGreen
                    )
                    summaryMetric(
                        value: formatVineCount(totalVines),
                        label: "Vines",
                        icon: "leaf",
                        color: VineyardTheme.earthBrown
                    )
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var usersSubtitle: String {
        let count = vineyard?.users.count ?? 0
        return "\(count) user\(count == 1 ? "" : "s")"
    }

    private var financialOverviewSubtitle: String {
        canViewFinancials ? "Costs & totals" : "Blocks & summaries"
    }

    // MARK: - Shared components

    private func summaryMetric(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func toolCard(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color.opacity(0.8))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 170)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subtitles

    private var yieldToolSubtitle: String {
        let sessions = store.yieldSessions
        guard !sessions.isEmpty else { return "No estimates yet" }
        let blocksWithData = Set(sessions.flatMap(\.selectedPaddockIds)).count
        return "\(blocksWithData) block\(blocksWithData == 1 ? "" : "s") estimated"
    }

    private var growthReportSubtitle: String {
        let growthPins = store.pins.filter { $0.growthStageCode != nil }
        guard !growthPins.isEmpty else { return "No data recorded" }
        return "\(growthPins.count) observation\(growthPins.count == 1 ? "" : "s")"
    }

    private var workTasksSubtitle: String {
        let tasks = store.workTasks
        guard !tasks.isEmpty else { return "Log & calculate" }
        if canViewFinancials {
            let total = tasks.reduce(0) { $0 + $1.totalCost }
            let currencyCode = Locale.current.currency?.identifier ?? "USD"
            return "\(tasks.count) task\(tasks.count == 1 ? "" : "s") \u{2022} \(total.formatted(.currency(code: currencyCode)))"
        }
        return "\(tasks.count) task\(tasks.count == 1 ? "" : "s") logged"
    }

    private var maintenanceLogSubtitle: String {
        let logs = store.maintenanceLogs
        guard !logs.isEmpty else { return "No records yet" }
        if canViewFinancials {
            let total = logs.reduce(0) { $0 + $1.totalCost }
            let currencyCode = Locale.current.currency?.identifier ?? "USD"
            return "\(logs.count) record\(logs.count == 1 ? "" : "s") \u{2022} \(total.formatted(.currency(code: currencyCode)))"
        }
        return "\(logs.count) record\(logs.count == 1 ? "" : "s")"
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.headline)

            VStack(spacing: 10) {
                if let trip = lastCompletedTrip {
                    recentRow(
                        icon: "steeringwheel",
                        iconColor: .blue,
                        title: "Last Trip",
                        detail: trip.paddockName.isEmpty ? "Trip" : trip.paddockName,
                        time: trip.endTime ?? trip.startTime,
                        distance: trip.totalDistance
                    )
                }

                if let spray = lastSprayRecord, !isOperator {
                    recentRow(
                        icon: "sprinkler.and.droplets.fill",
                        iconColor: .purple,
                        title: "Last Spray",
                        detail: spray.sprayReference.isEmpty ? "Spray Record" : spray.sprayReference,
                        time: spray.date,
                        distance: nil
                    )
                }

                if lastCompletedTrip == nil && (lastSprayRecord == nil || isOperator) {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("No recent activity")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 24)
                        Spacer()
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
            }
        }
    }

    private func recentRow(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        time: Date,
        distance: Double?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.1), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let distance, distance > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(String(format: "%.1f km", distance / 1000))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(time, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Helpers

    private func formatVineCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

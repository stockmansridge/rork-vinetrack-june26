import SwiftUI

struct AlertsCentreView: View {
    @Environment(AlertService.self) private var alertService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(\.dismiss) private var dismiss

    @State private var isRefreshing: Bool = false
    @State private var pushDestination: AlertPushDestination?
    @State private var showInfo: Bool = false

    var body: some View {
        List {
            if alertService.activeAlerts.isEmpty {
                Section {
                    emptyState
                }
                if alertService.lastRefresh != nil {
                    lastCheckedSection
                }
            } else {
                Section {
                    ForEach(alertService.activeAlerts) { item in
                        Button {
                            Task { await alertService.markRead(item) }
                            handleAction(item.alert)
                        } label: {
                            AlertRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await alertService.dismiss(item) }
                            } label: {
                                Label("Dismiss", systemImage: "xmark.circle")
                            }
                            if !item.isRead {
                                Button {
                                    Task { await alertService.markRead(item) }
                                } label: {
                                    Label("Read", systemImage: "envelope.open")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Active alerts (\(alertService.activeAlerts.count))")
                        Spacer()
                        if !alertService.unreadAlerts.isEmpty {
                            Button("Mark all read") {
                                Task { await alertService.markAllRead() }
                            }
                            .font(.caption)
                        }
                    }
                }
                lastCheckedSection
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About alerts")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if accessControl.canChangeSettings {
                    NavigationLink {
                        AlertSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            AlertsInfoSheet()
        }
        .refreshable {
            await alertService.generateAndRefresh()
        }
        .task {
            await alertService.generateAndRefresh()
        }
        .navigationDestination(item: $pushDestination) { dest in
            switch dest {
            case .irrigation, .weather:
                IrrigationRecommendationView()
            
            case .disease:
                DiseaseRiskAdvisorView()
            case .workTasks:
                WorkTasksHubView()
            case .paddocks:
                VineyardSetupHubView()
            case .costReports:
                CostReportsView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Your vineyard is up to date")
                .font(.headline)
            Text("We'll flag irrigation needs, aged pins, spray jobs and weather risks here.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    @ViewBuilder
    private var lastCheckedSection: some View {
        if let last = alertService.lastRefresh {
            Section {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.tertiary)
                    Text("Last checked \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private func handleAction(_ alert: BackendAlert) {
        guard let action = alert.typedAction else { return }
        switch action {
        case .openPins, .openSprayProgram, .openSprayRecord:
            // Tab switches handled by NewMainTabView; pop back to home root.
            alertService.pendingNavigation = action
            dismiss()
        case .openWorkTasks:
            pushDestination = .workTasks
        case .openPaddocks:
            pushDestination = .paddocks
        case .openIrrigationAdvisor:
            pushDestination = .irrigation
        case .openWeather:
            // Weather/rain alerts route to Irrigation Advisor (which
            // shows current weather + rainfall) until a dedicated
            // weather hub exists. Falls back gracefully without
            // breaking navigation.
            pushDestination = .weather
        case .openDiseaseRisk:
            pushDestination = .disease
        case .openCostReports:
            pushDestination = .costReports
        }
    }
}

private enum AlertPushDestination: Identifiable, Hashable {
    case irrigation
    case weather
    case disease
    case workTasks
    case paddocks
    case costReports
    var id: String {
        switch self {
        case .irrigation: return "irrigation"
        case .weather: return "weather"
        case .disease: return "disease"
        case .workTasks: return "workTasks"
        case .paddocks: return "paddocks"
        case .costReports: return "costReports"
        }
    }
}

private struct AlertRow: View {
    let item: AlertWithStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(severityColor.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: severityIcon)
                    .foregroundStyle(severityColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.alert.title)
                        .font(.subheadline.weight(item.isRead ? .regular : .semibold))
                        .foregroundStyle(.primary)
                    if !item.isRead {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(item.alert.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if let badge = sourceBadge {
                    HStack(spacing: 4) {
                        Image(systemName: badge.icon)
                            .font(.caption2)
                        Text(badge.label)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
                    .help(badge.help)
                }
                HStack(spacing: 8) {
                    if let label = actionLabel {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                            Text(label)
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(severityColor)
                    }
                    if let date = item.alert.createdAt {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private struct SourceBadge {
        let icon: String
        let label: String
        let help: String
    }

    private var sourceBadge: SourceBadge? {
        switch item.alert.typedAlertType {
        case .diseaseDownyMildew, .diseaseBotrytis:
            let msg = item.alert.message.lowercased()
            if msg.contains("measured leaf wetness") && !msg.contains("no measured") {
                return SourceBadge(
                    icon: "drop.degreesign",
                    label: "Measured wetness",
                    help: "Risk uses measured leaf wetness from a connected station."
                )
            }
            return SourceBadge(
                icon: "drop.degreesign",
                label: "Estimated wetness",
                help: "Estimated wetness uses rain, humidity and dew point spread as a proxy."
            )
        case .diseasePowderyMildew:
            return SourceBadge(
                icon: "thermometer.sun",
                label: "Temp + RH model",
                help: "Powdery risk is driven by 21–30°C hours and humidity ≥ 60%."
            )
        default:
            return nil
        }
    }

    private var actionLabel: String? {
        switch item.alert.typedAction {
        case .openIrrigationAdvisor: return "Open Irrigation Advisor"
        case .openWeather: return "Open Weather"
        case .openPins: return "View Pins"
        case .openSprayProgram: return "Open Spray Program"
        case .openSprayRecord: return "Open Spray Record"
        case .openDiseaseRisk: return "Open Disease Risk"
        case .openWorkTasks: return "Open Work Tasks"
        case .openPaddocks: return "Open Blocks"
        case .openCostReports: return "Open Cost Reports"
        case .none: return nil
        }
    }

    private var severityColor: Color {
        switch item.alert.typedSeverity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var severityIcon: String {
        switch item.alert.typedAlertType {
        case .irrigationNeeded: return "drop.fill"
        case .agedPins: return "mappin.and.ellipse"
        case .weatherRisk: return "cloud.rain.fill"
        case .sprayJobDue: return "sprinkler.and.droplets.fill"
        case .syncIssue: return "exclamationmark.icloud"
        case .diseaseDownyMildew: return "leaf.fill"
        case .diseasePowderyMildew: return "aqi.medium"
        case .diseaseBotrytis: return "allergens"
        case .rainStarted: return "cloud.rain.fill"
        case .rain24hSummary: return "cloud.heavyrain.fill"
        case .rainTodayThresholdExceeded: return "drop.degreesign.fill"
        case .workTaskOverdue: return "person.2.badge.gearshape.fill"
        case .manyOpenPins: return "mappin.and.ellipse"
        case .forecastSetupMissingGeometry: return "map"
        case .costingSetupIncomplete: return "dollarsign.circle"
        case .none: return "bell.fill"
        }
    }
}

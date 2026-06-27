import SwiftUI

/// Compact alerts summary shown in the Home → Today section.
///
/// When there are active alerts, displays a header row with overall severity
/// and count plus an inline preview of the top 3 alerts (sorted by severity
/// then newest). When there are no alerts, shows a clear "All clear" empty
/// state so the user is never left wondering whether the system is running.
struct HomeAlertsCard: View {
    @Environment(AlertService.self) private var alertService

    private let maxPreviewRows: Int = 3

    var body: some View {
        // Only surface the alerts card on Home when there are active alerts
        // that need attention. "All clear" wastes vertical space and hides
        // genuine signal.
        if hasAlerts {
            NavigationLink {
                AlertsCentreView()
            } label: {
                headerRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: iconName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let secondary = secondaryText {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if alertService.unreadAlerts.count > 0 && hasAlerts {
                Text("\(alertService.unreadAlerts.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.15), in: Capsule())
            }
            Text("View")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Preview row

    private func alertPreviewRow(_ item: AlertWithStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(severityColor(item.alert.typedSeverity))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.alert.title)
                    .font(.caption.weight(item.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.alert.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Computed

    private var previewAlerts: [AlertWithStatus] {
        let sorted = alertService.activeAlerts.sorted { lhs, rhs in
            if lhs.alert.typedSeverity != rhs.alert.typedSeverity {
                return lhs.alert.typedSeverity > rhs.alert.typedSeverity
            }
            return (lhs.alert.createdAt ?? .distantPast) > (rhs.alert.createdAt ?? .distantPast)
        }
        return Array(sorted.prefix(maxPreviewRows))
    }

    private var hasAlerts: Bool { !alertService.activeAlerts.isEmpty }

    private var tint: Color {
        switch alertService.highestSeverity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        case .none: return .green
        }
    }

    private var iconName: String {
        hasAlerts ? "bell.badge.fill" : "checkmark.seal.fill"
    }

    private var primaryText: String {
        let active = alertService.activeAlerts
        if active.isEmpty { return "All clear" }
        if active.count == 1 { return "1 alert needs attention" }
        return "\(active.count) alerts need attention"
    }

    private var secondaryText: String? {
        let active = alertService.activeAlerts
        if active.isEmpty {
            return "No active alerts for this vineyard"
        }
        let summary = summaryByType(active)
        guard !summary.isEmpty else { return nil }
        return summary.prefix(2).joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        let active = alertService.activeAlerts.count
        return active == 0 ? "All clear, no active alerts" : "\(active) alerts need attention"
    }

    private func severityColor(_ s: AlertSeverity) -> Color {
        switch s {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

}

struct AlertsInfoSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(AlertService.self) private var alertService

        var body: some View {
            NavigationStack {
                List {
                    Section("What shows up here") {
                        infoRow(
                            icon: "cloud.rain.fill",
                            tint: .blue,
                            title: "Rain forecast",
                            detail: "Days within your forecast window where forecast rainfall meets the rain threshold."
                        )
                        infoRow(
                            icon: "drop.degreesign.fill",
                            tint: .blue,
                            title: "Rain recorded today",
                            detail: "Today's recorded rainfall (from your station, persisted daily row, or forecast fallback) meets the rain threshold."
                        )
                        infoRow(
                            icon: "cloud.bolt.rain.fill",
                            tint: .blue,
                            title: "Rain started / recorded",
                            detail: "Rain currently falling at your station, plus a 9 AM summary of the past 24 hours."
                        )
                        infoRow(
                            icon: "wind",
                            tint: .teal,
                            title: "Wind, frost & heat",
                            detail: "Forecast days exceeding your wind, low-temperature (frost) or high-temperature (heat) thresholds."
                        )
                        infoRow(
                            icon: "drop.fill",
                            tint: .cyan,
                            title: "Irrigation",
                            detail: "When the forecast water deficit over the next few days exceeds your irrigation threshold."
                        )
                        infoRow(
                            icon: "leaf.fill",
                            tint: .green,
                            title: "Disease risk",
                            detail: "Downy mildew, powdery mildew and botrytis assessments based on hourly weather and (when available) measured leaf wetness."
                        )
                        infoRow(
                            icon: "mappin.circle.fill",
                            tint: .orange,
                            title: "Aged pins",
                            detail: "Unresolved pins older than your aged-pin threshold."
                        )
                        infoRow(
                            icon: "person.2.badge.gearshape.fill",
                            tint: .indigo,
                            title: "Overdue work tasks",
                            detail: "Work tasks past their scheduled date that haven't been archived or finalised."
                        )
                        infoRow(
                            icon: "sparkles",
                            tint: .purple,
                            title: "Spray jobs due",
                            detail: "Spray records scheduled for today or tomorrow."
                        )
                    }
                    Section("How it works") {
                        Label("Alerts are generated automatically when the app refreshes for the selected vineyard.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                        Label("Thresholds and which alert types are enabled live in Settings → Alerts.", systemImage: "slider.horizontal.3")
                            .font(.footnote)
                        Label("Each day with risks gets its own alert so future rain or weather shows up before it happens.", systemImage: "calendar")
                            .font(.footnote)
                        Label("“All clear” means no enabled rule currently meets its threshold for this vineyard.", systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                    }
                    if let prefs = alertService.preferences {
                        Section("Current thresholds") {
                            thresholdRow("Rain", value: String(format: "≥ %.1f mm/day", prefs.rainAlertThresholdMm), enabled: prefs.weatherAlertsEnabled)
                            thresholdRow("Wind", value: String(format: "≥ %.0f km/h", prefs.windAlertThresholdKmh), enabled: prefs.weatherAlertsEnabled)
                            thresholdRow("Frost", value: String(format: "≤ %.1f°C", prefs.frostAlertThresholdC), enabled: prefs.weatherAlertsEnabled)
                            thresholdRow("Heat", value: String(format: "≥ %.1f°C", prefs.heatAlertThresholdC), enabled: prefs.weatherAlertsEnabled)
                            thresholdRow("Irrigation deficit", value: String(format: "≥ %.1f mm", prefs.irrigationDeficitThresholdMm), enabled: prefs.irrigationAlertsEnabled)
                            thresholdRow("Aged pins", value: "≥ \(prefs.agedPinDays) days", enabled: prefs.agedPinAlertsEnabled)
                            thresholdRow("Forecast window", value: "\(prefs.irrigationForecastDays) days", enabled: prefs.weatherAlertsEnabled || prefs.irrigationAlertsEnabled)
                        }
                    }
                }
                .navigationTitle("About alerts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        .presentationDetents([.medium, .large])
    }

    private func infoRow(icon: String, tint: Color, title: String, detail: String) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, alignment: .center)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        .padding(.vertical, 2)
    }

    private func thresholdRow(_ label: String, value: String, enabled: Bool) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(enabled ? value : "Off")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(enabled ? .primary : .secondary)
        }
    }
}

extension HomeAlertsCard {
    fileprivate func summaryByType(_ items: [AlertWithStatus]) -> [String] {
        var counts: [AlertType: Int] = [:]
        for item in items {
            guard let t = item.alert.typedAlertType else { continue }
            counts[t, default: 0] += 1
        }
        let order: [AlertType] = [
            .rainTodayThresholdExceeded, .rainStarted, .rain24hSummary, .weatherRisk, .irrigationNeeded,
            .agedPins, .manyOpenPins, .workTaskOverdue, .sprayJobDue,
            .diseaseDownyMildew, .diseasePowderyMildew, .diseaseBotrytis,
            .costingSetupIncomplete, .forecastSetupMissingGeometry, .syncIssue
        ]
        return order.compactMap { type in
            guard let n = counts[type], n > 0 else { return nil }
            switch type {
            case .weatherRisk: return "Weather"
            case .irrigationNeeded: return "Irrigation"
            case .agedPins: return "Aged pins"
            case .manyOpenPins: return "Open pins"
            case .costingSetupIncomplete: return "Costing setup"
            case .forecastSetupMissingGeometry: return "Setup needed"
            case .workTaskOverdue: return "Overdue tasks"
            case .sprayJobDue: return "Spray job"
            case .syncIssue: return "Sync"
            case .diseaseDownyMildew: return "Downy mildew"
            case .diseasePowderyMildew: return "Powdery mildew"
            case .diseaseBotrytis: return "Botrytis"
            case .rainStarted: return "Rain started"
            case .rain24hSummary: return "24h rain"
            case .rainTodayThresholdExceeded: return "Rain today"
            }
        }
    }
}

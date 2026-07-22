import SwiftUI

/// System-admin-only diagnostics for the alerts pipeline.
///
/// Visible from Settings → System Admin. Shows exactly what
/// `AlertService.generateAndRefresh` computed so we can see at a glance
/// whether the failure is in: preferences load, generation, Supabase
/// upsert, fetch-back, or the Home UI render. Provides manual buttons to
/// re-run generation, create a harmless test alert, and clear test alerts.
struct AlertDiagnosticsView: View {
    @Environment(AlertService.self) private var alertService
    @Environment(MigratedDataStore.self) private var store
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var isRunning: Bool = false
    @State private var lastAction: String?

    var body: some View {
        Form {
            if !systemAdmin.isSystemAdmin {
                Section {
                    Text("Visible only to VineTrack platform administrators.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            vineyardSection
            preferencesSection
            generationSection
            rainSection
            activeAlertsSection
            actionsSection
            if let last = lastAction {
                Section("Last action") {
                    Text(last)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Alert Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Pull the latest fetched state into the view so values aren't
            // stale from a previous screen.
            await alertService.refresh()
        }
    }

    // MARK: - Sections

    private var vineyardSection: some View {
        Section("Vineyard") {
            LabeledContent("Selected name", value: selectedVineyardName)
            LabeledContent("Selected ID", value: store.selectedVineyardId?.uuidString ?? "none")
            if let runStart = diag.lastRunStartedAt {
                LabeledContent("Last generation started", value: format(runStart))
            }
            if let runEnd = diag.lastRunAt {
                LabeledContent("Last generation finished", value: format(runEnd))
            }
            if let skip = diag.lastSkipReason, !skip.isEmpty {
                Text("Skipped: \(skip)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var preferencesSection: some View {
        Section("Preferences (loaded)") {
            if let prefs = diag.preferences ?? alertService.preferences {
                LabeledContent("Weather alerts", value: prefs.weatherAlertsEnabled ? "on" : "off")
                LabeledContent("Rain threshold", value: String(format: "%.1f mm", prefs.rainAlertThresholdMm))
                LabeledContent("Wind threshold", value: String(format: "%.0f km/h", prefs.windAlertThresholdKmh))
                LabeledContent("Frost threshold", value: String(format: "%.1f °C", prefs.frostAlertThresholdC))
                LabeledContent("Heat threshold", value: String(format: "%.1f °C", prefs.heatAlertThresholdC))
                LabeledContent("Irrigation alerts", value: prefs.irrigationAlertsEnabled ? "on" : "off")
                LabeledContent("Irrigation deficit", value: String(format: "%.1f mm", prefs.irrigationDeficitThresholdMm))
                LabeledContent("Forecast window", value: "\(prefs.irrigationForecastDays) days")
                LabeledContent("Aged pin alerts", value: prefs.agedPinAlertsEnabled ? "on (≥ \(prefs.agedPinDays)d)" : "off")
                LabeledContent("Disease alerts", value: prefs.diseaseAlertsEnabled ? "on" : "off")
                LabeledContent("Spray reminders", value: prefs.sprayJobRemindersEnabled ? "on" : "off")
            } else {
                Text("Preferences not loaded yet. Tap Run Alert Generation Now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generationSection: some View {
        Section("Generation") {
            LabeledContent("Rows generated", value: "\(diag.generatedCount)")
            LabeledContent("Upsert status", value: diag.upsertStatus ?? "—")
            if let err = diag.upsertError, !err.isEmpty {
                Text("Upsert error: \(err)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !diag.bySource.isEmpty {
                DisclosureGroup("By source") {
                    ForEach(diag.bySource.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        LabeledContent(entry.key, value: "\(entry.value)")
                    }
                }
            }
        }
    }

    private var rainSection: some View {
        Section("Rain (today)") {
            LabeledContent("Threshold", value: diag.rain.threshold.map { String(format: "%.1f mm", $0) } ?? "—")
            LabeledContent("Resolved value", value: diag.rain.resolvedMm.map { String(format: "%.2f mm", $0) } ?? "—")
            LabeledContent("Source", value: diag.rain.source ?? "—")
            LabeledContent("Condition", value: conditionLabel)
            LabeledContent("Local date", value: diag.rain.localDate ?? "—")
            LabeledContent("Dedup key", value: diag.rain.dedupKey ?? "—")
            if let id = diag.rain.generatedAlertId {
                LabeledContent("Generated alert id", value: id.uuidString)
                    .font(.caption.monospaced())
            }
            if let exp = diag.rain.generatedAlertExpiresAt {
                LabeledContent("Expires at", value: format(exp))
            }
            if let note = diag.rain.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let id = diag.rain.generatedAlertId {
                let fetchedBack = alertService.alerts.contains { $0.alert.id == id }
                let active = alertService.activeAlerts.contains { $0.alert.id == id }
                LabeledContent("Fetched back", value: fetchedBack ? "yes" : "no")
                    .foregroundStyle(fetchedBack ? Color.primary : Color.red)
                LabeledContent("Active on Home", value: active ? "yes" : "no")
                    .foregroundStyle(active ? Color.primary : Color.red)
            }
        }
    }

    private var activeAlertsSection: some View {
        Section("Fetch result") {
            LabeledContent("Fetched", value: "\(diag.fetchedCount)")
            LabeledContent("Active", value: "\(diag.activeCount)")
            LabeledContent("Unread", value: "\(diag.unreadCount)")
            LabeledContent("Dismissed", value: "\(diag.dismissedCount)")
            LabeledContent("Expired", value: "\(diag.expiredCount)")
            if let err = diag.fetchError, !err.isEmpty {
                Text("Fetch error: \(err)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !diag.activeTypes.isEmpty {
                DisclosureGroup("Active types") {
                    ForEach(diag.activeTypes, id: \.self) { type in
                        Text(type)
                            .font(.caption.monospaced())
                    }
                }
            }
            if !alertService.activeAlerts.isEmpty {
                DisclosureGroup("Active alerts (\(alertService.activeAlerts.count))") {
                    ForEach(alertService.activeAlerts) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.alert.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(item.alert.alertType) · \(item.alert.severity)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(item.alert.message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                Task { await runGeneration() }
            } label: {
                Label("Run Alert Generation Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isRunning)

            Button {
                Task { await createTest() }
            } label: {
                Label("Create Test Alert", systemImage: "bell.badge.fill")
            }
            .disabled(isRunning)

            Button(role: .destructive) {
                Task { await clearTest() }
            } label: {
                Label("Clear Test Alerts", systemImage: "trash")
            }
            .disabled(isRunning)
        }
    }

    // MARK: - Helpers

    private var diag: AlertDiagnosticsSnapshot { alertService.diagnostics }

    private var selectedVineyardName: String {
        guard let vid = store.selectedVineyardId,
              let v = store.vineyards.first(where: { $0.id == vid }) else { return "—" }
        return v.name
    }

    private var conditionLabel: String {
        guard let mm = diag.rain.resolvedMm, let t = diag.rain.threshold else { return "—" }
        return String(format: "%.2f >= %.1f = %@", mm, t, (mm >= t && t > 0) ? "true" : "false")
    }

    private func format(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().second())
    }

    private func runGeneration() async {
        isRunning = true
        defer { isRunning = false }
        lastAction = "Running generation…"
        await alertService.generateAndRefresh()
        lastAction = "Generation finished. generated=\(diag.generatedCount), upsert=\(diag.upsertStatus ?? "—"), active=\(diag.activeCount)"
    }

    private func createTest() async {
        isRunning = true
        defer { isRunning = false }
        lastAction = "Creating test alert…"
        let result = await alertService.createTestAlert()
        lastAction = result
    }

    private func clearTest() async {
        isRunning = true
        defer { isRunning = false }
        lastAction = "Clearing test alerts…"
        let result = await alertService.clearTestAlerts()
        lastAction = result
    }
}

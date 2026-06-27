import Foundation
import Observation
import CoreLocation

/// Service responsible for generating, fetching, and updating vineyard alerts.
/// Generation runs locally based on the in-memory data store; the resulting
/// alerts are upserted to Supabase (deduplicated via dedup_key) so they sync
/// across devices and members. Per-user read/dismiss is tracked separately.
@Observable
@MainActor
final class AlertService {

    enum Status: Equatable, Sendable {
        case idle
        case loading
        case success
        case failure(String)
    }

    var status: Status = .idle
    var alerts: [AlertWithStatus] = []
    var preferences: BackendAlertPreferences?
    var lastRefresh: Date?
    /// Deep-link request from a tapped alert. Observed by the main tab view
    /// to switch tabs / present the relevant screen, then cleared.
    var pendingNavigation: AlertAction?

    /// In-app diagnostics for the alerts pipeline. Surfaced via
    /// `AlertDiagnosticsView` (system admin only) so we can see exactly what
    /// the generator is doing without parsing console logs.
    var diagnostics: AlertDiagnosticsSnapshot = AlertDiagnosticsSnapshot()

    /// Serializes overlapping `refresh()` / `generateAndRefresh()` calls.
    /// Without this, Home + Diagnostics + foreground sweep can race and
    /// cancel each other, leaving stale `CancellationError` strings in the
    /// diagnostics snapshot even though data loaded fine.
    private var inFlight: Task<Void, Never>?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private weak var accessControl: BackendAccessControl?
    private let repository: any AlertRepositoryProtocol
    private let forecastService: IrrigationForecastService
    private let hourlyService: WeatherHourlyService

    init(repository: (any AlertRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseAlertRepository()
        self.forecastService = IrrigationForecastService()
        self.hourlyService = WeatherHourlyService()
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService, accessControl: BackendAccessControl? = nil) {
        self.store = store
        self.auth = auth
        self.accessControl = accessControl
    }

    // MARK: - Derived

    var activeAlerts: [AlertWithStatus] {
        alerts.filter { !$0.isDismissed && !isExpired($0.alert) }
    }

    var unreadAlerts: [AlertWithStatus] {
        activeAlerts.filter { !$0.isRead }
    }

    var highestSeverity: AlertSeverity? {
        let severities = activeAlerts.map { $0.alert.typedSeverity }
        if severities.contains(.critical) { return .critical }
        if severities.contains(.warning) { return .warning }
        if severities.contains(.info) { return .info }
        return nil
    }

    private func isExpired(_ alert: BackendAlert) -> Bool {
        guard let exp = alert.expiresAt else { return false }
        return exp < Date()
    }

    // MARK: - Refresh

    /// Fetch alerts and preferences for the currently selected vineyard.
    /// Non-blocking; failures are surfaced via `status` but never thrown.
    func refresh() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId,
              SupabaseClientProvider.shared.isConfigured else {
            return
        }
        status = .loading
        do {
            let prefs: BackendAlertPreferences
            if let existing = try await repository.fetchPreferences(vineyardId: vineyardId) {
                prefs = existing
            } else {
                prefs = BackendAlertPreferences.defaults(for: vineyardId)
            }
            self.preferences = prefs

            let fetched = try await repository.fetchAlerts(vineyardId: vineyardId)
            let statuses = try await repository.fetchUserStatus(alertIds: fetched.map { $0.id })
            let statusByAlert = Dictionary(uniqueKeysWithValues: statuses.map { ($0.alertId, $0) })
            self.alerts = fetched.map { AlertWithStatus(alert: $0, status: statusByAlert[$0.id]) }
            self.lastRefresh = Date()
            self.status = .success
        } catch is CancellationError {
            // Cancellation is expected when navigation/foreground sweep
            // supersedes an in-flight fetch — don't treat as failure.
            if case .loading = status { status = .idle }
        } catch {
            if Self.isCancellation(error) {
                if case .loading = status { status = .idle }
            } else {
                self.status = .failure(error.localizedDescription)
            }
        }
    }

    /// Returns true for Swift `CancellationError` and the URLSession
    /// `NSURLErrorCancelled` flavour both Supabase and our proxies surface
    /// when an enclosing Task is cancelled.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == "NSPOSIXErrorDomain" && ns.code == 89 { return true } // ECANCELED
        return false
    }

    /// Run local alert generation for the selected vineyard, push generated
    /// alerts (deduped by dedup_key), then refresh from server.
    func generateAndRefresh() async {
        // Coalesce overlapping calls. If a run is already in flight, await
        // it instead of starting a competing one (which would cancel the
        // first and leave a misleading CancellationError in diagnostics).
        if let existing = inFlight {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await self._generateAndRefresh()
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func _generateAndRefresh() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId,
              SupabaseClientProvider.shared.isConfigured else {
            print("[AlertService] generateAndRefresh skipped — not signed in / no vineyard / supabase unconfigured")
            diagnostics.lastSkipReason = "not signed in / no vineyard / supabase unconfigured"
            diagnostics.lastRunAt = Date()
            return
        }
        diagnostics = AlertDiagnosticsSnapshot()
        diagnostics.vineyardId = vineyardId
        diagnostics.lastRunStartedAt = Date()

        // Make sure we have preferences first.
        if preferences == nil {
            preferences = (try? await repository.fetchPreferences(vineyardId: vineyardId))
                ?? BackendAlertPreferences.defaults(for: vineyardId)
        }
        let prefs = preferences ?? BackendAlertPreferences.defaults(for: vineyardId)
        let userId = auth.userId
        diagnostics.preferences = prefs

        print("[AlertService] generateAndRefresh vineyard=\(vineyardId.uuidString.prefix(8)) prefs: agedPins=\(prefs.agedPinAlertsEnabled)(>=\(prefs.agedPinDays)d) irrigation=\(prefs.irrigationAlertsEnabled)(\(prefs.irrigationDeficitThresholdMm)mm) weather=\(prefs.weatherAlertsEnabled)(rain\(prefs.rainAlertThresholdMm)/wind\(prefs.windAlertThresholdKmh)/frost\(prefs.frostAlertThresholdC)/heat\(prefs.heatAlertThresholdC)) spray=\(prefs.sprayJobRemindersEnabled) disease=\(prefs.diseaseAlertsEnabled)")

        var generated: [BackendAlertUpsert] = []
        var bySource: [String: Int] = [:]

        if prefs.agedPinAlertsEnabled {
            let items = generateAgedPinAlerts(
                store: store,
                vineyardId: vineyardId,
                prefs: prefs,
                userId: userId
            )
            bySource["agedPins"] = items.count
            generated.append(contentsOf: items)
        }
        // Many open pins — independent of aged-pin threshold. Fires when
        // the count of open pins exceeds a general operational threshold.
        do {
            let items = generateManyOpenPinsAlerts(
                store: store,
                vineyardId: vineyardId,
                userId: userId
            )
            bySource["manyOpenPins"] = items.count
            generated.append(contentsOf: items)
        }
        // Overdue work tasks — always on. Fires when a work task's scheduled
        // date has passed and it isn't archived or finalised yet.
        do {
            let items = generateOverdueWorkTaskAlerts(
                store: store,
                vineyardId: vineyardId,
                userId: userId
            )
            bySource["workTaskOverdue"] = items.count
            generated.append(contentsOf: items)
        }
        if prefs.sprayJobRemindersEnabled {
            let items = generateSprayReminders(
                store: store,
                vineyardId: vineyardId,
                userId: userId
            )
            bySource["spray"] = items.count
            generated.append(contentsOf: items)
        }
        if prefs.irrigationAlertsEnabled {
            let items = await generateIrrigationAlerts(
                store: store,
                vineyardId: vineyardId,
                prefs: prefs,
                userId: userId
            )
            bySource["irrigation"] = items.count
            generated.append(contentsOf: items)
        } else if prefs.weatherAlertsEnabled {
            // Ensure we have a forecast even if irrigation alerts are disabled.
            await ensureForecast(store: store, vineyardId: vineyardId, prefs: prefs)
        }

        // Forecast setup warning — if any forecast/weather-driven alert
        // category is enabled but no paddock has polygon geometry, surface
        // one friendly setup hint (daily-deduped) rather than silently
        // skipping forecast generation.
        if prefs.weatherAlertsEnabled || prefs.irrigationAlertsEnabled || prefs.diseaseAlertsEnabled {
            let items = generateForecastSetupMissingGeometryAlerts(
                store: store,
                vineyardId: vineyardId,
                userId: userId
            )
            bySource["forecastSetupMissing"] = items.count
            generated.append(contentsOf: items)
        }

        if prefs.weatherAlertsEnabled {
            let weather = generateWeatherAlertsFromForecast(
                forecastDays: forecastService.forecast?.days ?? [],
                vineyardId: vineyardId,
                prefs: prefs,
                userId: userId
            )
            bySource["weather"] = weather.count
            generated.append(contentsOf: weather)
            let rain = await generateRainAlertsFromDavis(
                store: store,
                vineyardId: vineyardId,
                userId: userId
            )
            bySource["rainDavis"] = rain.count
            generated.append(contentsOf: rain)
            let rainToday = await generateRainTodayThresholdAlerts(
                store: store,
                vineyardId: vineyardId,
                prefs: prefs,
                userId: userId
            )
            bySource["rainToday"] = rainToday.count
            generated.append(contentsOf: rainToday)
        }

        // Costing setup incomplete — owner/manager only because it surfaces
        // financial setup state. Daily-deduped to avoid noise.
        if accessControl?.canViewCosting == true {
            let items = generateCostingSetupAlerts(
                store: store,
                vineyardId: vineyardId,
                userId: userId
            )
            bySource["costingSetup"] = items.count
            generated.append(contentsOf: items)
        }

        if prefs.diseaseAlertsEnabled {
            let items = await generateDiseaseAlerts(
                store: store,
                vineyardId: vineyardId,
                prefs: prefs,
                userId: userId
            )
            bySource["disease"] = items.count
            generated.append(contentsOf: items)
        }

        print("[AlertService] generated=\(generated.count) bySource=\(bySource)")
        diagnostics.generatedCount = generated.count
        diagnostics.bySource = bySource

        if !generated.isEmpty {
            do {
                try await repository.upsertAlerts(generated)
                print("[AlertService] upserted \(generated.count) alerts to Supabase")
                diagnostics.upsertStatus = "success (\(generated.count))"
                diagnostics.upsertError = nil
            } catch {
                if Self.isCancellation(error) {
                    print("[AlertService] upsert cancelled (superseded) — ignoring")
                    diagnostics.upsertStatus = "cancelled"
                    diagnostics.upsertError = nil
                } else {
                    print("[AlertService] upsert failed — \(error.localizedDescription)")
                    diagnostics.upsertStatus = "failed"
                    diagnostics.upsertError = error.localizedDescription
                }
            }
        } else {
            diagnostics.upsertStatus = "no rows generated"
            diagnostics.upsertError = nil
        }

        await refresh()
        diagnostics.fetchedCount = alerts.count
        diagnostics.activeCount = activeAlerts.count
        diagnostics.unreadCount = unreadAlerts.count
        diagnostics.dismissedCount = alerts.filter { $0.isDismissed }.count
        diagnostics.expiredCount = alerts.filter { isExpired($0.alert) }.count
        diagnostics.activeTypes = Array(Set(activeAlerts.compactMap { $0.alert.typedAlertType?.rawValue })).sorted()
        // Only surface fetch errors when there was a real failure AND no
        // data made it through. A succeeded-then-cancelled sequence should
        // not show a red error once active alerts are populated.
        if case .failure(let msg) = status, alerts.isEmpty {
            diagnostics.fetchError = msg
        } else {
            diagnostics.fetchError = nil
        }
        diagnostics.lastRunAt = Date()
        print("[AlertService] post-refresh fetched=\(alerts.count) active=\(activeAlerts.count) unread=\(unreadAlerts.count)")
    }

    // MARK: - Diagnostics helpers (system admin only)

    /// Create a harmless temporary alert for the selected vineyard so we can
    /// confirm the Supabase write / read / display path independently of any
    /// generator rule. Expires after 1 hour.
    func createTestAlert() async -> String {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId,
              SupabaseClientProvider.shared.isConfigured else {
            return "skipped — not signed in / no vineyard / supabase unconfigured"
        }
        let now = Date()
        let dedupKey = "test_alert:\(Int(now.timeIntervalSince1970))"
        let id = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        let upsert = BackendAlertUpsert(
            id: id,
            vineyardId: vineyardId,
            alertType: "test_alert",
            severity: AlertSeverity.info.rawValue,
            title: "Test alert",
            message: "Diagnostic test alert. Safe to dismiss.",
            relatedTable: nil,
            relatedId: nil,
            paddockId: nil,
            action: nil,
            dedupKey: dedupKey,
            generatedForDate: Calendar.current.startOfDay(for: now),
            expiresAt: now.addingTimeInterval(60 * 60),
            createdBy: auth.userId
        )
        do {
            try await repository.upsertAlerts([upsert])
        } catch {
            return "upsert failed: \(error.localizedDescription)"
        }
        await refresh()
        let nowVisible = alerts.contains { $0.alert.id == id }
        return nowVisible
            ? "created \(id.uuidString.prefix(8)) — visible in active alerts"
            : "created \(id.uuidString.prefix(8)) — upsert ok but NOT fetched back (check RLS / expires_at filter)"
    }

    /// Expire any rows created by `createTestAlert` so they disappear from
    /// the active list. Safe to call repeatedly.
    func clearTestAlerts() async -> String {
        guard let store, let vineyardId = store.selectedVineyardId,
              SupabaseClientProvider.shared.isConfigured else {
            return "skipped — not signed in / no vineyard / supabase unconfigured"
        }
        let testRows = alerts.filter { $0.alert.alertType == "test_alert" && $0.alert.vineyardId == vineyardId }
        guard !testRows.isEmpty else {
            await refresh()
            return "no test alerts found"
        }
        var cleared = 0
        for row in testRows {
            do {
                try await repository.deleteAlert(id: row.alert.id)
                cleared += 1
            } catch {
                print("[AlertService] clearTestAlerts delete failed — \(error.localizedDescription)")
            }
        }
        await refresh()
        return "cleared \(cleared) test alert(s)"
    }

    // MARK: - Aged pins

    private func generateAgedPinAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        prefs: BackendAlertPreferences,
        userId: UUID?
    ) -> [BackendAlertUpsert] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -prefs.agedPinDays, to: Date()) ?? Date()
        let aged = store.pins.filter {
            $0.vineyardId == vineyardId && !$0.isCompleted && $0.timestamp <= cutoff
        }
        guard !aged.isEmpty else { return [] }
        let count = aged.count
        let dedupKey = "aged_pins:\(prefs.agedPinDays)"
        let title = "\(count) aged pin\(count == 1 ? "" : "s")"
        let message = "\(count) unresolved pin\(count == 1 ? "" : "s") older than \(prefs.agedPinDays) days. Tap to review."
        let severity: AlertSeverity = count >= 10 ? .warning : .info
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        return [
            BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.agedPins.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: "pins",
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openPins.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today(),
                expiresAt: tomorrow(),
                createdBy: userId
            )
        ]
    }

    // MARK: - Many open pins

    /// Default thresholds (kept as constants for now; easy to promote to
    /// `BackendAlertPreferences` later without changing call sites).
    private static let manyOpenPinsInfoThreshold: Int = 10
    private static let manyOpenPinsWarningThreshold: Int = 20

    private func generateManyOpenPinsAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        userId: UUID?
    ) -> [BackendAlertUpsert] {
        let open = store.pins.filter { $0.vineyardId == vineyardId && !$0.isCompleted }
        let count = open.count
        guard count >= Self.manyOpenPinsInfoThreshold else { return [] }
        let dedupKey = "many_open_pins:\(yyyymmdd(Date()))"
        let severity: AlertSeverity = count >= Self.manyOpenPinsWarningThreshold ? .warning : .info
        let title = "Open pins building up"
        let message = "There are \(count) open pins that may need review."
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        return [
            BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.manyOpenPins.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: "pins",
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openPins.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today(),
                expiresAt: tomorrow(),
                createdBy: userId
            )
        ]
    }

    // MARK: - Forecast setup missing geometry

    /// Emits a single friendly setup-style alert (daily-deduped) when
    /// forecast/weather/disease alerts are enabled but no paddock in this
    /// vineyard has polygon points, so we can't resolve a centroid for
    /// forecast lookups. Stays quiet once geometry is added.
    private func generateForecastSetupMissingGeometryAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        userId: UUID?
    ) -> [BackendAlertUpsert] {
        let hasGeometry = store.paddocks.contains {
            $0.vineyardId == vineyardId && !$0.polygonPoints.isEmpty
        }
        if hasGeometry { return [] }
        let dedupKey = "forecast_setup_missing_geometry:\(yyyymmdd(Date()))"
        let title = "Forecast alerts need block boundaries"
        let message = "Add block boundaries so VineTrack can calculate vineyard forecast alerts for rain, wind, frost and heat."
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        return [
            BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.forecastSetupMissingGeometry.rawValue,
                severity: AlertSeverity.info.rawValue,
                title: title,
                message: message,
                relatedTable: nil,
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openPaddocks.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today(),
                expiresAt: tomorrow(),
                createdBy: userId
            )
        ]
    }

    // MARK: - Overdue work tasks

    private func generateOverdueWorkTaskAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        userId: UUID?
    ) -> [BackendAlertUpsert] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        // Work tasks in this app are primarily a *log* of work already performed.
        // Only treat a row as an outstanding scheduled job when it carries an
        // explicit scheduling status (e.g. "scheduled", "planned", "todo",
        // "in_progress"). Rows with no status, or a terminal status
        // (completed/done/logged/cancelled), are historical records and must
        // not generate overdue alerts.
        let scheduledStatuses: Set<String> = [
            "scheduled", "planned", "todo", "to_do", "pending", "in_progress", "in-progress", "active"
        ]
        let overdue = store.workTasks.filter { task in
            guard task.vineyardId == vineyardId else { return false }
            if task.isArchived || task.isFinalized { return false }
            let normalised = (task.status ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard scheduledStatuses.contains(normalised) else { return false }
            // Prefer endDate when set, otherwise fall back to date.
            let due = task.endDate ?? task.date
            return due < startOfToday
        }
        guard !overdue.isEmpty else { return [] }
        let count = overdue.count
        let dedupKey = "work_task_overdue:\(yyyymmdd(Date()))"
        let title = "\(count) overdue work task\(count == 1 ? "" : "s")"
        let message: String
        if count == 1, let task = overdue.first {
            let label = task.taskType.isEmpty ? "work task" : task.taskType
            message = "\(label) is past its scheduled date. Tap to review."
        } else {
            message = "\(count) work tasks are past their scheduled date. Tap to review."
        }
        let severity: AlertSeverity = count >= 5 ? .warning : .info
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        return [
            BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.workTaskOverdue.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: "work_tasks",
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openWorkTasks.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today(),
                expiresAt: tomorrow(),
                createdBy: userId
            )
        ]
    }

    // MARK: - Costing setup incomplete

    /// Owner/manager-only setup hint that mirrors the Cost Reports wizard.
    /// Fires once a day when the active vineyard has at least one trip and
    /// any required cost input is missing. Deduped by yyyy-MM-dd so repeated
    /// refreshes never create duplicates.
    private func generateCostingSetupAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        userId: UUID?
    ) -> [BackendAlertUpsert] {
        // Only surface this when costing is in use — i.e. there is at least
        // one trip in this vineyard. New vineyards without trips don't need
        // a financial setup alert yet.
        let hasTrips = store.trips.contains { $0.vineyardId == vineyardId }
        guard hasTrips else { return [] }
        let analysis = CostingSetupAnalysis.make(store: store, vineyardId: vineyardId)
        guard !analysis.allComplete else { return [] }
        let dedupKey = "costing_setup_incomplete:\(yyyymmdd(Date()))"
        let missing = analysis.missingCount
        let severity: AlertSeverity = missing >= 3 ? .warning : .info
        let title = "Costing setup incomplete"
        let message = "Some costing inputs are missing, so cost/ha or cost/tonne may be incomplete. \(missing) item\(missing == 1 ? "" : "s") need attention."
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        return [
            BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.costingSetupIncomplete.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: nil,
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openCostReports.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today(),
                expiresAt: tomorrow(),
                createdBy: userId
            )
        ]
    }

    // MARK: - Spray reminders

    private func generateSprayReminders(
        store: MigratedDataStore,
        vineyardId: UUID,
        userId: UUID?
    ) -> [BackendAlertUpsert] {
        let cal = Calendar.current
        let now = Date()
        let tomorrowEnd = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now
        let recordsDue = store.sprayRecords.filter {
            $0.vineyardId == vineyardId && $0.date >= cal.startOfDay(for: now) && $0.date < tomorrowEnd
        }
        guard !recordsDue.isEmpty else { return [] }
        let count = recordsDue.count
        let dedupKey = "spray_due:\(yyyymmdd(now))"
        let title = "\(count) spray job\(count == 1 ? "" : "s") due"
        let message = "Scheduled spray work today or tomorrow. Tap to review the spray program."
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        return [
            BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.sprayJobDue.rawValue,
                severity: AlertSeverity.warning.rawValue,
                title: title,
                message: message,
                relatedTable: "spray_records",
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openSprayProgram.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today(),
                expiresAt: cal.date(byAdding: .day, value: 2, to: now),
                createdBy: userId
            )
        ]
    }

    // MARK: - Irrigation

    private func ensureForecast(
        store: MigratedDataStore,
        vineyardId: UUID,
        prefs: BackendAlertPreferences
    ) async {
        let paddocks = store.paddocks.filter { $0.vineyardId == vineyardId && !$0.polygonPoints.isEmpty }
        guard let firstPaddock = paddocks.first else { return }
        let lat = firstPaddock.polygonPoints.map(\.latitude).reduce(0, +) / Double(firstPaddock.polygonPoints.count)
        let lon = firstPaddock.polygonPoints.map(\.longitude).reduce(0, +) / Double(firstPaddock.polygonPoints.count)
        await forecastService.fetchForecast(latitude: lat, longitude: lon, days: prefs.irrigationForecastDays, vineyardId: vineyardId)
    }

    private func generateIrrigationAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        prefs: BackendAlertPreferences,
        userId: UUID?
    ) async -> [BackendAlertUpsert] {
        // Use first paddock with a valid centroid as a proxy location.
        let paddocks = store.paddocks.filter { $0.vineyardId == vineyardId && !$0.polygonPoints.isEmpty }
        guard let firstPaddock = paddocks.first else { return [] }
        let lat = firstPaddock.polygonPoints.map(\.latitude).reduce(0, +) / Double(firstPaddock.polygonPoints.count)
        let lon = firstPaddock.polygonPoints.map(\.longitude).reduce(0, +) / Double(firstPaddock.polygonPoints.count)

        await forecastService.fetchForecast(latitude: lat, longitude: lon, days: prefs.irrigationForecastDays, vineyardId: vineyardId)
        guard let forecast = forecastService.forecast, !forecast.days.isEmpty else { return [] }

        let result = IrrigationCalculator.calculate(
            forecastDays: forecast.days,
            settings: IrrigationSettings.defaults
        )
        let deficit = result?.netDeficitMm ?? 0
        guard deficit >= prefs.irrigationDeficitThresholdMm else { return [] }

        let dedupKey = "irrigation_deficit:\(yyyymmdd(Date()))"
        let title = "Irrigation may be needed"
        let message = String(format: "Forecast deficit %.1f mm over the next %d days exceeds your threshold (%.1f mm).",
                             deficit, prefs.irrigationForecastDays, prefs.irrigationDeficitThresholdMm)
        let severity: AlertSeverity = deficit >= prefs.irrigationDeficitThresholdMm * 2 ? .warning : .info
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
        return [
            BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.irrigationNeeded.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: nil,
                relatedId: nil,
                paddockId: firstPaddock.id,
                action: AlertAction.openIrrigationAdvisor.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today(),
                expiresAt: Calendar.current.date(byAdding: .day, value: 1, to: Date()),
                createdBy: userId
            )
        ]
    }

    // MARK: - Weather

    private func generateWeatherAlertsFromForecast(
        forecastDays: [ForecastDay],
        vineyardId: UUID,
        prefs: BackendAlertPreferences,
        userId: UUID?
    ) -> [BackendAlertUpsert] {
        guard !forecastDays.isEmpty else { return [] }

        // Scan every forecast day in the configured window (not just today)
        // so future rain/wind/frost/heat events surface as soon as they enter
        // the forecast. Each day with risks emits its own alert, deduplicated
        // by date so refreshes don't create duplicates.
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let cutoff = cal.date(byAdding: .day, value: max(1, prefs.irrigationForecastDays), to: startOfToday) ?? startOfToday
        let relativeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }()

        var upserts: [BackendAlertUpsert] = []
        for day in forecastDays {
            let dayStart = cal.startOfDay(for: day.date)
            guard dayStart >= startOfToday, dayStart < cutoff else { continue }

            var risks: [String] = []
            var severity: AlertSeverity = .info
            if day.forecastRainMm >= prefs.rainAlertThresholdMm {
                risks.append(String(format: "rain %.1f mm", day.forecastRainMm))
                if day.forecastRainMm >= prefs.rainAlertThresholdMm * 2 {
                    severity = .warning
                }
            }
            if let wind = day.forecastWindKmhMax, wind >= prefs.windAlertThresholdKmh {
                risks.append(String(format: "wind %.0f km/h", wind))
                if wind >= prefs.windAlertThresholdKmh * 1.5 {
                    severity = max(severity, .warning)
                }
            }
            if let tMin = day.forecastTempMinC, tMin <= prefs.frostAlertThresholdC {
                risks.append(String(format: "frost low %.1f°C", tMin))
                severity = .critical
            }
            if let tMax = day.forecastTempMaxC, tMax >= prefs.heatAlertThresholdC {
                risks.append(String(format: "heat %.1f°C", tMax))
                if tMax >= prefs.heatAlertThresholdC + 5 {
                    severity = max(severity, .warning)
                }
            }
            guard !risks.isEmpty else { continue }

            let dedupKey = "weather_risk:\(yyyymmdd(day.date))"
            let dayLabel = relativeFormatter.string(from: day.date)
            let title: String
            if cal.isDateInToday(day.date) {
                title = "Weather risk today"
            } else if cal.isDateInTomorrow(day.date) {
                title = "Weather risk tomorrow"
            } else {
                title = "Weather risk \(dayLabel)"
            }
            let message = "Forecast for \(dayLabel): " + risks.joined(separator: ", ") + "."
            let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
            // Keep each day's alert visible until the end of that day so a
            // Monday rain forecast stays in the list right up to Monday.
            let expires = cal.date(byAdding: .day, value: 1, to: dayStart)
            upserts.append(BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.weatherRisk.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: nil,
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openWeather.rawValue,
                dedupKey: dedupKey,
                generatedForDate: dayStart,
                expiresAt: expires,
                createdBy: userId
            ))
        }
        return upserts
    }

    // MARK: - Rain today threshold (actual rainfall recorded so far today)

    /// Fires when today's *recorded* rainfall (so far) meets or exceeds the
    /// configured rain threshold. Independent of the forecast-rain weather
    /// alert, which scans the multi-day forecast.
    ///
    /// Data priority mirrors the Home rain card and Rain page:
    ///   1. `get_vineyard_current_weather` cached snapshot (`rain_today_mm`).
    ///   2. Persisted `rainfall_daily` row for today.
    ///   3. Forecast first-day rain (last-resort, when WU/Open-Meteo skip the
    ///      in-progress day).
    ///
    /// Dedup key is per local date so a single row per day stays in sync
    /// with the latest reading via upsert. If the threshold drops below the
    /// current reading the upsert overwrites the same row with an expired
    /// `expiresAt` so the alert clears without leaving a stale entry.
    private func generateRainTodayThresholdAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        prefs: BackendAlertPreferences,
        userId: UUID?
    ) async -> [BackendAlertUpsert] {
        let timezone = vineyardTimeZone(store: store, vineyardId: vineyardId)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        let localDate: String = {
            let comps = cal.dateComponents([.year, .month, .day], from: now)
            return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        }()
        let dedupKey = "rain_today_threshold:\(localDate)"
        let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)

        let threshold = prefs.rainAlertThresholdMm
        print("[AlertService][rainToday] start vineyard=\(vineyardId.uuidString.prefix(8)) localDate=\(localDate) threshold=\(threshold) weatherAlertsEnabled=\(prefs.weatherAlertsEnabled)")
        diagnostics.rain.threshold = threshold
        diagnostics.rain.dedupKey = dedupKey
        diagnostics.rain.localDate = localDate

        // 0. Provider-appropriate live refresh so the cached snapshot we
        //    read below reflects the latest available reading. Mirrors
        //    `HomeRainSummaryCard.refresh()` — without this step the alert
        //    generator races the Home card on cold launch and sees the
        //    pre-refresh cache (often empty / zero), so today's actual rain
        //    never triggers the threshold alert.
        await refreshTodayRainSources(vineyardId: vineyardId)

        // 1. Cached current observation.
        var todayMm: Double?
        var sourceLabel: String?
        if let snap = try? await WeatherCurrentService().fetchCachedCurrent(vineyardId: vineyardId) {
            todayMm = snap.rainTodayMm
            sourceLabel = Self.displaySource(rawSource: snap.source, stationName: snap.stationName)
            print("[AlertService][rainToday] step1 cached snapshot source=\(snap.source) status=\(snap.status) stale=\(snap.isStale) rainTodayMm=\(snap.rainTodayMm.map { String(format: "%.2f", $0) } ?? "nil")")
        } else {
            print("[AlertService][rainToday] step1 cached snapshot: nil/failed")
        }
        // 2. Persisted daily row for today.
        if todayMm == nil {
            if let rows = try? await PersistedRainfallService.fetchDailyRainfall(
                vineyardId: vineyardId, from: startOfDay, to: startOfDay
            ), let row = rows.first, let mm = row.rainfallMm {
                todayMm = mm
                if sourceLabel == nil {
                    sourceLabel = Self.displaySource(rawSource: row.source, stationName: row.stationName)
                }
                print("[AlertService][rainToday] step2 persisted daily row mm=\(mm) source=\(row.source ?? "nil")")
            } else {
                print("[AlertService][rainToday] step2 persisted daily row: none for today")
            }
        }
        // 3. Forecast first-day (last-resort fallback). Fetch the forecast
        //    here directly using vineyard lat/lon so this path works even
        //    when `forecastService.forecast` hasn't been populated upstream
        //    (e.g. paddock polygons missing, so irrigation alerts skipped).
        //    This mirrors `HomeRainSummaryCard` which fetches via vineyard
        //    settings lat/lon → paddock centroid.
        if todayMm == nil {
            if let (lat, lon) = vineyardCoordinates(store: store, vineyardId: vineyardId) {
                await forecastService.fetchForecast(latitude: lat, longitude: lon, days: 7, vineyardId: vineyardId)
                if let day = forecastService.forecast?.days.first(where: { cal.isDate($0.date, inSameDayAs: now) }) {
                    todayMm = day.forecastRainMm
                    if sourceLabel == nil { sourceLabel = "Forecast" }
                    print("[AlertService][rainToday] step3 forecast fallback mm=\(day.forecastRainMm)")
                } else {
                    print("[AlertService][rainToday] step3 forecast fallback: no matching day")
                }
            } else {
                print("[AlertService][rainToday] step3 forecast fallback skipped — no vineyard coordinates")
            }
        }

        diagnostics.rain.resolvedMm = todayMm
        diagnostics.rain.source = sourceLabel
        guard let mm = todayMm else {
            print("[AlertService][rainToday] NO VALUE resolved — emitting no alert (Home may have value via different path)")
            diagnostics.rain.note = "no value resolved from any source"
            return []
        }
        let condition = mm >= threshold && threshold > 0
        diagnostics.rain.condition = condition
        print("[AlertService][rainToday] resolvedMm=\(String(format: "%.2f", mm)) source=\(sourceLabel ?? "nil") threshold=\(threshold) condition=\(condition)")

        if condition {
            let severity: AlertSeverity = mm >= threshold * 2 ? .warning : .info
            let title = "Rain threshold exceeded"
            let sourceSuffix = sourceLabel.map { " (\($0))" } ?? ""
            let message = String(
                format: "%.1f mm recorded today%@. Threshold: %.1f mm.",
                mm, sourceSuffix, threshold
            )
            diagnostics.rain.generatedAlertId = alertId
            diagnostics.rain.generatedAlertExpiresAt = endOfDay
            diagnostics.rain.note = "alert generated"
            return [BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.rainTodayThresholdExceeded.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: nil,
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openWeather.rawValue,
                dedupKey: dedupKey,
                generatedForDate: startOfDay,
                expiresAt: endOfDay,
                createdBy: userId
            )]
        } else {
            // Threshold no longer met — overwrite the same row with an
            // expired timestamp so the previous alert clears on refresh.
            diagnostics.rain.note = threshold <= 0
                ? "threshold is 0 — disabled"
                : "below threshold (\(String(format: "%.1f", mm)) < \(String(format: "%.1f", threshold)))"
            return [BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.rainTodayThresholdExceeded.rawValue,
                severity: AlertSeverity.info.rawValue,
                title: "Rain threshold not exceeded",
                message: String(format: "%.1f mm recorded today (threshold %.1f mm).", mm, threshold),
                relatedTable: nil,
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openWeather.rawValue,
                dedupKey: dedupKey,
                generatedForDate: startOfDay,
                expiresAt: now.addingTimeInterval(-1),
                createdBy: userId
            )]
        }
    }

    /// Returns vineyard lat/lon from settings, falling back to paddock
    /// centroid. Mirrors the path used by `HomeRainSummaryCard`, the Rain
    /// page and other forecast-driven views.
    private func vineyardCoordinates(store: MigratedDataStore, vineyardId: UUID) -> (Double, Double)? {
        if let lat = store.settings.vineyardLatitude, let lon = store.settings.vineyardLongitude {
            return (lat, lon)
        }
        let paddocks = store.paddocks.filter { $0.vineyardId == vineyardId && !$0.polygonPoints.isEmpty }
        guard let first = paddocks.first else { return nil }
        let lat = first.polygonPoints.map(\.latitude).reduce(0, +) / Double(first.polygonPoints.count)
        let lon = first.polygonPoints.map(\.longitude).reduce(0, +) / Double(first.polygonPoints.count)
        return (lat, lon)
    }

    /// Mirrors `HomeRainSummaryCard.refresh()` so today's rainfall threshold
    /// alert evaluates against the same data the Home card displays. Picks at
    /// most one foreground refresh per call; all failures are swallowed so a
    /// transient network issue can never block alert generation.
    private func refreshTodayRainSources(vineyardId: UUID) async {
        await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vineyardId)
        let cfg = WeatherProviderStore.shared.config(for: vineyardId)
        let canUseDavis = (cfg.davisStationId?.isEmpty == false) &&
            ((cfg.davisIsVineyardShared && cfg.davisVineyardHasServerCredentials)
             || (cfg.davisHasCredentials && cfg.davisConnectionTested))

        if canUseDavis, let sid = cfg.davisStationId {
            do {
                _ = try await VineyardDavisProxyService.fetchCurrentConditions(
                    vineyardId: vineyardId, stationId: sid
                )
                return
            } catch {
                print("[AlertService] rain-today live Davis refresh failed — \(error.localizedDescription)")
            }
        }

        // Non-Davis path: WU backfill (recent days) then Open-Meteo gap fill.
        // Both intentionally skip the in-progress day server-side; today's
        // value still falls back to the forecast first-day reading below.
        do {
            _ = try await VineyardWundergroundProxyService.backfillRainfall(
                vineyardId: vineyardId, days: 2
            )
        } catch VineyardWundergroundProxyError.notConfigured {
            // No WU station — fall through.
        } catch VineyardWundergroundProxyError.forbidden {
            // Operator role — skip silently.
        } catch {
            print("[AlertService] rain-today WU refresh failed — \(error.localizedDescription)")
        }
        do {
            _ = try await VineyardOpenMeteoProxyService.backfillRainfallGaps(
                vineyardId: vineyardId, days: 7, timezone: TimeZone.current.identifier
            )
        } catch VineyardOpenMeteoProxyError.forbidden {
            // Operator role — skip silently.
        } catch {
            print("[AlertService] rain-today Open-Meteo gap fill failed — \(error.localizedDescription)")
        }
    }

    private static func displaySource(rawSource: String?, stationName: String?) -> String? {
        guard let raw = rawSource, !raw.isEmpty else { return nil }
        let label: String
        switch raw {
        case "davis_weatherlink": label = "Davis WeatherLink"
        case "wunderground_pws": label = "Weather Underground"
        case "manual": label = "Manual"
        case "open_meteo": label = "Open-Meteo"
        default: label = raw
        }
        if let name = stationName, !name.isEmpty {
            return "\(label) · \(name)"
        }
        return label
    }

    // MARK: - Rain alerts (Davis cached current)

    /// Phase 1 (iOS-only) rain alerts driven by the Davis cached current
    /// observation returned by `get_vineyard_current_weather`.
    ///
    /// Two alert types are generated, both deduplicated by `dedup_key`
    /// so repeated refreshes do not create duplicates:
    ///
    /// 1. `rain_started` — fires when `rain_rate_mm_per_hr > 0` and the
    ///    cache is fresh. Dedupe key uses a vineyard-local 3-hour bucket
    ///    (`rain_started:{yyyy-MM-dd}:{0-7}`) so a new alert can only be
    ///    created once every 3 hours per vineyard. Severity is
    ///    `warning` when rate ≥ 5 mm/hr, otherwise `info`. Auto-expires
    ///    after 6 hours.
    ///
    /// 2. `rain_24h_summary` — only created during the 09:00 hour in
    ///    vineyard-local time and only if rainfall in the past 24h is
    ///    > 0 mm. Past-24h rainfall is read via the davis-proxy historic
    ///    endpoint. One alert per vineyard per local date.
    ///
    /// Stale / unavailable / not-configured cache responses skip the
    /// `rain_started` branch quietly.
    private func generateRainAlertsFromDavis(
        store: MigratedDataStore,
        vineyardId: UUID,
        userId: UUID?
    ) async -> [BackendAlertUpsert] {
        let service = WeatherCurrentService()
        let cached: WeatherCurrentService.CachedSnapshot?
        do {
            cached = try await service.fetchCachedCurrent(vineyardId: vineyardId)
        } catch {
            print("[AlertService] rain alerts: fetchCachedCurrent failed — \(error.localizedDescription)")
            return []
        }

        let timezone = vineyardTimeZone(store: store, vineyardId: vineyardId)
        var localCal = Calendar(identifier: .gregorian)
        localCal.timeZone = timezone
        let now = Date()
        let localComps = localCal.dateComponents([.year, .month, .day, .hour], from: now)
        let localDate = String(
            format: "%04d-%02d-%02d",
            localComps.year ?? 0,
            localComps.month ?? 0,
            localComps.day ?? 0
        )
        let stationLabel: String = {
            if let name = cached?.stationName, !name.isEmpty { return name }
            if let v = store.vineyards.first(where: { $0.id == vineyardId }), !v.name.isEmpty {
                return v.name
            }
            return "the vineyard"
        }()

        var upserts: [BackendAlertUpsert] = []

        // 1. Rain started — only when cache is ok + fresh.
        if let snap = cached,
           snap.status == "ok",
           snap.isStale == false,
           let rate = snap.rainRateMmPerHr,
           rate > 0 {
            let bucket = (localComps.hour ?? 0) / 3
            let dedupKey = "rain_started:\(localDate):\(bucket)"
            let severity: AlertSeverity = rate >= 5 ? .warning : .info
            let title = "Rain has started"
            let message = String(
                format: "Rain detected at %@. Current rate %.1f mm/hr.",
                stationLabel,
                rate
            )
            let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
            let expires = localCal.date(byAdding: .hour, value: 6, to: now)
            upserts.append(BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: AlertType.rainStarted.rawValue,
                severity: severity.rawValue,
                title: title,
                message: message,
                relatedTable: nil,
                relatedId: nil,
                paddockId: nil,
                action: AlertAction.openWeather.rawValue,
                dedupKey: dedupKey,
                generatedForDate: localCal.startOfDay(for: now),
                expiresAt: expires,
                createdBy: userId
            ))
        }

        // 2. 9 AM rain summary — vineyard-local 09:00..09:59.
        if (localComps.hour ?? -1) == 9 {
            let stationId = cached?.stationId ?? ""
            var rainfallMm: Double? = nil
            if !stationId.isEmpty {
                let from = now.addingTimeInterval(-24 * 60 * 60)
                do {
                    let result = try await VineyardDavisProxyService.fetchHistoricRainfall(
                        vineyardId: vineyardId,
                        stationId: stationId,
                        from: from,
                        to: now
                    )
                    rainfallMm = result.totalMm
                } catch {
                    print("[AlertService] rain 24h summary: historic fetch failed — \(error.localizedDescription)")
                }
            }
            if let mm = rainfallMm, mm > 0 {
                let dedupKey = "rain_24h_summary:\(localDate)"
                let title = "Rainfall in past 24 hours"
                let message = String(
                    format: "%.1f mm of rain recorded at %@ in the past 24 hours.",
                    mm,
                    stationLabel
                )
                let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
                // Keep the daily summary visible until the end of the
                // following local day so it doesn't disappear before
                // managers see it.
                let expires = localCal.date(
                    byAdding: .day,
                    value: 2,
                    to: localCal.startOfDay(for: now)
                )
                upserts.append(BackendAlertUpsert(
                    id: alertId,
                    vineyardId: vineyardId,
                    alertType: AlertType.rain24hSummary.rawValue,
                    severity: AlertSeverity.info.rawValue,
                    title: title,
                    message: message,
                    relatedTable: nil,
                    relatedId: nil,
                    paddockId: nil,
                    action: AlertAction.openWeather.rawValue,
                    dedupKey: dedupKey,
                    generatedForDate: localCal.startOfDay(for: now),
                    expiresAt: expires,
                    createdBy: userId
                ))
            }
        }

        return upserts
    }

    /// Phase 1 timezone resolution. `vineyards.timezone` doesn't exist
    /// in the backend yet, so we default Stockmans Ridge Wines to
    /// Australia/Sydney and fall back to the device timezone for any
    /// other vineyard. Phase 2 will add a server-side timezone column.
    private func vineyardTimeZone(store: MigratedDataStore, vineyardId: UUID) -> TimeZone {
        let name = store.vineyards.first(where: { $0.id == vineyardId })?.name ?? ""
        if name.localizedCaseInsensitiveContains("Stockmans Ridge") {
            return TimeZone(identifier: "Australia/Sydney") ?? .current
        }
        return .current
    }

    // MARK: - Disease risk

    private func generateDiseaseAlerts(
        store: MigratedDataStore,
        vineyardId: UUID,
        prefs: BackendAlertPreferences,
        userId: UUID?
    ) async -> [BackendAlertUpsert] {
        let paddocks = store.paddocks.filter { $0.vineyardId == vineyardId && !$0.polygonPoints.isEmpty }
        guard let firstPaddock = paddocks.first else { return [] }
        let lat = firstPaddock.polygonPoints.map(\.latitude).reduce(0, +) / Double(firstPaddock.polygonPoints.count)
        let lon = firstPaddock.polygonPoints.map(\.longitude).reduce(0, +) / Double(firstPaddock.polygonPoints.count)

        await hourlyService.fetchWithDavisOverride(
            latitude: lat,
            longitude: lon,
            pastDays: 2,
            forecastDays: 3,
            vineyardId: vineyardId
        )
        guard let forecast = hourlyService.forecast, !forecast.hours.isEmpty else { return [] }

        var enabledModels: Set<DiseaseModel> = []
        if prefs.diseaseDownyEnabled { enabledModels.insert(.downyMildew) }
        if prefs.diseasePowderyEnabled { enabledModels.insert(.powderyMildew) }
        if prefs.diseaseBotrytisEnabled { enabledModels.insert(.botrytis) }
        guard !enabledModels.isEmpty else { return [] }

        let assessments = DiseaseRiskCalculator.assess(hours: forecast.hours, models: enabledModels)
        let today = today()
        let tomorrow = tomorrow()
        var upserts: [BackendAlertUpsert] = []

        for assessment in assessments {
            guard let severity = assessment.severity else { continue }
            let alertType: AlertType
            switch assessment.model {
            case .downyMildew: alertType = .diseaseDownyMildew
            case .powderyMildew: alertType = .diseasePowderyMildew
            case .botrytis: alertType = .diseaseBotrytis
            }
            let dedupKey = "disease:\(assessment.model.rawValue):\(yyyymmdd(Date()))"
            // Powdery is driven by temperature + RH, not wetness, so don't
            // append a wetness-source note for it.
            let wetnessNote: String
            switch assessment.model {
            case .powderyMildew:
                wetnessNote = ""
            case .downyMildew, .botrytis:
                wetnessNote = assessment.usedMeasuredWetness
                    ? " Based on measured leaf wetness."
                    : " Based on estimated wetness (no measured leaf wetness sensor)."
            }
            let alertId = deterministicUUID(vineyardId: vineyardId, dedupKey: dedupKey)
            upserts.append(BackendAlertUpsert(
                id: alertId,
                vineyardId: vineyardId,
                alertType: alertType.rawValue,
                severity: severity.rawValue,
                title: assessment.title,
                message: assessment.summary + wetnessNote,
                relatedTable: nil,
                relatedId: nil,
                paddockId: firstPaddock.id,
                action: AlertAction.openDiseaseRisk.rawValue,
                dedupKey: dedupKey,
                generatedForDate: today,
                expiresAt: tomorrow,
                createdBy: userId
            ))
        }
        return upserts
    }

    // MARK: - User actions

    func markRead(_ alert: AlertWithStatus) async {
        guard !alert.isRead else { return }
        try? await repository.markStatus(alertId: alert.alert.id, read: true, dismissed: nil)
        if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
            let now = Date()
            let newStatus = BackendAlertUserStatus(
                alertId: alert.alert.id,
                userId: alerts[idx].status?.userId ?? UUID(),
                readAt: now,
                dismissedAt: alerts[idx].status?.dismissedAt
            )
            alerts[idx] = AlertWithStatus(alert: alert.alert, status: newStatus)
        }
    }

    func markAllRead() async {
        for a in unreadAlerts {
            await markRead(a)
        }
    }

    func dismiss(_ alert: AlertWithStatus) async {
        try? await repository.markStatus(alertId: alert.alert.id, read: nil, dismissed: true)
        if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
            let now = Date()
            let newStatus = BackendAlertUserStatus(
                alertId: alert.alert.id,
                userId: alerts[idx].status?.userId ?? UUID(),
                readAt: alerts[idx].status?.readAt,
                dismissedAt: now
            )
            alerts[idx] = AlertWithStatus(alert: alert.alert, status: newStatus)
        }
    }

    // MARK: - Preferences

    func savePreferences(_ prefs: BackendAlertPreferences) async {
        do {
            try await repository.upsertPreferences(prefs)
            self.preferences = prefs
        } catch {
            self.status = .failure(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func today() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    private func tomorrow() -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: today()) ?? Date()
    }

    private func yyyymmdd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Deterministic UUID derived from vineyardId + dedup key. Matching
    /// vineyard_id+dedup_key uniqueness in SQL means upserts overwrite the
    /// same row, but we still send a stable id so client and server agree.
    private func deterministicUUID(vineyardId: UUID, dedupKey: String) -> UUID {
        let raw = "\(vineyardId.uuidString):\(dedupKey)"
        var hash = UInt64(5381)
        for byte in raw.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        let h1 = hash
        let h2 = hash &* 6364136223846793005 &+ 1442695040888963407
        for i in 0..<8 {
            bytes[i] = UInt8((h1 >> (8 * i)) & 0xff)
            bytes[8 + i] = UInt8((h2 >> (8 * i)) & 0xff)
        }
        // Set version (4) and variant (RFC4122) bits.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

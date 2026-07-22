import Foundation

nonisolated enum AlertSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case info
    case warning
    case critical

    var displayName: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated enum AlertType: String, Codable, Sendable {
    case irrigationNeeded = "irrigation_needed"
    case agedPins = "aged_pins"
    case weatherRisk = "weather_risk"
    case sprayJobDue = "spray_job_due"
    case syncIssue = "sync_issue"
    case diseaseDownyMildew = "disease_downy_mildew"
    case diseasePowderyMildew = "disease_powdery_mildew"
    case diseaseBotrytis = "disease_botrytis"
    case rainStarted = "rain_started"
    case rain24hSummary = "rain_24h_summary"
    case rainTodayThresholdExceeded = "rain_today_threshold_exceeded"
    case workTaskOverdue = "work_task_overdue"
    case manyOpenPins = "many_open_pins"
    case forecastSetupMissingGeometry = "forecast_setup_missing_geometry"
    case costingSetupIncomplete = "costing_setup_incomplete"
}

nonisolated enum AlertAction: String, Codable, Sendable {
    case openIrrigationAdvisor = "open_irrigation_advisor"
    case openPins = "open_pins"
    case openSprayProgram = "open_spray_program"
    case openSprayRecord = "open_spray_record"
    case openWeather = "open_weather"
    case openDiseaseRisk = "open_disease_risk"
    case openWorkTasks = "open_work_tasks"
    case openPaddocks = "open_paddocks"
    case openCostReports = "open_cost_reports"
}

nonisolated struct BackendAlert: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let alertType: String
    let severity: String
    let title: String
    let message: String
    let relatedTable: String?
    let relatedId: UUID?
    let paddockId: UUID?
    let action: String?
    let dedupKey: String
    let generatedForDate: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let expiresAt: Date?
    let createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case alertType = "alert_type"
        case severity
        case title
        case message
        case relatedTable = "related_table"
        case relatedId = "related_id"
        case paddockId = "paddock_id"
        case action
        case dedupKey = "dedup_key"
        case generatedForDate = "generated_for_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case createdBy = "created_by"
    }

    var typedSeverity: AlertSeverity { AlertSeverity(rawValue: severity) ?? .info }
    var typedAlertType: AlertType? { AlertType(rawValue: alertType) }
    var typedAction: AlertAction? { action.flatMap { AlertAction(rawValue: $0) } }

    init(
        id: UUID,
        vineyardId: UUID,
        alertType: String,
        severity: String,
        title: String,
        message: String,
        relatedTable: String?,
        relatedId: UUID?,
        paddockId: UUID?,
        action: String?,
        dedupKey: String,
        generatedForDate: Date?,
        createdAt: Date?,
        updatedAt: Date?,
        expiresAt: Date?,
        createdBy: UUID?
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.alertType = alertType
        self.severity = severity
        self.title = title
        self.message = message
        self.relatedTable = relatedTable
        self.relatedId = relatedId
        self.paddockId = paddockId
        self.action = action
        self.dedupKey = dedupKey
        self.generatedForDate = generatedForDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.createdBy = createdBy
    }

    /// Tolerant decoder so the alerts fetch survives:
    /// - Postgres `date` columns (`generated_for_date` returns `"2026-05-19"`)
    ///   which the Supabase Swift SDK's default ISO8601 strategy can't parse.
    /// - Timestamps with or without fractional seconds.
    /// - Unknown `alert_type` / `severity` values (kept as raw strings so the
    ///   row is still surfaced; the `typed*` helpers fall back gracefully).
    /// - Missing optional columns on older rows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.alertType = try c.decode(String.self, forKey: .alertType)
        self.severity = (try? c.decode(String.self, forKey: .severity)) ?? "info"
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        self.message = (try? c.decode(String.self, forKey: .message)) ?? ""
        self.relatedTable = try c.decodeIfPresent(String.self, forKey: .relatedTable)
        self.relatedId = try? c.decodeIfPresent(UUID.self, forKey: .relatedId)
        self.paddockId = try? c.decodeIfPresent(UUID.self, forKey: .paddockId)
        self.action = try c.decodeIfPresent(String.self, forKey: .action)
        self.dedupKey = (try? c.decode(String.self, forKey: .dedupKey)) ?? ""
        self.generatedForDate = BackendAlert.flexibleDate(c, .generatedForDate)
        self.createdAt = BackendAlert.flexibleDate(c, .createdAt)
        self.updatedAt = BackendAlert.flexibleDate(c, .updatedAt)
        self.expiresAt = BackendAlert.flexibleDate(c, .expiresAt)
        self.createdBy = try? c.decodeIfPresent(UUID.self, forKey: .createdBy)
    }

    private static func flexibleDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendAlertDateParser.parse(s)
    }
}

nonisolated enum BackendAlertDateParser {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let timestampNoTZ: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func parse(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoBasic.date(from: s) { return d }
        if let d = timestampNoTZ.date(from: s) { return d }
        if let d = dateOnly.date(from: s) { return d }
        return nil
    }
}

nonisolated struct BackendAlertUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let alertType: String
    let severity: String
    let title: String
    let message: String
    let relatedTable: String?
    let relatedId: UUID?
    let paddockId: UUID?
    let action: String?
    let dedupKey: String
    let generatedForDate: Date?
    let expiresAt: Date?
    let createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case alertType = "alert_type"
        case severity
        case title
        case message
        case relatedTable = "related_table"
        case relatedId = "related_id"
        case paddockId = "paddock_id"
        case action
        case dedupKey = "dedup_key"
        case generatedForDate = "generated_for_date"
        case expiresAt = "expires_at"
        case createdBy = "created_by"
    }
}

nonisolated struct BackendAlertUserStatus: Codable, Sendable, Hashable {
    let alertId: UUID
    let userId: UUID
    let readAt: Date?
    let dismissedAt: Date?

    enum CodingKeys: String, CodingKey {
        case alertId = "alert_id"
        case userId = "user_id"
        case readAt = "read_at"
        case dismissedAt = "dismissed_at"
    }
}

nonisolated struct BackendAlertPreferences: Codable, Sendable, Hashable {
    let vineyardId: UUID
    var irrigationAlertsEnabled: Bool
    var irrigationForecastDays: Int
    var irrigationDeficitThresholdMm: Double
    var agedPinAlertsEnabled: Bool
    var agedPinDays: Int
    var weatherAlertsEnabled: Bool
    var rainAlertThresholdMm: Double
    var windAlertThresholdKmh: Double
    var frostAlertThresholdC: Double
    var heatAlertThresholdC: Double
    var sprayJobRemindersEnabled: Bool
    var pushEnabled: Bool
    var diseaseAlertsEnabled: Bool
    var diseaseDownyEnabled: Bool
    var diseasePowderyEnabled: Bool
    var diseaseBotrytisEnabled: Bool
    /// When true, prefer measured leaf wetness from an ag-weather provider
    /// over the humidity/dew-point proxy. Reserved for future integrations.
    var diseaseUseMeasuredWetness: Bool

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case irrigationAlertsEnabled = "irrigation_alerts_enabled"
        case irrigationForecastDays = "irrigation_forecast_days"
        case irrigationDeficitThresholdMm = "irrigation_deficit_threshold_mm"
        case agedPinAlertsEnabled = "aged_pin_alerts_enabled"
        case agedPinDays = "aged_pin_days"
        case weatherAlertsEnabled = "weather_alerts_enabled"
        case rainAlertThresholdMm = "rain_alert_threshold_mm"
        case windAlertThresholdKmh = "wind_alert_threshold_kmh"
        case frostAlertThresholdC = "frost_alert_threshold_c"
        case heatAlertThresholdC = "heat_alert_threshold_c"
        case sprayJobRemindersEnabled = "spray_job_reminders_enabled"
        case pushEnabled = "push_enabled"
        case diseaseAlertsEnabled = "disease_alerts_enabled"
        case diseaseDownyEnabled = "disease_downy_enabled"
        case diseasePowderyEnabled = "disease_powdery_enabled"
        case diseaseBotrytisEnabled = "disease_botrytis_enabled"
        case diseaseUseMeasuredWetness = "disease_use_measured_wetness"
    }

    init(
        vineyardId: UUID,
        irrigationAlertsEnabled: Bool,
        irrigationForecastDays: Int,
        irrigationDeficitThresholdMm: Double,
        agedPinAlertsEnabled: Bool,
        agedPinDays: Int,
        weatherAlertsEnabled: Bool,
        rainAlertThresholdMm: Double,
        windAlertThresholdKmh: Double,
        frostAlertThresholdC: Double,
        heatAlertThresholdC: Double,
        sprayJobRemindersEnabled: Bool,
        pushEnabled: Bool,
        diseaseAlertsEnabled: Bool = true,
        diseaseDownyEnabled: Bool = true,
        diseasePowderyEnabled: Bool = true,
        diseaseBotrytisEnabled: Bool = true,
        diseaseUseMeasuredWetness: Bool = false
    ) {
        self.vineyardId = vineyardId
        self.irrigationAlertsEnabled = irrigationAlertsEnabled
        self.irrigationForecastDays = irrigationForecastDays
        self.irrigationDeficitThresholdMm = irrigationDeficitThresholdMm
        self.agedPinAlertsEnabled = agedPinAlertsEnabled
        self.agedPinDays = agedPinDays
        self.weatherAlertsEnabled = weatherAlertsEnabled
        self.rainAlertThresholdMm = rainAlertThresholdMm
        self.windAlertThresholdKmh = windAlertThresholdKmh
        self.frostAlertThresholdC = frostAlertThresholdC
        self.heatAlertThresholdC = heatAlertThresholdC
        self.sprayJobRemindersEnabled = sprayJobRemindersEnabled
        self.pushEnabled = pushEnabled
        self.diseaseAlertsEnabled = diseaseAlertsEnabled
        self.diseaseDownyEnabled = diseaseDownyEnabled
        self.diseasePowderyEnabled = diseasePowderyEnabled
        self.diseaseBotrytisEnabled = diseaseBotrytisEnabled
        self.diseaseUseMeasuredWetness = diseaseUseMeasuredWetness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.irrigationAlertsEnabled = try c.decode(Bool.self, forKey: .irrigationAlertsEnabled)
        self.irrigationForecastDays = try c.decode(Int.self, forKey: .irrigationForecastDays)
        self.irrigationDeficitThresholdMm = try c.decode(Double.self, forKey: .irrigationDeficitThresholdMm)
        self.agedPinAlertsEnabled = try c.decode(Bool.self, forKey: .agedPinAlertsEnabled)
        self.agedPinDays = try c.decode(Int.self, forKey: .agedPinDays)
        self.weatherAlertsEnabled = try c.decode(Bool.self, forKey: .weatherAlertsEnabled)
        self.rainAlertThresholdMm = try c.decode(Double.self, forKey: .rainAlertThresholdMm)
        self.windAlertThresholdKmh = try c.decode(Double.self, forKey: .windAlertThresholdKmh)
        self.frostAlertThresholdC = try c.decode(Double.self, forKey: .frostAlertThresholdC)
        self.heatAlertThresholdC = try c.decode(Double.self, forKey: .heatAlertThresholdC)
        self.sprayJobRemindersEnabled = try c.decode(Bool.self, forKey: .sprayJobRemindersEnabled)
        self.pushEnabled = try c.decode(Bool.self, forKey: .pushEnabled)
        // New disease columns: tolerate older rows without these fields.
        self.diseaseAlertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .diseaseAlertsEnabled) ?? true
        self.diseaseDownyEnabled = try c.decodeIfPresent(Bool.self, forKey: .diseaseDownyEnabled) ?? true
        self.diseasePowderyEnabled = try c.decodeIfPresent(Bool.self, forKey: .diseasePowderyEnabled) ?? true
        self.diseaseBotrytisEnabled = try c.decodeIfPresent(Bool.self, forKey: .diseaseBotrytisEnabled) ?? true
        self.diseaseUseMeasuredWetness = try c.decodeIfPresent(Bool.self, forKey: .diseaseUseMeasuredWetness) ?? false
    }

    static func defaults(for vineyardId: UUID) -> BackendAlertPreferences {
        BackendAlertPreferences(
            vineyardId: vineyardId,
            irrigationAlertsEnabled: true,
            irrigationForecastDays: 5,
            irrigationDeficitThresholdMm: 8,
            agedPinAlertsEnabled: true,
            agedPinDays: 14,
            weatherAlertsEnabled: true,
            rainAlertThresholdMm: 5,
            windAlertThresholdKmh: 25,
            frostAlertThresholdC: 1,
            heatAlertThresholdC: 35,
            sprayJobRemindersEnabled: true,
            pushEnabled: false,
            diseaseAlertsEnabled: true,
            diseaseDownyEnabled: true,
            diseasePowderyEnabled: true,
            diseaseBotrytisEnabled: true,
            diseaseUseMeasuredWetness: false
        )
    }
}

/// In-app diagnostics snapshot for the alerts pipeline. Captured during
/// `AlertService.generateAndRefresh` so an admin can see exactly what the
/// generator computed without parsing console logs.
nonisolated struct AlertDiagnosticsSnapshot: Sendable {
    var vineyardId: UUID?
    var preferences: BackendAlertPreferences?
    var lastRunStartedAt: Date?
    var lastRunAt: Date?
    var lastSkipReason: String?
    var generatedCount: Int = 0
    var bySource: [String: Int] = [:]
    var upsertStatus: String?
    var upsertError: String?
    var fetchedCount: Int = 0
    var activeCount: Int = 0
    var unreadCount: Int = 0
    var dismissedCount: Int = 0
    var expiredCount: Int = 0
    var activeTypes: [String] = []
    var fetchError: String?
    var rain: RainDiagnostics = RainDiagnostics()

    struct RainDiagnostics: Sendable {
        var threshold: Double?
        var resolvedMm: Double?
        var source: String?
        var condition: Bool?
        var dedupKey: String?
        var localDate: String?
        var generatedAlertId: UUID?
        var generatedAlertExpiresAt: Date?
        var note: String?
    }
}

/// Combined view-model for the UI: alert + user-specific status.
nonisolated struct AlertWithStatus: Sendable, Identifiable, Hashable {
    let alert: BackendAlert
    let status: BackendAlertUserStatus?

    var id: UUID { alert.id }
    var isRead: Bool { status?.readAt != nil }
    var isDismissed: Bool { status?.dismissedAt != nil }
}

import Foundation

import SwiftUI

nonisolated extension Date {
    func formattedTZ(date dateStyle: Date.FormatStyle.DateStyle, time timeStyle: Date.FormatStyle.TimeStyle, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: dateStyle, time: timeStyle)
        style.timeZone = timeZone
        return self.formatted(style)
    }
}

extension AppSettings {
    nonisolated var resolvedTimeZone: TimeZone {
        TimeZone(identifier: timezone) ?? .current
    }

    nonisolated var resolvedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = resolvedTimeZone
        return cal
    }

    nonisolated var timezoneAbbreviation: String {
        resolvedTimeZone.abbreviation() ?? resolvedTimeZone.identifier
    }

    /// Region-aware formatter derived from this org's international settings.
    /// Falls back to Australian behaviour for legacy/unset organisations.
    nonisolated var regionFormatter: RegionFormatter {
        RegionFormatter(settings: regionSettings)
    }
}

nonisolated enum AppAppearance: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

nonisolated struct AppSettings: Codable, Sendable, Identifiable {
    var id: UUID
    var vineyardId: UUID
    var timezone: String
    var seasonStartMonth: Int
    var seasonStartDay: Int
    var rowTrackingEnabled: Bool
    var rowTrackingInterval: Double
    var defaultPaddockId: UUID?
    var autoPhotoPrompt: Bool
    var enabledGrowthStageCodes: [String]
    var weatherStationId: String?
    var defaultWaterVolume: Double
    var defaultSprayRate: Double
    var defaultConcentrationFactor: Double
    var paddockOrder: [UUID]
    var canopyWaterRates: CanopyWaterRateEntry
    var seasonFuelCostPerLitre: Double
    var appearance: AppAppearance
    var fillTimerEnabled: Bool
    var samplesPerHectare: Int
    var defaultBlockBunchWeightsGrams: [UUID: Double]
    var elConfirmationEnabled: Bool
    var vineyardLatitude: Double?
    var vineyardLongitude: Double?
    var vineyardElevationMetres: Double?
    var useBEDD: Bool
    var calculationMode: GDDCalculationMode
    var resetMode: GDDResetMode
    var rainAlertEnabled: Bool
    var rainAlertThresholdMm: Double
    var rainAlertWindowDays: Int
    var irrigationAlertEnabled: Bool
    var irrigationAlertPaddockId: UUID?
    var irrigationKc: Double
    var irrigationEfficiencyPercent: Double
    var irrigationRainfallEffectivenessPercent: Double
    var irrigationReplacementPercent: Double
    var irrigationSoilBufferMm: Double
    var irrigationForecastDays: Int
    /// Vineyard-level default irrigation application rate (mm/hr). Used
    /// by the Irrigation Advisor in Whole Vineyard mode when no paddock
    /// system rate is selected. 0 means "not configured".
    var irrigationDefaultApplicationRateMmPerHour: Double
    /// Vineyard-level default recent-rain lookback window (days) used
    /// by the Irrigation Advisor. Allowed values: 1 (24h), 2 (48h),
    /// 7 (7d), 14 (14d). 0 means "not configured" — defaults to 7.
    var irrigationRecentRainLookbackDays: Int
    var aiSuggestionsEnabled: Bool
    /// Organisation-level international settings (country, currency, units,
    /// date format, terminology). Defaults to Australian behaviour, so existing
    /// organisations are unaffected.
    var regionSettings: OrganizationRegionSettings

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        timezone: String = TimeZone.current.identifier,
        seasonStartMonth: Int = 7,
        seasonStartDay: Int = 1,
        rowTrackingEnabled: Bool = true,
        rowTrackingInterval: Double = 1.0,
        defaultPaddockId: UUID? = nil,
        autoPhotoPrompt: Bool = false,
        enabledGrowthStageCodes: [String] = GrowthStage.allStages.map { $0.code },
        weatherStationId: String? = nil,
        defaultWaterVolume: Double = 0,
        defaultSprayRate: Double = 0,
        defaultConcentrationFactor: Double = 1.0,
        paddockOrder: [UUID] = [],
        canopyWaterRates: CanopyWaterRateEntry = .defaults,
        seasonFuelCostPerLitre: Double = 0,
        appearance: AppAppearance = .system,
        fillTimerEnabled: Bool = false,
        samplesPerHectare: Int = 20,
        defaultBlockBunchWeightsGrams: [UUID: Double] = [:],
        elConfirmationEnabled: Bool = true,
        vineyardLatitude: Double? = nil,
        vineyardLongitude: Double? = nil,
        vineyardElevationMetres: Double? = nil,
        useBEDD: Bool = true,
        calculationMode: GDDCalculationMode = .bedd,
        resetMode: GDDResetMode = .budburst,
        rainAlertEnabled: Bool = false,
        rainAlertThresholdMm: Double = 5,
        rainAlertWindowDays: Int = 28,
        irrigationAlertEnabled: Bool = false,
        irrigationAlertPaddockId: UUID? = nil,
        irrigationKc: Double = 0.65,
        irrigationEfficiencyPercent: Double = 90,
        irrigationRainfallEffectivenessPercent: Double = 80,
        irrigationReplacementPercent: Double = 100,
        irrigationSoilBufferMm: Double = 0,
        irrigationForecastDays: Int = 5,
        irrigationDefaultApplicationRateMmPerHour: Double = 0,
        irrigationRecentRainLookbackDays: Int = 7,
        aiSuggestionsEnabled: Bool = true,
        regionSettings: OrganizationRegionSettings = .australianDefaults
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.timezone = timezone
        self.seasonStartMonth = seasonStartMonth
        self.seasonStartDay = seasonStartDay
        self.rowTrackingEnabled = rowTrackingEnabled
        self.rowTrackingInterval = rowTrackingInterval
        self.defaultPaddockId = defaultPaddockId
        self.autoPhotoPrompt = autoPhotoPrompt
        self.enabledGrowthStageCodes = enabledGrowthStageCodes
        self.weatherStationId = weatherStationId
        self.defaultWaterVolume = defaultWaterVolume
        self.defaultSprayRate = defaultSprayRate
        self.defaultConcentrationFactor = defaultConcentrationFactor
        self.paddockOrder = paddockOrder
        self.canopyWaterRates = canopyWaterRates
        self.seasonFuelCostPerLitre = seasonFuelCostPerLitre
        self.appearance = appearance
        self.fillTimerEnabled = fillTimerEnabled
        self.samplesPerHectare = samplesPerHectare
        self.defaultBlockBunchWeightsGrams = defaultBlockBunchWeightsGrams
        self.elConfirmationEnabled = elConfirmationEnabled
        self.vineyardLatitude = vineyardLatitude
        self.vineyardLongitude = vineyardLongitude
        self.vineyardElevationMetres = vineyardElevationMetres
        self.useBEDD = useBEDD
        self.calculationMode = calculationMode
        self.resetMode = resetMode
        self.rainAlertEnabled = rainAlertEnabled
        self.rainAlertThresholdMm = rainAlertThresholdMm
        self.rainAlertWindowDays = rainAlertWindowDays
        self.irrigationAlertEnabled = irrigationAlertEnabled
        self.irrigationAlertPaddockId = irrigationAlertPaddockId
        self.irrigationKc = irrigationKc
        self.irrigationEfficiencyPercent = irrigationEfficiencyPercent
        self.irrigationRainfallEffectivenessPercent = irrigationRainfallEffectivenessPercent
        self.irrigationReplacementPercent = irrigationReplacementPercent
        self.irrigationSoilBufferMm = irrigationSoilBufferMm
        self.irrigationForecastDays = irrigationForecastDays
        self.irrigationDefaultApplicationRateMmPerHour = irrigationDefaultApplicationRateMmPerHour
        self.irrigationRecentRainLookbackDays = irrigationRecentRainLookbackDays
        self.aiSuggestionsEnabled = aiSuggestionsEnabled
        self.regionSettings = regionSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        timezone = try container.decode(String.self, forKey: .timezone)
        seasonStartMonth = try container.decode(Int.self, forKey: .seasonStartMonth)
        seasonStartDay = try container.decode(Int.self, forKey: .seasonStartDay)
        rowTrackingEnabled = try container.decode(Bool.self, forKey: .rowTrackingEnabled)
        rowTrackingInterval = try container.decode(Double.self, forKey: .rowTrackingInterval)
        defaultPaddockId = try container.decodeIfPresent(UUID.self, forKey: .defaultPaddockId)
        autoPhotoPrompt = try container.decodeIfPresent(Bool.self, forKey: .autoPhotoPrompt) ?? false
        enabledGrowthStageCodes = try container.decode([String].self, forKey: .enabledGrowthStageCodes)
        weatherStationId = try container.decodeIfPresent(String.self, forKey: .weatherStationId)
        defaultWaterVolume = try container.decodeIfPresent(Double.self, forKey: .defaultWaterVolume) ?? 0
        defaultSprayRate = try container.decodeIfPresent(Double.self, forKey: .defaultSprayRate) ?? 0
        defaultConcentrationFactor = try container.decodeIfPresent(Double.self, forKey: .defaultConcentrationFactor) ?? 1.0
        paddockOrder = try container.decodeIfPresent([UUID].self, forKey: .paddockOrder) ?? []
        canopyWaterRates = try container.decodeIfPresent(CanopyWaterRateEntry.self, forKey: .canopyWaterRates) ?? .defaults
        seasonFuelCostPerLitre = try container.decodeIfPresent(Double.self, forKey: .seasonFuelCostPerLitre) ?? 0
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        fillTimerEnabled = try container.decodeIfPresent(Bool.self, forKey: .fillTimerEnabled) ?? false
        samplesPerHectare = try container.decodeIfPresent(Int.self, forKey: .samplesPerHectare) ?? 20
        defaultBlockBunchWeightsGrams = try container.decodeIfPresent([UUID: Double].self, forKey: .defaultBlockBunchWeightsGrams) ?? [:]
        elConfirmationEnabled = try container.decodeIfPresent(Bool.self, forKey: .elConfirmationEnabled) ?? true
        vineyardLatitude = try container.decodeIfPresent(Double.self, forKey: .vineyardLatitude)
        vineyardLongitude = try container.decodeIfPresent(Double.self, forKey: .vineyardLongitude)
        vineyardElevationMetres = try container.decodeIfPresent(Double.self, forKey: .vineyardElevationMetres)
        useBEDD = try container.decodeIfPresent(Bool.self, forKey: .useBEDD) ?? true
        if let mode = try container.decodeIfPresent(GDDCalculationMode.self, forKey: .calculationMode) {
            calculationMode = mode
        } else {
            calculationMode = useBEDD ? .bedd : .gdd
        }
        resetMode = try container.decodeIfPresent(GDDResetMode.self, forKey: .resetMode) ?? .budburst
        rainAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .rainAlertEnabled) ?? false
        rainAlertThresholdMm = try container.decodeIfPresent(Double.self, forKey: .rainAlertThresholdMm) ?? 5
        rainAlertWindowDays = try container.decodeIfPresent(Int.self, forKey: .rainAlertWindowDays) ?? 28
        irrigationAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .irrigationAlertEnabled) ?? false
        irrigationAlertPaddockId = try container.decodeIfPresent(UUID.self, forKey: .irrigationAlertPaddockId)
        irrigationKc = try container.decodeIfPresent(Double.self, forKey: .irrigationKc) ?? 0.65
        irrigationEfficiencyPercent = try container.decodeIfPresent(Double.self, forKey: .irrigationEfficiencyPercent) ?? 90
        irrigationRainfallEffectivenessPercent = try container.decodeIfPresent(Double.self, forKey: .irrigationRainfallEffectivenessPercent) ?? 80
        irrigationReplacementPercent = try container.decodeIfPresent(Double.self, forKey: .irrigationReplacementPercent) ?? 100
        irrigationSoilBufferMm = try container.decodeIfPresent(Double.self, forKey: .irrigationSoilBufferMm) ?? 0
        irrigationForecastDays = try container.decodeIfPresent(Int.self, forKey: .irrigationForecastDays) ?? 5
        irrigationDefaultApplicationRateMmPerHour = try container.decodeIfPresent(Double.self, forKey: .irrigationDefaultApplicationRateMmPerHour) ?? 0
        irrigationRecentRainLookbackDays = try container.decodeIfPresent(Int.self, forKey: .irrigationRecentRainLookbackDays) ?? 7
        aiSuggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiSuggestionsEnabled) ?? true
        if let region = try container.decodeIfPresent(OrganizationRegionSettings.self, forKey: .regionSettings) {
            regionSettings = region
        } else {
            // Legacy records have no region block. Fall back to Australian
            // defaults but preserve the org's existing timezone selection.
            var defaults = OrganizationRegionSettings.australianDefaults
            defaults.timezone = timezone
            regionSettings = defaults
        }
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, timezone, seasonStartMonth, seasonStartDay
        case rowTrackingEnabled, rowTrackingInterval, defaultPaddockId
        case autoPhotoPrompt, enabledGrowthStageCodes, weatherStationId
        case defaultWaterVolume, defaultSprayRate, defaultConcentrationFactor
        case paddockOrder, canopyWaterRates, seasonFuelCostPerLitre, appearance, fillTimerEnabled, samplesPerHectare, defaultBlockBunchWeightsGrams, elConfirmationEnabled
        case vineyardLatitude, vineyardLongitude, vineyardElevationMetres, useBEDD, calculationMode, resetMode
        case rainAlertEnabled, rainAlertThresholdMm, rainAlertWindowDays
        case irrigationAlertEnabled, irrigationAlertPaddockId, irrigationKc, irrigationEfficiencyPercent, irrigationRainfallEffectivenessPercent, irrigationReplacementPercent, irrigationSoilBufferMm
        case irrigationForecastDays
        case irrigationDefaultApplicationRateMmPerHour
        case irrigationRecentRainLookbackDays
        case aiSuggestionsEnabled
        case regionSettings
    }
}

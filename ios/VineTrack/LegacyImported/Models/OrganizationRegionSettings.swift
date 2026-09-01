import Foundation

/// Organisation-level international settings data contract.
///
/// This is the canonical shape the iOS app leads with and the Lovable portal
/// follows. All values are stored as plain strings so they map cleanly onto
/// future text columns (e.g. on `public.vineyards`) and so unknown/foreign
/// values never break decoding.
///
/// IMPORTANT — non-breaking guarantees:
/// - Every field has an Australian default.
/// - Decoding tolerates missing/null fields and falls back to the AU default.
/// - Internal storage of records (areas in hectares, volumes in litres,
///   distances in metres) is unchanged. These settings only affect *display*
///   and *formatting*, never the stored values.
nonisolated struct OrganizationRegionSettings: Codable, Sendable, Equatable {
    /// ISO-3166 alpha-2 country code, e.g. "AU", "NZ", "US", "CA", "GB", "ZA".
    var countryCode: String
    /// ISO-4217 currency code, e.g. "AUD", "NZD", "USD", "CAD", "GBP", "ZAR".
    var currencyCode: String
    /// IANA timezone identifier, e.g. "Australia/Sydney".
    var timezone: String
    /// Area unit raw value — see `AreaUnit` ("hectares" | "acres").
    var areaUnit: String
    /// Volume unit raw value — see `VolumeUnit` ("litres" | "gallons").
    var volumeUnit: String
    /// Distance system raw value — see `DistanceSystem` ("metric" | "imperial").
    var distanceUnit: String
    /// Fuel unit raw value — see `FuelUnit` ("litres" | "gallons").
    var fuelUnit: String
    /// Spray-rate area denominator raw value — see `SprayRateAreaUnit`
    /// ("hectare" | "acre").
    var sprayRateAreaUnit: String
    /// Date format raw value — see `RegionDateFormat`
    /// ("DD/MM/YYYY" | "MM/DD/YYYY" | "YYYY-MM-DD").
    var dateFormat: String
    /// Terminology region raw value — see `TerminologyRegion`
    /// ("AU_NZ" | "US" | "UK" | "ZA").
    var terminologyRegion: String
    /// Grape sugar measurement raw value — see `SugarMeasurementUnit`
    /// ("brix" | "baume"). Empty string means "no explicit preference";
    /// the resolved unit then falls back to the country default
    /// (AU/NZ → Baumé, everywhere else → Brix).
    var sugarMeasurementUnit: String
    /// Rainfall display unit raw value — see `RainfallUnit`
    /// ("millimetres" | "inches", sql/216). Rainfall records are always
    /// stored in millimetres; this only affects display and formatting.
    var rainfallUnit: String

    // MARK: - Australian defaults (current production behaviour)

    static let australianDefaults = OrganizationRegionSettings(
        countryCode: "AU",
        currencyCode: "AUD",
        timezone: "Australia/Sydney",
        areaUnit: AreaUnit.hectares.rawValue,
        volumeUnit: VolumeUnit.litres.rawValue,
        distanceUnit: DistanceSystem.metric.rawValue,
        fuelUnit: FuelUnit.litres.rawValue,
        sprayRateAreaUnit: SprayRateAreaUnit.hectare.rawValue,
        dateFormat: RegionDateFormat.dayMonthYear.rawValue,
        terminologyRegion: TerminologyRegion.auNz.rawValue,
        sugarMeasurementUnit: "",
        rainfallUnit: RainfallUnit.millimetres.rawValue
    )

    init(
        countryCode: String = "AU",
        currencyCode: String = "AUD",
        timezone: String = "Australia/Sydney",
        areaUnit: String = AreaUnit.hectares.rawValue,
        volumeUnit: String = VolumeUnit.litres.rawValue,
        distanceUnit: String = DistanceSystem.metric.rawValue,
        fuelUnit: String = FuelUnit.litres.rawValue,
        sprayRateAreaUnit: String = SprayRateAreaUnit.hectare.rawValue,
        dateFormat: String = RegionDateFormat.dayMonthYear.rawValue,
        terminologyRegion: String = TerminologyRegion.auNz.rawValue,
        sugarMeasurementUnit: String = "",
        rainfallUnit: String = RainfallUnit.millimetres.rawValue
    ) {
        self.countryCode = countryCode
        self.currencyCode = currencyCode
        self.timezone = timezone
        self.areaUnit = areaUnit
        self.volumeUnit = volumeUnit
        self.distanceUnit = distanceUnit
        self.fuelUnit = fuelUnit
        self.sprayRateAreaUnit = sprayRateAreaUnit
        self.dateFormat = dateFormat
        self.terminologyRegion = terminologyRegion
        self.sugarMeasurementUnit = sugarMeasurementUnit
        self.rainfallUnit = rainfallUnit
    }

    /// Tolerant decoder: any missing/null field falls back to the AU default,
    /// guaranteeing existing organisations keep behaving exactly as today.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OrganizationRegionSettings.australianDefaults
        countryCode = (try? c.decodeIfPresent(String.self, forKey: .countryCode))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.countryCode
        currencyCode = (try? c.decodeIfPresent(String.self, forKey: .currencyCode))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.currencyCode
        timezone = (try? c.decodeIfPresent(String.self, forKey: .timezone))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.timezone
        areaUnit = (try? c.decodeIfPresent(String.self, forKey: .areaUnit))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.areaUnit
        volumeUnit = (try? c.decodeIfPresent(String.self, forKey: .volumeUnit))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.volumeUnit
        distanceUnit = (try? c.decodeIfPresent(String.self, forKey: .distanceUnit))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.distanceUnit
        fuelUnit = (try? c.decodeIfPresent(String.self, forKey: .fuelUnit))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.fuelUnit
        sprayRateAreaUnit = (try? c.decodeIfPresent(String.self, forKey: .sprayRateAreaUnit))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.sprayRateAreaUnit
        dateFormat = (try? c.decodeIfPresent(String.self, forKey: .dateFormat))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.dateFormat
        terminologyRegion = (try? c.decodeIfPresent(String.self, forKey: .terminologyRegion))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.terminologyRegion
        sugarMeasurementUnit = (try? c.decodeIfPresent(String.self, forKey: .sugarMeasurementUnit)) ?? ""
        rainfallUnit = (try? c.decodeIfPresent(String.self, forKey: .rainfallUnit))?.flatMap { $0.isEmpty ? nil : $0 } ?? d.rainfallUnit
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case currencyCode = "currency_code"
        case timezone
        case areaUnit = "area_unit"
        case volumeUnit = "volume_unit"
        case distanceUnit = "distance_unit"
        case fuelUnit = "fuel_unit"
        case sprayRateAreaUnit = "spray_rate_area_unit"
        case dateFormat = "date_format"
        case terminologyRegion = "terminology_region"
        case sugarMeasurementUnit = "sugar_measurement_unit"
        case rainfallUnit = "rainfall_unit"
    }
}

// MARK: - Typed accessors (safe parsing of the string contract)

nonisolated extension OrganizationRegionSettings {
    var area: AreaUnit { AreaUnit(rawValue: areaUnit) ?? .hectares }
    var volume: VolumeUnit { VolumeUnit(rawValue: volumeUnit) ?? .litres }
    var distance: DistanceSystem { DistanceSystem(rawValue: distanceUnit) ?? .metric }
    var fuel: FuelUnit { FuelUnit(rawValue: fuelUnit) ?? .litres }
    var sprayRateArea: SprayRateAreaUnit { SprayRateAreaUnit(rawValue: sprayRateAreaUnit) ?? .hectare }
    var dateStyle: RegionDateFormat { RegionDateFormat(rawValue: dateFormat) ?? .dayMonthYear }
    var terminology: TerminologyRegion { TerminologyRegion(rawValue: terminologyRegion) ?? .auNz }
    var rainfall: RainfallUnit { RainfallUnit(rawValue: rainfallUnit) ?? .millimetres }

    /// Resolved grape sugar measurement: the explicit vineyard preference when
    /// set, otherwise the regional default for the vineyard's country.
    var sugarUnit: SugarMeasurementUnit {
        SugarMeasurementUnit(rawValue: sugarMeasurementUnit)
            ?? SugarMeasurementUnit.regionalDefault(countryCode: countryCode)
    }

    var resolvedTimeZone: TimeZone { TimeZone(identifier: timezone) ?? .current }

    /// US and Canada use US liquid gallons; UK/other imperial markets use
    /// imperial gallons. Only relevant when a gallon unit is selected.
    var usesUSGallon: Bool {
        countryCode.uppercased() == "US" || countryCode.uppercased() == "CA"
    }
}

// MARK: - Unit enums

nonisolated enum AreaUnit: String, Codable, Sendable, CaseIterable {
    case hectares
    case acres

    var abbreviation: String {
        switch self {
        case .hectares: "ha"
        case .acres: "ac"
        }
    }
}

nonisolated enum VolumeUnit: String, Codable, Sendable, CaseIterable {
    case litres
    case gallons
}

nonisolated enum DistanceSystem: String, Codable, Sendable, CaseIterable {
    case metric
    case imperial
}

nonisolated enum FuelUnit: String, Codable, Sendable, CaseIterable {
    case litres
    case gallons

    var abbreviation: String {
        switch self {
        case .litres: "L"
        case .gallons: "gal"
        }
    }
}

/// Rainfall display units (sql/216 — `vineyards.rainfall_unit`). Rainfall
/// records are ALWAYS stored in millimetres; this preference only changes how
/// they are displayed, never the stored values.
nonisolated enum RainfallUnit: String, Codable, Sendable, CaseIterable {
    case millimetres
    case inches

    var abbreviation: String {
        switch self {
        case .millimetres: "mm"
        case .inches: "in"
        }
    }

    var displayName: String {
        switch self {
        case .millimetres: "Millimetres (mm)"
        case .inches: "Inches (in)"
        }
    }
}

nonisolated enum SprayRateAreaUnit: String, Codable, Sendable, CaseIterable {
    case hectare
    case acre

    var abbreviation: String {
        switch self {
        case .hectare: "ha"
        case .acre: "ac"
        }
    }
}

nonisolated enum RegionDateFormat: String, Codable, Sendable, CaseIterable {
    case dayMonthYear = "DD/MM/YYYY"
    case monthDayYear = "MM/DD/YYYY"
    case isoYearMonthDay = "YYYY-MM-DD"

    /// `Date.FormatStyle`-compatible representation is handled in
    /// `RegionFormatter`; this exposes the separator/order for manual builds.
    var dateFormatTemplate: String {
        switch self {
        case .dayMonthYear: "dd/MM/yyyy"
        case .monthDayYear: "MM/dd/yyyy"
        case .isoYearMonthDay: "yyyy-MM-dd"
        }
    }

    /// Two-digit-year variant of `dateFormatTemplate` for tight UI (e.g. the
    /// completion date under a pruning row's tick). Same field order.
    var shortDateFormatTemplate: String {
        switch self {
        case .dayMonthYear: "dd/MM/yy"
        case .monthDayYear: "MM/dd/yy"
        case .isoYearMonthDay: "yy-MM-dd"
        }
    }
}

/// Grape sugar measurement units (sql/180 — `vineyards.sugar_measurement_unit`
/// and `picking_records.sugar_unit`). Historical picking records always store
/// the unit alongside the value, so changing the vineyard preference never
/// reinterprets old data.
nonisolated enum SugarMeasurementUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case brix
    case baume

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brix: "Brix (°Bx)"
        case .baume: "Baumé (°Bé)"
        }
    }

    var symbol: String {
        switch self {
        case .brix: "°Bx"
        case .baume: "°Bé"
        }
    }

    /// Regional default for vineyards without an explicit saved preference:
    /// AU/NZ traditionally measure in Baumé, everywhere else in Brix.
    static func regionalDefault(countryCode: String) -> SugarMeasurementUnit {
        switch countryCode.uppercased() {
        case "AU", "NZ": .baume
        default: .brix
        }
    }
}

nonisolated enum TerminologyRegion: String, Codable, Sendable, CaseIterable {
    case auNz = "AU_NZ"
    case us = "US"
    case uk = "UK"
    case za = "ZA"

    /// The word used for an individual planted area. AU/NZ vineyards say
    /// "block"; other regions keep "block" for now but this is the hook for
    /// future region-specific terminology (e.g. "lot", "parcel").
    var blockTerm: String {
        switch self {
        case .auNz, .us, .uk, .za: "block"
        }
    }

    var blockTermPlural: String { blockTerm + "s" }
}

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
        terminologyRegion: TerminologyRegion.auNz.rawValue
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
        terminologyRegion: String = TerminologyRegion.auNz.rawValue
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

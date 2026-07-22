import Foundation

/// Central, region-aware formatter for display values.
///
/// VineTrack stores all records in canonical internal units:
/// - areas in **hectares**
/// - volumes / fuel in **litres**
/// - distances in **metres**
/// - spray rates per **hectare**
///
/// `RegionFormatter` converts those canonical values for *display only* based
/// on an `OrganizationRegionSettings`. With the Australian defaults it performs
/// no conversion and produces exactly the same strings as today, so existing
/// AU/NZ users are unaffected.
///
/// Construct via `RegionFormatter(settings:)`. For call sites that have no
/// settings yet, use `RegionFormatter.australian` which mirrors current output.
nonisolated struct RegionFormatter: Sendable {
    let settings: OrganizationRegionSettings

    init(settings: OrganizationRegionSettings = .australianDefaults) {
        self.settings = settings
    }

    /// Convenience formatter matching current production (AU) behaviour.
    static let australian = RegionFormatter(settings: .australianDefaults)

    // MARK: - Conversion constants

    private static let acresPerHectare = 2.471053814672
    private static let usGallonsPerLitre = 0.264172052
    private static let imperialGallonsPerLitre = 0.219969157
    private static let feetPerMetre = 3.280839895
    private static let milesPerKilometre = 0.621371192

    // MARK: - Area (input: hectares)

    /// Converts a hectare value into the configured display unit.
    func areaValue(hectares: Double) -> Double {
        switch settings.area {
        case .hectares: hectares
        case .acres: hectares * Self.acresPerHectare
        }
    }

    var areaUnitAbbreviation: String { settings.area.abbreviation }

    /// e.g. "12.50 ha" (AU) or "30.89 ac" (US).
    func formatArea(hectares: Double, fractionDigits: Int = 2) -> String {
        let value = areaValue(hectares: hectares)
        return "\(Self.number(value, fractionDigits: fractionDigits)) \(areaUnitAbbreviation)"
    }

    // MARK: - Volume (input: litres)

    func volumeValue(litres: Double) -> Double {
        switch settings.volume {
        case .litres: litres
        case .gallons: litres * gallonsPerLitre
        }
    }

    var volumeUnitAbbreviation: String {
        switch settings.volume {
        case .litres: "L"
        case .gallons: "gal"
        }
    }

    func formatVolume(litres: Double, fractionDigits: Int = 1) -> String {
        let value = volumeValue(litres: litres)
        return "\(Self.number(value, fractionDigits: fractionDigits)) \(volumeUnitAbbreviation)"
    }

    // MARK: - Fuel (input: litres)

    func fuelValue(litres: Double) -> Double {
        switch settings.fuel {
        case .litres: litres
        case .gallons: litres * gallonsPerLitre
        }
    }

    var fuelUnitAbbreviation: String { settings.fuel.abbreviation }

    func formatFuel(litres: Double, fractionDigits: Int = 1) -> String {
        let value = fuelValue(litres: litres)
        return "\(Self.number(value, fractionDigits: fractionDigits)) \(fuelUnitAbbreviation)"
    }

    /// Fuel cost per fuel unit. Input is the canonical cost **per litre**; for
    /// imperial/US fuel this is converted to cost **per gallon** so the rate and
    /// its unit label stay consistent (e.g. "$1.85/L" (AU) or "$7.00/gal" (US)).
    func formatFuelCostPerUnit(perLitre: Double) -> String {
        let perUnit: Double
        switch settings.fuel {
        case .litres: perUnit = perLitre
        case .gallons: perUnit = perLitre / gallonsPerLitre
        }
        return "\(formatCurrency(perUnit))/\(fuelUnitAbbreviation)"
    }

    /// Fuel consumption rate per engine hour. Input is canonical litres/hour;
    /// converts to gal/hr for imperial/US (e.g. "12.5 L/hr" or "3.3 gal/hr").
    func formatFuelRatePerHour(litresPerHour: Double, fractionDigits: Int = 1) -> String {
        let value = fuelValue(litres: litresPerHour)
        return "\(Self.number(value, fractionDigits: fractionDigits)) \(fuelUnitAbbreviation)/hr"
    }

    /// US vs imperial gallon depending on the organisation's country.
    private var gallonsPerLitre: Double {
        settings.usesUSGallon ? Self.usGallonsPerLitre : Self.imperialGallonsPerLitre
    }

    // MARK: - Distance (input: metres)

    /// Short distances (e.g. < 1 unit) stay in metres/feet; longer ones use
    /// kilometres/miles. Returns a formatted string with the chosen unit.
    func formatDistance(metres: Double, fractionDigits: Int = 2) -> String {
        switch settings.distance {
        case .metric:
            let km = metres / 1000.0
            return "\(Self.number(km, fractionDigits: fractionDigits)) km"
        case .imperial:
            let miles = (metres / 1000.0) * Self.milesPerKilometre
            return "\(Self.number(miles, fractionDigits: fractionDigits)) mi"
        }
    }

    /// Short, navigation-style distance for nearby points (e.g. distance to a
    /// pin). Uses metres/kilometres for metric and feet/miles for imperial,
    /// switching to the larger unit past ~1 unit. With AU (metric) defaults this
    /// matches the previous "337m" / "1.5km" display exactly.
    func formatShortDistance(metres: Double) -> String {
        switch settings.distance {
        case .metric:
            if metres < 1000 {
                return "\(Int(metres.rounded()))m"
            }
            return "\(Self.number(metres / 1000.0, fractionDigits: 1))km"
        case .imperial:
            let feet = metres * Self.feetPerMetre
            if feet < 5280 {
                return "\(Int(feet.rounded()))ft"
            }
            let miles = (metres / 1000.0) * Self.milesPerKilometre
            return "\(Self.number(miles, fractionDigits: 1))mi"
        }
    }

    /// Speed input is km/h (canonical). Converts to mph for imperial.
    func formatSpeed(kmh: Double, fractionDigits: Int = 1) -> String {
        switch settings.distance {
        case .metric:
            return "\(Self.number(kmh, fractionDigits: fractionDigits)) km/h"
        case .imperial:
            let mph = kmh * Self.milesPerKilometre
            return "\(Self.number(mph, fractionDigits: fractionDigits)) mph"
        }
    }

    // MARK: - Duration (input: seconds)

    /// Friendly elapsed-duration string for *display* (not live timers).
    ///
    /// Always uses "min" — never "m" — for minutes so it can't be confused
    /// with metres. Under 1 hour → "X min"; 1 hour or more → "X h Y min"
    /// (omitting the minutes when zero, e.g. "2 h"). Duration is not a
    /// region-converted unit, so this is also exposed as a `static` helper
    /// for call sites (e.g. exports) that have no formatter instance.
    static func formatDuration(seconds: TimeInterval) -> String {
        let safe = seconds.isFinite && seconds > 0 ? seconds : 0
        let totalMinutes = Int((safe / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 { return "\(hours) h \(minutes) min" }
        if hours > 0 { return "\(hours) h" }
        return "\(minutes) min"
    }

    /// Instance convenience mirroring `RegionFormatter.formatDuration(seconds:)`.
    func formatDuration(seconds: TimeInterval) -> String {
        Self.formatDuration(seconds: seconds)
    }

    // MARK: - Currency

    var currencyCode: String { settings.currencyCode }

    func formatCurrency(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = settings.currencyCode
        f.locale = currencyLocale
        return f.string(from: NSNumber(value: amount)) ?? "\(settings.currencyCode) \(Self.number(amount, fractionDigits: 2))"
    }

    private var currencyLocale: Locale {
        // Anchor the currency formatting to the organisation country so the
        // symbol placement/grouping matches local expectations.
        Locale(identifier: "en_\(settings.countryCode.uppercased())")
    }

    // MARK: - Spray rate (input: per hectare)

    /// Converts a per-hectare rate to the configured spray-rate area unit.
    func sprayRateValue(perHectare: Double) -> Double {
        switch settings.sprayRateArea {
        case .hectare: perHectare
        case .acre: perHectare / Self.acresPerHectare
        }
    }

    var sprayRateAreaAbbreviation: String { settings.sprayRateArea.abbreviation }

    /// e.g. "2.50 L/ha" (AU) or "1.01 L/ac" (US). `unitLabel` is the numerator
    /// unit such as "L" or "kg".
    func formatSprayRate(perHectare: Double, unitLabel: String, fractionDigits: Int = 2) -> String {
        let value = sprayRateValue(perHectare: perHectare)
        return "\(Self.number(value, fractionDigits: fractionDigits)) \(unitLabel)/\(sprayRateAreaAbbreviation)"
    }

    // MARK: - Yield per area (input: per hectare)

    /// Converts a per-hectare quantity into the configured display area unit.
    /// e.g. tonnes/ha → tonnes/acre for the US.
    func perAreaValue(perHectare: Double) -> Double {
        switch settings.area {
        case .hectares: perHectare
        case .acres: perHectare / Self.acresPerHectare
        }
    }

    /// Formats a yield-per-area value. `unitLabel` is the numerator unit such as
    /// "t" or "kg". e.g. "12.50 t/ha" (AU) or "5.06 t/ac" (US).
    func formatYieldPerArea(perHectare: Double, unitLabel: String = "t", fractionDigits: Int = 2) -> String {
        let value = perAreaValue(perHectare: perHectare)
        return "\(Self.number(value, fractionDigits: fractionDigits)) \(unitLabel)/\(areaUnitAbbreviation)"
    }

    /// The yield-per-area unit label only, e.g. "t/ha" (AU) or "t/ac" (US).
    func yieldPerAreaUnit(unitLabel: String = "t") -> String {
        "\(unitLabel)/\(areaUnitAbbreviation)"
    }

    // MARK: - Date / DateTime

    func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = settings.resolvedTimeZone
        f.locale = Locale(identifier: "en_\(settings.countryCode.uppercased())")
        f.dateFormat = settings.dateStyle.dateFormatTemplate
        return f.string(from: date)
    }

    func formatDateTime(_ date: Date, includeSeconds: Bool = false) -> String {
        let f = DateFormatter()
        f.timeZone = settings.resolvedTimeZone
        f.locale = Locale(identifier: "en_\(settings.countryCode.uppercased())")
        let time = includeSeconds ? "HH:mm:ss" : "HH:mm"
        f.dateFormat = "\(settings.dateStyle.dateFormatTemplate) \(time)"
        return f.string(from: date)
    }

    // MARK: - Terminology

    /// Singular word for a planted area, e.g. "block".
    var blockTerm: String { settings.terminology.blockTerm }
    var blockTermPlural: String { settings.terminology.blockTermPlural }

    /// Capitalised variants for headings.
    var blockTermCapitalised: String { blockTerm.capitalized }
    var blockTermPluralCapitalised: String { blockTermPlural.capitalized }

    // MARK: - Helpers

    private static func number(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }
}

package com.rork.vinetrack.data

import java.text.DateFormatSymbols
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Currency
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

/**
 * Central, region-aware formatter for display values — the Android twin of the
 * iOS `RegionFormatter`.
 *
 * VineTrack stores all records in canonical internal units:
 * - areas in **hectares**
 * - volumes / fuel in **litres**
 * - distances in **metres**
 * - spray rates per **hectare**
 *
 * This converts those canonical values for *display only* based on a
 * [RegionSettings]. With the Australian defaults it performs no conversion and
 * produces exactly the same strings as before, so existing AU/NZ users are
 * unaffected.
 */
class RegionFormatter(val settings: RegionSettings = RegionSettings.defaults) {

    private val area: AreaUnit get() = AreaUnit.from(settings.areaUnit)
    private val volume: VolumeUnit get() = VolumeUnit.from(settings.volumeUnit)
    private val fuel: FuelUnit get() = FuelUnit.from(settings.fuelUnit)
    private val distance: DistanceSystem get() = DistanceSystem.from(settings.distanceUnit)
    private val sprayRateArea: SprayRateAreaUnit get() = SprayRateAreaUnit.from(settings.sprayRateAreaUnit)
    private val rainfall: RainfallUnit get() = RainfallUnit.from(settings.rainfallUnit)

    /** US and Canada use US liquid gallons; UK/other imperial markets use imperial gallons. */
    private val usesUSGallon: Boolean
        get() = settings.countryCode.uppercase() == "US" || settings.countryCode.uppercase() == "CA"

    private val gallonsPerLitre: Double
        get() = if (usesUSGallon) US_GALLONS_PER_LITRE else IMPERIAL_GALLONS_PER_LITRE

    // MARK: - Area (input: hectares)

    fun areaValue(hectares: Double): Double = when (area) {
        AreaUnit.Hectares -> hectares
        AreaUnit.Acres -> hectares * ACRES_PER_HECTARE
    }

    val areaUnitAbbreviation: String get() = when (area) {
        AreaUnit.Hectares -> "ha"
        AreaUnit.Acres -> "ac"
    }

    /**
     * Full-word label for the configured area unit, for stat tiles that show the
     * number and its unit as separate lines (e.g. the Home "Vineyard Overview"
     * card) rather than as one "12.5 ha" string.
     *
     * Mirrors iOS `NewMainTabView.areaUnitLabel`.
     */
    val areaUnitName: String get() = when (area) {
        AreaUnit.Hectares -> "Hectares"
        AreaUnit.Acres -> "Acres"
    }

    /**
     * Area for large headline stat tiles: converts to the vineyard's unit, then
     * drops the decimal once the converted value reaches 100 ("1234", "12.5").
     * Returns the number ONLY — callers pair it with [areaUnitName] as a
     * separate caption.
     *
     * Distinct from [areaCompactValue], which trims at 10 for dense inline rows.
     * Both threshold on the CONVERTED value so the precision rule describes what
     * the user actually sees. Mirrors iOS `NewMainTabView.formattedHectares`.
     */
    fun formatAreaHeadline(hectares: Double): String {
        val value = areaValue(hectares)
        return if (value >= 100) number(value, 0) else number(value, 1)
    }

    /** e.g. "12.50 ha" (AU) or "30.89 ac" (US). */
    fun formatArea(hectares: Double, fractionDigits: Int = 2): String =
        "${number(areaValue(hectares), fractionDigits)} $areaUnitAbbreviation"

    /**
     * Compact area for dense rows and stat tiles: converts to the vineyard's
     * unit, then drops the decimals once the converted value reaches 10
     * (e.g. "12 ha", "4.5 ha", "30 ac").
     *
     * This reproduces the trimming the screens previously did inline with
     * hardcoded " ha" suffixes, so AU/NZ output is byte-for-byte unchanged
     * while other regions now convert. Thresholding on the CONVERTED value
     * keeps the precision rule about what the user actually sees.
     */
    fun formatAreaCompact(hectares: Double): String =
        "${compactNumber(areaValue(hectares))} $areaUnitAbbreviation"

    /** Compact area value with no unit suffix, for "12 ha"-style split labels. */
    fun areaCompactValue(hectares: Double): String = compactNumber(areaValue(hectares))

    /**
     * Inverse of [areaValue]: converts a value the user typed **in the displayed
     * unit** back to canonical hectares for storage.
     *
     * Editable regionalised fields must round-trip
     * `canonical → display → user edit → canonical`. Displaying acres while
     * saving the typed number as hectares would silently corrupt the record, so
     * every editable area field pairs [areaValue] on the way in with this on the
     * way out.
     */
    fun areaToCanonical(displayValue: Double): Double = when (area) {
        AreaUnit.Hectares -> displayValue
        AreaUnit.Acres -> displayValue / ACRES_PER_HECTARE
    }

    // MARK: - Volume (input: litres)

    fun volumeValue(litres: Double): Double = when (volume) {
        VolumeUnit.Litres -> litres
        VolumeUnit.Gallons -> litres * gallonsPerLitre
    }

    val volumeUnitAbbreviation: String get() = when (volume) {
        VolumeUnit.Litres -> "L"
        VolumeUnit.Gallons -> "gal"
    }

    fun formatVolume(litres: Double, fractionDigits: Int = 1): String =
        "${number(volumeValue(litres), fractionDigits)} $volumeUnitAbbreviation"

    /** Inverse of [volumeValue]: displayed volume → canonical litres. */
    fun volumeToCanonical(displayValue: Double): Double = when (volume) {
        VolumeUnit.Litres -> displayValue
        VolumeUnit.Gallons -> displayValue / gallonsPerLitre
    }

    // MARK: - Fuel (input: litres)

    fun fuelValue(litres: Double): Double = when (fuel) {
        FuelUnit.Litres -> litres
        FuelUnit.Gallons -> litres * gallonsPerLitre
    }

    val fuelUnitAbbreviation: String get() = when (fuel) {
        FuelUnit.Litres -> "L"
        FuelUnit.Gallons -> "gal"
    }

    fun formatFuel(litres: Double, fractionDigits: Int = 1): String =
        "${number(fuelValue(litres), fractionDigits)} $fuelUnitAbbreviation"

    /** Inverse of [fuelValue]: displayed fuel volume → canonical litres. */
    fun fuelToCanonical(displayValue: Double): Double = when (fuel) {
        FuelUnit.Litres -> displayValue
        FuelUnit.Gallons -> displayValue / gallonsPerLitre
    }

    /**
     * Fuel cost per fuel unit. Input is canonical cost **per litre**; converted
     * to cost **per gallon** for gallon markets (e.g. "$1.85/L" or "$7.00/gal").
     */
    fun formatFuelCostPerUnit(perLitre: Double): String {
        val perUnit = when (fuel) {
            FuelUnit.Litres -> perLitre
            FuelUnit.Gallons -> perLitre / gallonsPerLitre
        }
        return "${formatCurrency(perUnit)}/$fuelUnitAbbreviation"
    }

    /** Fuel consumption rate per engine hour (canonical L/hr → gal/hr for imperial). */
    fun formatFuelRatePerHour(litresPerHour: Double, fractionDigits: Int = 1): String =
        "${number(fuelValue(litresPerHour), fractionDigits)} $fuelUnitAbbreviation/hr"

    // MARK: - Rainfall (input: millimetres)

    /**
     * Converts a canonical millimetre rainfall value into the configured
     * display unit. Rainfall records are always STORED in millimetres
     * (sql/216); this is display-only. Mirrors iOS `rainfallValue(mm:)`.
     */
    fun rainfallValue(mm: Double): Double = when (rainfall) {
        RainfallUnit.Millimetres -> mm
        RainfallUnit.Inches -> mm / MM_PER_INCH
    }

    val rainfallUnitAbbreviation: String get() = when (rainfall) {
        RainfallUnit.Millimetres -> "mm"
        RainfallUnit.Inches -> "in"
    }

    /**
     * e.g. "12.5 mm" (AU) or "0.49 in" (US). Millimetres keep the historical
     * one-decimal display; inches use two decimals because 1 mm ≈ 0.04 in.
     * Mirrors iOS `formatRainfall(mm:)`.
     */
    fun formatRainfall(mm: Double, fractionDigits: Int? = null): String {
        val digits = fractionDigits ?: if (rainfall == RainfallUnit.Inches) 2 else 1
        return "${number(rainfallValue(mm), digits)} $rainfallUnitAbbreviation"
    }

    // MARK: - Distance (input: metres)

    fun formatDistance(metres: Double, fractionDigits: Int = 2): String = when (distance) {
        DistanceSystem.Metric -> "${number(metres / 1000.0, fractionDigits)} km"
        DistanceSystem.Imperial -> "${number((metres / 1000.0) * MILES_PER_KM, fractionDigits)} mi"
    }

    /** Short, navigation-style distance for nearby points (e.g. "337m" / "1.5km"). */
    fun formatShortDistance(metres: Double): String = when (distance) {
        DistanceSystem.Metric ->
            if (metres < 1000) "${metres.roundToInt()}m"
            else "${number(metres / 1000.0, 1)}km"
        DistanceSystem.Imperial -> {
            val feet = metres * FEET_PER_METRE
            if (feet < 5280) "${feet.roundToInt()}ft"
            else "${number((metres / 1000.0) * MILES_PER_KM, 1)}mi"
        }
    }

    /** Speed input is km/h (canonical); converts to mph for imperial. */
    fun formatSpeed(kmh: Double, fractionDigits: Int = 1): String = when (distance) {
        DistanceSystem.Metric -> "${number(kmh, fractionDigits)} km/h"
        DistanceSystem.Imperial -> "${number(kmh * MILES_PER_KM, fractionDigits)} mph"
    }

    // MARK: - Currency

    val currencyCode: String get() = settings.currencyCode

    fun formatCurrency(amount: Double): String {
        return runCatching {
            val nf = NumberFormat.getCurrencyInstance(currencyLocale)
            nf.currency = Currency.getInstance(settings.currencyCode)
            nf.format(amount)
        }.getOrElse { "${settings.currencyCode} ${number(amount, 2)}" }
    }

    private val currencyLocale: Locale
        get() = Locale.Builder().setLanguage("en").setRegion(settings.countryCode.uppercase()).build()

    /** The region's currency symbol, e.g. "$", "£", "€". Falls back to the code. */
    val currencySymbol: String
        get() = runCatching {
            Currency.getInstance(settings.currencyCode).getSymbol(currencyLocale)
        }.getOrElse { settings.currencyCode }

    /**
     * Compact currency label (e.g. "$1,250", "£42.50") using the region's
     * currency symbol. Whole amounts drop the decimals; otherwise two are shown.
     */
    fun formatCompactCurrency(amount: Double): String {
        val rounded = if (amount % 1.0 == 0.0) String.format(Locale.US, "%,d", amount.toLong())
        else String.format(Locale.US, "%,.2f", amount)
        return "$currencySymbol$rounded"
    }

    // MARK: - Spray rate (input: per hectare)

    fun sprayRateValue(perHectare: Double): Double = when (sprayRateArea) {
        SprayRateAreaUnit.Hectare -> perHectare
        SprayRateAreaUnit.Acre -> perHectare / ACRES_PER_HECTARE
    }

    val sprayRateAreaAbbreviation: String get() = when (sprayRateArea) {
        SprayRateAreaUnit.Hectare -> "ha"
        SprayRateAreaUnit.Acre -> "ac"
    }

    /** e.g. "2.50 L/ha" (AU) or "1.01 L/ac" (US). `unitLabel` is the numerator unit. */
    fun formatSprayRate(perHectare: Double, unitLabel: String, fractionDigits: Int = 2): String =
        "${number(sprayRateValue(perHectare), fractionDigits)} $unitLabel/$sprayRateAreaAbbreviation"

    /** Inverse of [sprayRateValue]: displayed per-area rate → canonical per hectare. */
    fun sprayRateToCanonical(displayValue: Double): Double = when (sprayRateArea) {
        SprayRateAreaUnit.Hectare -> displayValue
        SprayRateAreaUnit.Acre -> displayValue * ACRES_PER_HECTARE
    }

    /**
     * An application rate whose numerator is a **mass** (kg/ha, t/ha) or any
     * other unit that the Region & Units contract keeps canonical. Only the area
     * denominator converts, matching how iOS uses `formatSprayRate` with a
     * caller-supplied numerator label.
     */
    fun massPerAreaUnit(unitLabel: String = "kg"): String = "$unitLabel/$sprayRateAreaAbbreviation"

    /** The spray/application rate unit label only, e.g. "L/ha" or "gal/ac". */
    val volumePerAreaUnit: String get() = "$volumeUnitAbbreviation/$sprayRateAreaAbbreviation"

    /**
     * A canonical litres-per-hectare rate in the vineyard's units, converting
     * BOTH dimensions (volume and area) e.g. "1,200 L/ha" → "128 gal/ac".
     */
    fun formatVolumePerArea(litresPerHectare: Double, fractionDigits: Int = 0): String =
        "${number(sprayRateValue(volumeValue(litresPerHectare)), fractionDigits)} $volumePerAreaUnit"

    /** As [formatVolumePerArea] but per hour, e.g. "1,200 L/ha/h" → "128 gal/ac/h". */
    fun formatVolumePerAreaPerHour(litresPerHectarePerHour: Double): String {
        val v = sprayRateValue(volumeValue(litresPerHectarePerHour))
        return "${String.format(Locale.US, "%,.0f", v)} $volumePerAreaUnit/h"
    }

    // MARK: - Yield per area (input: per hectare)

    fun perAreaValue(perHectare: Double): Double = when (area) {
        AreaUnit.Hectares -> perHectare
        AreaUnit.Acres -> perHectare / ACRES_PER_HECTARE
    }

    /** e.g. "12.50 t/ha" (AU) or "5.06 t/ac" (US). */
    fun formatYieldPerArea(perHectare: Double, unitLabel: String = "t", fractionDigits: Int = 2): String =
        "${number(perAreaValue(perHectare), fractionDigits)} $unitLabel/$areaUnitAbbreviation"

    /** The yield-per-area unit label only, e.g. "t/ha" (AU) or "t/ac" (US). */
    fun yieldPerAreaUnit(unitLabel: String = "t"): String = "$unitLabel/$areaUnitAbbreviation"

    /** Inverse of [perAreaValue]: displayed per-area quantity → canonical per hectare. */
    fun perAreaToCanonical(displayValue: Double): Double = when (area) {
        AreaUnit.Hectares -> displayValue
        AreaUnit.Acres -> displayValue * ACRES_PER_HECTARE
    }

    // MARK: - Cost per unit

    /** Cost-per-area unit label, e.g. "Cost / ha" → "Cost / ac". */
    val costPerAreaUnit: String get() = areaUnitAbbreviation

    /**
     * A canonical cost **per hectare** rendered per the vineyard's area unit.
     * The money is only re-based over a smaller area, so an acre market sees a
     * proportionally smaller figure for the same total spend.
     */
    fun formatCostPerArea(costPerHectare: Double): String =
        "${formatCurrency(perAreaValue(costPerHectare))}/$areaUnitAbbreviation"

    /** A canonical cost **per litre** rendered per the vineyard's volume unit. */
    fun formatCostPerVolume(costPerLitre: Double): String {
        val perUnit = when (volume) {
            VolumeUnit.Litres -> costPerLitre
            VolumeUnit.Gallons -> costPerLitre / gallonsPerLitre
        }
        return "${formatCurrency(perUnit)}/$volumeUnitAbbreviation"
    }

    // MARK: - Dates

    /**
     * The vineyard's timezone (sql/099 `vineyards.timezone`), falling back to the
     * device zone exactly as iOS `resolvedTimeZone` does. Used for every
     * user-visible date so a vineyard's records read consistently regardless of
     * where the phone happens to be.
     */
    private val resolvedTimeZone: TimeZone
        get() = settings.timezone?.takeIf { it.isNotBlank() }
            ?.let { id -> TimeZone.getAvailableIDs().firstOrNull { it == id }?.let(TimeZone::getTimeZone) }
            ?: TimeZone.getDefault()

    /** Builds a formatter bound to the vineyard's locale and timezone, never the device's. */
    private fun dateFormatter(template: String): SimpleDateFormat =
        SimpleDateFormat(template, currencyLocale).apply { timeZone = resolvedTimeZone }

    /** The vineyard's numeric date template, identical to iOS `dateFormatTemplate`. */
    private val dateTemplate: String
        get() = when (RegionDateFormat.from(settings.dateFormat)) {
            RegionDateFormat.DayMonthYear -> "dd/MM/yyyy"
            RegionDateFormat.MonthDayYear -> "MM/dd/yyyy"
            RegionDateFormat.IsoYearMonthDay -> "yyyy-MM-dd"
        }

    /**
     * Region-aware numeric date — the exact Android twin of iOS
     * `RegionFormatter.formatDate`: "05/03/2026" (DD/MM/YYYY), "03/05/2026"
     * (MM/DD/YYYY) or "2026-03-05" (YYYY-MM-DD).
     *
     * This is the literal rendering of the vineyard's saved `dateFormat`, so a
     * vineyard set to MM/DD/YYYY never shows a day-first date.
     */
    fun formatDate(epochMs: Long): String = dateFormatter(dateTemplate).format(Date(epochMs))

    /**
     * Month-name date whose field ORDER still follows the vineyard's saved
     * `dateFormat`: "5 Mar 2026" (DD/MM/YYYY), "Mar 5, 2026" (MM/DD/YYYY) or
     * "2026 Mar 5" (YYYY-MM-DD).
     *
     * Used where a month name is materially easier to scan than digits (record
     * list rows, activity timelines). It is a presentation variant of the same
     * setting — never a second source of truth — so a US vineyard still reads
     * month-first here just as it does in [formatDate].
     */
    fun formatDateMedium(epochMs: Long): String {
        val template = when (RegionDateFormat.from(settings.dateFormat)) {
            RegionDateFormat.DayMonthYear -> "d MMM yyyy"
            RegionDateFormat.MonthDayYear -> "MMM d, yyyy"
            RegionDateFormat.IsoYearMonthDay -> "yyyy MMM d"
        }
        return dateFormatter(template).format(Date(epochMs))
    }

    /** Region-aware numeric date + 24h time, matching iOS `formatDateTime`. */
    fun formatDateTime(epochMs: Long, includeSeconds: Boolean = false): String {
        val time = if (includeSeconds) "HH:mm:ss" else "HH:mm"
        return dateFormatter("$dateTemplate $time").format(Date(epochMs))
    }

    /** Month-name date + locale-appropriate clock time, e.g. "5 Mar 2026, 3:04 pm". */
    fun formatDateTimeMedium(epochMs: Long): String =
        "${formatDateMedium(epochMs)}, ${formatTime(epochMs)}"

    /** Clock time in the vineyard's locale and timezone (12h or 24h per region). */
    fun formatTime(epochMs: Long): String {
        val is12Hour = currencyLocale.country in TWELVE_HOUR_COUNTRIES
        return dateFormatter(if (is12Hour) "h:mm a" else "HH:mm").format(Date(epochMs))
    }

    /** Weekday + month-name date without a year, e.g. "Thu 5 Mar" / "Thu, Mar 5". */
    fun formatDayAndMonth(epochMs: Long): String {
        val template = when (RegionDateFormat.from(settings.dateFormat)) {
            RegionDateFormat.MonthDayYear -> "EEE, MMM d"
            else -> "EEE d MMM"
        }
        return dateFormatter(template).format(Date(epochMs))
    }

    /** Month + year only, e.g. "March 2026", in the vineyard's locale. */
    fun formatMonthYear(epochMs: Long): String = dateFormatter("MMMM yyyy").format(Date(epochMs))

    /** Short month name for a 1-based month number, in the vineyard's locale. */
    fun monthAbbreviation(month: Int): String =
        DateFormatSymbols(currencyLocale).shortMonths.getOrNull(month - 1)
            ?.takeIf { it.isNotBlank() } ?: month.toString()

    /** Full month name for a 1-based month number, in the vineyard's locale. */
    fun monthName(month: Int): String =
        DateFormatSymbols(currencyLocale).months.getOrNull(month - 1)
            ?.takeIf { it.isNotBlank() } ?: month.toString()

    // MARK: - Temperature
    //
    // Temperature is deliberately NOT region-converted. The Region & Units
    // contract (sql/099) has no temperature unit, and iOS `RegionFormatter`
    // has no temperature conversion either — GDD/BEDD models, disease-risk
    // thresholds and spray records are all defined in Celsius. Converting on
    // Android alone would make the same vineyard read differently on the two
    // platforms, which is the very bug this layer exists to prevent.
    //
    // Celsius is therefore canonical AND displayed. If Fahrenheit display is
    // ever wanted it must be added to the shared backend contract and to iOS
    // first; `RegionFormatterTest` pins the current behaviour so an accidental
    // one-sided change fails the build.

    /** Canonical Celsius display, identical in every region (see note above). */
    fun formatTemperature(celsius: Double, fractionDigits: Int = 1): String =
        "${number(celsius, fractionDigits)}°C"

    // MARK: - Terminology

    val blockTerm: String get() = "block"
    val blockTermPlural: String get() = "blocks"
    val blockTermCapitalised: String get() = blockTerm.replaceFirstChar { it.uppercase() }
    val blockTermPluralCapitalised: String get() = blockTermPlural.replaceFirstChar { it.uppercase() }

    private fun number(value: Double, fractionDigits: Int): String =
        String.format(Locale.US, "%.${fractionDigits}f", value)

    /** Whole numbers at >= 10, otherwise one decimal. Locale-independent. */
    private fun compactNumber(value: Double): String =
        if (value >= 10) value.toInt().toString() else String.format(Locale.US, "%.1f", value)

    companion object {
        /**
         * Markets that read a 12-hour clock. Derived from the vineyard's country
         * code, not the device clock setting, so a record's timestamp reads the
         * same for every user of that vineyard.
         */
        private val TWELVE_HOUR_COUNTRIES = setOf("AU", "NZ", "US", "CA", "ZA", "IN", "PH")

        private const val ACRES_PER_HECTARE = 2.471053814672
        private const val US_GALLONS_PER_LITRE = 0.264172052
        private const val IMPERIAL_GALLONS_PER_LITRE = 0.219969157
        private const val FEET_PER_METRE = 3.280839895
        private const val MILES_PER_KM = 0.621371192
        private const val MM_PER_INCH = 25.4

        /** Convenience formatter matching current production (AU) behaviour. */
        val australian = RegionFormatter(RegionSettings.defaults)

        /** Friendly elapsed-duration string for display (not live timers). */
        fun formatDuration(seconds: Long): String {
            val safe = if (seconds > 0) seconds else 0
            val totalMinutes = ((safe.toDouble()) / 60.0).roundToInt()
            val hours = totalMinutes / 60
            val minutes = totalMinutes % 60
            return when {
                hours > 0 && minutes > 0 -> "$hours h $minutes min"
                hours > 0 -> "$hours h"
                else -> "$minutes min"
            }
        }
    }
}

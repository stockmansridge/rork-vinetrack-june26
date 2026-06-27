package com.rork.vinetrack.data

import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Currency
import java.util.Date
import java.util.Locale
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

    /** e.g. "12.50 ha" (AU) or "30.89 ac" (US). */
    fun formatArea(hectares: Double, fractionDigits: Int = 2): String =
        "${number(areaValue(hectares), fractionDigits)} $areaUnitAbbreviation"

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

    // MARK: - Dates

    /**
     * Region-aware medium date, the Android twin of iOS `RegionFormatter.formatDate`.
     * e.g. "5 Mar 2026" (AU/NZ/UK/ZA), "Mar 5, 2026" (US) or "2026-03-05" (CA/ISO).
     */
    fun formatDate(epochMs: Long): String {
        val template = when (RegionDateFormat.from(settings.dateFormat)) {
            RegionDateFormat.DayMonthYear -> "d MMM yyyy"
            RegionDateFormat.MonthDayYear -> "MMM d, yyyy"
            RegionDateFormat.IsoYearMonthDay -> "yyyy-MM-dd"
        }
        return SimpleDateFormat(template, currencyLocale).format(Date(epochMs))
    }

    // MARK: - Terminology

    val blockTerm: String get() = "block"
    val blockTermPlural: String get() = "blocks"
    val blockTermCapitalised: String get() = blockTerm.replaceFirstChar { it.uppercase() }
    val blockTermPluralCapitalised: String get() = blockTermPlural.replaceFirstChar { it.uppercase() }

    private fun number(value: Double, fractionDigits: Int): String =
        String.format(Locale.US, "%.${fractionDigits}f", value)

    companion object {
        private const val ACRES_PER_HECTARE = 2.471053814672
        private const val US_GALLONS_PER_LITRE = 0.264172052
        private const val IMPERIAL_GALLONS_PER_LITRE = 0.219969157
        private const val FEET_PER_METRE = 3.280839895
        private const val MILES_PER_KM = 0.621371192

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

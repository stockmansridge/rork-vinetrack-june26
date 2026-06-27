package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Vineyard-level "Region & Units" settings, mirroring the iOS
 * `OrganizationRegionSettings` contract (sql/099). These control how vineyard
 * records are *displayed and exported* — changing them never rewrites stored
 * records.
 *
 * The authoritative source is the `vineyards` row, read/written through the
 * `get_vineyard_region_settings` / `set_vineyard_region_settings` RPCs (see
 * [RegionSettingsRepository]). A copy is cached locally per-vineyard for
 * instant display on launch. Any null/blank value falls back to the Australian
 * defaults, so existing AU/NZ vineyards behave exactly as before.
 */
data class RegionSettings(
    val countryCode: String = "AU",
    val currencyCode: String = "AUD",
    val timezone: String? = null,
    val areaUnit: String = AreaUnit.Hectares.raw,
    val volumeUnit: String = VolumeUnit.Litres.raw,
    val distanceUnit: String = DistanceSystem.Metric.raw,
    val fuelUnit: String = FuelUnit.Litres.raw,
    val sprayRateAreaUnit: String = SprayRateAreaUnit.Hectare.raw,
    val dateFormat: String = RegionDateFormat.DayMonthYear.raw,
    val terminologyRegion: String = TerminologyRegion.AuNz.raw,
) {
    companion object {
        val defaults = RegionSettings()
    }
}

enum class AreaUnit(val raw: String, val label: String) {
    Hectares("hectares", "Hectares (ha)"),
    Acres("acres", "Acres (ac)");
    companion object { fun from(v: String?): AreaUnit = entries.firstOrNull { it.raw == v } ?: Hectares }
}

enum class VolumeUnit(val raw: String, val label: String) {
    Litres("litres", "Litres (L)"),
    Gallons("gallons", "Gallons (gal)");
    companion object { fun from(v: String?): VolumeUnit = entries.firstOrNull { it.raw == v } ?: Litres }
}

enum class DistanceSystem(val raw: String, val label: String) {
    Metric("metric", "Metric (km)"),
    Imperial("imperial", "Imperial (mi)");
    companion object { fun from(v: String?): DistanceSystem = entries.firstOrNull { it.raw == v } ?: Metric }
}

enum class FuelUnit(val raw: String, val label: String) {
    Litres("litres", "Litres (L)"),
    Gallons("gallons", "Gallons (gal)");
    companion object { fun from(v: String?): FuelUnit = entries.firstOrNull { it.raw == v } ?: Litres }
}

enum class SprayRateAreaUnit(val raw: String, val label: String) {
    Hectare("hectare", "Per Hectare (/ha)"),
    Acre("acre", "Per Acre (/ac)");
    companion object { fun from(v: String?): SprayRateAreaUnit = entries.firstOrNull { it.raw == v } ?: Hectare }
}

enum class RegionDateFormat(val raw: String, val label: String) {
    DayMonthYear("DD/MM/YYYY", "DD/MM/YYYY"),
    MonthDayYear("MM/DD/YYYY", "MM/DD/YYYY"),
    IsoYearMonthDay("YYYY-MM-DD", "YYYY-MM-DD");
    companion object { fun from(v: String?): RegionDateFormat = entries.firstOrNull { it.raw == v } ?: DayMonthYear }
}

enum class TerminologyRegion(val raw: String, val label: String) {
    AuNz("au_nz", "Australia / New Zealand"),
    Us("us", "United States / Canada"),
    Uk("uk", "United Kingdom"),
    Za("za", "South Africa");
    companion object { fun from(v: String?): TerminologyRegion = entries.firstOrNull { it.raw == v } ?: AuNz }
}

/** Supported currencies offered in the Region & Units picker. */
enum class RegionCurrency(val code: String, val label: String) {
    Aud("AUD", "Australian Dollar (AUD)"),
    Nzd("NZD", "New Zealand Dollar (NZD)"),
    Usd("USD", "US Dollar (USD)"),
    Cad("CAD", "Canadian Dollar (CAD)"),
    Gbp("GBP", "Pound Sterling (GBP)"),
    Zar("ZAR", "South African Rand (ZAR)"),
}

/**
 * Supported markets, each with a recommended preset the user can opt into when
 * switching country. Mirrors the iOS `RegionCountry` presets exactly.
 */
enum class RegionCountry(val code: String, val displayName: String) {
    Australia("AU", "Australia"),
    NewZealand("NZ", "New Zealand"),
    UnitedStates("US", "United States"),
    Canada("CA", "Canada"),
    UnitedKingdom("GB", "United Kingdom"),
    SouthAfrica("ZA", "South Africa");

    val recommendedPreset: RegionSettings
        get() = when (this) {
            Australia -> RegionSettings(countryCode = code, currencyCode = "AUD", areaUnit = AreaUnit.Hectares.raw, volumeUnit = VolumeUnit.Litres.raw, distanceUnit = DistanceSystem.Metric.raw, fuelUnit = FuelUnit.Litres.raw, sprayRateAreaUnit = SprayRateAreaUnit.Hectare.raw, dateFormat = RegionDateFormat.DayMonthYear.raw, terminologyRegion = TerminologyRegion.AuNz.raw)
            NewZealand -> RegionSettings(countryCode = code, currencyCode = "NZD", areaUnit = AreaUnit.Hectares.raw, volumeUnit = VolumeUnit.Litres.raw, distanceUnit = DistanceSystem.Metric.raw, fuelUnit = FuelUnit.Litres.raw, sprayRateAreaUnit = SprayRateAreaUnit.Hectare.raw, dateFormat = RegionDateFormat.DayMonthYear.raw, terminologyRegion = TerminologyRegion.AuNz.raw)
            UnitedStates -> RegionSettings(countryCode = code, currencyCode = "USD", areaUnit = AreaUnit.Acres.raw, volumeUnit = VolumeUnit.Gallons.raw, distanceUnit = DistanceSystem.Imperial.raw, fuelUnit = FuelUnit.Gallons.raw, sprayRateAreaUnit = SprayRateAreaUnit.Acre.raw, dateFormat = RegionDateFormat.MonthDayYear.raw, terminologyRegion = TerminologyRegion.Us.raw)
            Canada -> RegionSettings(countryCode = code, currencyCode = "CAD", areaUnit = AreaUnit.Hectares.raw, volumeUnit = VolumeUnit.Litres.raw, distanceUnit = DistanceSystem.Metric.raw, fuelUnit = FuelUnit.Litres.raw, sprayRateAreaUnit = SprayRateAreaUnit.Hectare.raw, dateFormat = RegionDateFormat.IsoYearMonthDay.raw, terminologyRegion = TerminologyRegion.Us.raw)
            UnitedKingdom -> RegionSettings(countryCode = code, currencyCode = "GBP", areaUnit = AreaUnit.Hectares.raw, volumeUnit = VolumeUnit.Litres.raw, distanceUnit = DistanceSystem.Metric.raw, fuelUnit = FuelUnit.Litres.raw, sprayRateAreaUnit = SprayRateAreaUnit.Hectare.raw, dateFormat = RegionDateFormat.DayMonthYear.raw, terminologyRegion = TerminologyRegion.Uk.raw)
            SouthAfrica -> RegionSettings(countryCode = code, currencyCode = "ZAR", areaUnit = AreaUnit.Hectares.raw, volumeUnit = VolumeUnit.Litres.raw, distanceUnit = DistanceSystem.Metric.raw, fuelUnit = FuelUnit.Litres.raw, sprayRateAreaUnit = SprayRateAreaUnit.Hectare.raw, dateFormat = RegionDateFormat.DayMonthYear.raw, terminologyRegion = TerminologyRegion.Za.raw)
        }

    companion object { fun from(v: String?): RegionCountry = entries.firstOrNull { it.code == v } ?: Australia }
}

/**
 * Caches [RegionSettings] per-vineyard in SharedPreferences for instant display
 * on launch, following the same lightweight pattern as [CanopyWaterRatesStore].
 * The backend remains the source of truth via [RegionSettingsRepository].
 */
class RegionSettingsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_region_settings", Context.MODE_PRIVATE)

    fun load(vineyardId: String?): RegionSettings {
        val k = keyPrefix(vineyardId)
        val d = RegionSettings.defaults
        return RegionSettings(
            countryCode = prefs.getString("${k}country", d.countryCode) ?: d.countryCode,
            currencyCode = prefs.getString("${k}currency", d.currencyCode) ?: d.currencyCode,
            timezone = prefs.getString("${k}timezone", null),
            areaUnit = prefs.getString("${k}area", d.areaUnit) ?: d.areaUnit,
            volumeUnit = prefs.getString("${k}volume", d.volumeUnit) ?: d.volumeUnit,
            distanceUnit = prefs.getString("${k}distance", d.distanceUnit) ?: d.distanceUnit,
            fuelUnit = prefs.getString("${k}fuel", d.fuelUnit) ?: d.fuelUnit,
            sprayRateAreaUnit = prefs.getString("${k}spray_rate_area", d.sprayRateAreaUnit) ?: d.sprayRateAreaUnit,
            dateFormat = prefs.getString("${k}date_format", d.dateFormat) ?: d.dateFormat,
            terminologyRegion = prefs.getString("${k}terminology", d.terminologyRegion) ?: d.terminologyRegion,
        )
    }

    fun save(vineyardId: String?, s: RegionSettings) {
        val k = keyPrefix(vineyardId)
        prefs.edit {
            putString("${k}country", s.countryCode)
            putString("${k}currency", s.currencyCode)
            if (s.timezone != null) putString("${k}timezone", s.timezone) else remove("${k}timezone")
            putString("${k}area", s.areaUnit)
            putString("${k}volume", s.volumeUnit)
            putString("${k}distance", s.distanceUnit)
            putString("${k}fuel", s.fuelUnit)
            putString("${k}spray_rate_area", s.sprayRateAreaUnit)
            putString("${k}date_format", s.dateFormat)
            putString("${k}terminology", s.terminologyRegion)
        }
    }

    private fun keyPrefix(vineyardId: String?): String = "${vineyardId ?: "default"}__"
}

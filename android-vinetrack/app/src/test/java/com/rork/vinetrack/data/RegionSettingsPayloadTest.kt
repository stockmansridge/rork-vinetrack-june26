package com.rork.vinetrack.data

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the shared Region & Units RPC payloads.
 *
 * PostgREST resolves an overloaded function by the exact SET OF ARGUMENT NAMES
 * in the JSON body. `set_vineyard_region_settings` has two overloads — the
 * legacy 11-parameter one (sql/099) and the current 12-parameter one with the
 * sugar preference (sql/180). Dropping a null argument from the body therefore
 * matches NEITHER overload and PostgREST answers `404 PGRST202`, which is what
 * produced "Request failed (404)" when saving on Android.
 *
 * These tests pin the wire shape: every named parameter is always present, and
 * empty/absent values are literal JSON `null` — identical to what iOS sends.
 */
class RegionSettingsPayloadTest {

    private val vineyardId = "6f1b3a5c-2d4e-4f7a-9b8c-1a2b3c4d5e6f"

    @Test
    fun setArgsAlwaysSendEveryNamedParameterEvenWhenNull() {
        // Worst case: no timezone (managed under Vineyard Location) and no
        // explicit sugar preference — the exact combination that 404'd.
        val settings = RegionSettings.defaults.copy(timezone = null, sugarMeasurementUnit = "")

        val args = RegionSettingsPayload.setArgs(vineyardId, settings)

        assertEquals(RegionSettingsPayload.SET_KEYS.toSet(), args.keys)
        assertEquals(12, args.size)
        assertEquals(JsonNull, args["p_timezone"])
        assertEquals(JsonNull, args["p_sugar_measurement_unit"])
        assertEquals(vineyardId, args["p_vineyard_id"]?.jsonPrimitive?.content)
    }

    @Test
    fun setArgsCarryTheUsersRegionalChoices() {
        val settings = RegionSettings.defaults.copy(
            countryCode = "US",
            currencyCode = "USD",
            timezone = "America/Los_Angeles",
            areaUnit = AreaUnit.Acres.raw,
            volumeUnit = VolumeUnit.Gallons.raw,
            distanceUnit = DistanceSystem.Imperial.raw,
            fuelUnit = FuelUnit.Gallons.raw,
            sprayRateAreaUnit = SprayRateAreaUnit.Acre.raw,
            dateFormat = RegionDateFormat.MonthDayYear.raw,
            terminologyRegion = TerminologyRegion.Us.raw,
            sugarMeasurementUnit = SugarMeasurementUnit.Brix.raw,
        )

        val args = RegionSettingsPayload.setArgs(vineyardId, settings)

        assertEquals("US", args["p_country_code"]?.jsonPrimitive?.content)
        assertEquals("USD", args["p_currency_code"]?.jsonPrimitive?.content)
        assertEquals("America/Los_Angeles", args["p_timezone"]?.jsonPrimitive?.content)
        assertEquals("acres", args["p_area_unit"]?.jsonPrimitive?.content)
        assertEquals("gallons", args["p_volume_unit"]?.jsonPrimitive?.content)
        assertEquals("imperial", args["p_distance_unit"]?.jsonPrimitive?.content)
        assertEquals("gallons", args["p_fuel_unit"]?.jsonPrimitive?.content)
        assertEquals("acre", args["p_spray_rate_area_unit"]?.jsonPrimitive?.content)
        assertEquals(RegionDateFormat.MonthDayYear.raw, args["p_date_format"]?.jsonPrimitive?.content)
        assertEquals(TerminologyRegion.Us.raw, args["p_terminology_region"]?.jsonPrimitive?.content)
        assertEquals("brix", args["p_sugar_measurement_unit"]?.jsonPrimitive?.content)
    }

    @Test
    fun legacyFallbackOmitsOnlyTheSugarParameter() {
        val args = RegionSettingsPayload.setArgs(
            vineyardId,
            RegionSettings.defaults,
            includeSugarUnit = false,
        )

        assertEquals(RegionSettingsPayload.LEGACY_SET_KEYS.toSet(), args.keys)
        assertEquals(11, args.size)
        assertTrue("sugar param must be absent for the legacy overload", !args.containsKey("p_sugar_measurement_unit"))
    }

    @Test
    fun blankValuesAreSentAsNullNotEmptyStrings() {
        val settings = RegionSettings.defaults.copy(countryCode = "   ", currencyCode = "")

        val args = RegionSettingsPayload.setArgs(vineyardId, settings)

        assertEquals(JsonNull, args["p_country_code"])
        assertEquals(JsonNull, args["p_currency_code"])
    }

    @Test
    fun getArgsMatchTheSingleParameterReadRpc() {
        val args = RegionSettingsPayload.getArgs(vineyardId)

        assertEquals(setOf("p_vineyard_id"), args.keys)
        assertEquals(vineyardId, args["p_vineyard_id"]?.jsonPrimitive?.content)
    }

    /**
     * Guards the exact regression: the shared JSON config drops nulls, so a
     * `@Serializable` args class silently shrinks the body. The payload builder
     * must be immune to that setting.
     */
    @Test
    fun payloadSurvivesTheSharedExplicitNullsFalseJsonConfig() {
        val settings = RegionSettings.defaults.copy(timezone = null, sugarMeasurementUnit = "")

        val encoded = SupabaseClient.json.encodeToString(
            kotlinx.serialization.json.JsonObject.serializer(),
            RegionSettingsPayload.setArgs(vineyardId, settings),
        )

        RegionSettingsPayload.SET_KEYS.forEach { key ->
            assertTrue("payload must contain $key, got $encoded", encoded.contains("\"$key\""))
        }
        assertTrue("nulls must be explicit", encoded.contains("\"p_timezone\":null"))
        assertTrue("nulls must be explicit", encoded.contains("\"p_sugar_measurement_unit\":null"))
    }
}

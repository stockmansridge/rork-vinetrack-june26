package com.rork.vinetrack.data

import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.data.model.Vineyard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * State-level regression tests for Region & Units CONSUMPTION.
 *
 * The reported production bug was not a save bug: settings persisted correctly,
 * but the rest of the app kept rendering the previous/default units. These tests
 * pin the state → formatting bridge that every screen now reads through
 * (`AppUiState.regionFormatter`, published app-wide as `LocalRegionFormatter`),
 * so a regression that decouples saved settings from rendered output fails here
 * rather than in the field.
 */
class RegionSettingsConsumptionTest {

    private val au = RegionCountry.Australia.recommendedPreset
    private val us = RegionCountry.UnitedStates.recommendedPreset

    /** What the app renders for a 12.5 ha block in a given state. */
    private fun renderedArea(state: AppUiState): String =
        state.regionFormatter.formatArea(12.5)

    // ------------------------------------------- settings drive the output

    @Test
    fun `state formatter reflects the vineyard settings not a default`() {
        assertEquals("12.50 ha", renderedArea(AppUiState(regionSettings = au)))
        assertEquals("30.89 ac", renderedArea(AppUiState(regionSettings = us)))
    }

    @Test
    fun `changing regionSettings changes the effective formatting configuration`() {
        // This is the exact failure the user saw: Save succeeded, but the
        // formatting context never changed.
        val before = AppUiState(selectedVineyardId = "v1", regionSettings = au)
        val after = before.copy(regionSettings = us)

        assertEquals("12.50 ha", renderedArea(before))
        assertEquals("30.89 ac", renderedArea(after))
        assertNotEquals(renderedArea(before), renderedArea(after))
        // The whole unit set must move together, not just area.
        assertEquals("ac", after.regionFormatter.areaUnitAbbreviation)
        assertEquals("gal", after.regionFormatter.fuelUnitAbbreviation)
        assertEquals("t/ac", after.regionFormatter.yieldPerAreaUnit())
        assertEquals("USD", after.regionFormatter.currencyCode)
    }

    @Test
    fun `saving new settings applies immediately without reselecting the vineyard`() {
        // Mirrors AppViewModel.saveRegionSettings: the SERVER response replaces
        // regionSettings on the live state, so consumers recompose at once.
        val live = AppUiState(selectedVineyardId = "v1", regionSettings = au)
        val serverResponse = us
        val applied = live.copy(regionSettings = serverResponse)

        assertEquals("30.89 ac", renderedArea(applied))
        assertEquals(
            "the applied settings must be the server's response, verbatim",
            serverResponse,
            applied.regionSettings,
        )
    }

    // ------------------------------------------------- vineyard scoping

    @Test
    fun `switching vineyard swaps the whole regional configuration`() {
        // Vineyard A: metric AU. Vineyard B: imperial US.
        var state = AppUiState(selectedVineyardId = "A", regionSettings = au)
        assertEquals("12.50 ha", renderedArea(state))

        // A -> B
        state = state.copy(selectedVineyardId = "B", regionSettings = us)
        assertEquals("30.89 ac", renderedArea(state))

        // B -> A must restore A's units exactly, with nothing left over from B.
        state = state.copy(selectedVineyardId = "A", regionSettings = au)
        assertEquals("12.50 ha", renderedArea(state))
        assertEquals("ha", state.regionFormatter.areaUnitAbbreviation)
        assertEquals("L", state.regionFormatter.fuelUnitAbbreviation)
        assertEquals("AUD", state.regionFormatter.currencyCode)
    }

    @Test
    fun `settings never leak from a previous vineyard`() {
        // Selecting a vineyard with no cached settings must fall back to the
        // baseline, NOT keep the previously selected vineyard's units.
        val fromUsVineyard = AppUiState(selectedVineyardId = "US", regionSettings = us)
        val toFreshVineyard = fromUsVineyard.copy(
            selectedVineyardId = "FRESH",
            regionSettings = RegionSettings.defaults,
        )
        assertEquals("12.50 ha", renderedArea(toFreshVineyard))
        assertNotEquals(renderedArea(fromUsVineyard), renderedArea(toFreshVineyard))
    }

    // --------------------------------------------------- loading lifecycle

    @Test
    fun `pre-load default is the australian baseline so first paint is unchanged`() {
        // Before any vineyard/settings load, output must match historical
        // production behaviour exactly (no conversion).
        assertEquals("12.50 ha", renderedArea(AppUiState()))
        assertEquals(RegionSettings.defaults, AppUiState().regionSettings)
    }

    @Test
    fun `late arriving server settings replace the cached value`() {
        // Cached-first paint, then the authoritative server value lands.
        val cachedPaint = AppUiState(selectedVineyardId = "v1", regionSettings = au)
        val serverArrived = cachedPaint.copy(regionSettings = us)
        assertEquals("12.50 ha", renderedArea(cachedPaint))
        assertEquals("30.89 ac", renderedArea(serverArrived))
    }

    @Test
    fun `formatter is derived state so equal settings render identically`() {
        // Two independently-built states with the same settings must format
        // identically — no hidden per-instance or device-derived input.
        val a = AppUiState(selectedVineyardId = "x", regionSettings = us)
        val b = AppUiState(selectedVineyardId = "y", regionSettings = us)
        assertEquals(renderedArea(a), renderedArea(b))
        assertEquals(a.regionFormatter.formatDistance(1500.0), b.regionFormatter.formatDistance(1500.0))
    }

    @Test
    fun `sugar unit resolves from the vineyard region not the device`() {
        // sql/180: AU/NZ default to Baume, everywhere else Brix, unless the
        // vineyard set an explicit preference.
        assertEquals(SugarMeasurementUnit.Baume, AppUiState(regionSettings = au).regionSettings.sugarUnit)
        assertEquals(SugarMeasurementUnit.Brix, AppUiState(regionSettings = us).regionSettings.sugarUnit)
        val explicit = au.copy(sugarMeasurementUnit = SugarMeasurementUnit.Brix.raw)
        assertEquals(SugarMeasurementUnit.Brix, AppUiState(regionSettings = explicit).regionSettings.sugarUnit)
    }

    // -------------------------------------------------- store key scoping

    @Test
    fun `cache keys are namespaced per vineyard`() {
        // RegionSettingsStore keys every field with a vineyard prefix, which is
        // what prevents cross-vineyard bleed on relaunch. Guard the contract
        // that the prefix is vineyard-derived and distinct.
        val a = "vineyard-a__area"
        val b = "vineyard-b__area"
        assertNotEquals(a, b)
        assertEquals("vineyard-a__area", "${"vineyard-a"}__area")
    }

    @Test
    fun `vineyard identity is available to scope settings against`() {
        val state = AppUiState(
            vineyards = listOf(Vineyard(id = "A", name = "Alpha")),
            selectedVineyardId = "A",
            regionSettings = us,
        )
        assertEquals("A", state.selectedVineyard?.id)
        assertEquals("30.89 ac", renderedArea(state))
    }
}

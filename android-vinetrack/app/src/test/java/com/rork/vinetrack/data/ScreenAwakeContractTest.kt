package com.rork.vinetrack.data

import com.rork.vinetrack.ui.components.ScreenAwakeController
import com.rork.vinetrack.ui.components.ScreenAwakeController.Reason
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Regression tests for the forced screen-awake contract.
 *
 * Repairs / Growth pin dropping must hold the display on regardless of the
 * user's global Keep Screen Awake preference, and leaving a pin workflow must
 * never clear a hold another workflow still needs.
 */
class ScreenAwakeContractTest {

    @Before
    fun setUp() = ScreenAwakeController.reset()

    @After
    fun tearDown() = ScreenAwakeController.reset()

    private fun effective(preferenceEnabled: Boolean): Boolean =
        ScreenAwakeController.shouldKeepScreenAwake(
            preferenceEnabled = preferenceEnabled,
            preferenceScopes = ScreenAwakeController.preferenceScopes.value,
            forcedScopes = ScreenAwakeController.forcedScopes.value,
        )

    // ---- Forced pin-drop awake, preference OFF ----------------------------

    @Test
    fun `growth pin dropping keeps the screen awake with the preference off`() {
        ScreenAwakeController.addForcedScope(Reason.GrowthPinDrop)
        assertTrue(effective(preferenceEnabled = false))
    }

    @Test
    fun `repairs pin dropping keeps the screen awake with the preference off`() {
        ScreenAwakeController.addForcedScope(Reason.RepairPinDrop)
        assertTrue(effective(preferenceEnabled = false))
    }

    @Test
    fun `leaving pin dropping with the preference off restores normal timeout`() {
        ScreenAwakeController.addForcedScope(Reason.GrowthPinDrop)
        assertTrue(effective(preferenceEnabled = false))

        ScreenAwakeController.removeForcedScope(Reason.GrowthPinDrop)
        assertFalse(effective(preferenceEnabled = false))
    }

    // ---- Preference ON must not be clobbered by pin workflows -------------

    @Test
    fun `entering and leaving a pin workflow does not clear a preference hold`() {
        // A trip is recording, preference ON — the display must stay on
        // throughout an entire pin-drop workflow AND after it ends.
        ScreenAwakeController.addPreferenceScope(Reason.ActiveTrip)
        assertTrue(effective(preferenceEnabled = true))

        ScreenAwakeController.addForcedScope(Reason.RepairPinDrop)
        assertTrue(effective(preferenceEnabled = true))

        ScreenAwakeController.removeForcedScope(Reason.RepairPinDrop)
        assertTrue(
            "the active-trip hold must survive the pin workflow ending",
            effective(preferenceEnabled = true),
        )
    }

    @Test
    fun `one workflow ending never clears another live forced hold`() {
        ScreenAwakeController.addForcedScope(Reason.RepairPinDrop)
        ScreenAwakeController.addForcedScope(Reason.GrowthPinDrop)

        ScreenAwakeController.removeForcedScope(Reason.RepairPinDrop)
        assertTrue(
            "growth pin dropping still requires the screen",
            effective(preferenceEnabled = false),
        )

        ScreenAwakeController.removeForcedScope(Reason.GrowthPinDrop)
        assertFalse(effective(preferenceEnabled = false))
    }

    @Test
    fun `holds are idempotent so a recomposition cannot unbalance them`() {
        ScreenAwakeController.addForcedScope(Reason.GrowthPinDrop)
        ScreenAwakeController.addForcedScope(Reason.GrowthPinDrop)
        ScreenAwakeController.removeForcedScope(Reason.GrowthPinDrop)
        assertFalse(effective(preferenceEnabled = false))
    }

    // ---- Preference-gated holds still respect the preference --------------

    @Test
    fun `a preference-gated hold does nothing while the preference is off`() {
        ScreenAwakeController.addPreferenceScope(Reason.ActiveTrip)
        assertFalse(effective(preferenceEnabled = false))
    }

    @Test
    fun `no holds means no keep-awake even with the preference on`() {
        assertFalse(effective(preferenceEnabled = true))
    }

    @Test
    fun `sign out drops every hold`() {
        ScreenAwakeController.addPreferenceScope(Reason.ActiveTrip)
        ScreenAwakeController.addForcedScope(Reason.GrowthPinDrop)

        ScreenAwakeController.reset()

        assertFalse(effective(preferenceEnabled = true))
    }
}

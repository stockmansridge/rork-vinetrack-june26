package com.rork.vinetrack.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermanentItemPilotPolicyTest {
    @Test fun adminAndFlagAndMembershipAreAllRequired() {
        val policy = PermanentItemPilotPolicy
        assertTrue(policy.allowed(true, true, "account", "vineyard", "manager"))
        assertFalse(policy.allowed(false, true, "account", "vineyard", "owner"))
        assertFalse(policy.allowed(true, false, "account", "vineyard", "owner"))
        assertFalse(policy.allowed(true, true, null, "vineyard", "manager"))
        assertFalse(policy.allowed(true, true, "account", null, "manager"))
        assertFalse(policy.allowed(true, true, "account", "vineyard", null))
    }

    @Test fun onlyFixedFixtureLocationsAndTypesPassValidation() {
        assertTrue(PermanentItemPilotPolicy.valid("North Flush Valve", "flush_valve", -34.0, 138.0))
        assertFalse(PermanentItemPilotPolicy.valid("  ", "pump", -34.0, 138.0))
        assertFalse(PermanentItemPilotPolicy.valid("Spray", "spray", -34.0, 138.0))
        assertFalse(PermanentItemPilotPolicy.valid("Valve", "pump", 91.0, 138.0))
        assertFalse(PermanentItemPilotPolicy.valid("Valve", "pump", -34.0, 181.0))
        assertFalse(PermanentItemPilotPolicy.valid("Valve", "pump", Double.NaN, 138.0))
    }
}

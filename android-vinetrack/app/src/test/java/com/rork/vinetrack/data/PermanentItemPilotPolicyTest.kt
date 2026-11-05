package com.rork.vinetrack.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermanentItemPilotPolicyTest {
    @Test fun adminAndFlagAndMembershipAreAllRequired() {
        val policy = PermanentItemPilotPolicy
        assertTrue(policy.allowed(true, true, "account", "vineyard", "manager"))
        assertTrue(policy.allowed(false, true, "account", "vineyard", "owner"))
        assertTrue(policy.allowed(false, true, "account", "vineyard", "manager"))
        assertFalse(policy.allowed(false, true, "account", "vineyard", "supervisor"))
        assertFalse(policy.allowed(false, true, "account", "vineyard", "operator"))
        assertTrue(policy.canHardDelete("owner"))
        assertTrue(policy.canHardDelete("manager"))
        assertFalse(policy.canHardDelete("supervisor"))
        assertFalse(policy.canHardDelete("operator"))
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
        assertTrue(PermanentItemPilotPolicy.valid("Valve", "custom_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", -34.0, 138.0))
        assertFalse(PermanentItemPilotPolicy.valid("Valve", "custom_invalid", -34.0, 138.0))
        assertTrue(PermanentItemPilotPolicy.COLORS.values.toSet().size == 8)
        assertTrue(PermanentItemPilotPolicy.hex("gate", emptyList()) == "#D97706")
    }
}

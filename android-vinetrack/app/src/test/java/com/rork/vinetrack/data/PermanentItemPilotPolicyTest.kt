package com.rork.vinetrack.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermanentItemPilotPolicyTest {
    @Test fun authenticatedVineyardScopeDoesNotRequireSystemAdmin() {
        val policy = PermanentItemPilotPolicy
        assertTrue(policy.eligible("account", "vineyard"))
        assertFalse(policy.eligible(null, "vineyard"))
        assertFalse(policy.eligible("account", null))
        assertFalse(policy.eligible(" ", "vineyard"))
        assertFalse(policy.eligible("account", " "))
        // Actual membership and can_manage are decided by the server RPC.
        assertTrue(policy.canHardDelete("owner"))
        assertTrue(policy.canHardDelete("manager"))
        assertTrue(policy.canHardDelete("supervisor"))
        assertFalse(policy.canHardDelete("operator"))
        assertFalse(policy.canHardDelete(null))
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

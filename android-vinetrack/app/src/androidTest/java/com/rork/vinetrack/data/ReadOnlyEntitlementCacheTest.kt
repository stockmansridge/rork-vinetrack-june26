package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.subscription.EntitlementVerificationSnapshot
import com.rork.vinetrack.data.subscription.EntitlementVerificationStore
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Real preferences, isolated synthetic namespace; no owner data or clearing. */
class ReadOnlyEntitlementCacheTest {
    private fun context(): Context {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "readonly_contract_${UUID.randomUUID()}_"
        return object : ContextWrapper(target) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                target.getSharedPreferences(prefix + name, mode)
        }
    }

    private val owner = "b0000000-0000-4000-8000-000000000001"
    private val vineyard = "a0000000-0000-4000-8000-000000000001"
    private val expired = VineyardOperationalAccess(true, false, "trial_expired")

    @Test fun verifiedRestrictionSurvivesRecreationWithoutRenewingAccountGrace() {
        val context = context()
        val store = EntitlementVerificationStore(context)
        val before = EntitlementVerificationSnapshot(owner, 123L, true, "trial", knownExpiresAtMs = 456L)
        store.save(before)
        store.recordOperationalAccess(owner, mapOf(vineyard to expired))
        val restored = requireNotNull(EntitlementVerificationStore(context).load(owner))
        assertEquals(before.lastVerifiedAtMs, restored.lastVerifiedAtMs)
        assertEquals(before.wasEntitled, restored.wasEntitled)
        assertEquals(before.knownExpiresAtMs, restored.knownExpiresAtMs)
        assertEquals(expired, restored.operationalAccessFor(vineyard, owner))
    }

    @Test fun providerRefreshRetainsRestrictionAndFreshMatrixCanReplaceIt() {
        val context = context()
        val store = EntitlementVerificationStore(context)
        store.recordOperationalAccess(owner, mapOf(vineyard to expired))
        assertFalse(requireNotNull(store.load(owner)).wasEntitled)
        store.recordVerification(owner, true, "active:pro")
        assertEquals(expired, EntitlementVerificationStore(context).load(owner)?.operationalAccessFor(vineyard, owner))
        val paid = VineyardOperationalAccess(true, true)
        store.recordOperationalAccess(owner, mapOf(vineyard to paid))
        assertEquals(true, store.load(owner)?.operationalAccessFor(vineyard, owner)?.canWrite)
        store.recordOperationalAccess(owner, emptyMap())
        assertTrue(requireNotNull(store.load(owner)?.operationalAccessByVineyard).isEmpty())
        assertTrue(requireNotNull(store.load(owner)).wasEntitled)
    }

    @Test fun accountSwitchAndUnownedLegacySnapshotCannotTransferCapabilities() {
        val context = context()
        val store = EntitlementVerificationStore(context)
        store.recordOperationalAccess(owner, mapOf(vineyard to expired))
        store.recordVerification("another-owner", false, null)
        assertNull(store.load("another-owner")?.operationalAccessByVineyard)
        assertNull(store.load(owner))
        store.save(EntitlementVerificationSnapshot(null, 1, true, operationalAccessByVineyard = mapOf(vineyard to expired)))
        store.recordVerification(owner, false, null)
        assertNull(EntitlementVerificationStore(context).load(owner)?.operationalAccessByVineyard)
    }
}

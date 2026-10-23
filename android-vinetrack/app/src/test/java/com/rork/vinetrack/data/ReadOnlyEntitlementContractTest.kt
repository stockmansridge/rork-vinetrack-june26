package com.rork.vinetrack.data

import com.rork.vinetrack.data.subscription.EntitlementVerificationSnapshot
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Contract/cache preparation, NOT operational action/replay enforcement tests. */
class ReadOnlyEntitlementContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val vineyard = "a0000000-0000-4000-8000-000000000001"
    private val owner = "b0000000-0000-4000-8000-000000000001"

    private fun entry(fields: String): VineyardAccessEntry = json.decodeFromString(
        "{\"vineyard_id\":\"$vineyard\",$fields}",
    )

    @Test fun missingWriteFieldPreservesLegacyWritableCapability() {
        val row = entry("\"has_vineyard_access\":true")
        assertNull(row.canWrite)
        assertTrue(row.operationalAccess.canEnter && row.operationalAccess.canWrite)
    }

    @Test fun explicitNullWriteFieldAlsoPreservesCompatibility() {
        val access = entry("\"has_vineyard_access\":true,\"can_write\":null").operationalAccess
        assertTrue(access.canWrite)
        assertNull(access.readOnlyReason)
    }

    @Test fun expiredContractSeparatesEntryFromWriteWithoutChangingLegacyRoutingFlag() {
        val row = entry("\"has_vineyard_access\":false,\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"")
        assertFalse(row.hasVineyardAccess)
        assertTrue(row.operationalAccess.canEnter)
        assertFalse(row.operationalAccess.canWrite)
        assertTrue(row.operationalAccess.isTrialExpiredReadOnly)
    }

    @Test fun explicitEntryDenialCannotBecomeWritable() {
        val access = entry("\"has_vineyard_access\":true,\"can_enter_vineyard\":false,\"can_write\":true,\"read_only_reason\":\"trial_expired\"").operationalAccess
        assertFalse(access.canEnter || access.canWrite)
        assertNull(access.readOnlyReason)
        assertFalse(access.isTrialExpiredReadOnly)
    }

    @Test fun absentEntryFieldsDoNotInventMembership() {
        val access = entry("\"can_write\":true").operationalAccess
        assertFalse(access.canEnter || access.canWrite)
    }

    @Test fun reasonAloneCannotInferReadOnly() {
        val access = entry("\"has_vineyard_access\":true,\"read_only_reason\":\"trial_expired\"").operationalAccess
        assertTrue(access.canWrite)
        assertFalse(access.isTrialExpiredReadOnly)
    }

    @Test fun historicalTrialMetadataCannotOverrideEffectiveGrant() {
        val access = entry("\"has_vineyard_access\":true,\"is_trial\":true,\"subscription_status\":\"expired\"").operationalAccess
        assertTrue(access.canWrite)
    }

    @Test fun existingGrantSourcesRemainWritable() {
        listOf("active_trial", "paid", "legacy", "manual", "internal_unlimited", "billing_grant", "migrated").forEach { source ->
            val access = entry("\"has_vineyard_access\":true,\"vineyard_access_source\":\"$source\"").operationalAccess
            assertTrue(source, access.canEnter && access.canWrite)
        }
    }

    @Test fun personalTrialDenialDoesNotContaminatePaidVineyardCapability() {
        val account = json.decodeFromString<VineTrackAccessRow>("{\"has_access\":false,\"can_write\":false,\"can_enter_vineyard\":true,\"read_only_reason\":\"trial_expired\"}")
        val row = entry("\"has_vineyard_access\":true,\"can_write\":true,\"vineyard_access_source\":\"paid_vineyard\"")
        assertEquals(false, account.canWrite)
        assertEquals(true, account.canEnterVineyard)
        assertEquals("trial_expired", account.readOnlyReason)
        assertFalse(account.grantsAppAccess)
        assertTrue(row.operationalAccess.canWrite)
    }

    @Test fun missingAccountFieldsDoNotChangeExistingAppDecision() {
        val account = json.decodeFromString<VineTrackAccessRow>("{\"has_access\":true}")
        assertNull(account.canEnterVineyard)
        assertNull(account.canWrite)
        assertNull(account.readOnlyReason)
        assertTrue(account.grantsAppAccess)
    }

    @Test fun matrixKeepsVineyardsIndependentAndUnlistedVineyardUnknown() {
        val expired = entry("\"has_vineyard_access\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"")
        val paid = VineyardAccessEntry("a0000000-0000-4000-8000-000000000002", hasVineyardAccess = true, canWrite = true)
        val matrix = VineyardAccessMatrix(vineyards = listOf(expired, paid))
        assertEquals(true, matrix.operationalAccessByVineyard[vineyard]?.isTrialExpiredReadOnly)
        assertEquals(true, matrix.operationalAccessByVineyard[paid.vineyardId]?.canWrite)
        assertNull(matrix.entryFor("foreign"))
        assertTrue(VineyardAccessMatrix().operationalAccessByVineyard.isEmpty())
        assertEquals(expired, matrix.entryFor(vineyard.uppercase()))
    }

    @Test fun oldSnapshotDecodesWithoutCapabilities() {
        val snapshot = json.decodeFromString<EntitlementVerificationSnapshot>("{\"last_verified_at_ms\":0,\"was_entitled\":true}")
        assertNull(snapshot.operationalAccessByVineyard)
    }

    @Test fun cachedReadOnlySurvivesRoundTripWithoutBecomingAnAccountGrant() {
        val access = entry("\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"").operationalAccess
        val original = EntitlementVerificationSnapshot(owner, 0, false, knownExpiresAtMs = 1, operationalAccessByVineyard = mapOf(vineyard to access))
        val restored = json.decodeFromString<EntitlementVerificationSnapshot>(json.encodeToString(EntitlementVerificationSnapshot.serializer(), original))
        assertEquals(original, restored)
        assertEquals(true, restored.operationalAccessFor(vineyard.uppercase(), owner)?.isTrialExpiredReadOnly)
        assertFalse(restored.wasEntitled)
        assertNull(restored.operationalAccessFor(vineyard, "another-owner"))
        assertNull(restored.operationalAccessFor(vineyard, null))
    }

    @Test fun unownedLegacySnapshotCannotSupplyScopedCapabilities() {
        val unowned = EntitlementVerificationSnapshot(null, 0, true, operationalAccessByVineyard = mapOf(vineyard to VineyardOperationalAccess(true, true)))
        assertNull(unowned.operationalAccessFor(vineyard, owner))
    }

    @Test fun providerRefreshRetainsSameOwnersRestrictionButNotAnotherOwners() {
        val access = entry("\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"").operationalAccess
        val previous = EntitlementVerificationSnapshot(owner, 0, false, operationalAccessByVineyard = mapOf(vineyard to access))
        val refreshed = EntitlementVerificationSnapshot(owner, 100, true).retainingOperationalAccess(previous)
        assertEquals(access, refreshed.operationalAccessFor(vineyard, owner))
        assertTrue(refreshed.wasEntitled)
        assertEquals(100L, refreshed.lastVerifiedAtMs)
        assertNull(EntitlementVerificationSnapshot("another-owner", 100, false).retainingOperationalAccess(previous).operationalAccessByVineyard)
        assertNull(EntitlementVerificationSnapshot(null, 100, false).retainingOperationalAccess(previous).operationalAccessByVineyard)
    }

    @Test fun freshEmptyMatrixAndWritableGrantReplacePreviousRestriction() {
        val expired = entry("\"can_enter_vineyard\":true,\"can_write\":false,\"read_only_reason\":\"trial_expired\"").operationalAccess
        val before = EntitlementVerificationSnapshot(owner, 0, false, operationalAccessByVineyard = mapOf(vineyard to expired))
        val empty = before.copy(operationalAccessByVineyard = emptyMap()).retainingOperationalAccess(before)
        assertTrue(requireNotNull(empty.operationalAccessByVineyard).isEmpty())
        val writable = before.copy(operationalAccessByVineyard = mapOf(vineyard to VineyardOperationalAccess(true, true))).retainingOperationalAccess(before)
        assertEquals(true, writable.operationalAccessFor(vineyard, owner)?.canWrite)
        assertNull(writable.operationalAccessFor(vineyard, owner)?.readOnlyReason)
    }
}

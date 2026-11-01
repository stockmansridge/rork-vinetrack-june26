package com.rork.vinetrack.data.auth

import org.junit.Assert.*
import org.junit.Test

/** Real production JSON/serializers on Gradle; no Android APIs are needed by this contract. */
class DomainCacheRecoveryContractTest {
    private val owner = "00000000-0000-0000-0000-0000000000a1"
    private val vineyard = "00000000-0000-0000-0000-0000000000b1"
    private fun cache(active: Boolean = false): Map<String, Any> = linkedMapOf(
        "cache_owner_user_id" to owner,
        "trips_$vineyard" to """[{"id":"cached-trip","vineyard_id":"$vineyard","is_active":$active}]""",
        "trips_at_$vineyard" to 1L,
    )
    private fun failure(expected: String, action: () -> Unit) {
        val thrown = runCatching(action).exceptionOrNull()
        assertTrue("Expected typed cache diagnostic, got ${thrown?.javaClass?.simpleName}", thrown is EvidenceContractFailure)
        val diagnostic = (thrown as EvidenceContractFailure).diagnostic
        assertEquals("vinetrack_domain_cache", diagnostic.category)
        assertEquals(expected, diagnostic.rule)
        assertFalse(diagnostic.toString().contains(owner))
        assertFalse(diagnostic.toString().contains(vineyard))
        assertNull(thrown.cause)
    }
    @Test fun completedTripsStillRecoverAndAllowCleanExit() {
        val values = cache()
        assertEquals(setOf(vineyard), CleanExitCacheContract.recoveryScopes(values, owner))
        CleanExitCacheContract.validate(values)
    }
    @Test fun originalAccountCanRecoverAnActiveTripListSnapshotWithoutRewritingIt() {
        val values = cache(true).toMutableMap()
        val before = values.toMap()
        assertEquals(setOf(vineyard), CleanExitCacheContract.recoveryScopes(values, owner))
        assertEquals(before, values)
    }
    @Test fun signOutStillRefusesAnActiveTrip() {
        failure("DOMAIN_TRIPS_ACTIVE_ON_CLEAN_EXIT") { CleanExitCacheContract.validate(cache(true)) }
    }
    @Test fun emptyOutboxNeverInventsAVineyard() {
        assertEquals(setOf(vineyard), CleanExitCacheContract.recoveryScopes(cache() + ("spray_target_outbox" to "[]"), owner))
    }
    @Test fun nonemptyOutboxStillBlocksRecovery() {
        failure("DOMAIN_TARGET_OUTBOX") {
            CleanExitCacheContract.recoveryScopes(cache() + ("spray_target_outbox" to "[{}]"), owner)
        }
    }
    @Test fun wrongCacheOwnerIsRejectedEvenForInactiveTrips() {
        failure("DOMAIN_CACHE_OWNER_MISMATCH") { CleanExitCacheContract.recoveryScopes(cache(), "different-account") }
    }
    @Test fun missingCacheOwnerIsNotManufactured() {
        failure("DOMAIN_CACHE_OWNER_MISMATCH") { CleanExitCacheContract.recoveryScopes(cache() - "cache_owner_user_id", owner) }
    }
    @Test fun missingTimestampHasDatasetSpecificDiagnostic() {
        failure("DOMAIN_TRIPS_TIMESTAMP") { CleanExitCacheContract.recoveryScopes(cache() - "trips_at_$vineyard", owner) }
    }
    @Test fun stringTimestampDoesNotPassAsALong() {
        failure("DOMAIN_TRIPS_TIMESTAMP") { CleanExitCacheContract.recoveryScopes(cache() + ("trips_at_$vineyard" to "1"), owner) }
    }
    @Test fun malformedJsonIsNotTreatedAsAnEmptyCache() {
        failure("DOMAIN_TRIPS_DECODE_SCHEMA") { CleanExitCacheContract.recoveryScopes(cache() + ("trips_$vineyard" to "PRIVATE_invalid_json"), owner) }
    }
    @Test fun futureUnknownFieldsRemainProtected() {
        failure("DOMAIN_TRIPS_DECODE_SCHEMA") {
            CleanExitCacheContract.recoveryScopes(cache() + ("trips_$vineyard" to """[{"id":"trip","vineyard_id":"$vineyard","unknown_private_field":"retained"}]"""), owner)
        }
    }
    @Test fun wrongRowScopeIsRejected() {
        failure("DOMAIN_TRIPS_ROW_ID_SCOPE") {
            CleanExitCacheContract.recoveryScopes(cache() + ("trips_$vineyard" to """[{"id":"trip","vineyard_id":"other-vineyard"}]"""), owner)
        }
    }
    @Test fun unknownPreferenceKeyRemainsProtected() {
        failure("DOMAIN_UNKNOWN_OR_ORPHAN_KEY") { CleanExitCacheContract.recoveryScopes(cache() + ("private_future_store" to "[]"), owner) }
    }
    @Test fun orphanTimestampRemainsProtected() {
        failure("DOMAIN_UNKNOWN_OR_ORPHAN_KEY") { CleanExitCacheContract.recoveryScopes(cache() + ("pins_at_orphan" to 1L), owner) }
    }
    @Test fun missingChildParentDoesNotAcquireTheTaskIdAsVineyard() {
        failure("DOMAIN_WORKTASK_LABOUR_RECOVERY_SCOPE") {
            CleanExitCacheContract.recoveryScopes(cache() + mapOf("worktask_labour_task" to "[]", "worktask_labour_at_task" to 1L), owner)
        }
    }
    @Test fun nestedTimestampDoesNotCreateASpuriousScope() {
        assertEquals(setOf(vineyard), CleanExitCacheContract.recoveryScopes(cache() + mapOf("yield_session_$vineyard" to "[]", "yield_session_at_$vineyard" to 1L), owner))
    }
    @Test fun emptyCacheHasNoRecoveryScopes() {
        assertEquals(emptySet<String>(), CleanExitCacheContract.recoveryScopes(emptyMap<String, Any>(), owner))
    }
    @Test fun mixedFortyFourKeyFixtureKeepsExactScopesAndBytes() {
        // Synthetic keys only. Matching the reported key count does NOT reproduce the phone's values.
        val groups = listOf("paddocks", "pins", "trips", "growth", "worktask", "maintenance", "yield", "damage",
            "yield_session", "fuel", "spray", "spray_job_templates", "spray_targets", "worker_types", "machines",
            "spray_equipment", "picking", "vineyard_clones", "vineyard_rootstocks", "work_task_machines_vineyard", "work_task_materials_vineyard")
        val values = linkedMapOf<String, Any>("cache_owner_user_id" to owner, "spray_target_outbox" to "[]")
        groups.forEach { values["${it}_$vineyard"] = "[]"; values["${it}_at_$vineyard"] = 1L }
        values["trips_$vineyard"] = cache(true).getValue("trips_$vineyard")
        assertEquals(44, values.size)
        val before = values.toMap()
        assertEquals(setOf(vineyard), CleanExitCacheContract.recoveryScopes(values, owner))
        assertEquals(before, values)
    }
    private fun yieldCache(scope: String = vineyard.uppercase()): Map<String, Any> = mapOf(
        "cache_owner_user_id" to owner,
        "yield_session_$vineyard" to """[{"id":"00000000-0000-0000-0000-0000000000C1","vineyardId":"$scope","createdAt":"2026-11-01T00:00:00Z","selectedPaddockIds":[],"sampleSites":[],"blockBunchWeightsKg":[]}]""",
        "yield_session_at_$vineyard" to 1L,
    )
    @Test fun iosUppercaseYieldSessionRecoversWithoutChangingEvidence() {
        val values = yieldCache(); val before = values.toMap()
        assertEquals(setOf(vineyard), CleanExitCacheContract.recoveryScopes(values, owner))
        assertEquals(before, values)
    }
    @Test fun differentYieldVineyardStillRejected() {
        failure("DOMAIN_YIELD_SESSION_RECOVERY_SCOPE") { CleanExitCacheContract.recoveryScopes(yieldCache(owner), owner) }
    }
    @Test fun nonUuidCaseDifferencesAreNotTreatedAsIdentity() {
        assertFalse(CleanExitCacheContract.sameIdentity("PRIVATE", "private"))
        assertFalse(CleanExitCacheContract.sameIdentity(" $vineyard", vineyard))
    }

}

package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.model.SprayActualInputDraft
import com.rork.vinetrack.data.model.SprayTankActual
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*

/** Read-only admission, not replay authority. History requires an exact isolated server read.
 * Pending confirmations keep their distinct original-authorship rules; edits are never adopted.
 */
internal object TankActualRecoveryVerifier {
    const val STORE = "vinetrack_spray_tank_actuals"
    private val codec = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private val remoteCodec = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    const val COLUMNS = "id,vineyard_id,spray_record_id,trip_id,tank_session_id,tank_number,water_volume_l,chemicals,confirmed_at,confirmed_by,client_updated_at,correction_version,last_corrected_at"
    @Serializable private data class Cache(val records: List<SprayTankActual> = emptyList(),
        val pendingIds: Set<String> = emptySet(), val inputDrafts: List<SprayActualInputDraft> = emptyList())
    private fun fail(rule: String): Nothing = throw EvidenceContractFailure(RecoveryEvidenceDiagnostic(STORE, rule))
    private fun decode(values: Map<String, *>): Cache {
        if (values.keys.any { it != "cache" }) fail("ACTUAL_UNKNOWN_KEY")
        val raw = values["cache"] ?: return Cache()
        if (raw !is String) fail("ACTUAL_CACHE_EXPECTED_STRING")
        val cache = try {
            val source = codec.parseToJsonElement(raw)
            codec.decodeFromJsonElement(Cache.serializer(), source).also {
                if (!RetainedJsonFields.preserves(source, codec.encodeToJsonElement(Cache.serializer(), it))) fail("ACTUAL_SUPPLIED_FIELDS_CHANGED")
            }
        } catch (failure: EvidenceContractFailure) { throw failure }
          catch (_: Exception) { fail("ACTUAL_INVALID_LOCAL_SCHEMA") }
        if (cache.records.map { it.id }.distinct().size != cache.records.size ||
            cache.records.map { it.tripId to it.tankSessionId }.distinct().size != cache.records.size ||
            cache.pendingIds.any { id -> cache.records.none { it.id == id } }) fail("ACTUAL_AMBIGUOUS_IDENTITY")
        if (cache.inputDrafts.any { !it.hasValidIdentity() } ||
            cache.inputDrafts.map { Triple(it.ownerUserId,it.vineyardId,it.key) }.distinct().size != cache.inputDrafts.size)
            fail("ACTUAL_INPUT_DRAFT_SCHEMA")
        cache.records.forEach {
            if (listOf(it.id,it.vineyardId,it.tripId,it.sprayRecordId,it.confirmedBy).any(String::isBlank) ||
                it.correctionVersion < 0) fail("ACTUAL_RECORD_IDENTITY")
            try { normal(codec.encodeToJsonElement(SprayTankActual.serializer(), it)) }
            catch (_: Exception) { fail("ACTUAL_LOCAL_TIMESTAMP_SCHEMA") }
        }
        return cache
    }
    private fun validateOwned(cache: Cache, owner: String): Set<String> {
        cache.records.filter { it.id in cache.pendingIds }.forEach {
            if (!CleanExitCacheContract.sameIdentity(it.confirmedBy, owner)) fail("ACTUAL_PENDING_OWNER_MISMATCH")
            if (it.correctionVersion != 0L || it.lastCorrectedAt != null || it.clientUpdatedAt != it.confirmedAt)
                fail("ACTUAL_PENDING_EDIT_REQUIRES_REVIEW")
        }
        cache.inputDrafts.forEach { if (it.ownerUserId != owner) fail("ACTUAL_INPUT_OWNER_MISMATCH") }
        return cache.records.mapTo(mutableSetOf()) { it.vineyardId }.apply { addAll(cache.inputDrafts.map { it.vineyardId }) }
    }
    fun inspectWithoutProof(values: Map<String,*>, owner: String?): Set<String> {
        val cache = decode(values)
        if (owner == null) {
            if (cache.records.isNotEmpty() || cache.inputDrafts.isNotEmpty()) fail("ACTUAL_ORIGINAL_ACCOUNT_REQUIRED")
            return emptySet()
        }
        val scopes = validateOwned(cache, owner)
        if (cache.records.any { it.id !in cache.pendingIds }) fail("ACTUAL_SERVER_VERIFICATION_REQUIRED")
        return scopes
    }
    class Proof private constructor(private val owner: String, private val epoch: Long,
        private val values: Map<String,*>, private val scopes: Set<String>) {
        fun inspect(current: Map<String,*>, original: String, currentEpoch: Long): Set<String> {
            if (owner != original || epoch != currentEpoch || current != values) fail("ACTUAL_RECOVERY_EVIDENCE_CHANGED")
            return scopes
        }
        companion object {
            internal fun verified(owner: String, epoch: Long, values: Map<String,*>, scopes: Set<String>) = Proof(owner,epoch,values.toMap(),scopes)
        }
    }
    // Only declared identity and timestamp fields are canonicalised, never arbitrary names/IDs.
    private val ids = setOf("id","vineyard_id","spray_record_id","trip_id","confirmed_by","plannedChemicalId","savedChemicalId","replacesPlannedChemicalId")
    private val times = setOf("confirmed_at","client_updated_at","last_corrected_at","snapshotAt")
    private fun normal(value: JsonElement, field: String? = null): JsonElement = when(value) {
        is JsonObject -> JsonObject(value.mapValues { (k,v) -> normal(v,k) })
        is JsonArray -> JsonArray(value.map { normal(it) })
        is JsonPrimitive -> if (value.isString && field in ids) JsonPrimitive(CleanExitCacheContract.identityKey(value.content))
            else if (value.isString && field in times) JsonPrimitive(java.time.OffsetDateTime.parse(value.content).toInstant().toString()) else value
        else -> value
    }
    suspend fun verify(owner: String, epoch: Long, values: Map<String,*>, permitted: Set<String>,
        get: suspend (String) -> JsonElement): Proof {
        val cache = decode(values)
        val scopes = validateOwned(cache, owner)
        if (scopes.any { scope -> permitted.none { CleanExitCacheContract.sameIdentity(scope,it) } }) fail("ACTUAL_VINEYARD_ACCESS_REFUSED")
        for (actual in cache.records.filter { it.id !in cache.pendingIds }) {
            // URL encoding prevents non-UUID historical local identifiers from becoming query syntax.
            fun escaped(s: String) = java.net.URLEncoder.encode(s,"UTF-8")
            val response = get("spray_tank_actuals?select=$COLUMNS&id=eq.${escaped(actual.id)}&vineyard_id=eq.${escaped(actual.vineyardId)}&deleted_at=is.null&limit=2")
            val rows = try { remoteCodec.decodeFromJsonElement(ListSerializer(SprayTankActual.serializer()),response) }
                catch (_: Exception) { fail("ACTUAL_SERVER_RESPONSE_SCHEMA") }
            val found = rows.singleOrNull() ?: fail("ACTUAL_SERVER_HISTORY_NOT_VERIFIED")
            val expected = normal(codec.encodeToJsonElement(SprayTankActual.serializer(),actual))
            val server = try { normal(codec.encodeToJsonElement(SprayTankActual.serializer(),found)) }
                catch (_: Exception) { fail("ACTUAL_SERVER_TIMESTAMP_SCHEMA") }
            if (!RetainedJsonFields.preserves(expected,server) || !RetainedJsonFields.preserves(server,expected)) fail("ACTUAL_SERVER_HISTORY_MISMATCH")
        }
        return Proof.verified(owner,epoch,values,scopes)
    }
}

package com.rork.vinetrack.data

/** Shared entitlement admission. Auth/roles remain separate. The sidecar ledger never
 * changes operation IDs, payloads, receipt phases, timestamps or retry counters. */
class VineyardWriteAuthority(
    private val owner: () -> String?,
    private val load: () -> Map<String, String>,
    private val persist: (Map<String, String>) -> Unit,
    private val cached: (String, String) -> VineyardOperationalAccess? = { _, _ -> null },
) {
    class Restricted(val reason: String) : IllegalStateException(reason)
    @Volatile var deniedVineyardId: String? = null
        private set
    private fun scope(vineyardId: String): String? = owner()?.lowercase(java.util.Locale.ROOT)?.let {
        "$it:${vineyardId.lowercase(java.util.Locale.ROOT)}"
    }
    @Synchronized fun heldReason(vineyardId: String): String? {
        val user = owner() ?: return null
        val key = scope(vineyardId) ?: return null
        val holds = load()
        holds[key]?.let { return it }
        if (cached(user, vineyardId)?.isTrialExpiredReadOnly == true) {
            persist(holds + (key to TRIAL_HOLD))
            return TRIAL_HOLD
        }
        return null
    }
    fun canWrite(vineyardId: String): Boolean = heldReason(vineyardId) == null
    fun admit(vineyardId: String): Boolean = canWrite(vineyardId).also { if (!it) deniedVineyardId = vineyardId }
    fun requireWrite(vineyardId: String) {
        if (!admit(vineyardId)) throw Restricted(heldReason(vineyardId) ?: "VT_READ_ONLY")
    }
    @Synchronized fun verified(vineyardId: String, access: VineyardOperationalAccess, explicitlyWritable: Boolean) {
        val key = scope(vineyardId) ?: return
        val holds = load()
        if (access.isTrialExpiredReadOnly) persist(holds + (key to TRIAL_HOLD))
        else if (explicitlyWritable && access.canWrite) persist(holds - key)
    }
    @Synchronized fun handleServerCode(code: String?, vineyardId: String): Boolean {
        if (code != "VT_READ_ONLY") return false
        val key = scope(vineyardId) ?: return false
        val holds = load()
        persist(holds + (key to (holds[key] ?: "VT_READ_ONLY")))
        return true
    }
    companion object { const val TRIAL_HOLD = "READ_ONLY_TRIAL_EXPIRED" }
}

/** Installed from the session boundary, before domain stores/replay workers are used. */
object OperationalWrites {
    @Volatile var authority: VineyardWriteAuthority? = null
    fun requireWrite(vineyardId: String) { authority?.requireWrite(vineyardId) }
    fun canWrite(vineyardId: String): Boolean = authority?.canWrite(vineyardId) ?: true
    fun admit(vineyardId: String): Boolean = authority?.admit(vineyardId) ?: true

    /** Only structured server codes establish a hold; HTTP 403 alone is not entitlement. */
    fun handleServerError(error: Throwable, vineyardId: String): Boolean {
        if (error is VineyardWriteAuthority.Restricted) return true
        val code = (error as? BackendError.Server)?.body?.let { body ->
            runCatching {
                val objectValue = kotlinx.serialization.json.Json.parseToJsonElement(body) as? kotlinx.serialization.json.JsonObject
                (objectValue?.get("code") as? kotlinx.serialization.json.JsonPrimitive)?.content
            }.getOrNull()
        }
        if (code == "VT_READ_ONLY") authority?.handleServerCode(code, vineyardId)
        return code == "VT_READ_ONLY" || !canWrite(vineyardId)
    }
}

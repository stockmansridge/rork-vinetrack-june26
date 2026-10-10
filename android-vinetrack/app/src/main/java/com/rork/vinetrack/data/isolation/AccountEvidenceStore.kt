package com.rork.vinetrack.data.isolation

import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Opaque runtime authority. Durable account identity is stored with each new record, not inferred from a hash. */
internal class FieldAccountCapability internal constructor(
    internal val account: String,
    internal val vineyards: Set<String>,
    internal val incarnation: String,
)

@Serializable
internal data class OwnedEvidence(
    val version: Int = 1,
    val account: String,
    val vineyard: String,
    val collection: String,
    val recordId: String,
    val revision: String,
    val originalPhotoPath: String? = null,
    val bytes: ByteArray,
    val sha256: String,
)

/** Trial immutable records: no legacy adoption, no overwrite and no physical cleanup. */
internal class AccountEvidenceStore(private val root: File, private val disk: IsolationDisk) {
    private val json = Json { encodeDefaults = true }
    private val authority = authorities.computeIfAbsent(root.canonicalPath) { Authority() }

    fun authenticateVerifiedAccount(account: String, vineyards: Set<String>): FieldAccountCapability = synchronized(authority) {
        require(account.isNotBlank() && vineyards.all { it.isNotBlank() })
        FieldAccountCapability(account, vineyards.toSet(), UUID.randomUUID().toString()).also { authority.current = it }
    }

    fun revoke(): Unit = synchronized(authority) { authority.current = null }

    fun append(capability: FieldAccountCapability, vineyard: String, collection: String, recordId: String,
               bytes: ByteArray, originalPhotoPath: String? = null): String = synchronized(authority) {
        checkAccess(capability, vineyard)
        require(collection.isNotBlank() && recordId.isNotBlank())
        val revision = UUID.randomUUID().toString()
        val row = OwnedEvidence(account = capability.account, vineyard = vineyard, collection = collection,
            recordId = recordId, revision = revision, originalPhotoPath = originalPhotoPath,
            bytes = bytes.copyOf(), sha256 = IsolationDisk.digest(bytes))
        disk.locked(root) {
            val file = File(namespace(capability), "$revision.record")
            disk.publishBytes(file, json.encodeToString(row).toByteArray(Charsets.UTF_8))
        }
        revision
    }

    fun read(capability: FieldAccountCapability, vineyard: String, collection: String): List<OwnedEvidence> = synchronized(authority) {
        checkAccess(capability, vineyard)
        disk.locked(root) {
            val directory = namespace(capability)
            check(directory.absoluteFile == directory.canonicalFile) { "Linked account namespace" }
            val files = if (directory.exists()) checkNotNull(directory.listFiles()) else emptyArray()
            files.filter { it.name.endsWith(".record") }.map { file ->
                check(file.absoluteFile == file.canonicalFile && file.isFile) { "Linked protected record" }
                val row = json.decodeFromString<OwnedEvidence>(file.readText())
                check(row.version == 1 && row.account == capability.account && file.name == "${row.revision}.record") { "Conflicting protected record" }
                check(IsolationDisk.digest(row.bytes) == row.sha256) { "Corrupted protected record; original retained" }
                row
            }.filter { it.vineyard == vineyard && it.collection == collection }
        }
    }

    /** A durable exact-revision receipt retains the immutable payload/JPEG; it does not authorise disposal. */
    fun acknowledge(capability: FieldAccountCapability, vineyard: String, collection: String, revision: String): Boolean = synchronized(authority) {
        val row = read(capability, vineyard, collection).singleOrNull { it.revision == revision } ?: return@synchronized false
        disk.locked(root) {
            val receipt = File(namespace(capability), "$revision.receipt")
            val bytes = json.encodeToString(Receipt(row.account, row.vineyard, revision, row.sha256)).toByteArray(Charsets.UTF_8)
            if (receipt.exists()) {
                check(receipt.absoluteFile == receipt.canonicalFile && receipt.readBytes().contentEquals(bytes))
            } else disk.publishBytes(receipt, bytes)
            disk.confirmPublished(receipt)
            true
        }
    }

    /** Resolves a protected copy, never the unscoped legacy absolute File(path). */
    fun photoBytes(capability: FieldAccountCapability, vineyard: String, collection: String, revision: String,
                   originalPath: String): ByteArray? = synchronized(authority) {
        read(capability, vineyard, collection)
            .singleOrNull { it.revision == revision && it.originalPhotoPath == originalPath }?.bytes?.copyOf()
    }

    private fun checkAccess(capability: FieldAccountCapability, vineyard: String) {
        check(authority.current === capability && vineyard in capability.vineyards) { "Field account access revoked or vineyard unavailable" }
    }

    private fun namespace(capability: FieldAccountCapability): File =
        File(root, IsolationDisk.digest(capability.account.toByteArray(Charsets.UTF_8)))

    @Serializable
    private data class Receipt(val account: String, val vineyard: String, val revision: String, val sha256: String)
    private class Authority { var current: FieldAccountCapability? = null }
    private companion object { val authorities = ConcurrentHashMap<String, Authority>() }
}

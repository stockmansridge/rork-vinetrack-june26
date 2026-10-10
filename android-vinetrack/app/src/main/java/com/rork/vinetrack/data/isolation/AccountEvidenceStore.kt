package com.rork.vinetrack.data.isolation

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Runtime authority is never restored from disk or inferred from vineyard membership. */
internal class FieldAccountCapability internal constructor(
    internal val account: String,
    internal val vineyards: Set<String>,
    internal val incarnation: String,
)

internal data class OwnedEvidence(
    val version: Int = 2,
    val account: String,
    val vineyard: String,
    val collection: String,
    val recordId: String,
    val revision: String,
    val originalPhotoPath: String? = null,
    val bytes: ByteArray,
    val sha256: String,
)

@Serializable
internal data class OwnedRecordMetadata(
    val version: Int = 2,
    val account: String,
    val vineyard: String,
    val collection: String,
    val recordId: String,
    val revision: String,
    val originalPhotoPath: String? = null,
    val length: Long,
    val sha256: String,
    val blob: String,
    val sequence: Long = 0,
)

/** Immutable binary backend for disabled adapters. Intents, blobs, records and receipts are never deleted. */
internal class AccountEvidenceStore(
    private val root: File,
    private val disk: IsolationDisk,
    private val availableBytes: () -> Long = { root.usableSpace },
) {
    private val json = Json { encodeDefaults = true }
    private val authority = authorities.computeIfAbsent(root.canonicalPath) { Authority() }

    fun authenticateVerifiedAccount(account: String, vineyards: Set<String>): FieldAccountCapability = synchronized(authority) {
        require(account.isNotBlank() && vineyards.all { it.isNotBlank() })
        FieldAccountCapability(account, vineyards.toSet(), UUID.randomUUID().toString()).also { authority.current = it }
    }

    fun revoke(): Unit = synchronized(authority) { authority.current = null }

    fun append(capability: FieldAccountCapability, vineyard: String, collection: String, recordId: String,
               bytes: ByteArray, originalPhotoPath: String? = null): String {
        val immutable = bytes.copyOf()
        return appendStream(capability, vineyard, collection, recordId, UUID.randomUUID().toString(),
            immutable.size.toLong(), IsolationDisk.digest(immutable), originalPhotoPath) { ByteArrayInputStream(immutable) }
    }

    /** Caller retains a stable revision to resume this exact write; a retry with different bytes is refused. */
    fun appendBinary(capability: FieldAccountCapability, vineyard: String, collection: String, recordId: String,
                     revision: String, source: File, originalPhotoPath: String? = null): String = synchronized(authority) {
        checkAccess(capability, vineyard)
        check(source.absoluteFile == source.canonicalFile && source.isFile) { "Invalid binary source" }
        appendStream(capability, vineyard, collection, recordId, revision, source.length(),
            IsolationDisk.digest(source), originalPhotoPath) { source.inputStream() }
    }

    private fun appendStream(capability: FieldAccountCapability, vineyard: String, collection: String, recordId: String,
                             revision: String, length: Long, hash: String, originalPhotoPath: String?,
                             open: () -> InputStream): String = synchronized(authority) {
        checkAccess(capability, vineyard)
        require(collection.isNotBlank() && recordId.isNotBlank())
        require(revision.matches(Regex("[a-zA-Z0-9-]{1,80}")))
        val candidate = OwnedRecordMetadata(account = capability.account, vineyard = vineyard, collection = collection,
            recordId = recordId, revision = revision, originalPhotoPath = originalPhotoPath,
            length = length, sha256 = hash, blob = "$revision.bin")
        disk.locked(root) {
            val directory = namespace(capability)
            val intent = File(directory, "$revision.intent")
            val record = File(directory, "$revision.record")
            val previous = if (intent.exists()) {
                check(intent.absoluteFile == intent.canonicalFile && intent.isFile)
                json.decodeFromString<OwnedRecordMetadata>(intent.readText()).also {
                    check(it.copy(sequence = 0) == candidate) { "Retry differs from retained original intent" }
                }
            } else null
            val sequence = previous?.sequence ?: Math.addExact(directory.listFiles()?.filter { it.extension == "intent" }
                ?.maxOfOrNull { json.decodeFromString<OwnedRecordMetadata>(it.readText()).sequence } ?: 0L, 1L)
            val row = candidate.copy(sequence = sequence)
            val blob = File(directory, row.blob)
            val encoded = json.encodeToString(row).toByteArray(Charsets.UTF_8)
            val reserve = Math.addExact(1024L * 1024L + encoded.size * 2L, if (blob.exists()) 0 else length)
            check(availableBytes() >= reserve) { "Insufficient space; original binary retained" }
            if (intent.exists()) checkMetadata(intent, row) else {
                check(!record.exists() && !blob.exists()) { "Incomplete ownership journal; retain evidence" }
                disk.publishBytes(intent, encoded)
            }
            disk.confirmPublished(intent)
            if (!blob.exists()) disk.publish(blob) { output -> open().use { it.copyTo(output, 64 * 1024) } }
            disk.verify(blob, row.length, row.sha256)
            disk.confirmPublished(blob)
            if (record.exists()) checkMetadata(record, row) else disk.publishBytes(record, encoded)
            disk.confirmPublished(record)
        }
        revision
    }

    /** Listing loads metadata only, never JSON-encoded photo bytes. Interrupted intents cannot masquerade as empty. */
    fun metadata(capability: FieldAccountCapability, vineyard: String, collection: String): List<OwnedRecordMetadata> = synchronized(authority) {
        checkAccess(capability, vineyard)
        disk.locked(root) { metadataLocked(capability, vineyard, collection) }
    }

    fun read(capability: FieldAccountCapability, vineyard: String, collection: String): List<OwnedEvidence> = synchronized(authority) {
        checkAccess(capability, vineyard)
        disk.locked(root) {
            metadataLocked(capability, vineyard, collection).map { row ->
                val blob = File(namespace(capability), row.blob)
                disk.verify(blob, row.length, row.sha256)
                OwnedEvidence(account = row.account, vineyard = row.vineyard, collection = row.collection,
                    recordId = row.recordId, revision = row.revision, originalPhotoPath = row.originalPhotoPath,
                    bytes = blob.readBytes(), sha256 = row.sha256)
            }
        }
    }

    /** Scoped streaming resolver: no absolute file or unrevocable stream escapes the capability boundary. */
    fun copyBinary(capability: FieldAccountCapability, vineyard: String, collection: String, revision: String,
                   output: OutputStream, originalPath: String? = null): Boolean = synchronized(authority) {
        checkAccess(capability, vineyard)
        disk.locked(root) {
            val row = metadataLocked(capability, vineyard, collection).singleOrNull {
                it.revision == revision && (originalPath == null || it.originalPhotoPath == originalPath)
            } ?: return@locked false
            val blob = File(namespace(capability), row.blob)
            disk.verify(blob, row.length, row.sha256)
            blob.inputStream().use { it.copyTo(output, 64 * 1024) }
            true
        }
    }

    /** Exact revision receipt retains all original payloads and is not permission for garbage collection. */
    fun acknowledge(capability: FieldAccountCapability, vineyard: String, collection: String, revision: String): Boolean = synchronized(authority) {
        checkAccess(capability, vineyard)
        disk.locked(root) {
            val row = metadataLocked(capability, vineyard, collection).singleOrNull { it.revision == revision } ?: return@locked false
            disk.verify(File(namespace(capability), row.blob), row.length, row.sha256)
            val receipt = File(namespace(capability), "$revision.receipt")
            val bytes = json.encodeToString(Receipt(row.account, row.vineyard, revision, row.sha256)).toByteArray(Charsets.UTF_8)
            if (receipt.exists()) {
                check(receipt.absoluteFile == receipt.canonicalFile && receipt.readBytes().contentEquals(bytes))
            } else disk.publishBytes(receipt, bytes)
            disk.confirmPublished(receipt)
            true
        }
    }

    fun photoBytes(capability: FieldAccountCapability, vineyard: String, collection: String, revision: String,
                   originalPath: String): ByteArray? = synchronized(authority) {
        val output = java.io.ByteArrayOutputStream()
        if (copyBinary(capability, vineyard, collection, revision, output, originalPath)) output.toByteArray() else null
    }

    private fun metadataLocked(capability: FieldAccountCapability, vineyard: String, collection: String): List<OwnedRecordMetadata> {
        val directory = namespace(capability)
        check(directory.absoluteFile == directory.canonicalFile) { "Linked account namespace" }
        val files = if (directory.exists()) checkNotNull(directory.listFiles()) else emptyArray()
        val intents = files.filter { it.extension == "intent" }.map { file ->
            check(file.absoluteFile == file.canonicalFile && file.isFile)
            val row = json.decodeFromString<OwnedRecordMetadata>(file.readText())
            check(row.version == 2 && row.account == capability.account && file.name == "${row.revision}.intent" &&
                row.blob == "${row.revision}.bin" && row.revision.matches(Regex("[a-zA-Z0-9-]{1,80}"))) { "Conflicting protected ownership" }
            row
        }
        val selected = intents.filter { it.vineyard == vineyard && it.collection == collection }
        selected.forEach { row ->
            val record = File(directory, "${row.revision}.record")
            checkMetadata(record, row)
            val blob = File(directory, row.blob)
            disk.verify(blob, row.length, row.sha256)
            disk.confirmPublished(File(directory, "${row.revision}.intent"))
            disk.confirmPublished(blob)
            disk.confirmPublished(record)
        }
        check(files.filter { it.extension == "record" }.all { file -> intents.any { file.name == "${it.revision}.record" } }) {
            "Missing ownership intent; original retained"
        }
        check(files.filter { it.extension == "bin" }.all { file -> intents.any { file.name == it.blob } }) {
            "Binary lacks ownership evidence; original retained"
        }
        check(intents.map { it.sequence }.distinct().size == intents.size && intents.all { it.sequence > 0 }) {
            "Conflicting record order"
        }
        return selected.sortedBy { it.sequence }
    }

    private fun checkMetadata(file: File, expected: OwnedRecordMetadata) {
        check(file.absoluteFile == file.canonicalFile && file.isFile) { "Incomplete publication; retry exact intent" }
        check(json.decodeFromString<OwnedRecordMetadata>(file.readText()) == expected) { "Conflicting ownership journal" }
    }

    private fun checkAccess(capability: FieldAccountCapability, vineyard: String) {
        check(authority.current === capability && vineyard in capability.vineyards) { "Field account access revoked or vineyard unavailable" }
    }

    private fun namespace(capability: FieldAccountCapability): File =
        File(root, IsolationDisk.digest(capability.account.toByteArray(Charsets.UTF_8)))

    @Serializable private data class Receipt(val account: String, val vineyard: String, val revision: String, val sha256: String)
    private class Authority { var current: FieldAccountCapability? = null }
    private companion object { val authorities = ConcurrentHashMap<String, Authority>() }
}

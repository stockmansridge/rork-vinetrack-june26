package com.rork.vinetrack.data.isolation

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Raw sources are inventory-approved business files, never decoded models or auth stores. */
internal data class RawEvidenceSource(val identity: String, val file: File)

@Serializable
internal data class VaultEntry(val source: String, val length: Long, val sha256: String, val blob: String)

@Serializable
internal data class VaultManifest(
    val version: Int = 1,
    val status: String = "PREPARED",
    val entries: List<VaultEntry>,
)

/** Copy-only trial vault. There is deliberately no source removal, ownership inference or adoption API. */
internal class RawEvidenceVault(
    private val root: File,
    private val disk: IsolationDisk,
    private val sources: () -> List<RawEvidenceSource>,
    private val availableBytes: () -> Long = { root.usableSpace },
    private val checkpoint: (String) -> Unit = {},
) {
    private val json = Json { encodeDefaults = true }
    private val prepared = File(root, "prepared.json")
    private val verified = File(root, "verified.json")

    fun preserve(): VaultManifest = disk.locked(root) {
        val current = inventory()
        val manifest = if (prepared.exists()) {
            json.decodeFromString<VaultManifest>(prepared.readText()).also { validate(it) }
        } else {
            check(!verified.exists()) { "Missing preservation journal" }
            val entries = current.mapIndexed { index, source ->
                VaultEntry(source.identity, source.file.length(), IsolationDisk.digest(source.file), "$index.raw")
            }
            VaultManifest(entries = entries).also {
                ensureSpace(it)
                checkpoint("before-prepare")
                disk.publishBytes(prepared, json.encodeToString(it).toByteArray(Charsets.UTF_8))
                checkpoint("after-prepare")
            }
        }
        validate(manifest)
        disk.confirmPublished(prepared)
        verifySources(manifest, current)
        ensureSpace(manifest)
        for (entry in manifest.entries) {
            val blob = File(root, entry.blob)
            if (!blob.exists()) {
                val source = current.single { it.identity == entry.source }
                checkpoint("before-copy:${entry.blob}")
                disk.publish(blob) { output -> source.file.inputStream().use { it.copyTo(output, 64 * 1024) } }
                checkpoint("after-copy:${entry.blob}")
            }
            disk.verify(blob, entry.length, entry.sha256)
            disk.confirmPublished(blob)
        }
        // Re-inventory catches additions/removals and changes while copying, not just decode failures.
        verifySources(manifest, inventory())
        val committed = manifest.copy(status = "VERIFIED_NOT_ACTIVATED")
        checkpoint("before-verify-commit")
        if (!verified.exists()) disk.publishBytes(verified, json.encodeToString(committed).toByteArray(Charsets.UTF_8))
        check(json.decodeFromString<VaultManifest>(verified.readText()) == committed) { "Conflicting vault commit" }
        disk.confirmPublished(verified)
        checkpoint("after-verify-commit")
        committed
    }

    private fun inventory(): List<RawEvidenceSource> = sources().sortedBy { it.identity }.also { rows ->
        check(rows.map { it.identity }.distinct().size == rows.size) { "Duplicate source identity" }
        rows.forEach {
            check(it.identity.isNotBlank() && it.file.isFile) { "Missing source evidence" }
            check(it.file.absoluteFile == it.file.canonicalFile) { "Linked source evidence is not supported" }
        }
    }

    private fun validate(manifest: VaultManifest) {
        check(manifest.version == 1 && manifest.status == "PREPARED") { "Unsupported preservation journal" }
        check(manifest.entries.map { it.source }.distinct().size == manifest.entries.size)
        manifest.entries.forEachIndexed { index, entry ->
            check(entry.blob == "$index.raw" && entry.length >= 0 && entry.sha256.matches(Regex("[a-f0-9]{64}")))
        }
    }

    private fun verifySources(manifest: VaultManifest, current: List<RawEvidenceSource>) {
        check(manifest.entries.map { it.source } == current.map { it.identity }) { "Source inventory changed; preserve originals and seek recovery" }
        manifest.entries.zip(current).forEach { (entry, source) -> disk.verify(source.file, entry.length, entry.sha256) }
    }

    private fun ensureSpace(manifest: VaultManifest) {
        var required = Math.addExact(1024L * 1024L,
            Math.multiplyExact(json.encodeToString(manifest).toByteArray(Charsets.UTF_8).size.toLong(), 2L))
        manifest.entries.filterNot { File(root, it.blob).exists() }.forEach { entry ->
            required = Math.addExact(required, entry.length)
        }
        check(availableBytes() >= required) { "Insufficient space; keep originals and free unrelated storage" }
    }
}

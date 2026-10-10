package com.rork.vinetrack.data.isolation

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal data class ClosedEvidenceEntry(val path: String, val length: Long, val sha256: String)

@Serializable
internal data class ClosedEvidenceManifest(val version: Int = 1, val entries: List<ClosedEvidenceEntry>)

/** Closed sandbox set, not an export or backup transport. The digest must come from an independent retained anchor. */
internal class ClosedEvidenceSet(private val disk: IsolationDisk) {
    private val json = Json { encodeDefaults = true }

    fun seal(root: File, manifest: File): String = disk.locked(root) {
        check(!manifest.canonicalFile.toPath().startsWith(root.canonicalFile.toPath())) { "Manifest must not include itself" }
        val bytes = json.encodeToString(ClosedEvidenceManifest(entries = inventory(root))).toByteArray(Charsets.UTF_8)
        if (manifest.exists()) {
            check(manifest.absoluteFile == manifest.canonicalFile && manifest.readBytes().contentEquals(bytes)) { "Closed set changed" }
        } else disk.publishBytes(manifest, bytes)
        disk.confirmPublished(manifest)
        IsolationDisk.digest(bytes)
    }

    fun verify(root: File, manifest: File, expectedDigest: String): ClosedEvidenceManifest = disk.locked(root) {
        check(manifest.absoluteFile == manifest.canonicalFile && manifest.isFile) { "Missing restore manifest; recovery held" }
        check(IsolationDisk.digest(manifest) == expectedDigest) { "Restore anchor mismatch" }
        val retained = json.decodeFromString<ClosedEvidenceManifest>(manifest.readText())
        check(retained.version == 1 && retained.entries == retained.entries.sortedBy { it.path })
        check(retained.entries.map { it.path }.distinct().size == retained.entries.size)
        check(inventory(root) == retained.entries) { "Incomplete or changed restore; never an empty queue" }
        retained.entries.forEach { disk.confirmPublished(resolve(root, it.path)) }
        disk.confirmPublished(manifest)
        retained
    }

    private fun inventory(root: File): List<ClosedEvidenceEntry> {
        check(root.absoluteFile == root.canonicalFile && root.isDirectory)
        val result = mutableListOf<ClosedEvidenceEntry>()
        fun walk(directory: File) {
            check(directory.absoluteFile == directory.canonicalFile)
            checkNotNull(directory.listFiles()).sortedBy { it.name }.forEach { file ->
                check(file.absoluteFile == file.canonicalFile) { "Linked recovery dependency" }
                if (file.isDirectory) walk(file) else {
                    check(file.isFile)
                    val path = root.toPath().relativize(file.toPath()).toString().replace(File.separatorChar, '/')
                    if (path != "storage.lock") {
                        check(!file.name.endsWith(".partial")) { "Unfinished publication blocks restore seal" }
                        result += ClosedEvidenceEntry(path, file.length(), IsolationDisk.digest(file))
                    }
                }
            }
        }
        walk(root)
        return result.sortedBy { it.path }
    }

    private fun resolve(root: File, relative: String): File {
        check(relative.isNotBlank() && !relative.startsWith('/') && relative.split('/').none { it == ".." || it == "." || it.isEmpty() })
        val file = File(root, relative)
        check(file.absoluteFile == file.canonicalFile && file.toPath().startsWith(root.toPath()))
        return file
    }
}

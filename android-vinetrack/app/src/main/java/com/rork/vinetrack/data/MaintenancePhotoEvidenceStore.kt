package com.rork.vinetrack.data

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Durable original upload evidence and genuine storage receipt, scoped to author/vineyard.
 * No retry counters, credentials, background replay or selected-vineyard inference. */
class MaintenancePhotoEvidenceStore(private val directory: File) {
    @Serializable
    data class Entry(
        val owner: String,
        val vineyard: String,
        val log: String,
        val createdAt: String,
        val revision: String,
        val uploadedPath: String? = null,
        val deleting: Boolean = false,
        val objectRemoved: Boolean = false,
    )
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    private fun folder(owner: String, vineyard: String, log: String): File {
        listOf(owner, vineyard, log).forEach { MaintenanceWriteScope.requireUuid(it) }
        return File(directory, "${owner.lowercase(java.util.Locale.ROOT)}/${vineyard.lowercase(java.util.Locale.ROOT)}/${log.lowercase(java.util.Locale.ROOT)}")
    }

    @Synchronized fun stage(owner: String, vineyard: String, log: String, jpeg: ByteArray): Entry {
        val dir = folder(owner, vineyard, log)
        val metadata = File(dir, "entry.json")
        if (metadata.exists()) {
            val original = json.decodeFromString<Entry>(metadata.readText())
            check(original.owner == owner && original.vineyard == vineyard && original.log == log && !original.deleting)
            check(File(dir, "${original.revision}.jpg").isFile) { "Original maintenance evidence unavailable; retained for recovery" }
            return original
        }
        check(dir.mkdirs() || dir.isDirectory)
        val entry = Entry(owner, vineyard, log, Instant.now().toString(), UUID.randomUUID().toString())
        atomicWrite(File(dir, "${entry.revision}.jpg"), jpeg)
        atomicWrite(metadata, json.encodeToString(entry).toByteArray(Charsets.UTF_8))
        return entry
    }

    @Synchronized fun entries(owner: String, vineyard: String): List<Entry> {
        MaintenanceWriteScope.requireUuid(owner); MaintenanceWriteScope.requireUuid(vineyard)
        val root = File(directory, "${owner.lowercase(java.util.Locale.ROOT)}/${vineyard.lowercase(java.util.Locale.ROOT)}")
        return root.listFiles().orEmpty().filter { it.isDirectory }.mapNotNull { dir ->
            val file = File(dir, "entry.json")
            if (!file.exists()) null else json.decodeFromString<Entry>(file.readText()).also {
                check(it.owner == owner && it.vineyard == vineyard && it.log.equals(dir.name, true))
            }
        }
    }

    @Synchronized fun stageDelete(owner: String, vineyard: String, log: String, path: String): Entry {
        check(path == "${vineyard.lowercase(java.util.Locale.ROOT)}/maintenance/${log.lowercase(java.util.Locale.ROOT)}/photo.jpg")
        val dir = folder(owner, vineyard, log)
        val metadata = File(dir, "entry.json")
        if (metadata.exists()) return json.decodeFromString<Entry>(metadata.readText()).also {
            check(it.owner == owner && it.vineyard == vineyard && it.log == log && it.deleting && it.uploadedPath == path)
        }
        check(dir.mkdirs() || dir.isDirectory)
        val entry = Entry(owner, vineyard, log, Instant.now().toString(), UUID.randomUUID().toString(), uploadedPath = path, deleting = true)
        atomicWrite(metadata, json.encodeToString(entry).toByteArray(Charsets.UTF_8))
        return entry
    }

    @Synchronized fun recordRemovalReceipt(entry: Entry): Entry {
        check(entry.deleting && entry.uploadedPath != null)
        val metadata = File(folder(entry.owner, entry.vineyard, entry.log), "entry.json")
        check(json.decodeFromString<Entry>(metadata.readText()) == entry)
        val next = entry.copy(objectRemoved = true)
        atomicWrite(metadata, json.encodeToString(next).toByteArray(Charsets.UTF_8))
        return next
    }

    @Synchronized fun bytes(entry: Entry): ByteArray = File(folder(entry.owner, entry.vineyard, entry.log), "${entry.revision}.jpg").readBytes()

    @Synchronized fun recordReceipt(entry: Entry, path: String): Entry {
        val expected = "${entry.vineyard.lowercase(java.util.Locale.ROOT)}/maintenance/${entry.log.lowercase(java.util.Locale.ROOT)}/photo.jpg"
        check(path == expected) { "Mismatched maintenance upload receipt" }
        val metadata = File(folder(entry.owner, entry.vineyard, entry.log), "entry.json")
        check(json.decodeFromString<Entry>(metadata.readText()) == entry) { "Original evidence changed; no overwrite" }
        val acknowledged = entry.copy(uploadedPath = path)
        atomicWrite(metadata, json.encodeToString(acknowledged).toByteArray(Charsets.UTF_8))
        return acknowledged
    }

    @Synchronized fun complete(entry: Entry) {
        val dir = folder(entry.owner, entry.vineyard, entry.log)
        val metadata = File(dir, "entry.json")
        check(json.decodeFromString<Entry>(metadata.readText()) == entry && entry.uploadedPath != null && (!entry.deleting || entry.objectRemoved))
        check(metadata.delete())
        File(dir, "${entry.revision}.jpg").delete()
    }

    private fun atomicWrite(destination: File, bytes: ByteArray) {
        val temporary = File(destination.parentFile, destination.name + ".pending")
        java.io.FileOutputStream(temporary).use { stream -> stream.write(bytes); stream.fd.sync() }
        check(temporary.renameTo(destination)) { "Maintenance evidence could not be saved; no upload attempted" }
    }
}

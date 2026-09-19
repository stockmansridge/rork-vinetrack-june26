package com.rork.vinetrack.data

import android.content.Context
import android.util.Log
import androidx.core.util.AtomicFile
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Durable, app-private mirror of vineyard-logo JPEG bytes and remote identity. */
class VineyardLogoCache(context: Context) {
    @Serializable
    data class Metadata(
        val remotePath: String,
        val remoteLogoUpdatedAt: String? = null,
    )

    data class Entry(
        val jpeg: ByteArray,
        val metadata: Metadata?,
    ) {
        fun isCurrent(remotePath: String, remoteLogoUpdatedAt: String?): Boolean =
            metadata?.remotePath == remotePath &&
                metadata.remoteLogoUpdatedAt == remoteLogoUpdatedAt
    }

    private val root: File = File(context.applicationContext.filesDir, DIRECTORY)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun load(vineyardId: String): Entry? {
        val directory = vineyardDirectory(vineyardId)
        val image = File(directory, IMAGE_NAME)
        if (!image.isFile) return null
        return runCatching {
            val jpeg = image.readBytes()
            if (jpeg.isEmpty()) return null
            val metadata = File(directory, METADATA_NAME)
                .takeIf(File::isFile)
                ?.readText()
                ?.let { encoded -> runCatching { json.decodeFromString<Metadata>(encoded) }.getOrNull() }
            Entry(jpeg = jpeg, metadata = metadata)
        }.onFailure {
            Log.w(TAG, "Vineyard logo cache read failed: ${it.javaClass.simpleName}")
        }.getOrNull()
    }

    /** Writes complete files through [AtomicFile], replacing the previous mirror only on success. */
    fun save(
        vineyardId: String,
        jpeg: ByteArray,
        remotePath: String,
        remoteLogoUpdatedAt: String?,
    ): Boolean {
        if (jpeg.isEmpty()) return false
        val directory = vineyardDirectory(vineyardId)
        return runCatching {
            directory.mkdirs()
            writeAtomic(File(directory, IMAGE_NAME), jpeg)
            val metadata = Metadata(remotePath, remoteLogoUpdatedAt)
            writeAtomic(
                File(directory, METADATA_NAME),
                json.encodeToString(Metadata.serializer(), metadata).encodeToByteArray(),
            )
            true
        }.onFailure {
            Log.w(TAG, "Vineyard logo cache write failed: ${it.javaClass.simpleName}")
        }.getOrDefault(false)
    }

    fun remove(vineyardId: String) {
        runCatching { vineyardDirectory(vineyardId).deleteRecursively() }
            .onFailure { Log.w(TAG, "Vineyard logo cache delete failed: ${it.javaClass.simpleName}") }
    }

    private fun vineyardDirectory(vineyardId: String): File =
        File(root, vineyardId.lowercase().replace(UNSAFE_PATH_CHARS, "_"))

    private fun writeAtomic(file: File, bytes: ByteArray) {
        val atomicFile = AtomicFile(file)
        val stream = atomicFile.startWrite()
        try {
            stream.write(bytes)
            atomicFile.finishWrite(stream)
        } catch (error: Exception) {
            atomicFile.failWrite(stream)
            throw error
        }
    }

    private companion object {
        const val DIRECTORY = "vineyard_logos"
        const val IMAGE_NAME = "logo.jpg"
        const val METADATA_NAME = "metadata.json"
        const val TAG = "VineyardLogoCache"
        val UNSAFE_PATH_CHARS = Regex("[^a-z0-9-]")
    }
}

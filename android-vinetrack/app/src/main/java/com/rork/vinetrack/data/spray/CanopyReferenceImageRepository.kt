package com.rork.vinetrack.data.spray

import android.content.Context
import android.graphics.BitmapFactory
import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.encodeURLPathPart
import io.ktor.http.isSuccess
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class CanopyReferenceRemoteImage(
    val path: String,
    @SerialName("updated_at") val updatedAt: String,
)

@Serializable
data class CanopyReferenceConfiguration(
    val bucket: String,
    @SerialName("config_updated_at") val configUpdatedAt: String? = null,
    val images: Map<String, CanopyReferenceRemoteImage>,
)

fun interface CanopyReferenceConfigSource {
    suspend fun fetch(): CanopyReferenceConfiguration
}

fun interface CanopyReferenceImageDownloader {
    suspend fun download(bucket: String, path: String): ByteArray
}

@Serializable
data class CanopyReferenceManifestEntry(
    val slotKey: String,
    val remotePath: String,
    val remoteUpdatedAt: String,
    val localFilename: String,
    val successfulDownload: Boolean,
) {
    fun matches(remote: CanopyReferenceRemoteImage): Boolean =
        successfulDownload && remotePath == remote.path && remoteUpdatedAt == remote.updatedAt
}

@Serializable
data class CanopyReferenceManifest(
    val entries: Map<String, CanopyReferenceManifestEntry> = emptyMap(),
)

/**
 * Durable mirror of portal-managed canopy reference images.
 *
 * Files live under app-private filesDir, not an HTTP or temporary cache. A
 * replacement is decoded and atomically promoted before its manifest identity
 * is committed, so offline use and failed refreshes retain the last good image.
 */
class CanopyReferenceImageRepository(
    private val root: File,
    private val configSource: CanopyReferenceConfigSource,
    private val downloader: CanopyReferenceImageDownloader,
    private val validator: (ByteArray) -> Boolean,
    private val json: Json = Json { ignoreUnknownKeys = true; encodeDefaults = true },
) {
    private val manifestFile = File(root, MANIFEST_NAME)
    private val mutex = Mutex()
    private var manifest: CanopyReferenceManifest = loadManifest()
    private var hasAttemptedSessionRefresh = false
    private val _localFiles = MutableStateFlow(resolveUsableFiles(manifest))
    val localFiles: StateFlow<Map<String, File>> = _localFiles.asStateFlow()

    suspend fun refreshOncePerSession() = mutex.withLock {
        if (hasAttemptedSessionRefresh) return@withLock
        val configuration = runCatching { configSource.fetch() }.getOrElse { return@withLock }
        if (configuration.bucket.isBlank()) return@withLock
        hasAttemptedSessionRefresh = true
        apply(configuration)
    }

    suspend fun refresh() = mutex.withLock {
        val configuration = runCatching { configSource.fetch() }.getOrElse { return@withLock }
        if (configuration.bucket.isBlank()) return@withLock
        hasAttemptedSessionRefresh = true
        apply(configuration)
    }

    fun localFile(slotKey: String): File? = _localFiles.value[slotKey]

    fun manifestEntry(slotKey: String): CanopyReferenceManifestEntry? = manifest.entries[slotKey]

    private suspend fun apply(configuration: CanopyReferenceConfiguration) {
        val remoteImages = configuration.images.filterKeys(SprayCanopyReferenceImages.slotKeys::contains)

        val removedKeys = manifest.entries.keys - remoteImages.keys
        if (removedKeys.isNotEmpty()) {
            val obsolete = removedKeys.mapNotNull(manifest.entries::get)
            val reset = manifest.copy(entries = manifest.entries - removedKeys)
            if (saveManifest(reset)) {
                manifest = reset
                obsolete.forEach { File(root, it.localFilename).delete() }
                publishFiles()
            }
        }

        SprayCanopyReferenceImages.slotKeys.forEach { slotKey ->
            val remoteImage = remoteImages[slotKey] ?: return@forEach
            if (remoteImage.path.isBlank() || remoteImage.updatedAt.isBlank()) return@forEach
            val existing = manifest.entries[slotKey]
            if (existing?.matches(remoteImage) == true && isUsable(existing.localFilename)) return@forEach

            val bytes = runCatching { downloader.download(configuration.bucket, remoteImage.path) }.getOrNull()
                ?: return@forEach
            if (!validator(bytes)) return@forEach
            persistReplacement(slotKey, remoteImage, bytes)
        }
    }

    private fun persistReplacement(
        slotKey: String,
        remoteImage: CanopyReferenceRemoteImage,
        bytes: ByteArray,
    ) {
        root.mkdirs()
        val safeSlot = slotKey.replace('.', '_')
        val filename = "$safeSlot-${UUID.randomUUID().toString().lowercase()}.img"
        val destination = File(root, filename)
        val temporary = File(root, ".${UUID.randomUUID()}.download")
        val promoted = runCatching {
            temporary.outputStream().use { stream -> stream.write(bytes); stream.fdSync() }
            val persisted = temporary.readBytes()
            require(validator(persisted))
            require(temporary.renameTo(destination))
        }.isSuccess
        if (!promoted) {
            temporary.delete()
            destination.delete()
            return
        }

        val previous = manifest.entries[slotKey]
        val entry = CanopyReferenceManifestEntry(
            slotKey = slotKey,
            remotePath = remoteImage.path,
            remoteUpdatedAt = remoteImage.updatedAt,
            localFilename = filename,
            successfulDownload = true,
        )
        val updated = manifest.copy(entries = manifest.entries + (slotKey to entry))
        if (!saveManifest(updated)) {
            destination.delete()
            return
        }
        manifest = updated
        publishFiles()
        if (previous?.localFilename != null && previous.localFilename != filename) {
            File(root, previous.localFilename).delete()
        }
    }

    private fun loadManifest(): CanopyReferenceManifest {
        if (!manifestFile.isFile) return CanopyReferenceManifest()
        return runCatching { json.decodeFromString<CanopyReferenceManifest>(manifestFile.readText()) }
            .getOrDefault(CanopyReferenceManifest())
    }

    private fun saveManifest(value: CanopyReferenceManifest): Boolean = runCatching {
        root.mkdirs()
        val temporary = File(root, ".$MANIFEST_NAME.tmp")
        val backup = File(root, ".$MANIFEST_NAME.backup")
        temporary.outputStream().use { output ->
            output.write(json.encodeToString(value).encodeToByteArray())
            output.fd.sync()
        }
        backup.delete()
        if (manifestFile.exists()) require(manifestFile.renameTo(backup))
        if (!temporary.renameTo(manifestFile)) {
            if (backup.exists()) backup.renameTo(manifestFile)
            error("Could not promote canopy image manifest")
        }
        backup.delete()
    }.isSuccess

    private fun publishFiles() {
        _localFiles.value = resolveUsableFiles(manifest)
    }

    private fun resolveUsableFiles(value: CanopyReferenceManifest): Map<String, File> =
        value.entries.mapNotNull { (slot, entry) ->
            if (entry.successfulDownload && isUsable(entry.localFilename)) slot to File(root, entry.localFilename)
            else null
        }.toMap()

    private fun isUsable(filename: String): Boolean {
        val file = File(root, filename)
        if (!file.isFile) return false
        return runCatching { validator(file.readBytes()) }.getOrDefault(false)
    }

    private fun java.io.FileOutputStream.fdSync() {
        fd.sync()
    }

    companion object {
        const val DIRECTORY = "canopy_reference_images"
        private const val MANIFEST_NAME = "manifest.json"

        fun create(context: Context, session: SessionStore): CanopyReferenceImageRepository {
            val configSource = CanopyReferenceConfigSource {
                withContext(Dispatchers.IO) {
                    requireConfigAndToken(session).let { token ->
                        val response = SupabaseClient.http.post(
                            SupabaseClient.rpcUrl("get_canopy_reference_images_v1")
                        ) {
                            headers {
                                append("apikey", SupabaseClient.anonKey)
                                append("Authorization", "Bearer $token")
                            }
                            contentType(ContentType.Application.Json)
                            setBody(emptyMap<String, String>())
                        }
                        when {
                            response.status.isSuccess() -> response.body()
                            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
                        }
                    }
                }
            }
            val downloader = CanopyReferenceImageDownloader { bucket, path ->
                withContext(Dispatchers.IO) {
                    val token = requireConfigAndToken(session)
                    val encodedPath = path.split('/').joinToString("/") { it.encodeURLPathPart() }
                    val response = SupabaseClient.http.get(
                        SupabaseClient.storageUrl("object/authenticated/${bucket.encodeURLPathPart()}/$encodedPath")
                    ) {
                        headers {
                            append("apikey", SupabaseClient.anonKey)
                            append("Authorization", "Bearer $token")
                        }
                    }
                    when {
                        response.status.isSuccess() -> response.bodyAsBytes()
                        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
                    }
                }
            }
            return CanopyReferenceImageRepository(
                root = File(context.applicationContext.filesDir, DIRECTORY),
                configSource = configSource,
                downloader = downloader,
                validator = { bytes ->
                    runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
                        .getOrNull()
                        ?.let { bitmap -> bitmap.width > 0 && bitmap.height > 0 }
                        ?: false
                },
            )
        }

        private fun requireConfigAndToken(session: SessionStore): String {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            return session.accessToken ?: throw BackendError.Unauthorized
        }
    }
}

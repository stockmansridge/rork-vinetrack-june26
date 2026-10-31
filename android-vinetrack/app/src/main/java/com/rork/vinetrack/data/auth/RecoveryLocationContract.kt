package com.rork.vinetrack.data.auth

import android.graphics.BitmapFactory
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileInputStream
import kotlinx.serialization.json.Json
import com.rork.vinetrack.data.VineyardLogoCache

/** Read-only location contracts. Never relocate files, resolve external URIs or create acknowledgements. */
internal object RecoveryLocationContract {
    private val codec = Json { ignoreUnknownKeys = false }
    fun requireLocation(ok: Boolean, rule: String) {
        if (!ok) throw EvidenceContractFailure(RecoveryEvidenceDiagnostic("file_dependencies", rule))
    }

    /** lstat, not exists(): a dangling symlink is retained evidence too. */
    fun present(file: File): Boolean = try { Os.lstat(file.path); true }
        catch (error: ErrnoException) {
            if (error.errno == OsConstants.ENOENT) false else {
                requireLocation(false, "LOCATION_STAT_UNAVAILABLE"); false
            }
        }

    fun directory(file: File, rule: String): List<File> {
        val stat = Os.lstat(file.path)
        requireLocation(!OsConstants.S_ISLNK(stat.st_mode) && file.absoluteFile == file.canonicalFile, "LOCATION_LINK_OR_ALIAS")
        requireLocation(OsConstants.S_ISDIR(stat.st_mode), rule)
        return file.listFiles()?.toList() ?: run {
            requireLocation(false, "LOCATION_LIST_UNAVAILABLE"); emptyList()
        }
    }

    fun emptyTree(file: File, rule: String) {
        if (!present(file)) return
        directory(file, rule).forEach { emptyTree(it, rule) }
    }

    /** Exact writer layout only; its folder is a scope to verify against current live access, not ownership. */
    fun logos(root: File): Set<String> {
        val scopes = mutableSetOf<String>()
        directory(root, "LOGO_ROOT_TYPE").forEach { vineyard ->
            requireLocation(vineyard.name.matches(Regex("[a-z0-9]+(?:-[a-z0-9]+)*")), "LOGO_SCOPE_FORMAT")
            val files = directory(vineyard, "LOGO_SCOPE_TYPE")
            requireLocation(files.map { it.name }.toSet() == setOf("logo.jpg", "metadata.json"), "LOGO_LAYOUT_OR_INTERRUPTED_WRITE")
            val metadata = readRegular(File(vineyard, "metadata.json"), 64 * 1024, "LOGO_METADATA_FILE")
            val decoded = try { codec.decodeFromString<VineyardLogoCache.Metadata>(metadata.decodeToString(throwOnInvalidSequence = true)) }
                catch (_: Exception) { requireLocation(false, "LOGO_METADATA_SCHEMA"); error("Unreachable") }
            requireLocation(decoded.remotePath.isNotBlank(), "LOGO_METADATA_SCHEMA")
            val jpeg = readRegular(File(vineyard, "logo.jpg"), 8 * 1024 * 1024, "LOGO_IMAGE_FILE")
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
            requireLocation(jpeg.size >= 4 && jpeg[0] == 0xff.toByte() && jpeg[1] == 0xd8.toByte() &&
                jpeg[jpeg.lastIndex - 1] == 0xff.toByte() && jpeg.last() == 0xd9.toByte() &&
                bounds.outMimeType == "image/jpeg" && bounds.outWidth in 1..8192 && bounds.outHeight in 1..8192,
                "LOGO_IMAGE_FORMAT")
            // Verify decodability without allocating the full retained image at its original dimensions.
            val options = BitmapFactory.Options().apply {
                inSampleSize = Integer.highestOneBit(maxOf(bounds.outWidth, bounds.outHeight) / 256).coerceAtLeast(1)
            }
            val image = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            requireLocation(image != null, "LOGO_IMAGE_FORMAT")
            image?.recycle()
            scopes.add(vineyard.name)
        }
        return scopes
    }

    private fun readRegular(file: File, maxBytes: Int, rule: String): ByteArray {
        val before = Os.lstat(file.path)
        requireLocation(!OsConstants.S_ISLNK(before.st_mode) && file.absoluteFile == file.canonicalFile, "LOCATION_LINK_OR_ALIAS")
        requireLocation(OsConstants.S_ISREG(before.st_mode) && before.st_nlink == 1L && before.st_size in 1L..maxBytes.toLong(), rule)
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        return FileInputStream(fd).use { input ->
            val opened = Os.fstat(fd)
            requireLocation(opened.st_dev == before.st_dev && opened.st_ino == before.st_ino && opened.st_size == before.st_size &&
                OsConstants.S_ISREG(opened.st_mode) && opened.st_nlink == 1L, rule)
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (output.size() <= maxBytes) {
                val count = input.read(buffer, 0, minOf(buffer.size, maxBytes + 1 - output.size()))
                if (count < 0) break
                output.write(buffer, 0, count)
            }
            val bytes = output.toByteArray()
            val after = Os.lstat(file.path)
            requireLocation(bytes.size.toLong() == before.st_size && after.st_dev == opened.st_dev && after.st_ino == opened.st_ino &&
                after.st_size == opened.st_size && after.st_mtime == opened.st_mtime && after.st_nlink == 1L, rule)
            bytes
        }
    }

    /** Fixed vocabulary only: never return a path, URI, arbitrary filename or record identifier. */
    fun retainedRule(file: File): String = when (file.name) {
        "pending_pin_photos" -> "FILES_PENDING_PIN_PHOTOS_RETAINED"
        "pin_photo_display_cache" -> "FILES_PIN_DISPLAY_CACHE_RETAINED"
        "photo-acquisitions" -> "FILES_PHOTO_ACQUISITIONS_RETAINED"
        "pending_chemical_label_photos" -> "FILES_CHEMICAL_PHOTOS_RETAINED"
        "scout_photos" -> "FILES_SCOUT_PHOTOS_RETAINED"
        "ripeness-heatmap" -> "FILES_RIPENESS_CACHE_RETAINED"
        "vintage-reports", "vintage-report-exports" -> "FILES_VINTAGE_REPORTS_RETAINED"
        "spray-planning-attempts-v1" -> "FILES_SPRAY_PLANNING_RETAINED"
        "maintenance-photo-evidence-v1" -> "FILES_MAINTENANCE_PHOTOS_RETAINED"
        "pin_capture_evidence_recovery_v2.json", "pin_capture_evidence_recovery_v2.json.bak", "pin_capture_evidence_recovery_v2.json.new" -> "FILES_PIN_CAPTURE_JOURNAL_RETAINED"
        "field-isolation-v2" -> "FILES_ISOLATION_EVIDENCE_RETAINED"
        else -> "FILES_UNREVIEWED_CONTENT"
    }
}

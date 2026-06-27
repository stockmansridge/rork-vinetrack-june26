package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.Paddock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Local JSON import / export for blocks (paddocks). Mirrors the iOS
 * `PaddockJSONService` / `BlocksHubView` workflow: a one-tap backup, device
 * migration, and share path for the whole block layout (boundaries, rows and
 * variety allocations).
 *
 * File shape (matches iOS):
 * ```
 * {
 *   "version": 1,
 *   "exportedAt": "2026-04-29T...",
 *   "vineyardId": "<uuid>",
 *   "paddocks": [ <Paddock>, ... ]
 * }
 * ```
 *
 * A bare `[ <Paddock>, ... ]` array is also accepted on import, matching the
 * iOS decoder's tolerant fallback. The exported file is written to the app
 * cache (`cache/exports`) and shared via [FileProvider]; it is never uploaded.
 */
object PaddockTransferService {

    /** Outcome of an import parse — created/updated/skipped counts and any per-entry errors. */
    data class ImportSummary(
        val created: Int = 0,
        val updated: Int = 0,
        val skipped: Int = 0,
        val errors: List<String> = emptyList(),
    )

    /** Successful parse result: the paddocks to upsert plus a human summary. */
    data class ParseResult(val paddocks: List<Paddock>, val summary: ImportSummary)

    /** Typed import failures with iOS-matching user-facing messages. */
    sealed class ImportError(val userMessage: String) : Exception(userMessage) {
        data object EmptyFile : ImportError("The selected file is empty.")
        data object NoBlocks : ImportError("The file did not contain any blocks.")
        data object InvalidJson :
            ImportError("This file is not a valid VineTrack blocks JSON file.")
    }

    @Serializable
    private data class ExportFile(
        val version: Int = 1,
        val exportedAt: String,
        val vineyardId: String? = null,
        val paddocks: List<Paddock>,
    )

    private val exportJson = Json {
        prettyPrint = true
        encodeDefaults = true
        ignoreUnknownKeys = true
    }

    private val importJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    // MARK: - Export

    /**
     * Build the blocks JSON for [paddocks], write it to the cache, and launch the
     * Android share sheet. Returns false if there is nothing to export or
     * generation failed; never throws.
     */
    fun exportAndShare(
        context: Context,
        paddocks: List<Paddock>,
        vineyardId: String?,
        vineyardName: String,
    ): Boolean {
        if (paddocks.isEmpty()) return false
        return try {
            val payload = ExportFile(
                version = 1,
                exportedAt = iso8601().format(Date()),
                vineyardId = vineyardId,
                paddocks = paddocks,
            )
            val text = exportJson.encodeToString(ExportFile.serializer(), payload)

            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val file = File(dir, fileName(vineyardName))
            file.writeText(text)

            val uri: Uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(
                Intent.createChooser(share, "Share blocks").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e: Exception) {
            android.util.Log.e("PaddockTransferService", "Blocks export failed", e)
            false
        }
    }

    // MARK: - Import

    /**
     * Parse blocks JSON [data] into paddocks scoped to [vineyardId], computing a
     * create/update/skip summary against the [existing] list. Throws an
     * [ImportError] with a user-facing message on failure.
     */
    fun parseJson(data: String, vineyardId: String, existing: List<Paddock>): ParseResult {
        val trimmed = data.trim()
        if (trimmed.isEmpty()) throw ImportError.EmptyFile

        val parsed: List<Paddock> = decode(trimmed)
        if (parsed.isEmpty()) throw ImportError.NoBlocks

        val existingIds: Set<String> = existing.map { it.id }.toSet()
        var created = 0
        var updated = 0
        var skipped = 0
        val errors = mutableListOf<String>()
        val result = mutableListOf<Paddock>()

        parsed.forEachIndexed { index, incoming ->
            val entryNumber = index + 1
            if (incoming.name.trim().isEmpty()) {
                skipped++
                errors.add("Block $entryNumber: missing name")
                return@forEachIndexed
            }
            val paddock = incoming.copy(vineyardId = vineyardId)
            if (existingIds.contains(paddock.id)) updated++ else created++
            result.add(paddock)
        }

        return ParseResult(
            paddocks = result,
            summary = ImportSummary(created = created, updated = updated, skipped = skipped, errors = errors),
        )
    }

    /** Render an import summary into the multi-line message shown in the result dialog (matches iOS). */
    fun summaryMessage(summary: ImportSummary): String {
        val lines = mutableListOf(
            "Created: ${summary.created}",
            "Updated: ${summary.updated}",
            "Skipped: ${summary.skipped}",
        )
        if (summary.errors.isNotEmpty()) {
            lines.add("")
            lines.addAll(summary.errors.take(5))
            if (summary.errors.size > 5) lines.add("…and ${summary.errors.size - 5} more")
        }
        return lines.joinToString("\n")
    }

    private fun decode(text: String): List<Paddock> {
        // Wrapped { version, paddocks: [...] } shape first, then a bare array.
        runCatching { importJson.decodeFromString(ExportFile.serializer(), text) }
            .getOrNull()?.let { return it.paddocks }
        runCatching {
            importJson.decodeFromString(
                kotlinx.serialization.builtins.ListSerializer(Paddock.serializer()),
                text,
            )
        }.getOrNull()?.let { return it }
        throw ImportError.InvalidJson
    }

    private fun iso8601(): SimpleDateFormat =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = java.util.TimeZone.getTimeZone("UTC")
        }

    private fun fileName(vineyardName: String): String {
        val safe = vineyardName.ifBlank { "Vineyard" }
            .replace(" ", "_")
            .replace("/", "-")
            .replace(":", "-")
            .replace(Regex("[^A-Za-z0-9_\\-]"), "")
            .ifBlank { "Vineyard" }
        val date = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        return "${safe}_blocks_$date.json"
    }
}

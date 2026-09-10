package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.serialization.json.Json

/**
 * Exports only pin-recovery evidence for one vineyard from local app stores.
 * It is read-only and intentionally excludes auth/session preferences.
 */
object PinRecoveryDiagnosticExporter {
    fun exportAndShare(context: Context, vineyardId: String): Boolean = runCatching {
        // Normal startup captures this before load/replay. The fallback exists for
        // upgrades that reach Export before the next vineyard bootstrap.
        val evidence = RecoverySnapshotStore(context).load(vineyardId)
            ?: RecoverySnapshotStore.captureBeforeMutation(context, vineyardId)
        val directory = File(context.cacheDir, "exports").apply { mkdirs() }
        val file = File(directory, "vinetrack-pin-recovery-${vineyardId.take(8)}.json")
        file.writeText(json.encodeToString(RecoverySnapshotStore.Snapshot.serializer(), evidence))
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        context.startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND).apply {
                    type = "application/json"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
                "Share pin recovery evidence",
            ),
        )
    }.isSuccess

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }
}

package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.serialization.json.Json

/**
 * Exports the immutable pre-mutation snapshot and a separately timestamped view
 * of current local evidence. It intentionally excludes auth/session preferences.
 */
object PinRecoveryDiagnosticExporter {
    fun exportAndShare(context: Context, vineyardId: String): Boolean = runCatching {
        // Normal startup captures this before load/replay. The fallback exists for
        // upgrades that reach Export before the next vineyard bootstrap.
        val store = RecoverySnapshotStore(context)
        val original = when (val loaded = store.loadResult(vineyardId)) {
            is RecoverySnapshotStore.LoadResult.Valid -> loaded.snapshot
            is RecoverySnapshotStore.LoadResult.Unreadable -> error("The original recovery snapshot is unreadable and was left unchanged.")
            RecoverySnapshotStore.LoadResult.Missing -> when (
                val captured = RecoverySnapshotStore.captureBeforeMutation(context, vineyardId)
            ) {
                is RecoverySnapshotStore.SaveResult.Existing -> captured.snapshot
                is RecoverySnapshotStore.SaveResult.Persisted -> captured.snapshot
                is RecoverySnapshotStore.SaveResult.ExistingUnreadable -> error("The original recovery snapshot is unreadable and was left unchanged.")
                RecoverySnapshotStore.SaveResult.Failed -> error("Recovery evidence could not be preserved. Please retry.")
            }
        }
        val current = RecoverySnapshotStore.collectCurrentEvidence(context, vineyardId)
        val evidence = RecoverySnapshotStore.exportBundle(original, current)
        val directory = File(context.cacheDir, "exports").apply { mkdirs() }
        val file = File(directory, "vinetrack-pin-recovery-${vineyardId.take(8)}.json")
        file.writeText(json.encodeToString(RecoverySnapshotStore.ExportBundle.serializer(), evidence))
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

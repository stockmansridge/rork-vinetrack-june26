package com.rork.vinetrack.data

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.Trip
import java.io.File
import java.time.Instant
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Exports only pin-recovery evidence for one vineyard from local app stores.
 * It is read-only and intentionally excludes auth/session preferences.
 */
object PinRecoveryDiagnosticExporter {
    @Serializable
    private data class Evidence(
        val formatVersion: Int = 1,
        val vineyardId: String,
        val exportedAt: String,
        val pendingPinWrites: List<PendingWrite>,
        val captureEvidence: List<PinCaptureEvidenceStore.Evidence>,
        val cachedPins: List<Pin>,
        val cachedTrips: List<Trip>,
        val activeTrip: Trip?,
    )

    fun exportAndShare(context: Context, vineyardId: String): Boolean = runCatching {
        val pending = PendingWriteRepository(context).list().filter { write ->
            write.entityType == PendingEntityType.PIN && payloadVineyardId(write.payloadJson) == vineyardId
        }
        val cache = DomainCacheStore(context)
        val active = ActiveTripStore(context).load()?.takeIf { it.vineyardId == vineyardId }?.trip
        val evidence = Evidence(
            vineyardId = vineyardId,
            exportedAt = Instant.now().toString(),
            pendingPinWrites = pending,
            captureEvidence = PinCaptureEvidenceStore(context).load().filter { it.vineyardId == vineyardId },
            cachedPins = cache.loadPins(vineyardId),
            cachedTrips = cache.loadTrips(vineyardId),
            activeTrip = active,
        )
        val directory = File(context.cacheDir, "exports").apply { mkdirs() }
        val file = File(directory, "vinetrack-pin-recovery-${vineyardId.take(8)}.json")
        file.writeText(json.encodeToString(Evidence.serializer(), evidence))
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

    private fun payloadVineyardId(payload: String): String? = runCatching {
        json.parseToJsonElement(payload).jsonObject["vineyard_id"]?.jsonPrimitive?.content
    }.getOrNull()

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }
}

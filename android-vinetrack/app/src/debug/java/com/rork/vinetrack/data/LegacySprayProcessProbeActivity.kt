package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.os.Bundle
import android.os.Process
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import com.rork.vinetrack.data.auth.SessionStore
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.util.UUID

/** Debug-only isolated Android process. Never registers a real account or calls a transport. */
class LegacySprayProcessProbeActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val result = runCatching { execute() }.getOrElse { "LEGACY_PROBE_FAILED" }
        setContent { MaterialTheme { Text(result) } }
    }
    private fun execute(): String {
        val id = intent.getStringExtra("case") ?: error("Missing case")
        UUID.fromString(id)
        val mode = intent.getStringExtra("mode") ?: error("Missing mode")
        val prefix = "legacy_process_${id}_"
        val isolated = object : ContextWrapper(this) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int) = baseContext.getSharedPreferences(prefix + name, mode)
        }
        if (mode == "cleanup") {
            listOf("vinetrack_session", LegacySpraySaveStore.PREFERENCES).forEach { deleteSharedPreferences(prefix + it) }
            return "LEGACY_CLEANED"
        }
        val actor = UUID.nameUUIDFromBytes("actor$id".toByteArray()).toString()
        val vineyard = UUID.nameUUIDFromBytes("vineyard$id".toByteArray()).toString()
        val trip = UUID.nameUUIDFromBytes("trip$id".toByteArray()).toString()
        val record = UUID.nameUUIDFromBytes("record$id".toByteArray()).toString()
        val session = SessionStore(isolated)
        if (!session.hasSession) session.save("synthetic-access", "synthetic-refresh", actor, null)
        val input = SprayRecordRepository.SprayInput("2026-10-15", "2026-10-15T08:00:00Z", null, null, null, null,
            "Original", "Frozen", null, null, null, null, null, null, sprayEquipmentId = null,
            operationType = "foliar_spray", tripId = trip, tanks = emptyList())
        val original = LegacySpraySaveStore.Attempt(actor, session.retentionGuard.identityEpoch.value,
            LegacySpraySaveStore.TripIntent(trip, vineyard, null, emptyList(), "Frozen block", "Synthetic operator",
                input.startTime, null, actor, "freeDrive", emptyList(), 0, "2026-10-15T08:01:00Z"), record, input)
        val store = LegacySpraySaveStore(isolated)
        if (mode == "read") {
            val raw = isolated.getSharedPreferences(LegacySpraySaveStore.PREFERENCES, MODE_PRIVATE).getString("attempts", null) ?: error("Missing")
            val retained = Json.decodeFromString<List<LegacySpraySaveStore.Attempt>>(raw).single()
            if (retained.rpc != null) {
                check(retained == original.copy(rpc = retained.rpc, rpcClaimed = true))
                check(store.blocks(trip))
                val accepted = kotlinx.coroutines.runBlocking {
                    store.sendReceipt(retained, { true }) { rpc, request ->
                        check(rpc == "recover_legacy_spray_pair_v1" && request == retained.rpc)
                        LegacySprayPairReceipt.Receipt(1, "accepted", request.operation, vineyard, trip, record,
                            "a".repeat(64), "2026-10-15T03:00:01Z")
                    }
                }
                check(accepted && !store.blocks(trip))
                return "LEGACY_RECOVERED_RPC_CLAIMED"
            }
            check(retained.copy(stage = LegacySpraySaveStore.Stage.PREPARED) == original)
            check(store.pending(vineyard).single() == retained && store.blocks(trip))
            return "LEGACY_RECOVERED_${retained.stage}"
        }
        if (mode == "RPC_CLAIMED") {
            val attempt = original.copy(rpc = LegacySprayPairReceipt.prepare(TripRepository(session).legacyReceiptInsert(original.trip),
                SprayRecordRepository(session).legacyReceiptInsert(vineyard, input, record, original.trip.createdAt, actor)))
            store.prepare(attempt)
            kotlinx.coroutines.runBlocking { runCatching {
                store.sendReceipt(attempt, { true }) { _, _ -> error("Synthetic lost successful response") }
            } }
            check(store.pending(vineyard).single().rpcClaimed)
            return "LEGACY_RETAINED_${Process.myPid()}"
        }
        val stage = LegacySpraySaveStore.Stage.valueOf(mode)
        check(stage != LegacySpraySaveStore.Stage.COMPLETE)
        store.prepare(original)
        LegacySpraySaveStore.Stage.entries.drop(1).take(stage.ordinal).forEach { store.mark(original, it) }
        return "LEGACY_RETAINED_${Process.myPid()}"
    }
}

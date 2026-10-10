package com.rork.vinetrack.data.isolation

import com.rork.vinetrack.data.PendingWriteStoring
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.insights.InsightsKeyValueStore
import com.rork.vinetrack.data.insights.PairedGrowthCaptureJournal
import com.rork.vinetrack.data.insights.PairedGrowthCaptureJournalStore
import java.io.ByteArrayOutputStream
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Disabled adapter core. Every key revision is append-only, including logical removal; legacy data is never an input. */
internal class DisabledOwnedValues(
    private val accounts: AccountEvidenceStore,
    private val capability: FieldAccountCapability,
    private val vineyard: String,
    private val collection: String,
) : InsightsKeyValueStore {
    private val json = Json { encodeDefaults = true }

    override fun read(key: String): String? {
        val row = accounts.metadata(capability, vineyard, collection).lastOrNull { it.recordId == key } ?: return null
        val output = ByteArrayOutputStream()
        check(accounts.copyBinary(capability, vineyard, collection, row.revision, output))
        return json.decodeFromString<String?>(output.toString(Charsets.UTF_8.name()))
    }

    override fun write(key: String, value: String): Boolean = publish(key, value)
    override fun remove(key: String): Boolean = publish(key, null)

    private fun publish(key: String, value: String?): Boolean {
        accounts.append(capability, vineyard, collection, key, json.encodeToString(value).toByteArray(Charsets.UTF_8))
        return true
    }
}

/** Actual PendingWriteRepository persistence seam. Only self-contained explicit-vineyard payloads are supported yet. */
internal class DisabledPendingWriteAdapter(
    private val values: DisabledOwnedValues,
    private val vineyard: String,
) : PendingWriteStoring {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PendingWrite.serializer())
    override fun load(): List<PendingWrite> = values.read("writes")?.let { json.decodeFromString(serializer, it) } ?: emptyList()
    override fun save(writes: List<PendingWrite>): Boolean {
        writes.forEach { write ->
            val payload = json.parseToJsonElement(write.payloadJson).jsonObject
            val candidates = listOfNotNull(payload["vineyardId"]?.jsonPrimitive?.content,
                payload["vineyard_id"]?.jsonPrimitive?.content).toSet()
            check(candidates == setOf(vineyard)) { "Unsupported or conflicting operation vineyard; retain original" }
        }
        return values.write("writes", json.encodeToString(serializer, writes))
    }
    override fun clear(): Boolean = values.remove("writes")
}

/** Actual paired capture coordinator seam; journal updates remain isolated across accounts in a shared vineyard. */
internal class DisabledPairedJournalAdapter(
    private val values: DisabledOwnedValues,
    private val vineyard: String,
) : PairedGrowthCaptureJournalStore {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PairedGrowthCaptureJournal.serializer())
    override fun load(): List<PairedGrowthCaptureJournal> = values.read("journals")?.let {
        json.decodeFromString(serializer, it).also { rows -> check(rows.all { row -> row.vineyardId == vineyard }) }
    } ?: emptyList()
    override fun save(journal: PairedGrowthCaptureJournal): Boolean {
        check(journal.vineyardId == vineyard)
        return write(load().filterNot { it.operationId == journal.operationId } + journal)
    }
    override fun remove(operationId: String): Boolean = write(load().filterNot { it.operationId == operationId })
    private fun write(rows: List<PairedGrowthCaptureJournal>): Boolean = values.write("journals", json.encodeToString(serializer, rows))
}

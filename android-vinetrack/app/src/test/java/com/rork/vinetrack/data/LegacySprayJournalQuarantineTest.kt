package com.rork.vinetrack.data

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacySprayJournalQuarantineTest {
    private val t1 = "11111111-1111-4111-8111-111111111111"
    private val r1 = "22222222-2222-4222-8222-222222222222"
    private val t2 = "33333333-3333-4333-8333-333333333333"
    private val r2 = "44444444-4444-4444-8444-444444444444"

    private data class Row(val trip: String, val record: String)

    /** Stand-in for strict decode + validate: rows must have `ok: true`. */
    private fun decode(row: JsonElement): Row {
        val obj = row as JsonObject
        check(obj["ok"]?.jsonPrimitive?.content == "true") { "validation failed" }
        return Row((obj["trip"] as JsonObject)["id"]!!.jsonPrimitive.content, obj["recordId"]!!.jsonPrimitive.content)
    }

    private fun row(trip: String, record: String, ok: Boolean) =
        """{"trip":{"id":"$trip"},"recordId":"$record","ok":$ok}"""

    private fun split(raw: String) = LegacySprayJournalQuarantine.split(raw, ::decode) { it.trip to it.record }

    @Test fun readableRowsAreKeptAndOnlyTheUnreadableOneIsSetAside() {
        val result = split("[${row(t1, r1, true)},${row(t2, r2, false)}]")
        assertEquals(listOf(Row(t1, r1)), result.kept)
        assertEquals(1, result.reasons.size)
        val reason = result.reasons.single()
        assertTrue(reason, reason.startsWith("row 1: validate:IllegalStateException (validation failed)"))
        assertTrue("identifies the set-aside row for support", reason.contains("trip=$t2") && reason.contains("record=$r2"))
    }

    @Test fun duplicateIdentitiesAreAllSetAsideNeverGuessed() {
        val result = split("[${row(t1, r1, true)},${row(t1, r2, true)}]")
        assertTrue(result.kept.isEmpty())
        assertEquals(2, result.reasons.size)
        assertTrue(result.reasons.all { "duplicate_identity" in it })
    }

    @Test fun unparseableStoreSetsEverythingAside() {
        val result = split("not json")
        assertTrue(result.kept.isEmpty())
        assertTrue(result.reasons.single().startsWith("store: unparseable_json_array"))
    }

    @Test fun originalBytesAreRetainedVerbatimAndEntriesAccumulate() {
        val raw1 = "[${row(t2, r2, false)}]"
        val first = LegacySprayJournalQuarantine.append(null,
            LegacySprayJournalQuarantine.Entry(1_000L, listOf("row 0: validate:X"), 0, raw1))
        val second = LegacySprayJournalQuarantine.append(first,
            LegacySprayJournalQuarantine.Entry(2_000L, listOf("store: unparseable_json_array (X)"), 0, "not json"))
        assertEquals(listOf(raw1, "not json"), LegacySprayJournalQuarantine.originals(second))
        val lines = LegacySprayJournalQuarantine.diagnostics(second)
        assertTrue(lines.any { it.contains("rows_set_aside: 1; rows_kept: 0; original_bytes_retained: true") })
        assertTrue(lines.any { it == "  set_aside_reason: row 0: validate:X" })
    }

    @Test fun anUnreadableEarlierLogIsKeptNotOverwritten() {
        val next = LegacySprayJournalQuarantine.append("garbage",
            LegacySprayJournalQuarantine.Entry(3_000L, emptyList(), 1, "[]"))
        assertEquals(listOf("garbage", "[]"), LegacySprayJournalQuarantine.originals(next))
    }

    @Test fun decodeErrorsDropEchoedInput() {
        val error = kotlinx.serialization.SerializationException("Encountered an unknown key 'foo' at offset 3\nJSON input: {\"secret\":1}")
        val text = LegacySprayJournalQuarantine.describe(error)
        assertEquals("decode:SerializationException (Encountered an unknown key 'foo' at offset 3)", text)
    }
}

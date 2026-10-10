package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Vineyard
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class VineyardCachePerformanceTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(Vineyard.serializer())

    @Test fun repeatedEncodingIsExactAndDoesNotDecideWhetherMetadataIsSaved() {
        val events = mutableListOf<VineyardCacheTiming>()
        val codec = VineyardCacheCodec { events += it }
        val rows = listOf(Vineyard("fixture", "Fixture", latitude = -33.12345678912345))
        val golden = json.encodeToString(serializer, rows)
        assertEquals(golden, codec.encode(rows, null))
        assertEquals(golden, codec.encode(rows, golden))
        assertTrue(events.last().reused)
        assertEquals(false, events.last().changed)
        assertEquals(rows, json.decodeFromString(serializer, golden))
    }

    @Test fun changedFieldsAndOrderCannotReuseEncoding() {
        val events = mutableListOf<VineyardCacheTiming>()
        val codec = VineyardCacheCodec { events += it }
        val first = Vineyard("first", "First", timezone = "Australia/Sydney")
        val second = Vineyard("second", "Second")
        val previous = codec.encode(listOf(first, second), null)
        val changed = listOf(second, first.copy(timezone = "UTC", elevationMetres = 123.123456789))
        val raw = codec.encode(changed, previous)
        assertFalse(events.last().reused)
        assertEquals(true, events.last().changed)
        assertEquals(json.encodeToString(serializer, changed), raw)
    }

    @Test fun unicodeSpellingAndSignedZeroRemainByteDistinct() {
        val events = mutableListOf<VineyardCacheTiming>()
        val codec = VineyardCacheCodec { events += it }
        val first = Vineyard("fixture", "\u00e9", latitude = 0.0)
        val raw = codec.encode(listOf(first), null)
        val alternate = first.copy(name = "e\u0301", latitude = -0.0)
        val encoded = codec.encode(listOf(alternate), raw)
        assertFalse(events.last().reused)
        assertEquals(json.encodeToString(serializer, listOf(alternate)), encoded)
        assertNotEquals(raw, encoded)
    }

    @Test fun returnedListMutationCannotAlterDecodeOrEncodeMemos() {
        val codec = VineyardCacheCodec()
        val first = Vineyard("fixture", "First")
        val mutable = mutableListOf(first)
        val raw = codec.encode(mutable, null)
        mutable[0] = first.copy(name = "Changed")
        assertEquals(json.encodeToString(serializer, mutable), codec.encode(mutable, raw))
        val returned = codec.decode(raw).toMutableList()
        returned[0] = first.copy(name = "Unsaved")
        assertEquals(listOf(first), codec.decode(raw))
    }

    @Test fun actualReturnedMutableListCannotPoisonSharedMemo() {
        val codec = VineyardCacheCodec()
        val rows = listOf(Vineyard("a", "A"), Vineyard("b", "B"))
        val raw = json.encodeToString(serializer, rows)
        val returned = codec.decode(raw)
        if (returned is MutableList<Vineyard>) returned.clear()
        assertEquals(rows, codec.decode(raw))
    }

    @Test fun rawChangeMissingAndCorruptionKeepExistingFallbacks() {
        val events = mutableListOf<VineyardCacheTiming>()
        val codec = VineyardCacheCodec { events += it }
        val a = json.encodeToString(serializer, listOf(Vineyard("a", "A")))
        val b = json.encodeToString(serializer, listOf(Vineyard("b", "B")))
        assertEquals("a", codec.decode(a).first().id)
        assertEquals("a", codec.decode(a).first().id)
        assertTrue(events.last().reused)
        assertEquals("b", codec.decode(b).first().id)
        assertFalse(events.last().reused)
        assertTrue(codec.decode("corrupt").isEmpty())
        assertTrue(codec.decode(null).isEmpty())
        assertEquals("a", codec.decode(a).first().id)
    }

    @Test fun immutableReadWorkerRunsOffCallerAndPropagatesFailure() = runBlocking {
        val caller = Thread.currentThread()
        val worker = LocalCacheReadWorker.read { Thread.currentThread() }
        assertNotSame(caller, worker)
        val failure = IllegalStateException("fixture")
        try {
            LocalCacheReadWorker.read<Unit> { throw failure }
            fail("Read failure must propagate")
        } catch (caught: IllegalStateException) {
            // Coroutine debug stack recovery may copy the exception and retain
            // the original as its cause; type and failure semantics must survive.
            assertEquals(failure.message, caught.message)
            assertTrue(caught === failure || caught.cause === failure)
        }
    }

    @Test fun delayedHydrationCannotReplaceClearedNewerOrOtherOwnerCache() {
        val hydration = VineyardCacheHydration(listOf(Vineyard("fixture", "Fixture")), 100L, "original-bytes")
        assertTrue(hydration.matchesSource("owner", "owner", "original-bytes", 100L))
        assertFalse(hydration.matchesSource("owner", "other", "original-bytes", 100L))
        assertFalse(hydration.matchesSource("owner", "owner", "newer-bytes", 100L))
        assertFalse(hydration.matchesSource("owner", "owner", "original-bytes", 101L))
        assertFalse(hydration.matchesSource("owner", null, null, null))
    }

    @Test fun formatDefaultsUnknownFieldsAndPrecisionMatchOriginalCodec() {
        val codec = VineyardCacheCodec()
        val legacy = """[{"id":"fixture","name":"Fixture","latitude":-33.12345678912345,"unknown":42}]"""
        val expected = json.decodeFromString(serializer, legacy)
        assertEquals(expected, codec.decode(legacy))
        assertEquals(json.encodeToString(serializer, expected), codec.encode(expected, legacy))
        assertEquals(expected.first().latitude?.toBits(), codec.decode(legacy).first().latitude?.toBits())
    }

    @Test fun boundedSyntheticBenchmark() {
        val rows = (0 until 300).map { Vineyard("fixture-$it", "Fixture $it", latitude = -33.12345678912345) }
        val raw = json.encodeToString(serializer, rows)
        val codec = VineyardCacheCodec()
        val before = System.nanoTime()
        repeat(20) { assertEquals(rows, json.decodeFromString(serializer, raw)) }
        val baseline = (System.nanoTime() - before) / 20.0 / 1_000_000
        codec.decode(raw)
        val after = System.nanoTime()
        repeat(20) { assertEquals(rows, codec.decode(raw)) }
        val memo = (System.nanoTime() - after) / 20.0 / 1_000_000
        println("PERSISTENCE_BENCH syntheticVineyards records=300 bytes=${raw.toByteArray().size} baselineDecodeMs=$baseline memoDecodeMs=$memo")
    }
}

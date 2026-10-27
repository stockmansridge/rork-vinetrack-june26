package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import com.rork.vinetrack.data.model.SavedChemical
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SavedChemicalDecodeMemoAndroidTest {
    private fun isolated(check: (SavedChemicalLocalStore, android.content.SharedPreferences) -> Unit) {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "chemical_decode_${UUID.randomUUID()}"
        val prefs = base.getSharedPreferences(name, Context.MODE_PRIVATE)
        val names = mutableSetOf(name)
        val context = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(n: String, mode: Int): android.content.SharedPreferences {
                val scoped = if (n == "vinetrack_saved_chemicals_local") name else name + n
                names.add(scoped)
                return base.getSharedPreferences(scoped, mode)
            }
        }
        try { check(SavedChemicalLocalStore(context), prefs) }
        finally {
            names.forEach { base.deleteSharedPreferences(it) }
        }
    }

    @Test fun currentBytesAndAccountVineyardKeysRemainAuthoritative() = isolated { store, prefs ->
        val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
        val serializer = ListSerializer(SavedChemical.serializer())
        fun put(key: String, name: String) {
            check(prefs.edit().putString(key, json.encodeToString(serializer,
                listOf(SavedChemical("chemical", "vineyard-A", name = name)))).commit())
        }
        put("owner-A|vineyard-A", "Before")
        val before = store.load("owner-A", "vineyard-A")
        assertSame(before, store.load("owner-A", "vineyard-A"))
        assertTrue(store.load("owner-B", "vineyard-A").isEmpty())
        assertTrue(store.load("owner-A", "vineyard-B").isEmpty())
        put("owner-A|vineyard-A", "After")
        assertEquals("After", store.load("owner-A", "vineyard-A").single().name)
        check(prefs.edit().putString("owner-A|vineyard-A", "corrupt").commit())
        assertTrue(store.load("owner-A", "vineyard-A").isEmpty())
        check(prefs.edit().remove("owner-A|vineyard-A").commit())
        assertTrue(store.load("owner-A", "vineyard-A").isEmpty())
    }

    @Test fun legacyGeneratedRateIdentityIsNotFrozenByMemoization() = isolated { store, prefs ->
        val raw = """[{"id":"chemical","vineyard_id":"vineyard-A","rates":[{"label":"Legacy","value":1.0}]}]"""
        check(prefs.edit().putString("owner-A|vineyard-A", raw).commit())
        val first = store.load("owner-A", "vineyard-A").single().rates.single().id
        val second = store.load("owner-A", "vineyard-A").single().rates.single().id
        assertNotEquals(first, second)
    }
}

package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Durable, account- and vineyard-scoped Chemical Store snapshot. Not a second write queue. */
interface SavedChemicalLocalStoring {
    fun load(userId: String, vineyardId: String): List<SavedChemical>
    fun save(userId: String, vineyardId: String, rows: List<SavedChemical>): Boolean
}

class SavedChemicalLocalStore(context: Context) : SavedChemicalLocalStoring {
    private val prefs = context.applicationContext.getSharedPreferences("vinetrack_saved_chemicals_local", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(SavedChemical.serializer())

    private fun key(userId: String, vineyardId: String): String = "$userId|$vineyardId"

    override fun load(userId: String, vineyardId: String): List<SavedChemical> {
        val raw = prefs.getString(key(userId, vineyardId), null) ?: return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }

    override fun save(userId: String, vineyardId: String, rows: List<SavedChemical>): Boolean =
        prefs.edit().putString(key(userId, vineyardId), json.encodeToString(serializer, rows)).commit()
}

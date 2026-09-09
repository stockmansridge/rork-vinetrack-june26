package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.ManualSprayPayload
import kotlinx.serialization.json.Json

/** Vineyard-scoped durable form draft, separate from the mutation outbox. */
class ManualSprayDraftStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("vinetrack_manual_spray_drafts_v1", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    fun load(vineyardId: String): ManualSprayPayload? = preferences.getString(vineyardId, null)?.let { encoded -> runCatching { json.decodeFromString<ManualSprayPayload>(encoded) }.getOrNull() }
    fun save(payload: ManualSprayPayload): Boolean = preferences.edit().putString(payload.vineyardId, json.encodeToString(ManualSprayPayload.serializer(), payload)).commit()
    fun clear(vineyardId: String) { preferences.edit().remove(vineyardId).apply() }
}

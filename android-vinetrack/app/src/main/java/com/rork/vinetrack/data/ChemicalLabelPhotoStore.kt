package com.rork.vinetrack.data

import android.content.Context
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Durable metadata; committed before the chemical is handed back to the caller. */
internal interface ChemicalLabelPhotoStoring {
    fun load(): List<ChemicalLabelAttachment>
    fun save(rows: List<ChemicalLabelAttachment>)
}

internal class ChemicalLabelPhotoStore(context: Context) : ChemicalLabelPhotoStoring {
    private val prefs = context.applicationContext.getSharedPreferences("vinetrack_chemical_label_photos", Context.MODE_PRIVATE)
    private val serializer = ListSerializer(ChemicalLabelAttachment.serializer())
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    override fun load(): List<ChemicalLabelAttachment> = prefs.getString("attachments", null)?.let {
        runCatching { json.decodeFromString(serializer, it) }.getOrDefault(emptyList())
    } ?: emptyList()

    override fun save(rows: List<ChemicalLabelAttachment>) {
        check(prefs.edit().putString("attachments", json.encodeToString(serializer, rows)).commit()) {
            "Couldn't persist chemical label photo metadata."
        }
    }
}

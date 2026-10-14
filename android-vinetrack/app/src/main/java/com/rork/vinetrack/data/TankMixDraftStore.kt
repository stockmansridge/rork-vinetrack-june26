package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.FieldStoreAccess
import kotlinx.serialization.json.*

/** Operator text only; never tank/session authority. Retained through Back, restart and uncertain commit. */
class TankMixDraftStore(context: Context) {
    private val preferences = context.getSharedPreferences("actual_tank_mix_drafts_v1", Context.MODE_PRIVATE)
    private val access = FieldStoreAccess(context)
    fun read(owner: String, vineyard: String, trip: String, tank: String): Map<String,String> = access.admittedForOwner(owner) {
        preferences.getString("$owner/$vineyard/$trip/$tank", null)?.let { raw ->
            runCatching { Json.parseToJsonElement(raw).jsonObject.mapValues { it.value.jsonPrimitive.content } }.getOrDefault(emptyMap())
        } ?: emptyMap()
    }
    fun save(owner: String, vineyard: String, trip: String, tank: String, text: Map<String,String>): Boolean = access.admittedForOwner(owner) {
        preferences.edit().putString("$owner/$vineyard/$trip/$tank",JsonObject(text.mapValues { JsonPrimitive(it.value) }).toString()).commit()
    }
}

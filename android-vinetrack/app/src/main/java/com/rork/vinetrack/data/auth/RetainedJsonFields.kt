package com.rork.vinetrack.data.auth

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Read-only compatibility check AFTER production decoding with preservation-aware codecs. New optional
 * model defaults may be present in the encoding but absent in an older snapshot.
 * Every supplied field, array position, type and value must survive; custom
 * serializers must not silently replace malformed rate evidence with an empty list.
 * This does not rewrite storage, confer authorship or acknowledge any operation.
 */
internal object RetainedJsonFields {
    fun preserves(source: JsonElement, encoded: JsonElement): Boolean = when (source) {
        is JsonObject -> encoded is JsonObject && source.all { (key, value) ->
            encoded[key]?.let { preserves(value, it) } == true
        }
        is JsonArray -> encoded is JsonArray && source.size == encoded.size &&
            source.indices.all { preserves(source[it], encoded[it]) }
        is JsonPrimitive -> {
            if (source == encoded) true
            else if (encoded !is JsonPrimitive || source.isString || encoded.isString) false
            else {
                // JSON 1 and 1.0 denote the same number. Decimal comparison must
                // not hide a rounded large integer or a changed chemical quantity.
                val before = source.content.toBigDecimalOrNull()
                val after = encoded.content.toBigDecimalOrNull()
                before != null && after != null && before.compareTo(after) == 0
            }
        }
    }
}

package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.spray.SprayTarget
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*

private fun JsonObject.text(key: String): String? {
    val value = get(key) ?: return null
    if (value == JsonNull) return null
    val primitive = value as? JsonPrimitive ?: throw SerializationException("Invalid chemical text field")
    if (!primitive.isString) throw SerializationException("Invalid chemical text field")
    return primitive.content
}
private fun JsonObject.number(key: String): Double? {
    val value = get(key) ?: return null
    if (value == JsonNull) return null
    return (value as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
        ?: throw SerializationException("Invalid chemical number field")
}
private fun JsonDecoder.requireKnownFields(value: JsonObject, keys: Set<String>) {
    if (!json.configuration.ignoreUnknownKeys && value.keys.any { it !in keys }) {
        throw SerializationException("Unrecognized registered-use field in strict chemical codec")
    }
}
private fun JsonObject.integer(key: String): Int? {
    val value = get(key) ?: return null
    if (value == JsonNull) return null
    return (value as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
        ?: throw SerializationException("Invalid chemical period field")
}
private fun MutableMap<String, JsonElement>.field(key: String, value: JsonElement?) {
    if (value != null) put(key, value)
}

/** Preserves unrecognized rate evidence, without making unsupported bases executable. */
object ChemicalLabelRateSerializer : KSerializer<ChemicalLabelRate> {
    override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor
    private val keys = setOf("label", "condition", "basis", "value", "min_value", "max_value", "unit", "raw_text", "rate_id", "condition_ambiguous")
    override fun deserialize(decoder: Decoder): ChemicalLabelRate {
        val d = decoder as JsonDecoder
        val c = d.decodeJsonElement().jsonObject
        d.requireKnownFields(c, keys)
        val raw = c.text("basis")
        if (!d.json.configuration.ignoreUnknownKeys && raw != null && ChemicalLabelRateBasis.entries.none { it.raw == raw }) {
            throw SerializationException("Unsupported rate basis in strict chemical codec")
        }
        val basis = ChemicalLabelRateBasis.from(raw)
        val ambiguous = c["condition_ambiguous"]?.let { value ->
            if (value == JsonNull) null else (value as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
                ?: throw SerializationException("Invalid rate ambiguity field")
        }
        return ChemicalLabelRate(
            label = c.text("label") ?: "", condition = c.text("condition"),
            basis = basis, value = c.number("value"), minValue = c.number("min_value"), maxValue = c.number("max_value"),
            unit = c.text("unit") ?: "", rawText = c.text("raw_text"), rateId = c.text("rate_id"),
            conditionAmbiguous = ambiguous,
            unknownFields = c.filter { (key, value) -> key !in keys || value == JsonNull },
            unsupportedBasis = raw?.takeIf { token -> ChemicalLabelRateBasis.entries.none { it.raw == token } },
        )
    }
    override fun serialize(encoder: Encoder, value: ChemicalLabelRate) {
        val c = value.unknownFields.toMutableMap()
        c["label"] = JsonPrimitive(value.label)
        c.field("condition", value.condition?.let(::JsonPrimitive))
        c["basis"] = JsonPrimitive(value.unsupportedBasis ?: value.basis.raw)
        c.field("value", value.value?.let(::JsonPrimitive))
        c.field("min_value", value.minValue?.let(::JsonPrimitive))
        c.field("max_value", value.maxValue?.let(::JsonPrimitive))
        c["unit"] = JsonPrimitive(value.unit)
        c.field("raw_text", value.rawText?.let(::JsonPrimitive))
        c.field("rate_id", value.rateId?.let(::JsonPrimitive))
        c.field("condition_ambiguous", value.conditionAmbiguous?.let(::JsonPrimitive))
        (encoder as JsonEncoder).encodeJsonElement(JsonObject(c))
    }
}

/** Unknown registered-use fields survive caches and editing rather than being dropped. */
object ChemicalRegisteredUseSerializer : KSerializer<ChemicalRegisteredUse> {
    override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor
    private val keys = setOf("crop", "target_raw", "target", "rates", "direction_id", "withholding_period_days", "withholding_statement", "re_entry_period_hours", "re_entry_statement", "restrictions", "provenance")
    override fun deserialize(decoder: Decoder): ChemicalRegisteredUse {
        val d = decoder as JsonDecoder
        val c = d.decodeJsonElement().jsonObject
        d.requireKnownFields(c, keys)
        val rawTarget = c.text("target")
        val target = SprayTarget.entries.firstOrNull { it.raw == rawTarget }
        if (!d.json.configuration.ignoreUnknownKeys && rawTarget != null && target == null) {
            throw SerializationException("Unsupported target in strict chemical codec")
        }
        val provenance = c["provenance"]?.takeUnless { it == JsonNull }?.let { d.json.decodeFromJsonElement(ChemicalProvenanceMapSerializer, it) }
        return ChemicalRegisteredUse(
            crop = c.text("crop") ?: "", targetRaw = c.text("target_raw") ?: "",
            target = target,
            rates = c["rates"]?.takeUnless { it == JsonNull }?.let { d.json.decodeFromJsonElement(ListSerializer(ChemicalLabelRate.serializer()), it) } ?: emptyList(),
            directionId = c.text("direction_id"),
            withholdingPeriodDays = c.integer("withholding_period_days"),
            withholdingStatement = c.text("withholding_statement"),
            reEntryPeriodHours = c.integer("re_entry_period_hours"),
            reEntryStatement = c.text("re_entry_statement"), restrictions = c.text("restrictions"),
            provenance = provenance,
            unknownFields = c.filter { (key, value) -> key !in keys || value == JsonNull || (key == "provenance" && provenance == null) || (key == "target" && rawTarget != null && target == null) },
        )
    }
    override fun serialize(encoder: Encoder, value: ChemicalRegisteredUse) {
        val e = encoder as JsonEncoder
        val c = value.unknownFields.toMutableMap()
        c["crop"] = JsonPrimitive(value.crop)
        c["target_raw"] = JsonPrimitive(value.targetRaw)
        c.field("target", value.target?.let { e.json.encodeToJsonElement(SprayTarget.serializer(), it) })
        c["rates"] = e.json.encodeToJsonElement(ListSerializer(ChemicalLabelRate.serializer()), value.rates)
        c.field("direction_id", value.directionId?.let(::JsonPrimitive))
        c.field("withholding_period_days", value.withholdingPeriodDays?.let(::JsonPrimitive))
        c.field("withholding_statement", value.withholdingStatement?.let(::JsonPrimitive))
        c.field("re_entry_period_hours", value.reEntryPeriodHours?.let(::JsonPrimitive))
        c.field("re_entry_statement", value.reEntryStatement?.let(::JsonPrimitive))
        c.field("restrictions", value.restrictions?.let(::JsonPrimitive))
        c.field("provenance", value.provenance?.let { e.json.encodeToJsonElement(MapSerializer(String.serializer(), String.serializer()), it) })
        e.encodeJsonElement(JsonObject(c))
    }
}

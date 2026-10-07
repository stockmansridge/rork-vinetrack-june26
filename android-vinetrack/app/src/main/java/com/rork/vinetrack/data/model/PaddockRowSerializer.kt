package com.rork.vinetrack.data.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*

/** Retains Portal fractional row numbers on wire/cache while leaving integer editors intact. */
object PaddockRowSerializer : KSerializer<PaddockRow> {
    @Serializable
    private data class Payload(
        val id: String? = null,
        val number: Int = 0,
        val decimalNumber: Double? = null,
        val startPoint: CoordinatePoint? = null,
        val endPoint: CoordinatePoint? = null,
        val vineCountOverride: Int? = null,
    )

    override val descriptor: SerialDescriptor = Payload.serializer().descriptor

    override fun deserialize(decoder: Decoder): PaddockRow {
        val input = decoder as JsonDecoder
        val fields = input.decodeJsonElement().jsonObject.toMutableMap()
        val number = fields["number"]?.jsonPrimitive?.doubleOrNull ?: 0.0
        require(number.isFinite() && number >= Int.MIN_VALUE && number <= Int.MAX_VALUE) { "Invalid row number" }
        fields["number"] = JsonPrimitive(number.toInt())
        if (number != number.toInt().toDouble()) {
            fields["decimalNumber"] = JsonPrimitive(number)
        }
        val p = input.json.decodeFromJsonElement(Payload.serializer(), JsonObject(fields))
        return PaddockRow(p.id, p.number, p.decimalNumber, p.startPoint, p.endPoint, p.vineCountOverride)
    }

    override fun serialize(encoder: Encoder, value: PaddockRow) {
        val output = encoder as JsonEncoder
        val p = Payload(value.id, value.number, null, value.startPoint, value.endPoint, value.vineCountOverride)
        val fields = output.json.encodeToJsonElement(Payload.serializer(), p).jsonObject.toMutableMap()
        fields.remove("decimalNumber")
        value.decimalNumber?.let { fields["number"] = JsonPrimitive(it) }
        output.encodeJsonElement(JsonObject(fields))
    }
}

package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.ChemicalRate
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*

/** New catalogue rows store an options object in rates; never reinterpret it as legacy scalar defaults. */
object CatalogueLegacyRatesSerializer : KSerializer<List<ChemicalRate>> {
    private val delegate = ListSerializer(ChemicalRate.serializer())
    override val descriptor: SerialDescriptor = delegate.descriptor
    override fun deserialize(decoder: Decoder): List<ChemicalRate> {
        val jsonDecoder = decoder as? JsonDecoder ?: return delegate.deserialize(decoder)
        val element = jsonDecoder.decodeJsonElement()
        return if (element is JsonArray) runCatching { jsonDecoder.json.decodeFromJsonElement(delegate, element) }.getOrDefault(emptyList()) else emptyList()
    }
    override fun serialize(encoder: Encoder, value: List<ChemicalRate>) = delegate.serialize(encoder, value)
}

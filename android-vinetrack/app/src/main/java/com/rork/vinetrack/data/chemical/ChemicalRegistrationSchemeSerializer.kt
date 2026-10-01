package com.rork.vinetrack.data.chemical

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/** Unknown scheme metadata never makes an international product undecodable. */
object ChemicalRegistrationSchemeSerializer : KSerializer<ChemicalRegistrationScheme> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("ChemicalRegistrationScheme", PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): ChemicalRegistrationScheme =
        ChemicalRegistrationScheme.from(decoder.decodeString()) ?: ChemicalRegistrationScheme.OTHER
    override fun serialize(encoder: Encoder, value: ChemicalRegistrationScheme) = encoder.encodeString(value.raw)
}

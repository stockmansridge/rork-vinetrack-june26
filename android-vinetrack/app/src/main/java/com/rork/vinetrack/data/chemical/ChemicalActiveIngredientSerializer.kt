package com.rork.vinetrack.data.chemical

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*

/** Preserves unsupported concentration-unit wording without widening the executable unit enum. */
object ChemicalActiveIngredientSerializer : KSerializer<ChemicalActiveIngredient> {
    override val descriptor: SerialDescriptor = ChemicalActiveIngredientWire.serializer().descriptor

    override fun deserialize(decoder: Decoder): ChemicalActiveIngredient {
        val d = decoder as JsonDecoder
        val objectValue = d.decodeJsonElement().jsonObject
        val rawValue = objectValue["concentration_unit"]?.takeUnless { it == JsonNull }
        val raw = rawValue?.let {
            val text = it as? JsonPrimitive ?: throw SerializationException("Invalid concentration unit")
            if (!text.isString) throw SerializationException("Invalid concentration unit")
            text.content
        }
        val unit = ChemicalConcentrationUnit.entries.firstOrNull { it.raw == raw }
        val unresolved = raw?.takeIf { unit == null }
        if (unresolved != null && !d.json.configuration.ignoreUnknownKeys) {
            throw SerializationException("Unsupported concentration unit in strict chemical codec")
        }
        val readable = if (unresolved != null) JsonObject(objectValue + ("concentration_unit" to JsonNull)) else objectValue
        val wire = d.json.decodeFromJsonElement(ChemicalActiveIngredientWire.serializer(), readable)
        return ChemicalActiveIngredient(name = wire.name, concentration = wire.concentration, concentrationUnit = wire.concentrationUnit,
            activityGroup = wire.activityGroup, groupSource = wire.groupSource, identitySource = wire.identitySource,
            unresolvedConcentrationUnit = unresolved)
    }

    override fun serialize(encoder: Encoder, value: ChemicalActiveIngredient) {
        val e = encoder as JsonEncoder
        val wire = ChemicalActiveIngredientWire(value.name, value.concentration, value.concentrationUnit,
            value.activityGroup, value.groupSource, value.identitySource)
        val objectValue = e.json.encodeToJsonElement(ChemicalActiveIngredientWire.serializer(), wire).jsonObject
        val output = if (value.concentrationUnit == null && value.unresolvedConcentrationUnit != null)
            JsonObject(objectValue + ("concentration_unit" to JsonPrimitive(value.unresolvedConcentrationUnit))) else objectValue
        e.encodeJsonElement(output)
    }
}

@Serializable
private data class ChemicalActiveIngredientWire(
    val name: String = "",
    val concentration: Double? = null,
    @SerialName("concentration_unit") val concentrationUnit: ChemicalConcentrationUnit? = null,
    @SerialName("activity_group") val activityGroup: ChemicalActivityGroup? = null,
    @SerialName("group_source") val groupSource: ChemicalDataSourceKind? = null,
    @SerialName("identity_source") val identitySource: ChemicalDataSourceKind? = null,
)

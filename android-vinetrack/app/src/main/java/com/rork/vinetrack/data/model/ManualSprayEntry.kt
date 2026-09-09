package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

@Serializable
enum class ManualSprayPhysicalForm { liquid, solid }

@Serializable
data class ManualSprayChemical(
    val id: String = UUID.randomUUID().toString(),
    val savedChemicalId: String,
    val name: String,
    val actualAmountBase: Double,
    val unit: String,
    val productCategory: String,
    val physicalForm: ManualSprayPhysicalForm,
    val snapshotAt: String = Instant.now().toString(),
) {
    val isDimensionCompatible: Boolean
        get() = when (physicalForm) {
            ManualSprayPhysicalForm.liquid -> unit == "Litres" || unit == "mL"
            ManualSprayPhysicalForm.solid -> unit == "Kg" || unit == "g"
        }
}

@Serializable
data class ManualSprayTank(
    val id: String = UUID.randomUUID().toString(),
    val actualId: String = UUID.randomUUID().toString(),
    val tankNumber: Int,
    val waterVolumeLitres: Double,
    val chemicals: List<ManualSprayChemical>,
) {
    fun copied(number: Int): ManualSprayTank = copy(
        id = UUID.randomUUID().toString(),
        actualId = UUID.randomUUID().toString(),
        tankNumber = number,
        chemicals = chemicals.map { it.copy(id = UUID.randomUUID().toString()) },
    )
}

@Serializable
data class ManualSprayBlock(val blockId: String, val blockName: String)

@Serializable
data class ManualSprayWeather(
    val observedAt: String,
    val source: String = "Operator observation",
    val temperatureC: Double? = null,
    val humidityPct: Double? = null,
    val windSpeedKmh: Double? = null,
    val windGustKmh: Double? = null,
    val windDirectionDeg: Double? = null,
    val rainMm: Double? = null,
)

@Serializable
data class ManualSprayPayload(
    val vineyardId: String,
    val manualEntryId: String = UUID.randomUUID().toString(),
    val sprayRecordId: String = UUID.randomUUID().toString(),
    val tripId: String = UUID.randomUUID().toString(),
    val reference: String,
    val operationType: String,
    val startUtc: String,
    val endUtc: String,
    val vineyardTimeZone: String,
    val tractorId: String?,
    val operatorUserId: String?,
    val sprayEquipmentId: String?,
    val startEngineHours: Double? = null,
    val endEngineHours: Double? = null,
    val notes: String? = null,
    val clientUpdatedAt: String = Instant.now().toString(),
    val blocks: List<ManualSprayBlock>,
    val tanks: List<ManualSprayTank>,
    val manualWeather: ManualSprayWeather? = null,
) {
    fun validationError(): String? {
        if (reference.isBlank()) return "Enter a name or reference."
        val start = runCatching { Instant.parse(startUtc) }.getOrNull() ?: return "Enter a valid start time."
        val end = runCatching { Instant.parse(endUtc) }.getOrNull() ?: return "Enter a valid end time."
        if (!end.isAfter(start)) return "End time must be after start time."
        if (tractorId == null) return "Select one tractor."
        if (operatorUserId == null) return "Select one operator."
        if (sprayEquipmentId == null) return "Select one spray unit."
        if (blocks.isEmpty()) return "Select at least one block."
        if (tanks.isEmpty()) return "Add at least one tank."
        if (startEngineHours != null && (!startEngineHours.isFinite() || startEngineHours < 0)) return "Start engine hours are invalid."
        if (endEngineHours != null && (!endEngineHours.isFinite() || endEngineHours < 0)) return "End engine hours are invalid."
        if (startEngineHours != null && endEngineHours != null && endEngineHours < startEngineHours) return "End engine hours cannot be below start."
        if (manualWeather != null && listOf(manualWeather.temperatureC, manualWeather.humidityPct, manualWeather.windSpeedKmh, manualWeather.windGustKmh, manualWeather.windDirectionDeg, manualWeather.rainMm).all { it == null }) return "Enter at least one weather measurement or turn manual weather off."
        if (tanks.map { it.id }.distinct().size != tanks.size || tanks.map { it.tankNumber }.distinct().size != tanks.size) return "Tank identities and numbers must be unique."
        tanks.forEach { tank ->
            if (tank.tankNumber < 1 || !tank.waterVolumeLitres.isFinite() || tank.waterVolumeLitres < 0) return "Tank ${tank.tankNumber} has an invalid water amount."
            if (tank.chemicals.isEmpty()) return "Tank ${tank.tankNumber} needs at least one chemical."
            tank.chemicals.forEach { chemical ->
                if (chemical.name.isBlank() || chemical.productCategory.isBlank() || !chemical.actualAmountBase.isFinite() || chemical.actualAmountBase < 0 || !chemical.isDimensionCompatible) return "Tank ${tank.tankNumber} has an invalid chemical amount, category, form, or unit."
            }
        }
        return null
    }
}

@Serializable
data class ManualSpraySaveResponse(
    val operationId: String,
    val manualEntryId: String,
    val sprayRecordId: String,
    val tripId: String,
    val source: String,
    val status: String,
    val syncVersion: Int,
    val serverConfirmed: Boolean,
)

fun canManageManualSprays(role: String?): Boolean = role?.lowercase() in setOf("owner", "manager", "supervisor")

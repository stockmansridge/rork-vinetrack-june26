package com.rork.vinetrack.data.spray

import kotlinx.serialization.json.Json

/** Lossless By Area setup in existing notes; never a second start or actual-coverage authority. */
object LegacySpraySetup {
    const val MARKER = "\n[VineTrack sprayer setup v1]\n"
    const val END = "\n[/VineTrack sprayer setup]"
    const val FULL_TANK_MESSAGE = "Only Full Tanks requires persisted tank intent, target-area/calibrated-rate specification and frozen planning outputs unavailable in receipt v1. Choose By Area in this draft to continue; your other inputs stay unchanged."
    const val WORK_MESSAGE = "Proposed pass selection requires the new planning contract. Deselect proposed passes in Select Work Area to use this draft with existing tracking; blocks, equipment and mix are retained."
    private val json = Json { ignoreUnknownKeys = false; encodeDefaults = true; explicitNulls = true }

    fun blocker(intent: SprayPlanningIntent?, resolution: SprayPlanningResolution?, cleared: Boolean = false): String? {
        if (intent == null && resolution == null && !cleared) return null
        if (cleared || intent == null) return "Planning evidence is incomplete. Recalculate this draft before starting."
        if (intent.method != SprayPlanningMethod.BY_AREA) return FULL_TANK_MESSAGE
        if (resolution == null) return "Choose a pass configuration and complete the carrier settings in this draft before starting."
        return intent.frozenResolutionBlocker(resolution)
    }
    fun canCarry(fields: SprayPlanningWireFields, cleared: Boolean = false): Boolean =
        fields.intent != null && blocker(fields.intent, fields.resolution(), cleared) == null

    fun notes(notes: String?, fields: SprayPlanningWireFields): String? {
        if (!canCarry(fields)) return notes
        val suffix = MARKER + json.encodeToString(SprayPlanningWireFields.serializer(), fields) + END
        val original = notes.orEmpty()
        return if (fields(original) == fields) original else original + suffix
    }
    fun fields(notes: String?): SprayPlanningWireFields? {
        val text = notes ?: return null
        val index = text.lastIndexOf(MARKER)
        if (index < 0 || !text.endsWith(END)) return null
        return runCatching { json.decodeFromString(SprayPlanningWireFields.serializer(), text.substring(index + MARKER.length, text.length - END.length)) }
            .getOrNull()?.takeIf { canCarry(it) }
    }
}
